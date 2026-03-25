defmodule CustyardWeb.Router do
  use CustyardWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CustyardWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :require_operator do
    plug CustyardWeb.Plugs.RequireOperator
  end

  pipeline :portal_auth do
    plug CustyardWeb.Plugs.PortalAuth
  end

  scope "/", CustyardWeb do
    pipe_through :browser

    live "/", HomeLive, :index
  end

  scope "/api", CustyardWeb do
    pipe_through :api

    # Legacy Lettermint webhook (backward compatible)
    post "/webhook/inbound", WebhookController, :inbound

    # Routed webhooks — dispatched by callback_token with source-specific adapters
    post "/webhook/route/:callback_token", WebhookController, :routed
  end

  # Operator routes - public (login/logout)
  scope "/operator", CustyardWeb.Operator, as: :operator do
    pipe_through [:browser]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  # Operator routes - protected LiveViews
  scope "/operator", CustyardWeb.Operator, as: :operator do
    pipe_through [:browser, :require_operator]

    live_session :operator,
      on_mount: [{CustyardWeb.Live.OperatorAuth, :default}] do
      live "/", AttentionQueueLive, :index
      live "/conversation/:id", ConversationLive, :show
      live "/organizations", OrganizationsLive, :index
      live "/projects", ProjectsLive, :index
      live "/neglect", NeglectReportLive, :index
      live "/settings", SettingsLive, :index
    end
  end

  # Portal routes - accessed via unguessable org token or custom domain
  scope "/p/:org_token", CustyardWeb.Portal, as: :portal do
    pipe_through [:browser, :portal_auth]

    live_session :portal,
      on_mount: [{CustyardWeb.Live.PortalAuth, :default}] do
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
