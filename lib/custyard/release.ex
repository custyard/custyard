defmodule Custyard.Release do
  @moduledoc """
  Release tasks run with `bin/custyard eval`: migrations, the operator
  bootstrap the container entrypoint runs before the server, the
  `bin/operator` and `bin/dsar` command lines (`rel/overlays/bin/operator`,
  `rel/overlays/bin/dsar`; the latter's commands are `Custyard.Release.Dsar`),
  and the SQLite export for moving the database to Turso.

  None of these start the application. They load its configuration and start
  only the Repo (`Ecto.Migrator.with_repo/2`), so they are safe to run on a
  machine whose server is already up, and they never start the endpoint,
  mail pollers or background workers.
  """

  alias Custyard.{OperatorAccount, OperatorAccounts, Repo}
  alias Custyard.Repo.Adapter
  alias Custyard.Release.Dsar

  require Custyard.Log, as: Log

  @app :custyard

  @operator_usage """
  Usage: bin/operator COMMAND

  Commands:
    add EMAIL [--role super_admin|admin|agent] [--organization ID]
        Create an operator (default role super_admin; admin and agent need
        --organization). An existing account is reported and never modified.
    list
        Show every operator: id, email, role, organization id, created at.
    remove EMAIL
        Delete an operator. Refuses to remove the last super_admin.
    help
        Show this help.

  Emails are case-insensitive. Operators log in with a link emailed to them;
  there are no passwords.
  """

  def migrate do
    startup_task(:migrate, fn ->
      load_app()
      Custyard.Storage.validate_fly_storage!()

      for repo <- repos() do
        case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true)) do
          {:ok, _, _} = result -> result
          {:error, reason} -> throw({:custyard_release_failure, reason})
        end
      end
    end)
  end

  def rollback(repo, version) do
    startup_task(:rollback, fn ->
      load_app()
      Custyard.Storage.validate_fly_storage!()

      case Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version)) do
        {:ok, _, _} = result -> result
        {:error, reason} -> throw({:custyard_release_failure, reason})
      end
    end)
  end

  @doc """
  Copies the local SQLite database into one file for
  `turso db create --from-file`, next to the database unless `path` says
  otherwise, and returns its path.

  The copy is a consistent snapshot (`VACUUM INTO`); writes after it are not
  in it, so stop the app first (`MAINTENANCE_MODE`, docs/ops/database.md).
  Run it as `custyard`: even read-only, SQLite creates the database's `-wal`
  and `-shm` files when they are missing, and root-owned ones would leave
  the app unable to write the file if you go back to it.

      fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.export_sqlite()'"
  """
  def export_sqlite(path \\ nil) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:exqlite)

    config = Application.get_env(@app, Repo, [])

    if Adapter.turso?(config) or !config[:database],
      do:
        raise("the database is not a local SQLite file (DATABASE_URL is set); nothing to export")

    source = config[:database]

    path = path || Path.join(Path.dirname(source), "turso-import.db")
    if File.exists?(path), do: raise("#{path} already exists; move it aside first")

    {:ok, db} = Exqlite.Sqlite3.open(source, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(db, "VACUUM INTO ?1")
      :ok = Exqlite.Sqlite3.bind(statement, [path])
      :done = Exqlite.Sqlite3.step(db, statement)
    after
      Exqlite.Sqlite3.close(db)
    end

    # Turso's import takes a database in WAL mode; the mode is stored in the
    # file.
    {:ok, copy} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(copy, "PRAGMA journal_mode = WAL")
    :ok = Exqlite.Sqlite3.close(copy)

    IO.puts("Exported #{source} to #{path}")
    path
  end

  @doc """
  Creates an operator unless one with this email already exists, which is
  reported and left unmodified. Raises on invalid input.

  Kept for shell history; `bin/operator add` is the supported command.

  Starts only the Repo, not the application: on a running machine the
  Endpoint already holds the HTTP port, so starting the application from
  `bin/custyard eval` would fail binding a second listener.

  ## Examples

      Custyard.Release.setup_operator("ops@example.com")
      Custyard.Release.setup_operator("agent@example.com", role: "agent", organization_id: 3)
  """
  def setup_operator(email, opts \\ []) when is_binary(email) do
    opts = opts |> Keyword.take([:role, :organization_id]) |> Keyword.put(:via, "cli")

    case with_repo(fn -> OperatorAccounts.create_operator(email, opts) end) do
      {:created, operator} = created ->
        IO.puts(created_line(operator))
        created

      {:exists, operator} = exists ->
        IO.puts(exists_line(operator))
        exists

      {:error, message} ->
        raise ArgumentError, "could not create operator: #{message}"
    end
  end

  @doc """
  Boot-time operator bootstrap. `entrypoint.sh` runs it after `migrate/0`,
  in the same eval, before the server starts.

  `OPERATOR_EMAIL` set: creates that super_admin if absent, or reports it
  unmodified. Unset (or blank): logs how to create the first operator.
  An invalid value emits a bounded diagnostic and fixed failure notice,
  then halts with status 1 so the boot fails before starting the server.
  """
  def bootstrap_operator do
    startup_task(:bootstrap, fn ->
      case bootstrap_operator(System.get_env("OPERATOR_EMAIL")) do
        :ok -> :ok
        {:error, reason} -> startup_failed!(:bootstrap, reason)
      end
    end)
  end

  @doc false
  # The testable half of bootstrap_operator/0: takes the variable's value
  # and returns instead of halting.
  def bootstrap_operator(env_value) do
    with_repo(fn ->
      result = env_value |> blank_to_nil() |> bootstrap_from_env()
      if result == :ok, do: warn_about_placeholder()
      result
    end)
  end

  defp bootstrap_from_env(nil) do
    if Repo.aggregate(OperatorAccount, :count) == 0 do
      Log.warning(:operator_bootstrap_required, reason: :no_operator_accounts)
    else
      Log.info(:operator_bootstrap_skipped, reason: :not_configured)
    end

    :ok
  end

  defp bootstrap_from_env(email) do
    result =
      case OperatorAccounts.create_operator(email, via: "boot") do
        {:created, _operator} ->
          :ok

        {:exists, operator} ->
          Log.info(:operator_bootstrap_account_exists,
            operator_id: operator.id,
            role: operator.role
          )

          :ok

        {:error, _message} = error ->
          error
      end

    if result == :ok do
      Log.warning(:operator_bootstrap_environment_retained)
    end

    result
  end

  defp warn_about_placeholder do
    placeholder = OperatorAccounts.placeholder_email()

    case OperatorAccounts.get_by_email(placeholder) do
      %OperatorAccount{role: "super_admin", id: id} ->
        Log.warning(:operator_placeholder_unroutable, operator_id: id)

      _ ->
        :ok
    end
  end

  @doc """
  Entry point for `rel/overlays/bin/operator`; `argv` arrives from
  `System.argv()`, never interpolated into code. Halts with the exit status
  (0 on success, 1 on a usage error or failure). Run `bin/operator help`.
  """
  def operator_cli(argv) do
    argv |> run_operator_cli() |> System.halt()
  end

  @doc """
  Entry point for `rel/overlays/bin/dsar`: data subject export and erasure
  (`Custyard.Release.Dsar`). `argv` arrives from `System.argv()`, never
  interpolated into code. Halts with the exit status (0 on success, 1 on a
  usage error, a refused erasure or a failure). Run `bin/dsar help`.
  """
  def dsar_cli(argv) do
    argv |> Dsar.run() |> System.halt()
  end

  @doc false
  # Does the work of operator_cli/1, printing to stdout and stderr, and
  # returns the exit status instead of halting.
  def run_operator_cli(argv) when is_list(argv) do
    case parse_operator_argv(argv) do
      :help ->
        IO.write(@operator_usage)
        0

      :usage ->
        IO.write(:stderr, @operator_usage)
        1

      command ->
        case with_repo(fn -> operator_command(command) end) do
          {:ok, lines} ->
            Enum.each(lines, &IO.puts/1)
            0

          {:error, message} ->
            IO.puts(:stderr, "Error: #{message}")
            1
        end
    end
  end

  defp parse_operator_argv(["help"]), do: :help

  # :keep so a repeated switch is seen and refused; by default OptionParser
  # silently keeps the last value, and `--role agent --role super_admin`
  # must not quietly mean one of them. The values are checked here too: an
  # empty --role would otherwise become the super_admin default, and an
  # organization id beyond 64 bits makes the SQLite driver raise.
  defp parse_operator_argv(["add" | args]) do
    case OptionParser.parse(args,
           strict: [role: [:string, :keep], organization: [:integer, :keep]]
         ) do
      {opts, [email], []} ->
        if Keyword.keys(opts) == Enum.uniq(Keyword.keys(opts)) and
             Enum.all?(opts, &valid_add_opt?/1),
           do: {:add, email, add_opts(opts)},
           else: :usage

      _ ->
        :usage
    end
  end

  defp parse_operator_argv(["list" | args]) do
    if OptionParser.parse(args, strict: []) == {[], [], []}, do: :list, else: :usage
  end

  defp parse_operator_argv(["remove" | args]) do
    case OptionParser.parse(args, strict: []) do
      {[], [email], []} -> {:remove, email}
      _ -> :usage
    end
  end

  defp parse_operator_argv(_argv), do: :usage

  defp valid_add_opt?({:role, role}), do: role in OperatorAccount.roles()
  defp valid_add_opt?({:organization, id}), do: OperatorAccounts.valid_id?(id)

  defp add_opts(opts) do
    Enum.map(opts, fn
      {:role, role} -> {:role, role}
      {:organization, id} -> {:organization_id, id}
    end)
  end

  defp operator_command({:add, email, opts}) do
    case OperatorAccounts.create_operator(email, [via: "cli"] ++ opts) do
      {:created, operator} -> {:ok, [created_line(operator)]}
      {:exists, operator} -> {:ok, [exists_line(operator)]}
      {:error, _message} = error -> error
    end
  end

  defp operator_command(:list) do
    case OperatorAccounts.list_operators() do
      [] -> {:ok, ["No operator accounts. Create one with: bin/operator add EMAIL"]}
      operators -> {:ok, operator_table(operators)}
    end
  end

  defp operator_command({:remove, email}) do
    case OperatorAccounts.remove_operator(email, via: "cli") do
      {:ok, %{operator: operator, soft_deleted_message_ids: message_ids}} ->
        cleared =
          if message_ids == [],
            do: [],
            else: [
              "Cleared the deleted-by operator on #{length(message_ids)} soft-deleted " <>
                "message(s); their ids are kept in the operator_removed audit event."
            ]

        {:ok,
         ["Removed operator #{operator.id}: #{operator.email} (#{role_label(operator)})"] ++
           cleared}

      {:error, _message} = error ->
        error
    end
  end

  defp created_line(operator) do
    "Created operator #{operator.id}: #{operator.email} (#{role_label(operator)}). " <>
      "They log in at /operator/login with a link sent to that address."
  end

  defp exists_line(operator),
    do: "#{operator.email} exists (role #{operator.role}), not modified"

  defp role_label(%OperatorAccount{organization_id: nil, role: role}), do: role

  defp role_label(%OperatorAccount{organization_id: id, role: role}),
    do: "#{role}, organization #{id}"

  defp operator_table(operators) do
    header = ["ID", "EMAIL", "ROLE", "ORGANIZATION", "CREATED", "NOTES"]

    rows =
      Enum.map(operators, fn operator ->
        [
          Integer.to_string(operator.id),
          printable(operator.email),
          operator.role,
          if(operator.organization_id,
            do: Integer.to_string(operator.organization_id),
            else: "-"
          ),
          DateTime.to_iso8601(operator.inserted_at),
          operator |> operator_notes() |> Enum.join("; ")
        ]
      end)

    widths =
      Enum.reduce([header | rows], List.duplicate(0, length(header)), fn row, widths ->
        Enum.zip_with(row, widths, &max(String.length(&1), &2))
      end)

    Enum.map([header | rows], fn row ->
      row
      |> Enum.zip_with(widths, &String.pad_trailing/2)
      |> Enum.join("  ")
      |> String.trim_trailing()
    end)
  end

  defp operator_notes(operator) do
    placeholder = OperatorAccounts.placeholder_email()

    [
      operator.email == placeholder &&
        "non-routable address, cannot log in: add your own super_admin, then " <>
          "bin/operator remove #{placeholder}",
      operator.email != OperatorAccount.normalize_email(operator.email) &&
        "email not normalized, cannot log in: remove it with its exact email",
      OperatorAccount.orphaned?(operator) &&
        "no organization (deleted?), cannot log in: remove it and add it again with --organization"
    ]
    |> Enum.filter(&is_binary/1)
  end

  # Stored emails are printed to a terminal: escape control and format
  # characters (ESC sequences, bidi overrides) instead of passing them through.
  defp printable(text) do
    if String.valid?(text) do
      String.replace(text, ~r/\p{C}/u, fn char ->
        "\\u{" <> (char |> String.to_charlist() |> hd() |> Integer.to_string(16)) <> "}"
      end)
    else
      inspect(text)
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  @doc false
  # Loads config and starts only the Repo for `fun`. Never starts the app.
  # The storage check runs before the Repo starts, as migrate/0 does: opening
  # SQLite first would create an empty database on the container's root
  # filesystem when the Fly volume is missing. Shared with Custyard.Release.Dsar.
  def with_repo(fun) when is_function(fun, 0) do
    load_app()
    Custyard.Storage.validate_fly_storage!()

    case Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end) do
      {:ok, result, _started} ->
        result

      {:error, reason} ->
        Log.error(:release_repository_start_failed, Log.failure(reason))
        {:error, "could not start the database; see structured diagnostics"}
    end
  end

  # The eval runner prints uncaught exceptions directly to stderr. Do not let
  # dependency exception messages, arguments or exit reasons reach that path.
  defp startup_task(task, fun) do
    fun.()
  rescue
    error -> startup_failed!(task, error)
  catch
    :throw, {:custyard_release_failure, reason} -> startup_failed!(task, reason)
    _kind, reason -> startup_failed!(task, reason)
  end

  defp startup_failed!(:migrate, reason) do
    Log.error(:release_migration_failed, Log.failure(reason))
    raise "Database migration failed; see structured diagnostics"
  end

  defp startup_failed!(:rollback, reason) do
    Log.error(:release_rollback_failed, Log.failure(reason))
    raise "Database rollback failed; see structured diagnostics"
  end

  defp startup_failed!(:bootstrap, reason) do
    Log.error(:operator_bootstrap_failed, bootstrap_failure_fields(reason))
    Logger.flush()
    IO.puts(:stderr, "OPERATOR_EMAIL: operator bootstrap failed; see structured diagnostics")
    System.halt(1)
  end

  defp bootstrap_failure_fields(reason) when is_binary(reason) do
    fields =
      for field <- ~w(email role organization_id tenant_id source),
          String.starts_with?(reason, field <> ": ") or
            String.contains?(reason, "; " <> field <> ": "),
          do: field

    if fields == [],
      do: Log.failure(reason),
      else: [reason: :validation_failed, validation_fields: fields]
  end

  defp bootstrap_failure_fields(reason), do: Log.failure(reason)

  defp load_app do
    Application.load(@app)
    # Release eval/CLI tasks deliberately do not start Custyard.Application.
    # Install privacy before storage validation, Repo startup or migrations can
    # emit dependency errors containing credentials or query values.
    Custyard.Log.install!()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
