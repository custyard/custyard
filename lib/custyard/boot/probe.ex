defmodule Custyard.Boot.Probe do
  @moduledoc """
  Can the configured database be reached, and what is known about it?

  Used at boot by `Custyard.Application` before the Repo starts, by
  `Custyard.Boot.Monitor` while the app sits in the database doctor mode, and
  by `bin/doctor` (`Custyard.Release.doctor_cli/1`). `run/1` needs nothing
  started: it opens one connection with the same driver module the Repo's
  pool would use (`Exqlite.Connection` for a file, `Custyard.Turso.Connection`
  for libSQL), runs `SELECT 1` and closes it. Going through the driver rather
  than a temporary Repo is what makes the error classifiable: a pool reports
  every connect failure as a generic `DBConnection.ConnectionError` and logs
  the real reason, which the privacy logger then discards.

  A failure is one of `Custyard.Boot.State.database_category/0` with a short
  sentence that names no host, token, path or raw error. The raw exception is
  returned by `check/2` for the CLI, which may print it to the operator's
  terminal, and is classified (never rendered) in the `boot_database_probe_failed`
  log event.

  Before the connection, `Custyard.Storage.check/1` runs for the selected
  storage provider (Fly or Bunny): on Fly a missing volume must be reported
  before SQLite creates an empty database on the container filesystem, and
  Bunny hosting refuses any database but its remote one before a local file
  is opened. The Bunny refusal is the category `:bunny_database_required`:
  no volume is involved, and the fix is the database setting. Its other
  problems become `:volume_missing`. Either way the detail is the storage
  check's own sentence.
  """

  alias Custyard.Boot.{Env, State}
  alias Custyard.{InstanceAdmins, Repo, Storage}

  require Custyard.Log, as: Log

  @connect_timeout 10_000
  @turso_timeout 15_000

  @type category :: State.database_category()

  @doc """
  Probes the database in `env` and records the outcome in
  `Custyard.Boot.State`. Options are passed to `check/2`.
  """
  @spec run(Env.t(), keyword) :: :ok | {:error, category, String.t()}
  def run(%Env{} = env, opts \\ []) do
    result = check(env, opts)
    record(env, result, opts)

    case result do
      :ok -> :ok
      {:error, category, detail, _raw} -> {:error, category, detail}
    end
  end

  @doc """
  `run/2` without touching the state, and with the raw error as a fourth
  element (an exception, or `nil` when there is none).

  Options: `storage: keyword` is passed to `Custyard.Storage.check/1`
  (tests pass `fly_app_name: nil`); `facts: false` skips the facts in
  `run/2`.
  """
  @spec check(Env.t(), keyword) :: :ok | {:error, category, String.t(), Exception.t() | nil}
  def check(%Env{} = env, opts \\ []) do
    with :ok <- volume(env, opts) do
      connect(env.settings[:database], env.settings)
    end
  end

  @doc """
  What is known about the database without connecting (`kind`, `path`,
  `mounted?`, `file_exists?`), plus `migrations` and `instance_admins` when the
  application Repo is running and answers.
  """
  @spec facts(Env.t()) :: map
  def facts(%Env{} = env) do
    base =
      case env.settings[:database] do
        {:sqlite, path} ->
          %{
            kind: :sqlite,
            path: path,
            mounted?: Storage.mounted?(path),
            file_exists?: File.exists?(path)
          }

        {:turso, _url, _token} ->
          %{kind: :turso}

        {:postgres, _url} ->
          %{kind: :postgres}

        nil ->
          %{kind: nil}
      end

    Map.merge(base, repo_facts())
  end

  @doc """
  The `Custyard.Repo` configuration for the database in `env`, as
  `config/runtime.exs` writes it.
  """
  @spec repo_config(Env.t()) :: keyword
  def repo_config(%Env{settings: settings}) do
    pool = [pool_size: settings[:pool_size] || 10]

    case settings[:database] do
      {:sqlite, path} -> [database: path, journal_mode: :wal, busy_timeout: 5000] ++ pool
      {:turso, url, token} -> turso_config(url, token, settings) ++ pool
      {:postgres, url} -> [url: url] ++ pool
      nil -> pool
    end
  end

  @doc """
  The category for a driver error, from its class and message. Exposed for
  the unit tests; `check/2` applies it.
  """
  @spec categorize(term) :: category
  def categorize(%Exqlite.Error{message: message}), do: sqlite_category(message)
  def categorize(%DBConnection.ConnectionError{message: message}), do: transport_category(message)
  def categorize(%{__struct__: Mint.TransportError}), do: :unreachable
  def categorize(%{__struct__: Mint.HTTPError}), do: :unreachable
  def categorize(%{__exception__: true} = error), do: transport_category(Exception.message(error))
  def categorize(message) when is_binary(message), do: transport_category(message)
  def categorize(_other), do: :unknown

  @doc "The sentence shown for a category; names nothing from the environment."
  @spec detail(category) :: String.t()
  def detail(:unreachable),
    do: "the database host did not answer; check the URL's host and port and network egress"

  def detail(:auth_rejected),
    do:
      "the database rejected the credentials; check that TURSO_AUTH_TOKEN (or " <>
        "BUNNY_DATABASE_AUTH_TOKEN) was created for the database in the configured URL"

  def detail(:not_writable),
    do:
      "the SQLite file cannot be opened for writing; check DATABASE_PATH, the volume mount " <>
        "and ownership (uid custyard)"

  def detail(:locked), do: "the SQLite file is locked by another process"

  def detail(:migration_failed),
    do: "a database migration failed; the migration is named in the container log"

  def detail(:volume_missing), do: "the data volume is not mounted at /data"

  def detail(:bunny_database_required),
    do:
      "Bunny hosting keeps no local files, so the database must be Bunny Database; " <>
        "set BUNNY_DATABASE_URL and BUNNY_DATABASE_AUTH_TOKEN"

  def detail(:unknown),
    do:
      "the database connection failed for a reason the probe does not classify; " <>
        "the error class is in the container log"

  # ---------------------------------------------------------------------------

  defp volume(env, opts) do
    storage_opts = Keyword.merge([repo_config: repo_config(env)], Keyword.get(opts, :storage, []))

    case Storage.check(storage_opts) do
      :ok ->
        :ok

      {:error, :bunny_database_required, detail} ->
        {:error, :bunny_database_required, String.trim(detail), nil}

      {:error, _problem, detail} ->
        {:error, :volume_missing, String.trim(detail), nil}
    end
  end

  # Hrana v3 for Turso, v2 for Bunny Database (Custyard.Turso.Connection).
  defp turso_config(url, token, settings) do
    [turso_url: url, turso_auth_token: token, turso_provider: settings[:turso_provider] || :turso]
  end

  defp connect(nil, _settings) do
    {:error, :unknown, "no database is configured; see the configuration report", nil}
  end

  defp connect({:sqlite, path}, _settings) do
    opts = [database: path, journal_mode: :wal, busy_timeout: 5000]

    case Exqlite.Connection.connect(opts) do
      {:ok, %{db: db}} ->
        result = Exqlite.Sqlite3.execute(db, "SELECT 1")
        Exqlite.Sqlite3.close(db)

        case result do
          :ok -> :ok
          {:error, reason} -> failure(%Exqlite.Error{message: to_string(reason)})
        end

      {:error, error} ->
        failure(error)
    end
  end

  defp connect({:turso, url, token}, settings) do
    # `bin/doctor` runs under `bin/custyard eval`, where no application has been
    # started; Mint needs :ssl for the HTTPS connection. A no-op in the app.
    {:ok, _} = Application.ensure_all_started(:ssl)

    opts =
      turso_config(url, token, settings) ++
        [connect_timeout: @connect_timeout, timeout: @turso_timeout]

    # connect/1 already runs SELECT 1, so a wrong URL or token fails here.
    case Custyard.Turso.Connection.connect(opts) do
      {:ok, state} ->
        Custyard.Turso.Connection.disconnect(nil, state)
        :ok

      {:error, error} ->
        failure(error)
    end
  rescue
    error -> failure(error)
  end

  defp connect({:postgres, url}, _settings) do
    if Application.get_env(:custyard, :repo_adapter, Custyard.Repo.Adapter) ==
         Ecto.Adapters.Postgres do
      postgres(url)
    else
      {:error, :unknown,
       "this image is built for SQLite/libSQL; unset the postgres:// DATABASE_URL to use " <>
         "the SQLite file, or set a libsql:// URL", nil}
    end
  end

  # The Postgres build is not the deployed image; a short-lived dynamic Repo
  # is enough to tell reachable from not.
  defp postgres(url) do
    case Repo.start_link(name: nil, url: url, pool_size: 1, queue_target: 1_000) do
      {:ok, pid} ->
        previous = Repo.put_dynamic_repo(pid)

        try do
          case Repo.query("SELECT 1", [], timeout: @connect_timeout) do
            {:ok, _} -> :ok
            {:error, error} -> failure(error)
          end
        rescue
          error -> failure(error)
        after
          Repo.put_dynamic_repo(previous)
          Supervisor.stop(pid)
        end

      {:error, reason} ->
        failure(reason)
    end
  end

  defp failure(error) do
    category = categorize(error)
    {:error, category, detail(category), if(is_exception(error), do: error, else: nil)}
  end

  # Linux SQLite reports a parent that is not a directory as eexist; macOS as enotdir.
  @posix_not_writable ~w(eacces erofs enotdir eexist enoent eperm eisdir enospc eio)

  defp sqlite_category(message) do
    text = String.downcase(message)

    cond do
      String.contains?(text, ["locked", "busy"]) ->
        :locked

      text in @posix_not_writable or
          String.contains?(text, ["unable to open", "readonly", "read-only", "permission"]) ->
        :not_writable

      true ->
        :unknown
    end
  end

  defp transport_category(message) do
    text = String.downcase(message)

    cond do
      String.contains?(text, ["http 401", "http 403", "unauthorized", "forbidden", "auth"]) ->
        :auth_rejected

      String.contains?(text, [
        "cannot connect",
        "domain",
        "refused",
        "timeout",
        "timed out",
        "tls",
        "ssl",
        "closed",
        "unreachable",
        "nxdomain"
      ]) ->
        :unreachable

      String.contains?(text, ["locked", "busy"]) ->
        :locked

      String.contains?(text, ["unable to open", "readonly", "permission"]) ->
        :not_writable

      true ->
        :unknown
    end
  end

  defp record(env, result, opts) do
    facts = if Keyword.get(opts, :facts, true), do: facts(env), else: %{}

    State.update(fn state ->
      database = %{
        state.database
        | attempts: state.database.attempts + 1,
          last_attempt_at: DateTime.utc_now(),
          facts: facts
      }

      database =
        case result do
          :ok ->
            %{database | status: :ok, category: nil, detail: nil}

          {:error, category, detail, raw} ->
            Log.error(
              :boot_database_probe_failed,
              [database_category: category, attempt: database.attempts] ++ Log.failure(raw)
            )

            %{database | status: :error, category: category, detail: detail}
        end

      %{state | database: database}
    end)
  end

  defp repo_facts do
    if Process.whereis(Repo) do
      %{
        migrations: length(Ecto.Migrator.migrated_versions(Repo)),
        instance_admins: InstanceAdmins.count()
      }
    else
      %{}
    end
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end
end
