defmodule CmAqiWeb.Router do
  @moduledoc """
  The Phoenix Router — maps URLs to the code that handles them.

  ## How Phoenix Routing Works

  When a browser requests a URL like "http://localhost:4000/subscribe", Phoenix:

  1. Receives the HTTP request at the Endpoint
  2. The Router matches the URL path against defined routes
  3. The request flows through a "pipeline" of plugs (middleware)
  4. Finally reaches the controller or LiveView that handles it

  ## Pipelines

  Pipelines are groups of plugs (middleware) that process requests.
  - `:browser` pipeline — for regular web pages (adds session, CSRF protection, etc.)
  - `:api` pipeline — for JSON API endpoints (no session needed)

  ## LiveView vs Controllers

  - **LiveView** (`live "/path", SomeLive`) — Interactive pages that update in real-time
    over WebSocket. Used for the dashboard and subscribe pages.
  - **Controllers** (`get "/path", SomeController, :action`) — Traditional request/response.
    Used for the LINE OAuth callback which is a simple redirect flow.
  """

  use CmAqiWeb, :router

  # ============================================================================
  # Pipelines
  # ============================================================================
  # A pipeline is an ordered series of "plugs" (middleware functions) that
  # process the request. Each plug can modify the connection (conn) struct.

  pipeline :browser do
    # Only accept HTML requests
    plug :accepts, ["html"]
    # Load session data from the cookie
    plug :fetch_session
    # Load flash messages for LiveView
    plug :fetch_live_flash
    # Set the outer HTML layout
    plug :put_root_layout, html: {CmAqiWeb.Layouts, :root}
    # CSRF protection (prevents cross-site attacks)
    plug :protect_from_forgery
    # Security headers (X-Frame-Options, etc.)
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # ============================================================================
  # Sitemap (XML, no browser pipeline needed)
  # ============================================================================

  scope "/", CmAqiWeb do
    get "/sitemap.xml", SitemapController, :index
  end

  # ============================================================================
  # Browser Routes
  # ============================================================================

  scope "/", CmAqiWeb do
    pipe_through :browser

    # `live` routes use Phoenix LiveView — these pages update in real-time
    # over a WebSocket connection without full page reloads.
    live "/", DashboardLive, :index
    live "/map", MapLive, :index
    live "/sensors", SensorsLive, :index
    live "/sensors/:station_id", SensorDetailLive, :show
    live "/subscribe", SubscribeLive, :index
    live "/about", AboutLive, :index
  end

  # ============================================================================
  # LINE OAuth Routes
  # ============================================================================
  # These use traditional controllers (not LiveView) because OAuth is a
  # redirect-based flow that doesn't need real-time WebSocket features.

  scope "/auth", CmAqiWeb do
    pipe_through :browser

    # Step 1: User clicks "Login with LINE" → we redirect them to LINE
    get "/line", LineAuthController, :request

    # Step 3: LINE redirects back here with an authorization code
    get "/line/callback", LineAuthController, :callback
  end

  # ============================================================================
  # Development-only Routes
  # ============================================================================
  # These routes are only available in dev mode (not in production).
  # They provide debugging tools like the Phoenix LiveDashboard.

  if Application.compile_env(:cm_aqi, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      # Phoenix LiveDashboard — shows metrics, processes, and system info
      live_dashboard "/dashboard", metrics: CmAqiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
