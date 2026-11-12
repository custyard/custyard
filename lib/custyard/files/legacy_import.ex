defmodule Custyard.Files.LegacyImport do
  @moduledoc """
  Copies the files earlier releases kept on disk into the database, once.

  Before `Custyard.Files`, a fetched inbound attachment was a file at
  `<attachment_dir>/<tenant id>/<first two hex chars of its SHA-256>/<SHA-256>`
  and a tenant logo a file at `<upload_dir>/logos/<name>`, both on the data
  volume. A deployment upgraded from such a release still has those files and
  the rows that refer to them: `message_attachments` rows in state `fetched`
  (by tenant and `sha256`) and `tenants.logo_url` (`/uploads/logos/<name>`).

  `run/1` stores every referenced file the database does not hold yet: an
  attachment as the tenant's `:attachment` file keyed by its SHA-256, a logo
  as the tenant's `:logo` file keyed by its name with the extension
  lowercased. Logos go first. Once `pending/1` is zero the import does not
  read the two directories again, and they can go.

  It runs in the background on every boot (`child_spec/1`, added by
  `Custyard.Application`) and on demand as
  `Custyard.Release.import_legacy_files/0`.

  A path is built from the tenant id and the hash, or from a logo name that
  is a valid `Custyard.Files` key, never from a stored path or a display
  filename, so no row can point the import at another file. The file must
  be a regular file (a symlink or a directory is refused) within the size
  an earlier release could have written, and an attachment's content must
  have the SHA-256 it is named by. A file that is not there is counted as
  missing, one that is there but fails a check as failed, and the import
  goes on to the next.

  The import writes, moves and deletes nothing on disk, and attachment rows
  are not touched: a scan verdict stays with its row. A second run finds the
  imported files in the database and reports only what is still missing or
  failing.

  The originals stay until someone deletes the directories, with one
  exception: the daily retention sweep removes an attachment's file once no
  row of its tenant references it
  (`Custyard.Attachments.sweep_legacy_files/1`), so erasure and retention
  still reach what an earlier release wrote. Logos on disk are never removed.

  The logs carry counts only, never a path, key, hash or filename.
  """

  import Ecto.Query

  alias Custyard.Attachments.Scanner
  alias Custyard.{Files, MessageAttachment, Repo, Tenant}
  alias Custyard.Files.StoredFile

  require Custyard.Log, as: Log

  @logo_prefix "/uploads/logos/"
  # The largest logo an earlier release accepted.
  @logo_max_bytes 2_000_000
  @zero %{attachments: 0, logos: 0, missing: 0, failed: 0}

  @typedoc """
  What one run did: files imported by kind, referenced files that are not on
  disk (`missing`) and files that are there but were refused or could not be
  stored (`failed`).
  """
  @type counts :: %{
          attachments: non_neg_integer,
          logos: non_neg_integer,
          missing: non_neg_integer,
          failed: non_neg_integer
        }

  @doc """
  A child that runs `boot/1` once, in a task of its own, so whoever starts
  it does not wait for the import. It is temporary: when the task ends,
  either way, the supervisor neither restarts it nor counts a failure.
  """
  @spec child_spec(keyword) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [__MODULE__, :boot, [opts]]},
      restart: :temporary
    }
  end

  @doc """
  The boot task: `run/1` when anything is pending. Never raises; a run that
  fails is logged as `legacy_file_import_failed` and returns `:error`, and
  the next boot tries again.
  """
  @spec boot(keyword) :: counts | :error
  def boot(opts \\ []) do
    if pending(opts) > 0, do: run(opts), else: @zero
  rescue
    error -> boot_failed(error)
  catch
    kind, reason -> boot_failed({kind, reason})
  end

  @doc """
  How many referenced files are not in the database yet: distinct
  `(tenant, sha256)` of fetched attachment rows without a published
  `:attachment` file, plus tenants whose `logo_url` names a logo without a
  published `:logo` file. Zero means the legacy directories are no longer
  needed.

  It reads the database only. `opts` are accepted so it can be called like
  `run/1`; none are used.
  """
  @spec pending(keyword) :: non_neg_integer
  def pending(_opts \\ []) do
    Repo.aggregate(subquery(pending_attachments()), :count) + length(pending_logos())
  end

  @doc """
  Imports every pending file and returns the counts.

  With nothing pending it returns zero counts without looking at the disk or
  logging. Otherwise it logs one `legacy_file_import_completed` event with
  the counts, as a warning when any file was missing or failed.

  A file that cannot be read or stored is counted and skipped. A database
  error while listing what is pending raises.

  Options: `:attachment_dir` and `:upload_dir` replace the configured
  directories (tests).
  """
  @spec run(keyword) :: counts
  def run(opts \\ []) do
    Log.operation([], fn ->
      attachments =
        Repo.all(from a in pending_attachments(), order_by: [a.tenant_id, a.sha256])

      case {attachments, pending_logos()} do
        {[], []} -> @zero
        {attachments, logos} -> attachments |> import_all(logos, opts) |> report()
      end
    end)
  end

  defp import_all(attachments, logos, opts) do
    attachment_dir = directory(opts, :attachment_dir)
    upload_dir = directory(opts, :upload_dir)

    # Logos first: they are public (portal, sign-in page, email) and answer
    # 404 until they are in, and there is at most one per tenant.
    @zero
    |> tally(logos, :logos, &import_logo(upload_dir, &1))
    |> tally(attachments, :attachments, &import_attachment(attachment_dir, &1))
  end

  defp tally(counts, references, kind, import) do
    Enum.reduce(references, counts, fn reference, counts ->
      counter =
        case attempt(import, reference) do
          :ok -> kind
          outcome -> outcome
        end

      Map.update!(counts, counter, &(&1 + 1))
    end)
  end

  # A database error or anything else unexpected is this file's failure, not
  # the run's: the remaining files are still imported.
  defp attempt(import, reference) do
    import.(reference)
  rescue
    _error -> :failed
  catch
    _kind, _reason -> :failed
  end

  # The hash is checked before it becomes a path, and again against the
  # content: a file renamed or damaged on disk is not stored under a hash it
  # does not have.
  defp import_attachment(dir, %{tenant_id: tenant_id, sha256: sha}) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, sha) do
      relative = [Integer.to_string(tenant_id), binary_part(sha, 0, 2), sha]

      case read_regular(dir, relative, Scanner.max_bytes()) do
        {:ok, bytes} ->
          if sha256(bytes) == sha, do: store(tenant_id, :attachment, sha, bytes), else: :failed

        outcome ->
          outcome
      end
    else
      :failed
    end
  end

  defp import_logo(dir, %{tenant_id: tenant_id, name: name, key: key}) do
    case read_regular(dir, ["logos", name], @logo_max_bytes) do
      {:ok, bytes} -> store(tenant_id, :logo, key, bytes)
      outcome -> outcome
    end
  end

  defp store(tenant_id, kind, key, bytes) do
    case Files.put(tenant_id, kind, key, bytes) do
      {:ok, _file} -> :ok
      {:error, _reason} -> :failed
    end
  end

  # Without a configured directory there is no disk to look on.
  defp read_regular(nil, _relative, _max_bytes), do: :missing

  # lstat, not stat: a symlink is reported as one instead of being followed
  # to whatever it points at. The size is checked before the read, so an
  # oversized file never enters memory, and after it, in case the file grew
  # in between.
  defp read_regular(dir, relative, max_bytes) do
    path = Path.join([dir | relative])

    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= max_bytes ->
        case File.read(path) do
          {:ok, bytes} when byte_size(bytes) <= max_bytes -> {:ok, bytes}
          _unreadable_or_grown -> :failed
        end

      {:ok, _not_a_file_or_too_large} ->
        :failed

      # The file, or a directory above it, is not there.
      {:error, reason} when reason in [:enoent, :enotdir] ->
        :missing

      {:error, _reason} ->
        :failed
    end
  end

  defp directory(opts, key) do
    case Keyword.get_lazy(opts, key, fn -> Application.get_env(:custyard, key) end) do
      dir when is_binary(dir) and dir != "" -> dir
      _unset -> nil
    end
  end

  defp report(counts) do
    fields = [
      imported_attachments: counts.attachments,
      imported_logos: counts.logos,
      missing_files: counts.missing,
      failed_files: counts.failed
    ]

    # Files left behind need someone to look; a clean import does not.
    if counts.missing + counts.failed > 0,
      do: Log.warning(:legacy_file_import_completed, fields),
      else: Log.info(:legacy_file_import_completed, fields)

    counts
  end

  defp boot_failed(reason) do
    Log.error(:legacy_file_import_failed, Log.failure(reason))
    :error
  end

  # One row per distinct content per tenant: several messages can carry the
  # same attachment, and it was one file on disk.
  defp pending_attachments do
    stored =
      from f in StoredFile,
        where:
          f.kind == :attachment and not is_nil(f.completed_at) and
            f.tenant_id == parent_as(:attachment).tenant_id and
            f.key == parent_as(:attachment).sha256,
        select: 1

    from a in MessageAttachment,
      as: :attachment,
      where: a.state == :fetched and not is_nil(a.sha256) and not exists(stored),
      distinct: true,
      select: %{tenant_id: a.tenant_id, sha256: a.sha256}
  end

  # The key needs the extension lowercased, which SQL cannot do to the tail
  # of a string, so the logo references are compared here. There is at most
  # one per tenant.
  defp pending_logos do
    references =
      from(t in Tenant,
        where: like(t.logo_url, ^(@logo_prefix <> "%")),
        order_by: t.id,
        select: {t.id, t.logo_url}
      )
      |> Repo.all()
      |> Enum.flat_map(&logo_reference/1)

    if references == [] do
      []
    else
      stored =
        from(f in StoredFile,
          where: f.kind == :logo and not is_nil(f.completed_at),
          select: {f.tenant_id, f.key}
        )
        |> Repo.all()
        |> MapSet.new()

      Enum.reject(references, &MapSet.member?(stored, {&1.tenant_id, &1.key}))
    end
  end

  # Only a plain name counts: the rule `Custyard.Files` applies to a key
  # admits no path separator and no leading dot, so a `logo_url` with a
  # subdirectory or a traversal names nothing here. `name` is the file as an
  # earlier release wrote it; `key` is what the logo is stored and served
  # under (`CustyardWeb.Uploads.logo_key/1`).
  defp logo_reference({tenant_id, @logo_prefix <> name}) do
    if Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/, name) do
      ext = Path.extname(name)
      key = String.replace_suffix(name, ext, String.downcase(ext, :ascii))
      [%{tenant_id: tenant_id, name: name, key: key}]
    else
      []
    end
  end

  # SQL LIKE ignores ASCII case, so a prefix in another case gets this far.
  defp logo_reference({_tenant_id, _other}), do: []

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
end
