defmodule CustyardWeb.Router do
  use CustyardWeb, :router

  # Content Security Policy restricts XSS impact by controlling script sources.
  # - default-src 'self': restrict all resources to same origin by default
  # - script-src 'self': only allow scripts from same origin (no inline/eval)
  # - style-src 'self' 'unsafe-inline': allow same-origin styles + inline (for LiveView)
  # - img-src 'self' data: https:: images from self, data URIs, and any HTTPS source
  # - connect-src 'self' wss:: allow same-origin fetch + WebSocket connections for LiveView
  # - frame-ancestors 'none': prevent clickjacking (supplements X-Frame-Options)
  @csp_header "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: https:; connect-src 'self' wss:; frame-ancestors 'none'"

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CustyardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp_header}
  end

  # API pipeline intentionally omits CSRF protection (:protect_from_forgery) because:
  # - Webhook endpoints use signature verification (HMAC) or callback tokens for auth
  # - Health endpoint is read-only
  # - API authentication is token-based, not session-based
  # If adding new state-mutating API endpoints, ensure they have appropriate auth.
  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_operator do
    plug CustyardWeb.Plugs.RequireOperator
  end

  pipeline :portal_auth do
    plug CustyardWeb.Plugs.PortalAuth
  end

  # Public intake surfaces (/i, /r — and /c when the slug claim lands):
  # anonymous, hammerable, and carrying bearer tokens in the path. The
  # resume URL must never leak via the Referer header, and the pages render
  # the sparse operator-branded :intake layout instead of the app chrome.
  pipeline :public_intake do
    plug CustyardWeb.Plugs.NoReferrer
    plug :put_root_layout, html: {CustyardWeb.Layouts, :intake_root}
  end

  pipeline :resume_cookie do
    plug CustyardWeb.Plugs.ResumeCookie
  end

  scope "/", CustyardWeb do
    pipe_through :browser

    live "/", HomeLive, :index
  end

  # Public intake pages — anonymous dead views, one per operator-configured
  # intake source key. Served on the application host only: on a custom
  # domain the CustomDomain plug rewrites /i/* into the portal scope, where
  # it 404s (intake is an operator surface, never a customer-portal one).
  scope "/i", CustyardWeb do
    pipe_through [:browser, :public_intake]

    get "/:source_key", IntakeController, :show
    post "/:source_key", IntakeController, :create
  end

  # Resume access — the token in the URL is the credential; every mount
  # re-authenticates it (nothing lives in the session). The uniform
  # "conversation unavailable" page is a dead view so invalid tokens never
  # cost a LiveView socket; it must be declared before the catch-all live
  # route ("unavailable" is not a valid token shape, but order still matters).
  scope "/r", CustyardWeb do
    pipe_through [:browser, :public_intake, :resume_cookie]

    get "/unavailable", ResumeController, :unavailable

    live_session :intake_resume,
      on_mount: [{CustyardWeb.Live.ResumeAuth, :default}],
      layout: {CustyardWeb.Layouts, :intake} do
      live "/:token", ResumeLive, :show
    end
  end

  scope "/api", CustyardWeb do
    pipe_through :api

    get "/health", HealthController, :index

    # Routed webhooks — dispatched by callback_token with source-specific adapters
    post "/webhook/route/:callback_token", WebhookController, :routed
  end

  # Operator routes - public (login/logout)
  scope "/operator", CustyardWeb.Operator, as: :operator do
    pipe_through [:browser]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/login/sent", SessionController, :sent
    get "/login/verify/:token", SessionController, :verify
    delete "/logout", SessionController, :delete
  end

  # Operator routes - protected LiveViews
  scope "/operator", CustyardWeb.Operator, as: :operator do
    pipe_through [:browser, :require_operator]

    # All authenticated operators
    live_session :operator,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :default}] do
      live "/", AttentionQueueLive, :index
      live "/conversation/:id", ConversationLive, :show
      live "/projects", ProjectsLive, :index
      live "/projects/:id", ProjectDetailLive, :show
      live "/neglect", NeglectReportLive, :index
    end

    # Admin+ only
    live_session :operator_admin,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :require_admin}] do
      live "/organizations", OrganizationsLive, :index
      live "/organizations/:id", OrganizationDetailLive, :show
    end

    # Super admin only
    live_session :operator_super_admin,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :require_super_admin}] do
      live "/settings", SettingsLive, :index
      live "/intake-sources", IntakeSourcesLive, :index
    end
  end

  # Portal routes - accessed via unguessable org token or custom domain
  scope "/p/:org_token", CustyardWeb.Portal, as: :portal do
    pipe_through [:browser, :portal_auth]

    live_session :portal,
      on_mount: [{CustyardWeb.Live.PortalAuth, :default}],
      layout: {CustyardWeb.Layouts, :portal} do
      live "/", RequestListLive, :index
      live "/request/:id", ConversationLive, :show
      live "/new", NewRequestLive, :new
      live "/projects", ProjectsListLive, :index
      live "/projects/:id", ProjectLive, :show
    end
  end

  # Note: Custom domain portal routes are handled by the CustomDomain plug
  # which rewrites paths from / -> /p/:token, /request/:id -> /p/:token/request/:id, etc.
  # This allows organizations to use their own domain (e.g., support.acme.com)
  # and have requests routed to the portal routes transparently.

  # LiveDashboard routes (requires phoenix_live_dashboard dependency)
  # if Application.compile_env(:custyard, :dev_routes) do
  #   import Phoenix.LiveDashboard.Router
  #
  #   scope "/dev" do
  #     pipe_through :browser
  #
  #     live_dashboard "/dashboard", metrics: CustyardWeb.Telemetry
  #   end
  # end
end
