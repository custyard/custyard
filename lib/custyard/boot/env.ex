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
  @near_miss_threshold 0.9

  @known_names Enum.sort(~w(
    ACKNOWLEDGMENTS_AMQP_URL
    ACKNOWLEDGMENTS_ENABLED
    ACKNOWLEDGMENTS_PREFETCH
    ACKNOWLEDGMENTS_QUEUE
    ACKNOWLEDGMENTS_SOURCE
    ATTACHMENT_DIR
    CREDENTIAL_ENCRYPTION_KEY
    CREDENTIAL_ENCRYPTION_KEY_PREVIOUS
    DATABASE_PATH
    DATABASE_URL
    EMAIL_FROM_ADDRESS
    EMAIL_FROM_NAME
    EMAIL_NOTIFICATIONS_ENABLED
    IMAP_ENABLED
    LETTERMINT_API_KEY
    LETTERMINT_API_URL
    LETTERMINT_PROJECT_TOKEN
    LETTERMINT_TEAM_TOKEN
    LIVE_VIEW_SIGNING_SALT
    LMTP_ENABLED
    LMTP_HOSTNAME
    LMTP_MAX_CONNECTIONS
    LMTP_NUM_ACCEPTORS
    LMTP_PORT
    LMTP_TLS_CACERTFILE
    LMTP_TLS_CERTFILE
    LMTP_TLS_KEYFILE
    MAIL_ADAPTER
    MAILGUN_API_KEY
    MAILGUN_DOMAIN
    MAINTENANCE_MODE
    OPERATOR_EMAIL
    OPERATOR_NOTIFICATION_EMAIL
    PHX_HOST
    POOL_SIZE
    PORT
    POSTMARK_API_KEY
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
    TURSO_AUTH_TOKEN
    UPLOAD_DIR
    WEBHOOK_SECRET_INTERCOM
    WEBHOOK_SECRET_LETTERMINT
    WEBHOOK_SECRET_LETTERMINT_STATUS
    WEBHOOK_SECRET_SLACK
    WEBHOOK_SECRET_ZENDESK
  ))

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
      |> operator_email()
      |> database()
      |> credential_keys()
      |> notifications()
      |> acknowledgments()
      |> imap()
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

  defp known?(name), do: name in @known_names
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
          "operator login is by emailed link; set one of #{Enum.join(@mail_adapters, ", ")} " <>
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
    {acc, token} =
      case {get(acc, "LETTERMINT_PROJECT_TOKEN"), get(acc, "LETTERMINT_API_KEY")} do
        {nil, nil} ->
          {credential(
             acc,
             "LETTERMINT_PROJECT_TOKEN",
             "the Lettermint project token that sends mail"
           ), nil}

        {nil, legacy} ->
          {warn(
             acc,
             "LETTERMINT_API_KEY",
             "deprecated name; rename it to LETTERMINT_PROJECT_TOKEN"
           ), legacy}

        {token, _} ->
          {acc, token}
      end

    put(acc, :mail, %{
      adapter: :lettermint,
      config: [
        adapter: Swoosh.Adapters.Lettermint,
        api_token: token,
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

  defp operator_email(acc) do
    case get(acc, "OPERATOR_EMAIL") do
      nil ->
        put(acc, :operator_email, nil)

      value ->
        if email?(value) do
          put(acc, :operator_email, value)
        else
          acc
          |> problem(
            "OPERATOR_EMAIL",
            :malformed,
            "must be an email address such as you@example.com"
          )
          |> put(:operator_email, nil)
        end
    end
  end

  defp email?(value), do: String.match?(value, ~r/\A[^@\s]+@[^@\s]+\z/)

  defp database(acc) do
    acc = integer(acc, "POOL_SIZE", 10, :pool_size)

    {source, url} =
      case {get(acc, "DATABASE_URL"), get(acc, "BUNNY_DATABASE_URL")} do
        {nil, nil} -> {nil, nil}
        {nil, bunny} -> {"BUNNY_DATABASE_URL", bunny}
        {url, _} -> {"DATABASE_URL", url}
      end

    cond do
      is_nil(url) ->
        sqlite(acc)

      String.starts_with?(url, "libsql://") ->
        turso(acc, source, url)

      String.starts_with?(url, ["postgres://", "postgresql://"]) ->
        acc
        |> put(:database, {:postgres, url})
        |> put(:database_reason, "#{source} is set, so PostgreSQL")

      true ->
        acc
        |> problem(
          source,
          :malformed,
          "must start with libsql:// (Turso) or postgres://; unset it to use the SQLite file"
        )
        |> put(:database, nil)
        |> put(:database_reason, "#{source} has an unsupported scheme, so no database")
    end
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
          |> put(:database, nil)
          |> put(:database_reason, "DATABASE_PATH is relative, so no database")
        end
    end
  end

  defp turso(acc, source, url) do
    token = get(acc, "TURSO_AUTH_TOKEN") || get(acc, "BUNNY_DATABASE_AUTH_TOKEN")

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
    |> put(:database_reason, "#{source} is set, so remote libSQL")
  end

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
      operator_email: get(acc, "OPERATOR_NOTIFICATION_EMAIL") || acc.settings.operator_email,
      from_name: get(acc, "EMAIL_FROM_NAME") || "Custyard",
      from_address: get(acc, "EMAIL_FROM_ADDRESS") || (host && "noreply@#{host}")
    }

    acc
    |> update_in([:settings], &Map.delete(&1, :notifications_enabled))
    |> put(:notifications, notifications)
  end

  defp acknowledgments(acc) do
    acc
    |> boolean("ACKNOWLEDGMENTS_ENABLED", nil, :ack_enabled)
    |> update_in([:settings], &Map.delete(&1, :ack_enabled))
    |> acknowledgments_prefetch()
    |> acknowledgments_pair()
  end

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

  # Whether URL and source are complete is decided at application start; here
  # only the half-configured state is a problem, and only in :prod where the
  # consumer is on by default.
  defp acknowledgments_pair(%{env: :prod} = acc) do
    case {get(acc, "ACKNOWLEDGMENTS_AMQP_URL"), get(acc, "ACKNOWLEDGMENTS_SOURCE")} do
      {nil, source} when is_binary(source) ->
        problem(
          acc,
          "ACKNOWLEDGMENTS_AMQP_URL",
          :missing,
          "ACKNOWLEDGMENTS_SOURCE is set, so the broker URL is needed too"
        )

      {url, nil} when is_binary(url) ->
        problem(
          acc,
          "ACKNOWLEDGMENTS_SOURCE",
          :missing,
          "ACKNOWLEDGMENTS_AMQP_URL is set, so the source name is needed too"
        )

      _ ->
        acc
    end
  end

  defp acknowledgments_pair(acc), do: acc

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
            "(organization page > Channels > New channel > \"Read a mailbox over IMAP\"), " <>
            "then unset IMAP_ENABLED and the other IMAP_* variables"
        )
    end
  end

  defp directories_and_platform(acc) do
    fly? = is_binary(get(acc, "FLY_APP_NAME"))
    bunny? = Enum.any?(acc.present, &String.starts_with?(&1, "BUNNY_"))

    platform =
      cond do
        fly? -> :fly
        bunny? -> :bunny
        true -> :unknown
      end

    acc
    |> put(:upload_dir, get(acc, "UPLOAD_DIR") || "/data/uploads")
    |> put(:attachment_dir, get(acc, "ATTACHMENT_DIR") || "/data/attachments")
    |> put(:trust_proxy_headers, fly?)
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
