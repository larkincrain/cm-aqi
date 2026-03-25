defmodule CmAqi.AqiPollerTest do
  @moduledoc """
  Tests for the AqiPoller GenServer using Mox.

  ## Testing GenServers

  Testing a GenServer involves:
  1. Starting it in a controlled way
  2. Sending it messages or calling its API
  3. Verifying it responded correctly

  ## Using Mox

  We use Mox to mock the HTTP client, so tests don't make real API calls.
  Instead, we tell the mock exactly what to return for each HTTP request.

  ## Note on `async: false`

  These tests can't run in parallel because they use Mox in global mode.
  GenServers run in their own process, so we need global mode for the mock
  to be accessible from the GenServer's process (not just the test process).
  """

  use CmAqi.DataCase, async: false

  import Mox

  # Set Mox to global mode so the GenServer process can use our mock.
  # In global mode, ANY process can call the mock (not just the test process).
  setup do
    Mox.set_mox_global()
    :ok
  end

  describe "AqiPoller initialization" do
    test "starts successfully with a custom name" do
      # Stub the HTTP client so the GenServer doesn't make real API calls.
      # The AQICN search endpoint returns a list of stations.
      stub(CmAqi.HttpClient.Mock, :get, fn _url, _headers ->
        {:ok, %{status: 200, body: %{"status" => "ok", "data" => []}}}
      end)

      # Start with a unique name to avoid conflicting with the app's poller
      assert {:ok, pid} = CmAqi.AqiPoller.start_link(name: :test_poller_init)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end

  describe "AQICN response handling" do
    test "handles empty search results" do
      stub(CmAqi.HttpClient.Mock, :get, fn _url, _headers ->
        {:ok, %{status: 200, body: %{"status" => "ok", "data" => []}}}
      end)

      assert {:ok, pid} = CmAqi.AqiPoller.start_link(name: :test_poller_empty)

      # Give the poller time to make its first poll (scheduled 1 second after start)
      Process.sleep(2000)

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "handles API errors gracefully without crashing" do
      stub(CmAqi.HttpClient.Mock, :get, fn _url, _headers ->
        {:error, %Req.TransportError{reason: :timeout}}
      end)

      assert {:ok, pid} = CmAqi.AqiPoller.start_link(name: :test_poller_error)

      # The poller should survive API failures (it logs and retries)
      Process.sleep(2000)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end

    test "handles AQICN API error responses" do
      stub(CmAqi.HttpClient.Mock, :get, fn _url, _headers ->
        {:ok, %{status: 200, body: %{"status" => "error", "data" => "Invalid key"}}}
      end)

      assert {:ok, pid} = CmAqi.AqiPoller.start_link(name: :test_poller_api_error)

      Process.sleep(2000)
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
