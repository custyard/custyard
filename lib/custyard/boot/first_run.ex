defmodule Custyard.Boot.FirstRun do
  @moduledoc """
  The schema, operator and mail steps of a production boot, and the
  `:first_run` / `:ready` decision (docs/backlog/1103-first-run-experience.md).

  ## Schema

  `migrate/2` runs the pending migrations one at a time, so a failure names
  the migration. `Custyard.Application` calls it synchronously, between the
  database probe and starting the supervision tree, on a temporary Repo
  (`Ecto.Migrator.with_repo/2`) rather than through an `Ecto.Migrator` child:
  a migrator child that raises takes the Repo down with it and the tree
  restarts in a loop with nothing to serve, while a failure returned here
  becomes the `:database_unavailable` card with category `:migration_failed`
  and no automatic restart.

  ## Process

  The GenServer starts after the Repo, PubSub and the mailer's HTTP client
  and does its work in `handle_continue/2`, so the rest of the tree keeps
  starting:

    0. the mode leaves `:starting` for `:first_run` or `:ready` by the count
       of operators who can log in. It happens here and not in
       `Custyard.Application` because a request let through now finds the
       Repo and PubSub running, and because `Custyard.Boot.State` is a
       read-modify-write with no lock, so it wants one writer;
    1. the operator from `OPERATOR_EMAIL` is created if absent
       (`Custyard.OperatorAccounts.create_operator/2`, `via: "boot"`); an
       existing account is never modified;
    2. when this boot created it, the welcome mail is sent through the real
       adapter and its provider verdict recorded (`Custyard.Boot.State`
       `:mail` step and `last_mail`);
    3. while no operator can log in, the mode stays `:first_run` and the
       check repeats every `recheck_every_ms` (5 s), so an account added
       with `bin/operator add` flips the mode to `:ready` without a restart.

  A boot that created the operator or waited in `:first_run` records
  `first_run.completed_at`, and `CustyardWeb.Plugs.BootGate` keeps the
  checklist on `GET /` until the next restart. A boot that found its
  operators leaves it nil, so `/` is the landing page.

  Options: `env:` (required), `schema:` (the `migrate/2` result),
  `recheck_every_ms:`, and `deliver:` (a function taking a `Swoosh.Email`,
  default `Custyard.Mailer.deliver/1`).
  """

  use GenServer

  alias Custyard.Boot.{Env, State}
  alias Custyard.Notifications.WelcomeEmail
  alias Custyard.OperatorAccounts

  require Custyard.Log, as: Log

  @recheck_every_ms 5_000

  @type schema :: %{
          total: non_neg_integer,
          applied: non_neg_integer,
          skipped: boolean,
          operators: non_neg_integer
        }

  # ---------------------------------------------------------------------------
  # Schema step

  @doc """
  Applies pending migrations on `repo`, one at a time, and counts what the
  database holds afterwards.

  Returns `{:ok, schema}` with the total number of applied migrations, how
  many this call applied, whether it was skipped (`skip: true`, the
  `SKIP_MIGRATIONS` flag) and how many operators can log in; or
  `{:error, detail, reason}` where `detail` names the failed migration and
  the exception class, never its message, and `reason` is the raw error.

  `start_repo: false` uses the already-running `repo` (tests); the default
  starts and stops a temporary one.
  """
  @spec migrate(module, keyword) :: {:ok, schema} | {:error, String.t(), term}
  def migrate(repo, opts \\ []) do
    skip = Keyword.get(opts, :skip, false)

    if Keyword.get(opts, :start_repo, true) do
      case Ecto.Migrator.with_repo(repo, &do_migrate(&1, skip)) do
        {:ok, result, _started} -> result
        {:error, reason} -> {:error, "the database could not be opened for migrations", reason}
      end
    else
      do_migrate(repo, skip)
    end
  rescue
    error -> {:error, "the database could not be opened for migrations", error}
  catch
    :exit, reason -> {:error, "the database could not be opened for migrations", reason}
  end

  defp do_migrate(repo, skip) do
    pending = for {:down, version, name} <- Ecto.Migrator.migrations(repo), do: {version, name}

    result =
      if skip do
        {:ok, 0}
      else
        Enum.reduce_while(pending, {:ok, 0}, fn {version, name}, {:ok, applied} ->
          try do
            Ecto.Migrator.run(repo, :up, to: version, log: false)
            {:cont, {:ok, applied + 1}}
          rescue
            error -> {:halt, {:error, migration_detail(version, name, error), error}}
          catch
            :exit, reason -> {:halt, {:error, migration_detail(version, name, reason), reason}}
          end
        end)
      end

    case result do
      {:ok, applied} ->
        {:ok,
         %{
           total: length(Ecto.Migrator.migrated_versions(repo)),
           applied: applied,
           skipped: skip,
           operators: count_operators()
         }}

      {:error, _detail, _reason} = error ->
        error
    end
  end

  defp migration_detail(version, name, %{__struct__: module}),
    do: "migration #{version}_#{name} failed (#{inspect(module)})"

  defp migration_detail(version, name, _reason), do: "migration #{version}_#{name} failed"

  # With migrations skipped the table may not exist yet.
  defp count_operators do
    OperatorAccounts.count_can_log_in()
  rescue
    _ -> 0
  end

  @doc "The `:schema` step text for a `migrate/2` result."
  @spec schema_detail(schema) :: String.t()
  def schema_detail(%{skipped: true, total: total}),
    do: "#{total} migrations applied, pending ones skipped (SKIP_MIGRATIONS)"

  def schema_detail(%{total: total, applied: 0}), do: "#{total} migrations applied"

  def schema_detail(%{total: total, applied: applied}),
    do: "#{total} migrations applied, #{applied} new this boot"

  # ---------------------------------------------------------------------------
  # Process

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      env: Keyword.fetch!(opts, :env),
      schema: Keyword.get(opts, :schema),
      created?: false,
      recheck_every_ms: Keyword.get(opts, :recheck_every_ms, @recheck_every_ms),
      deliver: Keyword.get(opts, :deliver, &Custyard.Mailer.deliver/1)
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    if state.schema, do: step(:schema, :ok, schema_detail(state.schema))
    open_gate()

    created = bootstrap_operator(state.env)
    welcome_mail(created, state)
    {:noreply, decide(%{state | created?: created != nil})}
  end

  @impl true
  def handle_info(:recheck, state), do: {:noreply, decide(state)}

  # Step 0 of the moduledoc. Dev, test and a restarted FirstRun are never in
  # :starting and skip this.
  defp open_gate do
    if State.mode() == :starting do
      mode = if count_operators() > 0, do: :ready, else: :first_run
      State.update(&%{&1 | mode: mode})
      Log.info(:boot_mode_decided, boot_mode: mode)
    end
  end

  defp decide(state) do
    if count_operators() > 0 do
      finish(state, State.mode())
    else
      if State.mode() != :first_run do
        State.update(&%{&1 | mode: :first_run})
        Log.info(:boot_mode_decided, boot_mode: :first_run)
      end

      Process.send_after(self(), :recheck, state.recheck_every_ms)
    end

    state
  end

  # Runs once per process: no recheck is scheduled after it. A supervisor
  # restart finds the operator in place and completed_at already set.
  defp finish(state, previous) do
    first_run? = state.created? or previous == :first_run

    State.update(fn s ->
      completed_at = s.first_run.completed_at || if(first_run?, do: DateTime.utc_now())
      %{s | mode: :ready, first_run: %{s.first_run | completed_at: completed_at}}
    end)

    step(:sign_in, :ok, "an operator can sign in")
    if previous != :ready, do: Log.info(:boot_mode_decided, boot_mode: :ready)
    if first_run?, do: Log.info(:boot_first_run_completed)
  end

  # Returns the operator this boot created, or nil.
  defp bootstrap_operator(%Env{settings: %{operator_email: nil}}) do
    step(:operator, :skipped, "OPERATOR_EMAIL is not set")
    nil
  end

  defp bootstrap_operator(%Env{settings: %{operator_email: email}}) do
    case OperatorAccounts.create_operator(email, via: "boot") do
      {:created, operator} ->
        remember_operator(operator)
        step(:operator, :ok, "#{operator.email} (#{operator.role}), from OPERATOR_EMAIL")
        operator

      {:exists, operator} ->
        remember_operator(operator)
        step(:operator, :ok, "exists, not modified")
        nil

      {:error, message} ->
        step(:operator, :failed, message)
        nil
    end
  end

  defp remember_operator(operator) do
    State.update(fn s -> %{s | first_run: %{s.first_run | operator_email: operator.email}} end)
  end

  defp welcome_mail(nil, _state), do: step(:mail, :skipped, "no new operator")

  defp welcome_mail(operator, %{env: %Env{settings: settings}} = state) do
    %{adapter: adapter} = settings.mail

    if adapter == :local do
      step(:mail, :skipped, "MAIL_ADAPTER=local discards mail")
    else
      %{from_name: from_name, from_address: from_address} = settings.notifications
      email = WelcomeEmail.build(operator.email, settings.host, {from_name, from_address})

      email
      |> deliver(state.deliver)
      |> record_mail(adapter)
    end
  end

  defp deliver(email, deliver) do
    deliver.(email)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp record_mail({:ok, _receipt}, adapter) do
    Log.info(:boot_welcome_mail_accepted, provider: adapter)
    step(:mail, :ok, "accepted by #{adapter}")
    last_mail(adapter, :ok, "accepted by #{adapter}")
  end

  defp record_mail({:error, reason}, adapter) do
    {status, message} = provider_error(reason)

    Log.error(
      :boot_welcome_mail_failed,
      [provider: adapter, provider_message: message] ++ Log.failure(reason)
    )

    detail =
      case {status, message} do
        {nil, nil} -> "#{adapter} rejected the message"
        {nil, message} -> "#{adapter} rejected the message (#{message})"
        {status, nil} -> "#{adapter} rejected the message (#{status})"
        {status, message} -> "#{adapter} rejected the message (#{status}: #{message})"
      end

    step(:mail, :failed, detail)
    last_mail(adapter, :error, detail)
  end

  defp last_mail(adapter, status, detail) do
    State.update(fn s ->
      %{
        s
        | last_mail: %{at: DateTime.utc_now(), adapter: adapter, status: status, detail: detail}
      }
    end)
  end

  @doc """
  `{status, message}` from a Swoosh delivery error: API adapters return
  `{:error, {status, body}}`, others an atom, a tuple or an exception. The
  message is bounded and address-free (`Custyard.Log.provider_message/1`).
  """
  @spec provider_error(term) :: {integer | nil, String.t() | nil}
  def provider_error({status, body}) when is_integer(status), do: {status, provider_text(body)}

  def provider_error(reason) when is_atom(reason),
    do: {nil, Log.provider_message(to_string(reason))}

  def provider_error(reason) when is_binary(reason), do: {nil, Log.provider_message(reason)}

  def provider_error(%{__exception__: true} = error),
    do: {nil, Log.provider_message(Exception.message(error))}

  def provider_error(reason), do: {nil, Log.provider_message(inspect(reason))}

  defp provider_text(body) when is_map(body) do
    [
      body["message"],
      nested_message(body["error"]),
      body["error"],
      body["detail"],
      body["errors"]
    ]
    |> Enum.find(&is_binary/1)
    |> case do
      nil -> Log.provider_message(Jason.encode!(body))
      text -> Log.provider_message(text)
    end
  end

  defp provider_text(body) when is_binary(body), do: Log.provider_message(body)
  defp provider_text(body), do: Log.provider_message(inspect(body))

  # `{"error": "Invalid token"}` is as common as `{"error": {"message": ...}}`;
  # get_in/2 would raise on the string.
  defp nested_message(%{} = error), do: error["message"]
  defp nested_message(_other), do: nil

  defp step(key, status, detail) do
    State.put_step(key, status, detail)
    Log.info(:boot_first_run_step, step: key, outcome: step_outcome(status))
  end

  defp step_outcome(:ok), do: :succeeded
  defp step_outcome(:failed), do: :failed
  defp step_outcome(:skipped), do: :skipped
end
