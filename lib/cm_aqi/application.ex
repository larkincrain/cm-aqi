defmodule CmAqi.Application do
  @moduledoc """
  The OTP Application module — the entry point for the entire application.

  ## What is an OTP Application?

  In Elixir/OTP, an "application" is the top-level unit of code that gets started
  and stopped together. When you run `mix phx.server`, this module's `start/2`
  function is called.

  ## The Supervision Tree

  The `children` list defines the application's "supervision tree" — a hierarchy
  of processes that are started, monitored, and automatically restarted if they
  crash. This is one of Elixir's most powerful features: fault tolerance by design.

  The order matters! Each child is started in the order listed:
  1. Telemetry — monitoring and metrics
  2. Repo — database connection pool
  3. PubSub — inter-process message broadcasting
  4. AqiPoller — periodically fetches air quality data
  5. AlertBroadcaster — monitors AQI changes and sends notifications
  6. Endpoint — the web server (starts last so everything else is ready)

  ## Supervision Strategy

  `:one_for_one` means if a child process crashes, ONLY that process is restarted.
  Other strategies include `:one_for_all` (restart everything if one crashes) and
  `:rest_for_one` (restart the crashed process and all processes started after it).
  """

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Telemetry: collects and reports application metrics
      CmAqiWeb.Telemetry,

      # Repo: the database connection pool (must start before anything that queries the DB)
      CmAqi.Repo,

      # DNS Cluster: for distributed Elixir nodes (used in production on Fly.io)
      {DNSCluster, query: Application.get_env(:cm_aqi, :dns_cluster_query) || :ignore},

      # PubSub: enables broadcasting messages between processes.
      # This is how AqiPoller sends real-time updates to LiveView dashboards
      # and the AlertBroadcaster.
      {Phoenix.PubSub, name: CmAqi.PubSub},

      # AqiPoller: our GenServer that polls OpenAQ every 10 minutes.
      # It's started here so it begins polling as soon as the app boots.
      CmAqi.AqiPoller,

      # FirePoller: polls NASA FIRMS for active fire detections in northern Thailand.
      CmAqi.FirePoller,

      # AlertBroadcaster: subscribes to PubSub and sends LINE notifications
      # when AQI thresholds are crossed. Started after PubSub so it can subscribe.
      CmAqi.AlertBroadcaster,

      # Endpoint: the Phoenix web server — started last so all other services
      # are ready before we begin accepting web requests.
      CmAqiWeb.Endpoint
    ]

    # :one_for_one supervision: if any ONE child crashes, only THAT child is restarted.
    # The supervisor keeps running and watching the other children.
    opts = [strategy: :one_for_one, name: CmAqi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Called when the application's configuration changes (e.g., in dev with hot reload).
  @impl true
  def config_change(changed, _new, removed) do
    CmAqiWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
