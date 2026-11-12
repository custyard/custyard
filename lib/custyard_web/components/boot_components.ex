defmodule CustyardWeb.BootComponents do
  @moduledoc """
  Function components and formatting helpers shared by the doctor cards
  (`CustyardWeb.BootHTML`) and `/admin/system`.

  Everything here renders from a `Custyard.Boot.State`; nothing touches the
  Repo, the session or the request, so the doctor cards can be served before
  `Plug.Session` while the database is down. Names only, never values: the
  state's `env` carries variable names and shapes, and every string from it
  is HTML-escaped on output.
  """

  use Phoenix.Component

  alias Custyard.Boot.{Build, Env, State}

  @step_labels %{
    schema: "Database schema",
    instance_admin: "Instance administrator",
    mail: "Outbound mail",
    sign_in: "Sign in"
  }

  @step_glyphs %{ok: "✓", pending: "○", running: "◌", failed: "✗", skipped: "–"}

  @category_labels %{
    unreachable: "cannot connect",
    auth_rejected: "authentication rejected",
    not_writable: "database path is not writable",
    locked: "database file is locked",
    migration_failed: "a migration failed",
    volume_missing: "no volume mounted at /data",
    bunny_database_required: "Bunny hosting requires Bunny Database",
    unknown: "connection failed"
  }

  @category_checks %{
    unreachable: [
      "DATABASE_URL has the right host and port",
      "the container has network egress to the database"
    ],
    auth_rejected: [
      "TURSO_AUTH_TOKEN was created for this database",
      "DATABASE_URL is the URL from `turso db show --url`"
    ],
    not_writable: [
      "DATABASE_PATH points into a writable directory",
      "the volume is mounted at /data",
      "the directory is owned by the custyard user"
    ],
    locked: [
      "another process holds the database file; stop it or wait for it to finish",
      "only one container runs against this file"
    ],
    migration_failed: [
      "the container log has the migration name and the error",
      "fix the migration or the data it trips over, then restart the container"
    ],
    volume_missing: [
      "create a volume and mount it at /data",
      "DATABASE_PATH is under the mounted volume"
    ],
    bunny_database_required: [
      "BUNNY_DATABASE_URL and BUNNY_DATABASE_AUTH_TOKEN are set to this app's Bunny Database",
      "DATABASE_PROVIDER is unset or `bunny`; a SQLite file or another remote database is refused",
      "STORAGE_PROVIDER is `bunny` only when the container runs on Bunny hosting"
    ],
    unknown: ["the container log has the full error"]
  }

  @doc """
  The ground-truth block every card and the system page carry: image,
  boot time, visible environment (names only), near misses, and the
  resolved database with whatever the probe learned.
  """
  attr :state, State, required: true
  attr :id, :string, default: "boot-ground-truth"

  def ground_truth(assigns) do
    assigns = assign(assigns, :env, assigns.state.env)

    ~H"""
    <dl
      id={@id}
      class="grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1 font-mono text-xs text-zinc-600 dark:text-zinc-400"
      data-testid="boot-ground-truth"
    >
      <dt class="text-zinc-500">Image</dt>
      <dd>{image_line()}</dd>
      <dt class="text-zinc-500">Booted</dt>
      <dd>{format_time(@state.booted_at)}</dd>
      <dt :if={@env} class="text-zinc-500">Environment</dt>
      <dd :if={@env} class="break-words">{environment_summary(@env)}</dd>
      <dt :if={@env} class="text-zinc-500">Near misses</dt>
      <dd :if={@env}>{near_misses(@env)}</dd>
      <dt class="text-zinc-500">Database</dt>
      <dd class="break-words">{database_line(@state)}</dd>
    </dl>
    """
  end

  @doc "One first-run step: glyph, label, detail."
  attr :step, :map, required: true

  def step_glyph(assigns) do
    ~H"""
    <span class={["w-4 shrink-0 font-mono", glyph_class(@step.status)]} aria-hidden="true">
      {glyph(@step.status)}
    </span>
    <span class="sr-only">{@step.status}</span>
    """
  end

  defp glyph(status), do: Map.get(@step_glyphs, status, "?")

  defp glyph_class(:ok), do: "text-green-600 dark:text-green-400"
  defp glyph_class(:failed), do: "text-red-600 dark:text-red-400"
  defp glyph_class(:running), do: "text-indigo-600 dark:text-indigo-400"
  defp glyph_class(_), do: "text-zinc-400"

  @doc "Human label for a first-run step key."
  @spec step_label(atom) :: String.t()
  def step_label(key) do
    Map.get_lazy(@step_labels, key, fn ->
      key |> to_string() |> String.replace("_", " ") |> String.capitalize()
    end)
  end

  @doc "Humanized database failure category."
  @spec category_label(State.database_category() | nil) :: String.t()
  def category_label(category), do: Map.get(@category_labels, category, @category_labels.unknown)

  @doc "What to check for a database failure category."
  @spec category_checks(State.database_category() | nil) :: [String.t()]
  def category_checks(category), do: Map.get(@category_checks, category, @category_checks.unknown)

  @doc "`custyard 0.9.3 · git 7f3a2c1 · built 2026-11-03T14:02:00Z`"
  @spec image_line() :: String.t()
  def image_line do
    build = Build.describe()
    "custyard #{build.version} · git #{build.git_sha} · built #{build.built_at}"
  end

  @doc "UTC timestamp, or `unknown`."
  @spec format_time(DateTime.t() | nil) :: String.t()
  def format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  def format_time(_), do: "unknown"

  @doc "Whole seconds between `dt` and now, never negative."
  @spec seconds_ago(DateTime.t(), DateTime.t()) :: non_neg_integer
  def seconds_ago(%DateTime{} = dt, now \\ DateTime.utc_now()) do
    max(DateTime.diff(now, dt, :second), 0)
  end

  @doc """
  The resolved database, without a URL: `SQLite file at /data/custyard.db`,
  `Turso / libSQL over HTTPS`, `Bunny Database / libSQL over HTTPS`,
  `PostgreSQL`; `nil` when nothing is known.
  """
  @spec database_kind(State.t()) :: String.t() | nil
  def database_kind(%State{
        env: %Env{settings: %{database: {:turso, _, _}, turso_provider: :bunny}}
      }) do
    "Bunny Database / libSQL over HTTPS"
  end

  def database_kind(%State{env: %Env{settings: %{database: database}}})
      when not is_nil(database) do
    describe_database(database)
  end

  def database_kind(%State{database: %{facts: %{kind: :sqlite} = facts}}) do
    describe_database({:sqlite, Map.get(facts, :path, "unknown path")})
  end

  def database_kind(%State{database: %{facts: %{kind: kind}}}), do: describe_database({kind})
  def database_kind(_), do: nil

  defp describe_database({:sqlite, path}), do: "SQLite file at #{path}"
  defp describe_database({:turso, _url, _token}), do: "Turso / libSQL over HTTPS"
  defp describe_database({:turso}), do: "Turso / libSQL over HTTPS"
  defp describe_database({:postgres, _url}), do: "PostgreSQL"
  defp describe_database({:postgres}), do: "PostgreSQL"
  defp describe_database(_), do: nil

  @doc """
  Footer database line: kind, the reason it was chosen, and the probe's
  facts (mount, file, migrations, instance administrators) when known.
  """
  @spec database_line(State.t()) :: String.t()
  def database_line(%State{} = state) do
    reason = state.env && state.env.settings[:database_reason]

    [database_kind(state) || "undecided", reason | fact_parts(state.database.facts)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp fact_parts(facts) do
    [
      fact(facts, :mounted?, "/data is a mount", "/data is not a mount"),
      fact(facts, :file_exists?, "file exists", "file does not exist yet"),
      count(facts, :migrations, "migration"),
      count(facts, :instance_admins, "instance administrator")
    ]
  end

  defp fact(facts, key, yes, no) do
    case Map.get(facts, key) do
      true -> yes
      false -> no
      _ -> nil
    end
  end

  defp count(facts, key, noun) do
    case Map.get(facts, key) do
      1 -> "1 #{noun}"
      n when is_integer(n) -> "#{n} #{noun}s"
      _ -> nil
    end
  end

  @doc "`41 variables visible · 6 of them Custyard settings: PHX_HOST  PORT`"
  @spec environment_summary(Env.t()) :: String.t()
  def environment_summary(%Env{variable_count: total, present: present}) do
    summary = "#{total} variables visible · #{length(present)} of them Custyard settings"
    if present == [], do: summary, else: summary <> ": " <> Enum.join(present, "  ")
  end

  @doc "`MAIL_ADAPTOR (did you mean MAIL_ADAPTER)` or `none`."
  @spec near_misses(Env.t()) :: String.t()
  def near_misses(%Env{near_misses: []}), do: "none"

  def near_misses(%Env{near_misses: misses}) do
    Enum.map_join(misses, "  ", fn %{found: found, expected: expected} ->
      "#{found} (did you mean #{expected})"
    end)
  end

  @doc "Where to set variables on the detected platform."
  @spec platform_hint(atom) :: String.t()
  def platform_hint(:fly), do: "Fly: `fly secrets set KEY=value` for each line; the app restarts."

  def platform_hint(:bunny) do
    "Bunny: Environment variables in the Magic Container settings; values must not " <>
      "include quote characters; redeploy after saving."
  end

  def platform_hint(_) do
    "Docker: `-e KEY=value` on `docker run`, or an `environment:` block in docker-compose.yml; " <>
      "then recreate the container."
  end

  @doc "Mail adapters other than `local` and the one already in the paste block."
  @spec other_adapters(Env.t() | nil) :: [String.t()]
  def other_adapters(env) do
    chosen =
      case env do
        %Env{settings: %{mail: %{adapter: adapter}}} -> to_string(adapter)
        _ -> "lettermint"
      end

    Env.mail_adapters() -- ["local", chosen]
  end
end
