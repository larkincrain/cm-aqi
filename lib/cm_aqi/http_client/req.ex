defmodule CmAqi.HttpClient.Req do
  @moduledoc """
  Real HTTP client implementation using the Req library.

  ## What is Req?

  Req is a modern, batteries-included HTTP client for Elixir. It's the successor
  to HTTPoison/Tesla and is now included by default in Phoenix 1.8+ projects.
  It handles JSON encoding/decoding, retries, and other common patterns.

  This module is used in development and production for making real HTTP calls
  to the OpenAQ and LINE APIs. In tests, it's replaced by a Mox mock.
  """

  # `@behaviour` declares that this module implements the CmAqi.HttpClient behaviour.
  # The compiler will warn us if we forget to implement any @callback functions.
  @behaviour CmAqi.HttpClient

  @doc """
  Makes an HTTP GET request to the given URL.

  ## Parameters

  - `url` - The full URL to request (e.g., "https://api.openaq.org/v3/locations")
  - `headers` - A list of {key, value} header tuples

  ## Returns

  - `{:ok, %{status: 200, body: %{...}}}` on success
  - `{:error, reason}` on failure
  """
  @impl true
  def get(url, headers \\ []) do
    # Req.get! would raise on error; Req.get returns {:ok, resp} / {:error, reason}
    case Req.get(url, headers: headers) do
      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes an HTTP POST request with a JSON body.

  ## Parameters

  - `url` - The full URL to POST to
  - `body` - A map that will be JSON-encoded as the request body
  - `headers` - A list of {key, value} header tuples
  """
  @impl true
  def post(url, body, headers \\ []) do
    case Req.post(url, json: body, headers: headers) do
      {:ok, %Req.Response{status: status, body: resp_body}} ->
        {:ok, %{status: status, body: resp_body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
