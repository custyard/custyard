defmodule Custyard.Files.LegacyImportTest do
  # Sequential: the log capture is a global handler, the file-call tests set
  # global trace patterns, and the supervised task reads through the shared
  # sandbox connection.
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.Attachments.Scanner
  alias Custyard.Files
  alias Custyard.Files.{Chunk, LegacyImport, StoredFile}
  alias Custyard.{MessageAttachment, Tenant}

  @moduletag :tmp_dir
  # A run that leaves files behind logs a warning; show it only on failure.
  @moduletag capture_log: true

  @zero %{attachments: 0, logos: 0, missing: 0, failed: 0}
  @png <<137, 80, 78, 71, 13, 10, 26, 10, "logo">>

  setup %{tmp_dir: tmp_dir} do
    dirs = [
      attachment_dir: Path.join(tmp_dir, "attachments"),
      upload_dir: Path.join(tmp_dir, "uploads")
    ]

    File.mkdir_p!(dirs[:attachment_dir])
    File.mkdir_p!(Path.join(dirs[:upload_dir], "logos"))

    %{dirs: dirs, tenant: insert_tenant()}
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp file_sha256(path) do
    path
    |> File.stream!(1_048_576)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  # Where an earlier release kept a tenant's attachment with this hash.
  defp attachment_path(dirs, tenant, sha) do
    Path.join([dirs[:attachment_dir], Integer.to_string(tenant.id), binary_part(sha, 0, 2), sha])
  end

  defp logo_path(dirs, name), do: Path.join([dirs[:upload_dir], "logos", name])

  defp write!(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
    path
  end

  # A fetched attachment row as an earlier release left it, on a message of
  # its own in the tenant. No storage_path: the import must not need it.
  defp fetched_row(tenant, sha, attrs \\ []) do
    organization = insert_organization(tenant_id: tenant.id)
    thread = insert_thread(organization_id: organization.id)
    message = insert_message(thread_id: thread.id)

    Repo.insert!(
      struct!(
        %MessageAttachment{
          tenant_id: tenant.id,
          message_id: message.id,
          position: 0,
          state: :fetched,
          sha256: sha,
          size: 1,
          filename: "quarterly-report.pdf",
          content_type: "application/pdf",
          scan_status: :clean
        },
        attrs
      )
    )
  end

  # The file on disk and the row that refers to it. Returns the hash.
  defp legacy_attachment(dirs, tenant, bytes) do
    sha = sha256(bytes)
    write!(attachment_path(dirs, tenant, sha), bytes)
    fetched_row(tenant, sha)
    sha
  end

  # Past the changeset, as a row written by any earlier release may be.
  defp set_logo_url(tenant, logo_url) do
    Repo.update_all(from(t in Tenant, where: t.id == ^tenant.id), set: [logo_url: logo_url])
  end

  # The file on disk and the tenant's logo_url. Returns the file name.
  defp legacy_logo(dirs, tenant, bytes, ext \\ ".png") do
    name = Ecto.UUID.generate() <> ext
    write!(logo_path(dirs, name), bytes)
    set_logo_url(tenant, "/uploads/logos/" <> name)
    name
  end

  defp stored(tenant, kind, key) do
    assert %StoredFile{} = file = Files.get(tenant.id, kind, key)
    assert {:ok, bytes} = Files.read(file)
    bytes
  end

  defp stored_files, do: Repo.aggregate(StoredFile, :count)

  # Every entry below `dir` with its type, size, mode, modification time and
  # content. A symlink is listed as a link, not followed.
  defp listing(dir) do
    dir
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(dir, name)
      stat = File.lstat!(path, time: :posix)
      entry = {path, stat.type, stat.size, stat.mode, stat.mtime, content(path, stat.type)}

      if stat.type == :directory, do: [entry | listing(path)], else: [entry]
    end)
  end

  defp content(path, :regular), do: file_sha256(path)
  defp content(path, :symlink), do: File.read_link!(path)
  defp content(_path, _type), do: nil

  # The import's own log records, as JSON, at the level production logs at.
  defp with_import_log(fun) do
    previous = Logger.get_module_level(LegacyImport)
    Logger.put_module_level(LegacyImport, :info)

    try do
      {result, records} = Custyard.LogCapture.with_json(fun)
      {result, Enum.filter(records, &String.starts_with?(&1["event"], "legacy_file_import"))}
    after
      Logger.delete_module_level(LegacyImport)
      Enum.each(previous, fn {module, level} -> Logger.put_module_level(module, level) end)
    end
  end

  # Runs `fun` in a process of its own and returns its result with every
  # call that process, or one it spawned, made to :file or :prim_file, which
  # is where File and Path end up. The caller should have run the same code
  # once already, so that loading a module is not among them.
  defp with_file_calls(fun) do
    test = self()

    pid =
      spawn_link(fn ->
        receive do
          :go -> send(test, {:result, fun.()})
        end

        receive do
          :done -> :ok
        end
      end)

    patterns = [{:file, :_, :_}, {:prim_file, :_, :_}]
    Enum.each(patterns, &:erlang.trace_pattern(&1, true, []))
    :erlang.trace(pid, true, [:call, :set_on_spawn])

    try do
      send(pid, :go)
      assert_receive {:result, result}, 30_000
      ref = :erlang.trace_delivered(pid)
      assert_receive {:trace_delivered, ^pid, ^ref}, 5_000
      {result, file_calls([])}
    after
      Enum.each(patterns, &:erlang.trace_pattern(&1, false, []))
      send(pid, :done)
    end
  end

  defp file_calls(calls) do
    receive do
      {:trace, _pid, :call, {module, function, args}} ->
        file_calls([{module, function, length(args)} | calls])
    after
      0 -> Enum.reverse(calls)
    end
  end

  describe "run/1" do
    test "imports attachments and logos byte for byte under their tenants", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      other = insert_tenant()
      small = "%PDF-1.4 a small attachment"
      large = :crypto.strong_rand_bytes(2 * Files.chunk_bytes() + 17)

      small_sha = legacy_attachment(dirs, tenant, small)
      large_sha = legacy_attachment(dirs, other, large)
      logo = legacy_logo(dirs, tenant, @png)

      assert LegacyImport.pending() == 3
      before = listing(tmp_dir)

      assert LegacyImport.run(dirs) == %{attachments: 2, logos: 1, missing: 0, failed: 0}

      assert LegacyImport.pending() == 0
      assert listing(tmp_dir) == before

      assert stored(tenant, :attachment, small_sha) == small
      assert stored(other, :attachment, large_sha) == large
      assert stored(tenant, :logo, logo) == @png

      assert Files.get(other.id, :attachment, small_sha) == nil
      assert Files.get(tenant.id, :attachment, large_sha) == nil
      assert Files.get(other.id, :logo, logo) == nil
      assert stored_files() == 3
    end

    # A logo is public and answers 404 until it is in the database, so it
    # does not wait for the attachments.
    test "every logo is in the database before the first attachment is stored", %{
      dirs: dirs,
      tenant: tenant
    } do
      other = insert_tenant()
      shas = for n <- 1..2, do: legacy_attachment(dirs, tenant, "attachment #{n}")
      logos = for tenant <- [tenant, other], do: {tenant, legacy_logo(dirs, tenant, @png)}

      # Created inside the test's transaction and rolled back with it.
      Repo.query!("""
      CREATE TRIGGER logos_first BEFORE INSERT ON stored_files
      WHEN NEW.kind = 'attachment' AND
        (SELECT COUNT(*) FROM stored_files WHERE kind = 'logo' AND completed_at IS NOT NULL) < 2
      BEGIN SELECT RAISE(ABORT, 'an attachment before a logo'); END
      """)

      assert LegacyImport.run(dirs) == %{attachments: 2, logos: 2, missing: 0, failed: 0}

      for {tenant, logo} <- logos, do: assert(stored(tenant, :logo, logo) == @png)
      for sha <- shas, do: assert(Files.get(tenant.id, :attachment, sha))
    end

    test "a second run imports nothing and reports the same missing files", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      sha = legacy_attachment(dirs, tenant, "kept on disk")
      fetched_row(tenant, sha256("lost before the upgrade"))
      logo = legacy_logo(dirs, tenant, @png)
      before = listing(tmp_dir)

      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 1, missing: 1, failed: 0}
      imported = {stored_files(), Repo.aggregate(Chunk, :count)}

      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 0, missing: 1, failed: 0}
      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 0, missing: 1, failed: 0}

      assert {stored_files(), Repo.aggregate(Chunk, :count)} == imported
      assert LegacyImport.pending() == 1
      assert listing(tmp_dir) == before
      assert stored(tenant, :attachment, sha) == "kept on disk"
      assert stored(tenant, :logo, logo) == @png
    end

    test "files that are not on disk are missing and the rest are imported", %{
      dirs: dirs,
      tenant: tenant
    } do
      other = insert_tenant()
      sha = legacy_attachment(dirs, tenant, "still here")
      lost = sha256("lost attachment")
      fetched_row(tenant, lost)
      set_logo_url(tenant, "/uploads/logos/#{Ecto.UUID.generate()}.png")
      logo = legacy_logo(dirs, other, @png)

      assert LegacyImport.pending() == 4
      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 1, missing: 2, failed: 0}
      assert LegacyImport.pending() == 2

      assert stored(tenant, :attachment, sha) == "still here"
      assert stored(other, :logo, logo) == @png
      assert Files.get(tenant.id, :attachment, lost) == nil
      assert stored_files() == 2
    end

    test "directories that do not exist make every file missing", %{
      tmp_dir: tmp_dir,
      tenant: tenant
    } do
      fetched_row(tenant, sha256("volume already removed"))
      set_logo_url(tenant, "/uploads/logos/#{Ecto.UUID.generate()}.png")
      gone = Path.join(tmp_dir, "removed")

      assert LegacyImport.run(attachment_dir: gone, upload_dir: gone) ==
               %{attachments: 0, logos: 0, missing: 2, failed: 0}

      assert LegacyImport.run(attachment_dir: nil, upload_dir: "") ==
               %{attachments: 0, logos: 0, missing: 2, failed: 0}

      refute File.exists?(gone)
      assert stored_files() == 0
    end

    test "several rows for one content of a tenant are one file", %{dirs: dirs, tenant: tenant} do
      sha = legacy_attachment(dirs, tenant, "forwarded three times")
      fetched_row(tenant, sha)
      fetched_row(tenant, sha)

      assert LegacyImport.pending() == 1
      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 0}
      assert stored_files() == 1
    end

    test "the same content under two tenants is a file for each, read from its own directory", %{
      dirs: dirs,
      tenant: tenant
    } do
      other = insert_tenant()
      bystander = insert_tenant()
      bytes = "the same newsletter attachment"
      sha = legacy_attachment(dirs, tenant, bytes)
      assert legacy_attachment(dirs, other, bytes) == sha
      # Referenced by a third tenant whose own copy is gone.
      fetched_row(bystander, sha)

      assert LegacyImport.pending() == 3
      assert LegacyImport.run(dirs) == %{attachments: 2, logos: 0, missing: 1, failed: 0}

      mine = Files.get(tenant.id, :attachment, sha)
      theirs = Files.get(other.id, :attachment, sha)
      assert mine.id != theirs.id
      assert Files.read(mine) == {:ok, bytes}
      assert Files.read(theirs) == {:ok, bytes}
      assert Files.get(bystander.id, :attachment, sha) == nil
    end

    test "a logo is stored under its name with the extension lowercased", %{
      dirs: dirs,
      tenant: tenant
    } do
      name = legacy_logo(dirs, tenant, @png, ".PNG")
      key = String.replace_suffix(name, ".PNG", ".png")

      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 1, missing: 0, failed: 0}

      assert stored(tenant, :logo, key) == @png
      assert Files.get(tenant.id, :logo, name) == nil
      assert LegacyImport.pending() == 0
    end

    test "content that does not have the hash it is named by is failed", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      sha = sha256("what the row refers to")
      write!(attachment_path(dirs, tenant, sha), "something else")
      fetched_row(tenant, sha)
      good = legacy_attachment(dirs, tenant, "intact")
      before = listing(tmp_dir)

      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 1}
      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 0, missing: 0, failed: 1}

      assert Files.get(tenant.id, :attachment, sha) == nil
      assert stored(tenant, :attachment, good) == "intact"
      assert stored_files() == 1
      assert LegacyImport.pending() == 1
      assert listing(tmp_dir) == before
    end

    test "a hash that is not a lowercase SHA-256 never becomes a path", %{
      dirs: dirs,
      tenant: tenant
    } do
      fetched_row(tenant, "../../outside")
      fetched_row(tenant, String.duplicate("A", 64))
      failed = %{attachments: 0, logos: 0, missing: 0, failed: 2}

      assert LegacyImport.run(dirs) == failed
      assert {^failed, []} = with_file_calls(fn -> LegacyImport.run(dirs) end)
      assert stored_files() == 0
    end

    # The file is sparse and has the hash its row names, so only the size
    # bound keeps it out.
    @tag timeout: 180_000
    test "an attachment over the size bound is failed", %{dirs: dirs, tenant: tenant} do
      path = Path.join(dirs[:attachment_dir], "oversized")
      {:ok, device} = :file.open(path, [:write, :raw, :binary])
      :ok = :file.pwrite(device, Scanner.max_bytes(), "x")
      :ok = :file.close(device)
      assert File.stat!(path).size == Scanner.max_bytes() + 1

      sha = file_sha256(path)
      File.mkdir_p!(Path.dirname(attachment_path(dirs, tenant, sha)))
      File.rename!(path, attachment_path(dirs, tenant, sha))
      fetched_row(tenant, sha)
      good = legacy_attachment(dirs, tenant, "within the bound")

      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 1}

      assert Files.get(tenant.id, :attachment, sha) == nil
      assert stored(tenant, :attachment, good) == "within the bound"
      assert stored_files() == 1
    end

    test "a logo over the size bound is failed and one at the bound is imported", %{
      dirs: dirs,
      tenant: tenant
    } do
      other = insert_tenant()
      at_bound = :binary.copy(<<7>>, 2_000_000)
      kept = legacy_logo(dirs, tenant, at_bound)
      refused = legacy_logo(dirs, other, at_bound <> <<7>>)

      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 1, missing: 0, failed: 1}

      assert stored(tenant, :logo, kept) == at_bound
      assert Files.get(other.id, :logo, refused) == nil
      assert stored_files() == 1
    end

    test "a symlink in place of a file is failed, whatever it points at", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      bytes = "the right content, in the wrong place"
      sha = sha256(bytes)
      target = write!(Path.join([tmp_dir, "elsewhere", sha]), bytes)
      File.mkdir_p!(Path.dirname(attachment_path(dirs, tenant, sha)))
      File.ln_s!(target, attachment_path(dirs, tenant, sha))
      fetched_row(tenant, sha)

      name = Ecto.UUID.generate() <> ".png"
      logo_target = write!(Path.join([tmp_dir, "elsewhere", "logo.png"]), @png)
      File.ln_s!(logo_target, logo_path(dirs, name))
      set_logo_url(tenant, "/uploads/logos/" <> name)

      before = listing(tmp_dir)

      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 0, missing: 0, failed: 2}

      assert stored_files() == 0
      assert LegacyImport.pending() == 2
      assert listing(tmp_dir) == before
    end

    test "a directory in place of a file is failed", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      sha = sha256("a directory took its place")
      File.mkdir_p!(attachment_path(dirs, tenant, sha))
      fetched_row(tenant, sha)

      name = Ecto.UUID.generate() <> ".png"
      File.mkdir_p!(logo_path(dirs, name))
      set_logo_url(tenant, "/uploads/logos/" <> name)

      before = listing(tmp_dir)

      assert LegacyImport.run(dirs) == %{attachments: 0, logos: 0, missing: 0, failed: 2}

      assert stored_files() == 0
      assert listing(tmp_dir) == before
    end

    test "a logo_url that is not a plain name under /uploads/logos/ is ignored", %{dirs: dirs} do
      # Each of these has a file where a naive join would look for it.
      write!(Path.join(dirs[:upload_dir], "secret.png"), @png)
      write!(logo_path(dirs, "nested/logo.png"), @png)
      write!(logo_path(dirs, ".hidden.png"), @png)
      write!(logo_path(dirs, "logo.png"), @png)
      write!(Path.join(dirs[:upload_dir], "other/logo.png"), @png)

      for logo_url <- [
            "/uploads/logos/../secret.png",
            "/uploads/logos/..%2Fsecret.png",
            "/uploads/logos/%2e%2e/secret.png",
            "/uploads/logos/nested/logo.png",
            "/uploads/logos/nested\\logo.png",
            "/uploads/logos//logo.png",
            "/uploads/logos/.hidden.png",
            "/uploads/logos/",
            "/uploads/other/logo.png",
            "/UPLOADS/LOGOS/logo.png",
            "uploads/logos/logo.png",
            "https://cdn.example/uploads/logos/logo.png"
          ] do
        set_logo_url(insert_tenant(), logo_url)
      end

      assert LegacyImport.pending() == 0
      assert LegacyImport.run(dirs) == @zero
      assert stored_files() == 0
    end

    test "rows that are not fetched and files already stored are not pending", %{
      dirs: dirs,
      tenant: tenant
    } do
      for state <- [:pending, :skipped, :failed] do
        sha = legacy_attachment(dirs, tenant, "never finished: #{state}")

        Repo.update_all(from(a in MessageAttachment, where: a.sha256 == ^sha),
          set: [state: state]
        )
      end

      fetched_row(tenant, nil)

      # Stored by the current release: no file on disk, nothing to import.
      {:ok, _file} =
        Files.put(tenant.id, :attachment, sha256("stored directly"), "stored directly")

      fetched_row(tenant, sha256("stored directly"))
      key = Ecto.UUID.generate() <> ".png"
      {:ok, _file} = Files.put(tenant.id, :logo, key, @png)
      set_logo_url(tenant, "/uploads/logos/" <> key)

      assert LegacyImport.pending() == 0
      assert LegacyImport.run(dirs) == @zero
      assert stored_files() == 2
    end

    test "a file whose writer never published it is still pending", %{dirs: dirs, tenant: tenant} do
      sha = legacy_attachment(dirs, tenant, "interrupted upload")

      Repo.insert!(%StoredFile{
        tenant_id: tenant.id,
        kind: :attachment,
        key: sha,
        sha256: sha,
        size: 18,
        chunk_count: 1
      })

      assert LegacyImport.pending() == 1
      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 0}
      assert stored(tenant, :attachment, sha) == "interrupted upload"
    end

    test "attachment rows keep their scan state", %{dirs: dirs, tenant: tenant} do
      for status <- [:clean, :pending, :infected, :error] do
        sha = legacy_attachment(dirs, tenant, "scanned: #{status}")

        Repo.update_all(from(a in MessageAttachment, where: a.sha256 == ^sha),
          set: [scan_status: status, updated_at: ~U[2026-10-01 00:00:00Z]]
        )
      end

      rows = Repo.all(from a in MessageAttachment, order_by: a.id)

      assert LegacyImport.run(dirs) == %{attachments: 4, logos: 0, missing: 0, failed: 0}

      assert Repo.all(from a in MessageAttachment, order_by: a.id) == rows
      assert Enum.map(rows, & &1.scan_status) == [:clean, :pending, :infected, :error]
    end

    test "a file the database refuses is failed and the rest are imported", %{
      dirs: dirs,
      tenant: tenant
    } do
      shas = for n <- 1..3, do: legacy_attachment(dirs, tenant, "attachment #{n}")
      [first, refused, last] = Enum.sort(shas)
      logo = legacy_logo(dirs, tenant, @png)

      # Created inside the test's transaction and rolled back with it.
      Repo.query!("""
      CREATE TRIGGER refuse_one_file BEFORE INSERT ON stored_files
      WHEN NEW.key = '#{refused}'
      BEGIN SELECT RAISE(ABORT, 'file refused'); END
      """)

      assert LegacyImport.run(dirs) == %{attachments: 2, logos: 1, missing: 0, failed: 1}

      assert Files.get(tenant.id, :attachment, first)
      assert Files.get(tenant.id, :attachment, last)
      assert Files.get(tenant.id, :attachment, refused) == nil
      assert stored(tenant, :logo, logo) == @png

      Repo.query!("DROP TRIGGER refuse_one_file")
      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 0}
      assert LegacyImport.pending() == 0
    end
  end

  describe "logging" do
    test "one event with the counts and nothing that names a file", %{
      tmp_dir: tmp_dir,
      dirs: dirs,
      tenant: tenant
    } do
      imported = legacy_attachment(dirs, tenant, "imported")
      lost = sha256("lost")
      fetched_row(tenant, lost)
      damaged = sha256("damaged")
      write!(attachment_path(dirs, tenant, damaged), "not what the row refers to")
      fetched_row(tenant, damaged)
      logo = legacy_logo(dirs, tenant, @png)

      {counts, records} = with_import_log(fn -> LegacyImport.run(dirs) end)

      assert counts == %{attachments: 1, logos: 1, missing: 1, failed: 1}
      assert [record] = records
      assert record["event"] == "legacy_file_import_completed"
      assert record["level"] == "warning"
      assert record["imported_attachments"] == 1
      assert record["imported_logos"] == 1
      assert record["missing_files"] == 1
      assert record["failed_files"] == 1

      json = Jason.encode!(record)

      for private <- [tmp_dir, imported, lost, damaged, logo, "quarterly-report", ".png"] do
        refute json =~ private
      end

      # Beyond the envelope every record has, the counts are all there is.
      envelope =
        ~w(code_location event level operation_id origin schema_version service timestamp)

      assert Map.drop(record, envelope) == %{
               "imported_attachments" => 1,
               "imported_logos" => 1,
               "missing_files" => 1,
               "failed_files" => 1
             }
    end

    test "a run with nothing left behind is logged as info", %{dirs: dirs, tenant: tenant} do
      legacy_attachment(dirs, tenant, "imported")

      {_counts, records} = with_import_log(fn -> LegacyImport.run(dirs) end)

      assert [%{"level" => "info", "imported_attachments" => 1, "imported_logos" => 0} = record] =
               records

      assert record["missing_files"] == 0
      assert record["failed_files"] == 0
    end

    test "nothing is logged when there was nothing to do", %{dirs: dirs, tenant: tenant} do
      legacy_attachment(dirs, tenant, "imported")
      assert LegacyImport.run(dirs).attachments == 1

      assert {@zero, []} = with_import_log(fn -> LegacyImport.run(dirs) end)
      assert {@zero, []} = with_import_log(fn -> LegacyImport.boot(dirs) end)
    end
  end

  describe "the filesystem" do
    test "is not touched when nothing is pending", %{tmp_dir: tmp_dir, dirs: dirs, tenant: tenant} do
      legacy_attachment(dirs, tenant, "already imported")
      legacy_logo(dirs, tenant, @png)
      assert LegacyImport.run(dirs) == %{attachments: 1, logos: 1, missing: 0, failed: 0}

      nowhere = Path.join(tmp_dir, "does-not-exist")
      opts = [attachment_dir: nowhere, upload_dir: nowhere]

      # The first call of a function can load a module, which reads its file
      # in the calling process. Run both once before watching them.
      LegacyImport.run(opts)
      LegacyImport.boot(opts)

      assert {@zero, []} = with_file_calls(fn -> LegacyImport.run(opts) end)
      assert {@zero, []} = with_file_calls(fn -> LegacyImport.boot(opts) end)
      refute File.exists?(nowhere)
    end

    test "is not touched by pending/1, and is by a run with something pending", %{
      dirs: dirs,
      tenant: tenant
    } do
      legacy_attachment(dirs, tenant, "waiting")
      legacy_logo(dirs, tenant, @png)
      assert LegacyImport.pending(dirs) == 2

      assert {2, []} = with_file_calls(fn -> LegacyImport.pending(dirs) end)

      # The same probe sees the import read: an empty list above means no
      # file call was made, not that none could be seen.
      assert {%{attachments: 1, logos: 1}, calls} =
               with_file_calls(fn -> LegacyImport.run(dirs) end)

      assert {:file, :read_link_info, 2} in calls
      assert {:file, :read_file, 1} in calls
    end
  end

  describe "boot/1" do
    test "imports what is pending and returns the counts", %{dirs: dirs, tenant: tenant} do
      sha = legacy_attachment(dirs, tenant, "imported at boot")

      assert LegacyImport.boot(dirs) == %{attachments: 1, logos: 0, missing: 0, failed: 0}
      assert stored(tenant, :attachment, sha) == "imported at boot"
      assert LegacyImport.boot(dirs) == @zero
    end

    test "logs a failed run instead of raising", %{dirs: dirs} do
      # A Repo that is not running, as when the database goes away.
      previous = Repo.put_dynamic_repo(:custyard_legacy_import_test_no_repo)

      {result, records} =
        try do
          with_import_log(fn -> LegacyImport.boot(dirs) end)
        after
          Repo.put_dynamic_repo(previous)
        end

      assert result == :error
      assert [%{"event" => "legacy_file_import_failed", "level" => "error"} = record] = records
      assert record["reason"] == "exception"
      assert record["error_type"] == "Elixir.RuntimeError"
    end
  end

  describe "child_spec/1" do
    test "is a temporary task" do
      assert %{id: LegacyImport, restart: :temporary, start: {Task, :start_link, _args}} =
               Supervisor.child_spec({LegacyImport, []}, [])
    end

    test "runs the import once without the caller waiting on it", %{dirs: dirs, tenant: tenant} do
      sha = legacy_attachment(dirs, tenant, "imported in the background")

      pid = start_supervised!({LegacyImport, dirs})
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 10_000
      assert reason in [:normal, :noproc]

      assert stored(tenant, :attachment, sha) == "imported in the background"
      assert LegacyImport.pending() == 0
    end
  end
end
