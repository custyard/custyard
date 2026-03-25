defmodule CustyardWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :custyard

  @session_options [
    store: :cookie,
    key: "_custyard_key",
    signing_salt: "custyard_signing",
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

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options

  # Custom domain support - rewrites paths for white-label portal domains
  plug CustyardWeb.Plugs.CustomDomain

  plug CustyardWeb.Router
end
