defmodule CmAqi.HttpClient do
  @moduledoc """
  Behaviour (interface) for HTTP clients used throughout the application.

  ## What is a Behaviour?

  In Elixir, a "behaviour" is like an interface in Java or a protocol in Swift.
  It defines a set of functions that any implementing module MUST provide.

  ## Why Use a Behaviour for HTTP?

  We talk to two external APIs:
  1. **OpenAQ API** — to fetch air quality data
  2. **LINE API** — to send push notifications and handle OAuth

  In production, we use real HTTP calls (via the `Req` library). But in tests,
  we don't want to make real API calls — that would be slow, flaky, and might
  hit rate limits. Instead, we use **Mox** to create a mock that implements
  this same behaviour.

  This pattern is called "dependency injection" — we swap the real implementation
  for a fake one in tests. The config determines which implementation to use:

      # config/config.exs (production/dev)
      config :cm_aqi, :http_client, CmAqi.HttpClient.Req

      # config/test.exs
      config :cm_aqi, :http_client, CmAqi.HttpClient.Mock

  ## How to Get the Current Client

  Instead of hardcoding `CmAqi.HttpClient.Req`, modules call:

      client = CmAqi.HttpClient.client()
      client.get(url, headers)

  This returns whichever module is configured for the current environment.
  """

  # `@callback` defines a function that implementing modules must provide.
  # Think of it as an abstract method in an abstract class.

  @doc "Performs an HTTP GET request. Returns {:ok, response} or {:error, reason}."
  @callback get(url :: String.t(), headers :: list()) ::
              {:ok, map()} | {:error, any()}

  @doc "Performs an HTTP POST request with a JSON body."
  @callback post(url :: String.t(), body :: map(), headers :: list()) ::
              {:ok, map()} | {:error, any()}

  @doc """
  Returns the configured HTTP client module.

  Reads from application config, defaulting to the real Req-based client.
  """
  @spec client() :: module()
  def client do
    # Application.get_env reads from the app's configuration.
    # The first argument is the app name (:cm_aqi), the second is the config key.
    Application.get_env(:cm_aqi, :http_client, CmAqi.HttpClient.Req)
  end
end
