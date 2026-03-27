defmodule CustyardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :custyard

  @session_options [
    store: :cookie,
    key: "_custyard_key",
    signing_salt: "custyard_signing",
    # Encryption salt ensures session data (operator_id, portal_org_id) is encrypted,
    # not just signed. Without this, session contents are readable via Base64 decode.
    encryption_salt: "custyard_encrypt",
    same_site: "Lax",
    secure: Application.compile_env(:custyard, :env) == :prod,
    max_age: 86_400
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

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

  # Parsers for supported content types.
  # pass: restricts which additional content types pass through unparsed.
  # text/plain is allowed for some webhook providers that send text bodies.
  # The CacheRawBody reader caches raw body for webhook signature verification.
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["text/plain"],
    body_reader: {CustyardWeb.Plugs.CacheRawBody, :read_body, []},
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Custom domain support - rewrites paths for white-label portal domains
  plug CustyardWeb.Plugs.CustomDomain

  plug CustyardWeb.Router
end
