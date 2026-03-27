defmodule CustyardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :custyard

  # Session options - salts are configured at runtime for production security.
  # In production, runtime.exs sets :session_signing_salt and :session_encryption_salt
  # on the endpoint config, which are read by session_options/0 at boot time.
  #
  # Default salts are used for dev/test convenience but should never be used in prod.
  # The entrypoint.sh and runtime.exs derive salts from SECRET_KEY_BASE automatically.
  @default_signing_salt "custyard_dev_signing_DO_NOT_USE_IN_PROD"
  @default_encryption_salt "custyard_dev_encrypt_DO_NOT_USE_IN_PROD"

  # Build session options at runtime to use configured salts
  defp session_options do
    config = Application.get_env(:custyard, __MODULE__, [])

    [
      store: :cookie,
      key: "_custyard_key",
      signing_salt: config[:session_signing_salt] || @default_signing_salt,
      encryption_salt: config[:session_encryption_salt] || @default_encryption_salt,
      same_site: "Lax",
      secure: Application.get_env(:custyard, :env) == :prod,
      max_age: 86_400
    ]
  end

  # Expose for LiveView socket connection
  def session_options_for_socket, do: session_options()

  # LiveView socket - session options are resolved at runtime
  # check_origin: :conn is set at endpoint config level in runtime.exs
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {__MODULE__, :session_options_for_socket, []}]],
    longpoll: [connect_info: [session: {__MODULE__, :session_options_for_socket, []}]]

  plug Plug.Static,
    at: "/",
    from: :custyard,
    gzip: false,
    only: CustyardWeb.static_paths()

  # Serve uploaded files from persistent storage directory (configurable via :upload_dir)
  plug CustyardWeb.Plugs.UploadedFiles

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :custyard
  end

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  # Temporary debug plug for origin header diagnosis (remove after fixing)
  plug :log_origin_header

  defp log_origin_header(conn, _opts) do
    require Logger

    origin = Plug.Conn.get_req_header(conn, "origin")
    host_header = Plug.Conn.get_req_header(conn, "host")

    Logger.debug(
      "[OriginDebug] path=#{conn.request_path} origin=#{inspect(origin)} " <>
        "host=#{inspect(host_header)} conn.host=#{inspect(conn.host)} conn.scheme=#{inspect(conn.scheme)}"
    )

    conn
  end

  # Parsers for supported content types.
  # pass: restricts which additional content types pass through unparsed.
  # text/plain is allowed for some webhook providers that send text bodies.
  # The CacheRawBody reader caches raw body for webhook signature verification
  # and enforces a 1MB limit on JSON/webhook bodies.
  #
  # Size limits:
  # - JSON/urlencoded: 1MB (via CacheRawBody, configurable via :webhook_max_body_size)
  # - Multipart: 8MB total, 2MB per file (LiveView uploads have their own limits)
  plug Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: 8_000_000}, :json],
    pass: ["text/plain"],
    body_reader: {CustyardWeb.Plugs.CacheRawBody, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  # Session plug - options resolved at runtime for production security.
  # Using a callback wrapper to delay session options evaluation until request time.
  plug :session_plug

  defp session_plug(conn, _opts) do
    Plug.Session.call(conn, Plug.Session.init(session_options()))
  end

  # Custom domain support - rewrites paths for white-label portal domains
  plug CustyardWeb.Plugs.CustomDomain

  plug CustyardWeb.Router
end
