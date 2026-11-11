defmodule Custyard.Boot.State do
  @moduledoc """
  The boot verdict and what has happened since, shared between the
  application (which writes it) and the web layer (which renders it).

  Stored in `:persistent_term` because it is written a handful of times per
  boot and read on every request while the app is in a doctor or first-run
  mode. The default is `:ready`, so code paths that never set a state (tests,
  `bin/custyard eval`) behave as a fully booted application.

  Modes, in boot order (docs/backlog/1103-first-run-experience.md):

    * `:unconfigured` — `Custyard.Boot.Env` found problems; only the endpoint
      runs and every page is the doctor card.
    * `:starting` — configuration is complete; the endpoint is up and serving
      liveness while the database is probed and migrations run.
    * `:database_unavailable` — configuration is complete but the database
      probe failed; the endpoint serves the database card while
      `Custyard.Boot.Monitor` retries.
    * `:first_run` — the app is fully up on a database with no instance administrator who
      can log in; `/` shows the setup checklist, everything else is normal.
    * `:ready` — normal operation.
  """

  alias Custyard.Boot.Env

  @key {__MODULE__, :state}
  @retry_every_ms 10_000

  @type mode :: :unconfigured | :starting | :database_unavailable | :first_run | :ready

  @type database_category ::
          :unreachable
          | :auth_rejected
          | :not_writable
          | :locked
          | :migration_failed
          | :volume_missing
          | :unknown

  @typedoc """
  What the probe learned. `facts` holds whatever is known without values:
  `:kind` (`:sqlite | :turso | :postgres`), `:path` (SQLite only),
  `:mounted?` (whether `/data` is a mount), `:file_exists?`, `:migrations`
  (count applied) and `:instance_admins` (count that exist).
  """
  @type database :: %{
          status: :unknown | :ok | :error,
          category: database_category | nil,
          detail: String.t() | nil,
          attempts: non_neg_integer,
          last_attempt_at: DateTime.t() | nil,
          retry_every_ms: pos_integer,
          facts: map
        }

  @type step_key :: :schema | :instance_admin | :mail | :sign_in
  @type step_status :: :pending | :running | :ok | :failed | :skipped

  @type step :: %{key: step_key, status: step_status, detail: String.t() | nil}

  @type first_run :: %{
          steps: [step],
          instance_admin_email: String.t() | nil,
          completed_at: DateTime.t() | nil
        }

  @typedoc "Outcome of the most recent outbound mail attempt, for /admin/system."
  @type mail_result :: %{
          at: DateTime.t(),
          adapter: atom,
          status: :ok | :error,
          detail: String.t() | nil
        }

  @type t :: %__MODULE__{
          mode: mode,
          env: Env.t() | nil,
          booted_at: DateTime.t() | nil,
          database: database,
          first_run: first_run,
          last_mail: mail_result | nil
        }

  defstruct mode: :ready,
            env: nil,
            booted_at: nil,
            database: %{
              status: :unknown,
              category: nil,
              detail: nil,
              attempts: 0,
              last_attempt_at: nil,
              retry_every_ms: @retry_every_ms,
              facts: %{}
            },
            first_run: %{
              steps: [
                %{key: :schema, status: :pending, detail: nil},
                %{key: :instance_admin, status: :pending, detail: nil},
                %{key: :mail, status: :pending, detail: nil},
                %{key: :sign_in, status: :pending, detail: nil}
              ],
              instance_admin_email: nil,
              completed_at: nil
            },
            last_mail: nil

  @spec get() :: t
  def get, do: :persistent_term.get(@key, %__MODULE__{})

  @spec put(t) :: :ok
  def put(%__MODULE__{} = state), do: :persistent_term.put(@key, state)

  @spec update((t -> t)) :: t
  def update(fun) when is_function(fun, 1) do
    state = fun.(get())
    put(state)
    state
  end

  @spec mode() :: mode
  def mode, do: get().mode

  @doc "True while the endpoint should serve a doctor card instead of the app."
  @spec doctor?() :: boolean
  def doctor?, do: mode() in [:unconfigured, :starting, :database_unavailable]

  @doc "Sets one first-run step; unknown keys are appended."
  @spec put_step(step_key, step_status, String.t() | nil) :: t
  def put_step(key, status, detail \\ nil) do
    update(fn state ->
      steps = state.first_run.steps

      steps =
        if Enum.any?(steps, &(&1.key == key)),
          do:
            Enum.map(steps, fn
              %{key: ^key} = step -> %{step | status: status, detail: detail}
              step -> step
            end),
          else: steps ++ [%{key: key, status: status, detail: detail}]

      %{state | first_run: %{state.first_run | steps: steps}}
    end)
  end

  @doc false
  # Tests: forget everything so the next read is the default.
  def reset, do: :persistent_term.erase(@key)
end
