# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cm_aqi,
  ecto_repos: [CmAqi.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :cm_aqi, CmAqiWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CmAqiWeb.ErrorHTML, json: CmAqiWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CmAqi.PubSub,
  live_view: [signing_salt: "wFHVu5GY"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cm_aqi, CmAqi.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  cm_aqi: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  cm_aqi: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ============================================================================
# LINE Messaging API Configuration
# ============================================================================
# These are placeholder values for development. In production, these are
# loaded from environment variables in config/runtime.exs.
#
# LINE_CHANNEL_ID     - Your LINE Login channel ID (from LINE Developers Console)
# LINE_CHANNEL_SECRET - Your LINE Login channel secret
# LINE_CHANNEL_ACCESS_TOKEN - Your LINE Messaging API channel access token
# LINE_CALLBACK_URL   - The OAuth callback URL (e.g., http://localhost:4000/auth/line/callback)
config :cm_aqi, :line,
  channel_id: System.get_env("LINE_CHANNEL_ID", "your_channel_id"),
  channel_secret: System.get_env("LINE_CHANNEL_SECRET", "your_channel_secret"),
  channel_access_token: System.get_env("LINE_CHANNEL_ACCESS_TOKEN", "your_access_token"),
  callback_url: System.get_env("LINE_CALLBACK_URL", "http://localhost:4000/auth/line/callback")

# ============================================================================
# AQICN API Configuration
# ============================================================================
# AQICN (waqi.info) provides world air quality data including computed AQI values.
# Register for a free token at https://aqicn.org/data-platform/token/
# The token is passed as a query parameter: ?token=YOUR_TOKEN
config :cm_aqi, :aqicn_api_token, System.get_env("AQICN_API_TOKEN")

# NASA FIRMS API Configuration
# ============================================================================
# FIRMS provides near-real-time fire detection data from VIIRS satellites.
# Register for a free MAP_KEY at https://firms.modaps.eosdis.nasa.gov/
config :cm_aqi, :firms_map_key, System.get_env("FIRMS_MAP_KEY")

# ============================================================================
# HTTP Client Configuration
# ============================================================================
# We use a behaviour pattern so we can swap in a mock client during tests.
# In production/dev, we use the real Req-based HTTP client.
# In tests, Mox provides a mock implementation.
config :cm_aqi, :http_client, CmAqi.HttpClient.Req

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
