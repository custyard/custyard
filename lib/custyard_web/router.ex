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
    plug CustyardWeb.Plugs.NoReferrer
    plug CustyardWeb.Plugs.PortalAuth
    plug :put_root_layout, html: {CustyardWeb.Layouts, :portal_root}
  end

  # Public prospect surfaces (/i intake, /c conversation, /claim slug-claim):
  # anonymous, hammerable, and carrying bearer tokens in the path. The
  # conversation URL must never leak via the Referer header, and the pages render
  # the sparse operator-branded :intake layout instead of the app chrome.
  pipeline :public_intake do
    plug CustyardWeb.Plugs.NoReferrer
    plug :put_root_layout, html: {CustyardWeb.Layouts, :intake_root}
  end

  pipeline :conversation_cookie do
    plug CustyardWeb.Plugs.ConversationCookie
  end

  scope "/", CustyardWeb do
    pipe_through :browser

    live "/", HomeLive, :index
  end

  # Public intake pages — anonymous dead views, one per operator-configured
  # intake source key. Served on the application host only: on a custom
  # domain the CustomDomain plug rewrites /i/* into the portal scope, where
  # it 404s (intake is an operator surface, never a customer-portal one).
  scope "/intake", CustyardWeb do
    pipe_through [:browser, :public_intake]

    get "/:source_key", IntakeController, :show
    post "/:source_key", IntakeController, :create
  end

  # Conversation access — the token in the URL is the credential; every mount
  # re-authenticates it (nothing lives in the session). The uniform
  # "conversation unavailable" page is a dead view so invalid tokens never
  # cost a LiveView socket; it must be declared before the catch-all live
  # route ("unavailable" is not a valid token shape, but order still matters).
  scope "/threads", CustyardWeb do
    pipe_through [:browser, :public_intake, :conversation_cookie]

    get "/unavailable", Prospect.ConversationController, :unavailable

    live_session :prospect_conversation,
      on_mount: [{CustyardWeb.Live.ProspectAuth, :default}],
      layout: {CustyardWeb.Layouts, :intake} do
      live "/:token", Prospect.ConversationLive, :show
    end
  end

  # Slug-claim confirmation — scanner-safe dead views. GET peeks (zero
  # state change, so mail-scanner prefetch never consumes the single-use
  # token); the explicit POST confirms. Same no-referrer + :intake layout
  # discipline as /i and /c: the token in the path is a bearer credential.
  scope "/claims", CustyardWeb do
    pipe_through [:browser, :public_intake]

    get "/:token", ClaimConfirmationController, :show
    post "/:token/confirm", ClaimConfirmationController, :confirm
  end

  scope "/api", CustyardWeb do
    pipe_through :api

    get "/health", HealthController, :index

    # Routed webhooks — dispatched by callback_token with source-specific adapters
    post "/webhook/route/:callback_token", WebhookController, :routed

    # Provider delivery-status events for outbound replies (separate from inbound intake)
    post "/webhook/email-status/lettermint/:callback_token", EmailStatusController, :lettermint
  end

  scope "/app", CustyardWeb.Operator do
    pipe_through [:browser]
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/login/sent", SessionController, :sent
    get "/login/verify/:token", SessionController, :verify
    post "/login/verify/:token", SessionController, :consume
    delete "/logout", SessionController, :delete
  end

  scope "/app", CustyardWeb.Operator do
    pipe_through [:browser, :require_operator]
    get "/attachments/:id", AttachmentController, :show
    get "/attachments/:id/inline", AttachmentController, :inline

    live_session :staff,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :default}],
      layout: {CustyardWeb.Layouts, :operator} do
      live "/", AttentionQueueLive, :index
      live "/threads", AttentionQueueLive, :index
      live "/threads/:id", ConversationLive, :show
      live "/projects", ProjectsLive, :index
      live "/projects/:id", ProjectDetailLive, :show
      live "/neglect", NeglectReportLive, :index
      live "/customers", OrganizationsLive, :index
      live "/customers/:id", OrganizationDetailLive, :show
    end

    live_session :staff_admin,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :require_admin}],
      layout: {CustyardWeb.Layouts, :operator} do
      live "/settings/email", EmailSetupLive, :index
      live "/settings/workspace", TenantSettingsLive, :index
      live "/settings/staff", TenantSettingsLive, :index
      live "/settings/intake", IntakeSourcesLive, :index
      live "/settings/workflow", SettingsLive, :index
      live "/settings/slugs", SlugsLive, :index
      live "/settings/integrations", AcknowledgmentsLive, :index
    end
  end

  scope "/admin", CustyardWeb.Admin do
    pipe_through [:browser]
    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/login/verify/:token", SessionController, :verify
    post "/login/verify/:token", SessionController, :consume
    delete "/logout", SessionController, :delete

    live_session :instance_admin,
      on_mount: [{CustyardWeb.Live.InstanceAdminAuth, :default}],
      layout: {CustyardWeb.Layouts, :admin} do
      live "/", TenantsLive, :index
      live "/tenants", TenantsLive, :index
      live "/tenants/:id/settings", TenantsLive, :show
    end
  end

  scope "/portal/:org_token", CustyardWeb.Portal do
    pipe_through [:browser, :portal_auth]
    get "/attachments/:id", AttachmentController, :show

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

  # Development-only routes. dev_routes is set to true only in config/dev.exs,
  # so nothing here mounts in prod.
  if Application.compile_env(:custyard, :dev_routes) do
    # In dev, outbound mail is captured by the Swoosh Local (in-memory) adapter.
    # This UI renders that mailbox so you can open magic-link login emails at
    # http://localhost:4000/dev/mailbox. Deliberately NOT piped through :browser:
    # the strict CSP (script-src 'self') would block the preview's inline <script>.
    forward "/dev/mailbox", Plug.Swoosh.MailboxPreview

    # LiveDashboard (requires the phoenix_live_dashboard dependency, not yet added):
    # import Phoenix.LiveDashboard.Router
    # scope "/dev" do
    #   pipe_through :browser
    #   live_dashboard "/dashboard", metrics: CustyardWeb.Telemetry
    # end
  end
end
