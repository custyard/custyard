defmodule Custyard.Boot.Env do
  @moduledoc """
  Pure, never-raising parse of the process environment.

  `config/runtime.exs` calls `read/2` and configures whatever is valid; the
  verdict decides which supervision tree `Custyard.Application` starts. This
  module is the only place variable names are spelled out, so it depends on
  nothing started: Elixir stdlib and `:crypto`.

  Every value is trimmed of surrounding whitespace and newlines (with a
  warning). A value wrapped in matching quote characters is reported as
  malformed and otherwise treated as unset; silently stripping quotes would
  hide the next problem.
  """

  defstruct verdict: :configured,
            problems: [],
            warnings: [],
            settings: %{},
            present: [],
            variable_count: 0,
            near_misses: []

  @type kind :: :missing | :malformed | :unsupported
  @type problem :: %{variable: String.t(), kind: kind, detail: String.t()}
  @type warning :: %{variable: String.t() | nil, detail: String.t()}
  @type near_miss :: %{found: String.t(), expected: String.t()}

  @type t :: %__MODULE__{
          verdict: :configured | :unconfigured,
          problems: [problem],
          warnings: [warning],
          settings: map,
          present: [String.t()],
          variable_count: non_neg_integer,
          near_misses: [near_miss]
        }

  @mail_adapters ~w(mailgun sendgrid smtp postmark lettermint local)
  @lettermint_api_url "https://api.lettermint.co/v1"
  @default_database_path "/data/custyard.db"
  @database_providers ~w(sqlite turso bunny postgres)
  @storage_providers ~w(local fly bunny)
  @proxy_providers ~w(none fly bunny)
  @origin_secret_bytes 32
  @near_miss_threshold 0.9

  @known_names Enum.sort(~w(
    ACKNOWLEDGMENTS_PREFETCH
    ATTACHMENT_DIR
    CLAMAV_HOST
    CLAMAV_PORT
    CLAMAV_TIMEOUT_MS
    CREDENTIAL_ENCRYPTION_KEY
    CREDENTIAL_ENCRYPTION_KEY_PREVIOUS
    DATABASE_PATH
    DATABASE_PROVIDER
    DATABASE_URL
    DATA_VOLUME_ID
    EMAIL_FROM_ADDRESS
    EMAIL_FROM_NAME
    EMAIL_NOTIFICATIONS_ENABLED
    IMAP_ENABLED
    INSTANCE_ADMIN_EMAIL
    LETTERMINT_API_URL
    LETTERMINT_PROJECT_TOKEN
    LIVE_VIEW_SIGNING_SALT
    LMTP_ENABLED
    LMTP_HOSTNAME
    LMTP_MAX_CONNECTIONS
    LMTP_NUM_ACCEPTORS
    LMTP_PORT
    LMTP_TLS_CACERTFILE
    LMTP_TLS_CERTFILE
    LMTP_TLS_KEYFILE
    MAILGUN_API_KEY
    MAILGUN_DOMAIN
    MAIL_ADAPTER
    MAINTENANCE_MODE
    OUTBOUND_DELIVERY_ENABLED
    PHX_HOST
    POOL_SIZE
    PORT
    POSTMARK_API_KEY
    PROXY_PROVIDER
    SECRET_KEY_BASE
    SENDGRID_API_KEY
    SENTRY_DSN
    SENTRY_ENVIRONMENT
    SENTRY_RELEASE
    SESSION_ENCRYPTION_SALT
    SESSION_SIGNING_SALT
    SKIP_MIGRATIONS
    SMTP_HOST
    SMTP_PASSWORD
    SMTP_PORT
    SMTP_SSL
    SMTP_USERNAME
    STORAGE_PROVIDER
    TURSO_AUTH_TOKEN
    UPLOAD_DIR
  ))

  # Variables an earlier release read. They are still normalized so a value
  # left behind is named in a warning instead of silently doing nothing.
  @retired %{
    "OPERATOR_EMAIL" =>
      "no longer read; INSTANCE_ADMIN_EMAIL creates the first instance administrator",
    "OPERATOR_NOTIFICATION_EMAIL" => "no longer read; notifications go to each tenant's staff",
    "ACKNOWLEDGMENTS_ENABLED" =>
      "no longer read; each tenant enables its acknowledgment integration in Settings",
    "ACKNOWLEDGMENTS_AMQP_URL" => "no longer read; each tenant stores its broker URL in Settings",
    "ACKNOWLEDGMENTS_SOURCE" => "no longer read; each tenant stores its source in Settings",
    "ACKNOWLEDGMENTS_QUEUE" => "no longer read; each tenant stores its queue in Settings",
    "LETTERMINT_API_KEY" => "no longer read; the sending token is LETTERMINT_PROJECT_TOKEN",
    "LETTERMINT_TEAM_TOKEN" =>
      "no longer read; each tenant stores its Lettermint credentials in Email setup",
    "WEBHOOK_SECRET_INTERCOM" =>
      "no longer read; webhook secrets are stored with each tenant route",
    "WEBHOOK_SECRET_LETTERMINT" =>
      "no longer read; webhook secrets are stored with each tenant route",
    "WEBHOOK_SECRET_LETTERMINT_STATUS" =>
      "no longer read; webhook secrets are stored with each tenant route",
    "WEBHOOK_SECRET_SLACK" => "no longer read; webhook secrets are stored with each tenant route",
    "WEBHOOK_SECRET_ZENDESK" =>
      "no longer read; webhook secrets are stored with each tenant route"
  }

  @platform_prefixes ["FLY_", "BUNNY_"]

  @doc "Every variable name Custyard reads, sorted."
  @spec known_names() :: [String.t()]
  def known_names, do: @known_names

  @doc "Mail adapters accepted for MAIL_ADAPTER."
  @spec mail_adapters() :: [String.t()]
  def mail_adapters, do: @mail_adapters

  @doc """
  Parses `env` (defaults to `System.get_env/0`).

  Options: `config_env: :prod | :dev | :test` (default `:prod`). Nothing is
  required outside `:prod`, but shape checks on set values still apply.
  """
  @spec read(%{String.t() => String.t()}, keyword) :: t
  def read(env \\ System.get_env(), opts \\ []) do
    config_env = Keyword.get(opts, :config_env, :prod)

    acc =
      %{
        env: config_env,
        raw: env,
        values: %{},
        quoted: MapSet.new(),
        present: [],
        problems: [],
        warnings: [],
        settings: %{}
      }
      |> normalize()
      |> secret_key_base()
      |> host_and_port()
      |> mail()
      |> instance_admin_email()
      |> database()
      |> credential_keys()
      |> notifications()
      |> acknowledgments()
      |> outbound_delivery()
      |> attachment_scanner()
      |> skip_migrations()
      |> imap()
      |> retired()
      |> hosting()
      |> directories_and_platform()

    problems = Enum.reverse(acc.problems)

    %__MODULE__{
      verdict: if(problems == [], do: :configured, else: :unconfigured),
      problems: problems,
      warnings: Enum.reverse(acc.warnings),
      settings: acc.settings,
      present: Enum.sort(acc.present),
      variable_count: map_size(env),
      near_misses: near_misses(env)
    }
  end

  # ---------------------------------------------------------------------------
  # Normalization: trim, warn, reject quoted values

  defp normalize(acc) do
    acc.raw
    |> Enum.filter(fn {name, _} -> known?(name) or platform?(name) end)
    |> Enum.sort()
    |> Enum.reduce(acc, fn {name, raw}, acc -> normalize_one(acc, name, raw) end)
  end

  defp normalize_one(acc, name, raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    acc =
      if trimmed != raw and trimmed != "",
        do: warn(acc, name, "value had surrounding whitespace or a newline, trimmed"),
        else: acc

    cond do
      trimmed == "" ->
        acc

      quoted?(trimmed) ->
        %{acc | quoted: MapSet.put(acc.quoted, name)}
        |> mark_present(name)
        |> problem(
          name,
          :malformed,
          "value is wrapped in quote characters; remove them in the environment editor"
        )

      true ->
        acc
        |> mark_present(name)
        |> put_value(name, trimmed)
    end
  end

  defp normalize_one(acc, _name, _raw), do: acc

  defp quoted?(value) when byte_size(value) < 2, do: false

  defp quoted?(value) do
    first = String.first(value)
    first in ["\"", "'"] and String.last(value) == first
  end

  defp known?(name), do: name in @known_names or is_map_key(@retired, name)
  defp platform?(name), do: Enum.any?(@platform_prefixes, &String.starts_with?(name, &1))

  # ---------------------------------------------------------------------------
  # Rules

  defp secret_key_base(acc) do
    case get(acc, "SECRET_KEY_BASE") do
      nil ->
        acc
        |> require(
          "SECRET_KEY_BASE",
          "signs sessions and login links; generate with `openssl rand -base64 64`"
        )
        |> put(:secret_key_base, nil)

      value when byte_size(value) < 64 ->
        acc
        |> problem(
          "SECRET_KEY_BASE",
          :malformed,
          "must be at least 64 bytes (#{byte_size(value)} given); generate with `openssl rand -base64 64`"
        )
        |> put(:secret_key_base, nil)

      value ->
        put(acc, :secret_key_base, value)
    end
  end

  defp host_and_port(acc) do
    acc =
      case {get(acc, "PHX_HOST"), get(acc, "FLY_APP_NAME")} do
        {nil, fly_app} when is_binary(fly_app) and acc.env == :prod ->
          host = "#{fly_app}.fly.dev"

          acc
          |> warn("PHX_HOST", "not set; using #{host} from FLY_APP_NAME")
          |> put(:host, host)

        {nil, _} ->
          acc
          |> require("PHX_HOST", "public hostname used in emailed links")
          |> put(:host, nil)

        {host, _} ->
          if bare_hostname?(host) do
            put(acc, :host, host)
          else
            acc
            |> problem(
              "PHX_HOST",
              :malformed,
              "must be a bare hostname such as custyard.example.com, without scheme, path, or spaces"
            )
            |> put(:host, nil)
          end
      end

    integer(acc, "PORT", 4000, :port)
  end

  defp bare_hostname?(host) do
    not (String.contains?(host, ["/", ":"]) or String.match?(host, ~r/\s/))
  end

  defp mail(acc) do
    case get(acc, "MAIL_ADAPTER") do
      nil ->
        acc
        |> require(
          "MAIL_ADAPTER",
          "staff and administrator login is by emailed link; set one of #{Enum.join(@mail_adapters, ", ")} " <>
            "(local discards mail on purpose)"
        )
        |> put(:mail, nil)

      adapter when adapter in @mail_adapters ->
        mail_adapter(acc, adapter)

      _other ->
        acc
        |> problem(
          "MAIL_ADAPTER",
          :unsupported,
          "must be one of #{Enum.join(@mail_adapters, ", ")}"
        )
        |> put(:mail, nil)
    end
  end

  defp mail_adapter(acc, "local") do
    acc
    |> warn("MAIL_ADAPTER", "outbound mail is discarded; logins impossible")
    |> put(:mail, %{adapter: :local, config: [adapter: Swoosh.Adapters.Local]})
  end

  defp mail_adapter(acc, "lettermint") do
    acc =
      credential(
        acc,
        "LETTERMINT_PROJECT_TOKEN",
        "the Lettermint project token that sends installation mail"
      )

    put(acc, :mail, %{
      adapter: :lettermint,
      config: [
        adapter: Swoosh.Adapters.Lettermint,
        api_token: get(acc, "LETTERMINT_PROJECT_TOKEN"),
        base_url: get(acc, "LETTERMINT_API_URL") || @lettermint_api_url
      ]
    })
  end

  defp mail_adapter(acc, "mailgun") do
    acc =
      acc
      |> credential("MAILGUN_API_KEY", "the Mailgun API key")
      |> credential("MAILGUN_DOMAIN", "the Mailgun sending domain")

    put(acc, :mail, %{
      adapter: :mailgun,
      config: [
        adapter: Swoosh.Adapters.Mailgun,
        api_key: get(acc, "MAILGUN_API_KEY"),
        domain: get(acc, "MAILGUN_DOMAIN")
      ]
    })
  end

  defp mail_adapter(acc, "sendgrid") do
    acc = credential(acc, "SENDGRID_API_KEY", "the SendGrid API key")

    put(acc, :mail, %{
      adapter: :sendgrid,
      config: [adapter: Swoosh.Adapters.Sendgrid, api_key: get(acc, "SENDGRID_API_KEY")]
    })
  end

  defp mail_adapter(acc, "postmark") do
    acc = credential(acc, "POSTMARK_API_KEY", "the Postmark server API token")

    put(acc, :mail, %{
      adapter: :postmark,
      config: [adapter: Swoosh.Adapters.Postmark, api_key: get(acc, "POSTMARK_API_KEY")]
    })
  end

  defp mail_adapter(acc, "smtp") do
    acc =
      acc
      |> credential("SMTP_HOST", "the SMTP relay hostname")
      |> integer("SMTP_PORT", 587, :smtp_port)
      |> boolean("SMTP_SSL", false, :smtp_ssl)

    config = [
      adapter: Swoosh.Adapters.SMTP,
      relay: get(acc, "SMTP_HOST"),
      port: acc.settings.smtp_port,
      username: get(acc, "SMTP_USERNAME"),
      password: get(acc, "SMTP_PASSWORD"),
      ssl: acc.settings.smtp_ssl,
      tls: :always,
      auth: :always
    ]

    acc
    |> update_in([:settings], &Map.drop(&1, [:smtp_port, :smtp_ssl]))
    |> put(:mail, %{adapter: :smtp, config: config})
  end

  defp instance_admin_email(acc) do
    case get(acc, "INSTANCE_ADMIN_EMAIL") do
      nil ->
        put(acc, :instance_admin_email, nil)

      value ->
        if email?(value) do
          put(acc, :instance_admin_email, value)
        else
          acc
          |> problem(
            "INSTANCE_ADMIN_EMAIL",
            :malformed,
            "must be an email address such as you@example.com"
          )
          |> put(:instance_admin_email, nil)
        end
    end
  end

  defp email?(value), do: String.match?(value, ~r/\A[^@\s]+@[^@\s]+\z/)

  # The database provider is independent of where the container runs: Fly
  # staging may use Bunny Database. BUNNY_DATABASE_URL or
  # BUNNY_DATABASE_AUTH_TOKEN select the Bunny provider (libSQL over Hrana v2)
  # unless DATABASE_PROVIDER says otherwise, which is then a conflict. No
  # combination falls back to the SQLite file: a stale or half-set remote
  # database leaves the database undecided and the verdict unconfigured.
  defp database(acc) do
    acc = acc |> integer("POOL_SIZE", 10, :pool_size) |> put(:turso_provider, nil)

    db = %{
      url: get(acc, "DATABASE_URL"),
      token: get(acc, "TURSO_AUTH_TOKEN"),
      bunny_url: get(acc, "BUNNY_DATABASE_URL"),
      bunny_token: get(acc, "BUNNY_DATABASE_AUTH_TOKEN")
    }

    bunny_settings? = is_binary(db.bunny_url) or is_binary(db.bunny_token)

    provider =
      get(acc, "DATABASE_PROVIDER") || if(bunny_settings?, do: "bunny", else: :automatic)

    select_database(acc, db, provider, bunny_settings?)
  end

  defp select_database(acc, db, :automatic, _bunny_settings?), do: automatic(acc, db)
  defp select_database(acc, db, "bunny", _bunny_settings?), do: bunny(acc, db)

  defp select_database(acc, _db, provider, true) when provider in @database_providers do
    acc
    |> problem(
      "DATABASE_PROVIDER",
      :malformed,
      "conflicts with the BUNNY_DATABASE_* settings; set it to bunny or unset them"
    )
    |> no_database("DATABASE_PROVIDER conflicts with BUNNY_DATABASE_*, so no database")
  end

  defp select_database(acc, db, "sqlite", _bunny_settings?), do: explicit_sqlite(acc, db)

  defp select_database(acc, db, "turso", _bunny_settings?),
    do: explicit_remote(acc, db, "turso", "libsql://", ["libsql://"])

  defp select_database(acc, db, "postgres", _bunny_settings?),
    do: explicit_remote(acc, db, "postgres", "postgres://", ["postgres://", "postgresql://"])

  defp select_database(acc, _db, _unknown, _bunny_settings?) do
    acc
    |> problem(
      "DATABASE_PROVIDER",
      :unsupported,
      "must be one of #{Enum.join(@database_providers, ", ")}"
    )
    |> no_database("DATABASE_PROVIDER is not recognized, so no database")
  end

  # No DATABASE_PROVIDER and no Bunny settings: the URL's scheme decides.
  defp automatic(acc, %{url: nil, token: token}) when is_binary(token) do
    acc
    |> problem(
      "DATABASE_URL",
      :missing,
      "TURSO_AUTH_TOKEN is set, so the libsql:// URL is needed too; " <>
        "unset the token to use the SQLite file"
    )
    |> no_database("TURSO_AUTH_TOKEN is set without DATABASE_URL, so no database")
  end

  defp automatic(acc, %{url: nil}), do: sqlite(acc)

  defp automatic(acc, %{url: url, token: token}) do
    cond do
      String.starts_with?(url, "libsql://") ->
        turso(acc, url, token)

      String.starts_with?(url, ["postgres://", "postgresql://"]) ->
        postgres(acc, url)

      true ->
        acc
        |> problem(
          "DATABASE_URL",
          :malformed,
          "must start with libsql:// (Turso) or postgres://; unset it to use the SQLite " <>
            "file, or set DATABASE_PROVIDER=bunny for a Bunny Database URL"
        )
        |> no_database("DATABASE_URL has an unsupported scheme, so no database")
    end
  end

  defp explicit_sqlite(acc, %{url: nil, token: nil}), do: sqlite(acc)

  defp explicit_sqlite(acc, _db) do
    acc
    |> problem(
      "DATABASE_PROVIDER",
      :malformed,
      "sqlite conflicts with DATABASE_URL or TURSO_AUTH_TOKEN; unset them or change the provider"
    )
    |> no_database("DATABASE_PROVIDER=sqlite conflicts with remote settings, so no database")
  end

  defp explicit_remote(acc, %{url: nil}, provider, example, _schemes) do
    acc
    |> problem(
      "DATABASE_URL",
      :missing,
      "DATABASE_PROVIDER=#{provider} needs a #{example} URL"
    )
    |> no_database("DATABASE_PROVIDER=#{provider} without DATABASE_URL, so no database")
  end

  defp explicit_remote(acc, %{url: url, token: token}, provider, example, schemes) do
    cond do
      not String.starts_with?(url, schemes) ->
        acc
        |> problem(
          "DATABASE_URL",
          :malformed,
          "must start with #{example} when DATABASE_PROVIDER=#{provider}"
        )
        |> no_database(
          "DATABASE_URL does not match DATABASE_PROVIDER=#{provider}, so no database"
        )

      provider == "turso" ->
        turso(acc, url, token)

      true ->
        postgres(acc, url)
    end
  end

  defp no_database(acc, reason) do
    acc
    |> put(:database, nil)
    |> put(:database_reason, reason)
  end

  defp sqlite(acc) do
    case get(acc, "DATABASE_PATH") do
      nil ->
        acc
        |> put(:database, {:sqlite, @default_database_path})
        |> put(
          :database_reason,
          "no DATABASE_URL or DATABASE_PATH, so the SQLite file at the default #{@default_database_path}"
        )

      path ->
        if Path.type(path) == :absolute do
          acc
          |> put(:database, {:sqlite, path})
          |> put(:database_reason, "no DATABASE_URL, so the SQLite file at DATABASE_PATH")
        else
          acc
          |> problem("DATABASE_PATH", :malformed, "must be an absolute filesystem path")
          |> no_database("DATABASE_PATH is relative, so no database")
        end
    end
  end

  defp postgres(acc, url) do
    acc
    |> put(:database, {:postgres, url})
    |> put(:database_reason, "DATABASE_URL is set, so PostgreSQL")
  end

  defp turso(acc, url, token) do
    acc =
      if is_nil(token) and not plain_http?(url) do
        problem(
          acc,
          "TURSO_AUTH_TOKEN",
          :missing,
          "a Turso database needs a token: `turso db tokens create <db>`"
        )
      else
        acc
      end

    acc
    |> put(:database, {:turso, url, token})
    |> put(:turso_provider, :turso)
    |> put(:database_reason, "DATABASE_URL is set, so remote libSQL")
  end

  # Bunny Database: the same libSQL driver over Hrana v2. Either name of each
  # pair is accepted; two different values for one setting are a conflict
  # rather than a silent choice. Values are never part of a problem detail.
  defp bunny(acc, db) do
    cond do
      differ?(db.bunny_url, db.url) ->
        acc
        |> problem(
          "BUNNY_DATABASE_URL",
          :malformed,
          "conflicts with DATABASE_URL; set one URL or identical aliases"
        )
        |> no_database("BUNNY_DATABASE_URL conflicts with DATABASE_URL, so no database")

      differ?(db.bunny_token, db.token) ->
        acc
        |> problem(
          "BUNNY_DATABASE_AUTH_TOKEN",
          :malformed,
          "conflicts with TURSO_AUTH_TOKEN; set one token or identical aliases"
        )
        |> no_database(
          "BUNNY_DATABASE_AUTH_TOKEN conflicts with TURSO_AUTH_TOKEN, so no database"
        )

      is_nil(db.bunny_url || db.url) ->
        acc
        |> problem(
          "BUNNY_DATABASE_URL",
          :missing,
          "Bunny Database is selected, so its URL is needed (DATABASE_URL is accepted too)"
        )
        |> no_database("Bunny Database is selected without a URL, so no database")

      true ->
        source = if db.bunny_url, do: "BUNNY_DATABASE_URL", else: "DATABASE_URL"
        bunny_url(acc, source, db.bunny_url || db.url, db.bunny_token || db.token)
    end
  end

  defp bunny_url(acc, source, url, token) do
    if bunny_url?(url) do
      acc =
        if is_nil(token) do
          problem(
            acc,
            "BUNNY_DATABASE_AUTH_TOKEN",
            :missing,
            "a Bunny Database needs its access token (TURSO_AUTH_TOKEN is accepted too)"
          )
        else
          acc
        end

      acc
      |> put(:database, {:turso, url, token})
      |> put(:turso_provider, :bunny)
      |> put(:database_reason, "#{source} is set, so Bunny Database (remote libSQL)")
    else
      acc
      |> problem(
        source,
        :malformed,
        "a Bunny Database URL must be https:// or libsql:// with a host and without " <>
          "credentials, query parameters or a fragment"
      )
      |> no_database("#{source} is not a usable Bunny Database URL, so no database")
    end
  end

  defp bunny_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, query: nil, userinfo: nil, fragment: nil}}
      when scheme in ["libsql", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp differ?(a, b), do: is_binary(a) and is_binary(b) and a != b

  defp plain_http?(url) do
    url
    |> URI.parse()
    |> Map.get(:query)
    |> to_string()
    |> URI.decode_query()
    |> Map.get("tls") == "0"
  end

  defp credential_keys(acc) do
    {acc, current} =
      case get(acc, "CREDENTIAL_ENCRYPTION_KEY") do
        nil ->
          {require(
             acc,
             "CREDENTIAL_ENCRYPTION_KEY",
             "encrypts stored tenant credentials such as IMAP passwords and Lettermint tokens; " <>
               "generate with `openssl rand -base64 32`"
           ), nil}

        encoded ->
          decode_credential_key(acc, "CREDENTIAL_ENCRYPTION_KEY", encoded)
      end

    {acc, previous} =
      case get(acc, "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS") do
        nil -> {acc, nil}
        encoded -> decode_credential_key(acc, "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS", encoded)
      end

    put(acc, :credential_keys, %{current: current, previous: List.wrap(previous)})
  end

  defp decode_credential_key(acc, name, encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = key} ->
        {acc, key}

      _ ->
        raw = Map.get(acc.raw, name, encoded)
        newline = if String.ends_with?(raw, "\n"), do: ", trailing newline", else: ""

        {problem(
           acc,
           name,
           :malformed,
           "not Base64 of 32 bytes (#{byte_size(raw)} bytes#{newline}); " <>
             "generate with `openssl rand -base64 32`"
         ), nil}
    end
  end

  defp notifications(acc) do
    default_enabled =
      case acc.settings.mail do
        %{adapter: adapter} when adapter != :local -> true
        _ -> false
      end

    acc = boolean(acc, "EMAIL_NOTIFICATIONS_ENABLED", default_enabled, :notifications_enabled)
    host = acc.settings.host

    notifications = %{
      enabled: acc.settings.notifications_enabled,
      from_name: get(acc, "EMAIL_FROM_NAME") || "Custyard",
      from_address: get(acc, "EMAIL_FROM_ADDRESS") || (host && "noreply@#{host}")
    }

    acc
    |> update_in([:settings], &Map.delete(&1, :notifications_enabled))
    |> put(:notifications, notifications)
  end

  # Read by Custyard.Application before the migrations run.
  defp skip_migrations(acc), do: boolean(acc, "SKIP_MIGRATIONS", false, :skip_migrations)

  # Tenant integration records own the broker URL, source, queue and enabled
  # state. Only the consumption limit is a deployment setting.
  defp acknowledgments(acc), do: acknowledgments_prefetch(acc)

  defp acknowledgments_prefetch(acc) do
    with value when is_binary(value) <- get(acc, "ACKNOWLEDGMENTS_PREFETCH"),
         {count, ""} when count > 0 and count <= 100 <- Integer.parse(value) do
      acc
    else
      nil ->
        acc

      _ ->
        problem(
          acc,
          "ACKNOWLEDGMENTS_PREFETCH",
          :malformed,
          "must be an integer between 1 and 100"
        )
    end
  end

  # An installation-level stop for recovery and provider incidents. A value
  # that is neither true nor false is a problem, and delivery stays stopped:
  # a mistyped "false" must not send.
  defp outbound_delivery(acc) do
    case get(acc, "OUTBOUND_DELIVERY_ENABLED") do
      value when value in [nil, "true"] ->
        put(acc, :outbound_delivery_enabled, true)

      "false" ->
        put(acc, :outbound_delivery_enabled, false)

      _ ->
        acc
        |> problem("OUTBOUND_DELIVERY_ENABLED", :malformed, "must be true or false")
        |> put(:outbound_delivery_enabled, false)
    end
  end

  # clamd is optional. Without a host attachments stay quarantined; with a
  # port or timeout out of range the scanner is not configured either.
  defp attachment_scanner(acc) do
    case get(acc, "CLAMAV_HOST") do
      nil ->
        put(acc, :attachment_scanner, nil)

      host ->
        {acc, port} = ranged(acc, "CLAMAV_PORT", 3310, 1..65_535)
        {acc, timeout} = ranged(acc, "CLAMAV_TIMEOUT_MS", 10_000, 100..60_000)

        scanner = if port && timeout, do: %{host: host, port: port, timeout: timeout}
        put(acc, :attachment_scanner, scanner)
    end
  end

  defp ranged(acc, name, default, range) do
    case get(acc, name) do
      nil ->
        {acc, default}

      value ->
        case Integer.parse(value) do
          {int, ""} ->
            if int in range,
              do: {acc, int},
              else: {out_of_range(acc, name, range), nil}

          _ ->
            {out_of_range(acc, name, range), nil}
        end
    end
  end

  defp out_of_range(acc, name, first..last//_),
    do: problem(acc, name, :malformed, "must be an integer between #{first} and #{last}")

  defp imap(acc) do
    case get(acc, "IMAP_ENABLED") do
      value when value in [nil, "false"] ->
        acc

      _ ->
        problem(
          acc,
          "IMAP_ENABLED",
          :unsupported,
          "no longer supported; connect the mailbox as an IMAP channel " <>
            "(Email setup at /app/settings/email > Add support address > " <>
            "\"Read a mailbox over IMAP\"), " <>
            "then unset IMAP_ENABLED and the other IMAP_* variables"
        )
    end
  end

  defp retired(acc) do
    @retired
    |> Enum.sort()
    |> Enum.reduce(acc, fn {name, detail}, acc ->
      if name in acc.present, do: warn(acc, name, detail), else: acc
    end)
  end

  # Whose storage rules apply (Custyard.Storage) and which proxy is in front
  # are chosen separately from the database (Fly staging can run on Bunny
  # Database). Both default to Fly when FLY_APP_NAME is present and to nothing
  # special otherwise.
  defp hosting(acc) do
    fly? = is_binary(get(acc, "FLY_APP_NAME"))

    acc
    |> choice(
      "STORAGE_PROVIDER",
      :storage_provider,
      @storage_providers,
      if(fly?, do: :fly, else: :local),
      :invalid
    )
    |> choice(
      "PROXY_PROVIDER",
      :proxy_provider,
      @proxy_providers,
      if(fly?, do: :fly, else: :none),
      nil
    )
    |> unused_data_volume_id()
    |> bunny_origin_secret()
  end

  # An unrecognized value is never echoed. `invalid` is what the setting
  # becomes then: storage has a value that Custyard.Storage refuses, so a
  # release command cannot skip the storage check; the proxy keeps the
  # platform default so the doctor card that reports the problem is reachable.
  defp choice(acc, name, key, allowed, default, invalid) do
    case get(acc, name) do
      nil ->
        put(acc, key, default)

      value ->
        if value in allowed do
          put(acc, key, String.to_existing_atom(value))
        else
          acc
          |> problem(name, :unsupported, "must be one of #{Enum.join(allowed, ", ")}")
          |> put(key, invalid || default)
        end
    end
  end

  # Named the Bunny file volume while uploads and attachments were files on
  # it. Still a known name, so a deployment that sets it boots as before; its
  # value is not used.
  defp unused_data_volume_id(acc) do
    if "DATA_VOLUME_ID" in acc.present do
      warn(
        acc,
        "DATA_VOLUME_ID",
        "no longer used; files are stored in the database, so this variable can be removed"
      )
    else
      acc
    end
  end

  # Bunny's edge rule overwrites X-Custyard-Origin with this value and
  # CustyardWeb.Proxy compares it before trusting any forwarded header. A
  # missing or short secret leaves the setting nil, so the proxy refuses every
  # request but the health probes: the report on the container console and
  # `bin/doctor` name the problem, the doctor card is not served.
  defp bunny_origin_secret(%{settings: %{proxy_provider: :bunny}} = acc) do
    case get(acc, "BUNNY_ORIGIN_SECRET") do
      nil ->
        acc
        |> credential(
          "BUNNY_ORIGIN_SECRET",
          "PROXY_PROVIDER=bunny authenticates the CDN with this shared secret; " <>
            "generate with `openssl rand -hex 32`"
        )
        |> put(:bunny_origin_secret, nil)

      value when byte_size(value) < @origin_secret_bytes ->
        acc
        |> problem(
          "BUNNY_ORIGIN_SECRET",
          :malformed,
          "must be at least #{@origin_secret_bytes} bytes (#{byte_size(value)} given); " <>
            "generate with `openssl rand -hex 32`"
        )
        |> put(:bunny_origin_secret, nil)

      value ->
        put(acc, :bunny_origin_secret, value)
    end
  end

  defp bunny_origin_secret(acc), do: put(acc, :bunny_origin_secret, nil)

  defp directories_and_platform(acc) do
    fly? = is_binary(get(acc, "FLY_APP_NAME"))

    bunny? =
      :bunny in [acc.settings.storage_provider, acc.settings.proxy_provider] or
        Enum.any?(acc.present, &String.starts_with?(&1, "BUNNY_"))

    platform =
      cond do
        fly? -> :fly
        bunny? -> :bunny
        true -> :unknown
      end

    # Where earlier releases wrote tenant logos and inbound attachments. Files
    # are stored in the database; these only locate what such a release left
    # behind, for a one-time import and for the sweep of attachment files
    # whose rows are gone. Neither is validated or has to exist.
    acc
    |> put(:upload_dir, get(acc, "UPLOAD_DIR") || "/data/uploads")
    |> put(:attachment_dir, get(acc, "ATTACHMENT_DIR") || "/data/attachments")
    |> put(:trust_proxy_headers, acc.settings.proxy_provider == :fly)
    |> put(:platform, platform)
  end

  # ---------------------------------------------------------------------------
  # Near misses

  defp near_misses(env) do
    env
    |> Map.keys()
    |> Enum.reject(&(known?(&1) or platform?(&1)))
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      case near_miss(name) do
        nil -> []
        expected -> [%{found: name, expected: expected}]
      end
    end)
  end

  defp near_miss(name) do
    upcased = String.upcase(name)

    if upcased in @known_names do
      upcased
    else
      {expected, distance} =
        @known_names
        |> Enum.map(&{&1, String.jaro_distance(upcased, &1)})
        |> Enum.max_by(&elem(&1, 1))

      if distance >= @near_miss_threshold, do: expected
    end
  end

  # ---------------------------------------------------------------------------
  # Accumulator helpers

  defp get(acc, name), do: Map.get(acc.values, name)

  defp put(acc, key, value), do: put_in(acc, [:settings, key], value)

  defp put_value(acc, name, value), do: put_in(acc, [:values, name], value)

  defp mark_present(acc, name), do: %{acc | present: [name | acc.present]}

  defp problem(acc, variable, kind, detail) do
    %{acc | problems: [%{variable: variable, kind: kind, detail: detail} | acc.problems]}
  end

  defp warn(acc, variable, detail) do
    %{acc | warnings: [%{variable: variable, detail: detail} | acc.warnings]}
  end

  # A variable required in :prod only. A quoted value was already reported as
  # malformed and is not also missing.
  defp require(%{env: :prod} = acc, name, detail) do
    if MapSet.member?(acc.quoted, name), do: acc, else: problem(acc, name, :missing, detail)
  end

  defp require(acc, _name, _detail), do: acc

  # A credential required whenever its adapter is selected, in every env.
  defp credential(acc, name, detail) do
    if is_nil(get(acc, name)) and not MapSet.member?(acc.quoted, name),
      do: problem(acc, name, :missing, detail),
      else: acc
  end

  defp integer(acc, name, default, key) do
    case get(acc, name) do
      nil ->
        put(acc, key, default)

      value ->
        case Integer.parse(value) do
          {int, ""} when int > 0 ->
            put(acc, key, int)

          _ ->
            acc
            |> problem(name, :malformed, "must be a positive integer; using #{default}")
            |> put(key, default)
        end
    end
  end

  defp boolean(acc, name, default, key) do
    case get(acc, name) do
      nil ->
        put(acc, key, default)

      "true" ->
        put(acc, key, true)

      "false" ->
        put(acc, key, false)

      _ ->
        acc
        |> problem(name, :malformed, "must be true or false")
        |> put(key, default)
    end
  end
end
