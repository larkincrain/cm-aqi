defmodule CmAqiWeb.LineAuthControllerTest do
  @moduledoc """
  Tests for the LINE OAuth callback controller.

  These tests verify that:
  1. The request action redirects to LINE's OAuth page
  2. The callback action handles successful logins
  3. The callback action handles error cases
  """

  use CmAqiWeb.ConnCase, async: false

  import Mox

  setup :verify_on_exit!

  describe "GET /auth/line" do
    test "redirects to LINE authorization URL", %{conn: conn} do
      conn = get(conn, ~p"/auth/line")

      # The response should be a 302 redirect
      assert redirected_to(conn) =~ "access.line.me/oauth2"
      # The session should contain the OAuth state
      assert get_session(conn, :line_oauth_state) != nil
    end
  end

  describe "GET /auth/line/callback" do
    test "handles successful OAuth flow", %{conn: conn} do
      # Set up the state in the session (simulating step 1)
      conn = conn |> init_test_session(%{line_oauth_state: "test-state"})

      # Mock the token exchange
      expect(CmAqi.HttpClient.Mock, :post, fn _url, _body, _headers ->
        {:ok, %{status: 200, body: %{"access_token" => "mock-token"}}}
      end)

      # Mock the profile fetch
      expect(CmAqi.HttpClient.Mock, :get, fn _url, _headers ->
        {:ok,
         %{
           status: 200,
           body: %{
             "userId" => "U1234567890",
             "displayName" => "Test User",
             "pictureUrl" => "https://example.com/pic.jpg"
           }
         }}
      end)

      conn = get(conn, ~p"/auth/line/callback", %{code: "mock-code", state: "test-state"})

      # Should redirect to subscribe page
      assert redirected_to(conn) == "/subscribe"
      # Should store the user ID in the session
      assert get_session(conn, :line_user_id) != nil
    end

    test "rejects callback with mismatched state (CSRF protection)", %{conn: conn} do
      conn = conn |> init_test_session(%{line_oauth_state: "original-state"})

      conn = get(conn, ~p"/auth/line/callback", %{code: "mock-code", state: "wrong-state"})

      assert redirected_to(conn) == "/subscribe"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "failed"
    end

    test "handles LINE OAuth errors", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/line/callback", %{
          error: "access_denied",
          error_description: "User denied"
        })

      assert redirected_to(conn) == "/subscribe"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "User denied"
    end
  end
end
