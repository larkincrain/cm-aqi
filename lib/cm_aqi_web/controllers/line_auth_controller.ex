defmodule CmAqiWeb.LineAuthController do
  @moduledoc """
  Handles the LINE Login OAuth2 flow.

  ## OAuth2 Flow Overview

  OAuth2 is a standard protocol that lets users log into our app using their
  LINE account, WITHOUT us ever seeing their LINE password. Here's the flow:

  ### Step 1: Request (`/auth/line`)
  User clicks "Login with LINE" → We redirect them to LINE's authorization page.
  We include a random `state` parameter (stored in the session) to prevent
  CSRF attacks.

  ### Step 2: LINE Authorization
  The user sees LINE's login page and approves our app. This happens entirely
  on LINE's servers — we're not involved.

  ### Step 3: Callback (`/auth/line/callback`)
  LINE redirects the user back to our callback URL with two query parameters:
  - `code` — A short-lived authorization code
  - `state` — The same state we sent (we verify it matches to prevent CSRF)

  ### Step 4: Token Exchange
  We send the `code` to LINE's token endpoint and get back an access token.

  ### Step 5: Profile Fetch
  We use the access token to call LINE's profile API and get the user's ID,
  display name, and profile picture.

  ### Step 6: Create/Update User
  We store the user's LINE profile in our database and set their ID in the session.

  ## Why a Controller Instead of LiveView?

  OAuth requires HTTP redirects (302 responses), which LiveView doesn't support
  because it uses WebSockets. Controllers handle traditional HTTP request/response
  cycles, making them perfect for OAuth flows.
  """

  use CmAqiWeb, :controller

  alias CmAqi.LineClient
  alias CmAqi.Subscriptions

  require Logger

  @doc """
  Initiates the LINE Login OAuth flow by redirecting to LINE's auth page.

  Generates a random `state` parameter for CSRF protection and stores it
  in the session. Then redirects the user to LINE's authorization URL.
  """
  @spec request(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def request(conn, _params) do
    # Generate a random state token for CSRF protection.
    # :crypto.strong_rand_bytes generates cryptographically secure random bytes.
    # Base.url_encode64 converts them to a URL-safe string.
    state = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)

    # Store the state in the session so we can verify it in the callback.
    # `put_session/3` adds a key-value pair to the session cookie.
    conn
    |> put_session(:line_oauth_state, state)
    |> redirect(external: LineClient.authorize_url(state))
  end

  @doc """
  Handles the OAuth callback from LINE after user authorization.

  LINE redirects here with `code` and `state` query parameters.
  We verify the state, exchange the code for a token, fetch the user's
  profile, and create/update their record in our database.
  """
  @spec callback(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def callback(conn, %{"code" => code, "state" => state}) do
    # Verify the state parameter matches what we stored in the session.
    # This prevents CSRF attacks where an attacker could trick a user
    # into completing an OAuth flow they didn't initiate.
    stored_state = get_session(conn, :line_oauth_state)

    if state != stored_state do
      Logger.warning("LINE OAuth state mismatch — possible CSRF attack")

      conn
      |> put_flash(:error, "Authentication failed. Please try again.")
      |> redirect(to: ~p"/subscribe")
    else
      # State is valid — proceed with the OAuth flow
      handle_oauth_exchange(conn, code)
    end
  end

  # Handle cases where LINE returns an error instead of a code
  def callback(conn, %{"error" => error, "error_description" => description}) do
    Logger.error("LINE OAuth error: #{error} — #{description}")

    conn
    |> put_flash(:error, "LINE login failed: #{description}")
    |> redirect(to: ~p"/subscribe")
  end

  # Catch-all for unexpected callback parameters
  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Invalid callback. Please try again.")
    |> redirect(to: ~p"/subscribe")
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  # Exchanges the authorization code for a token, then fetches the user's profile.
  @spec handle_oauth_exchange(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  defp handle_oauth_exchange(conn, code) do
    # `with` chains multiple operations that might fail.
    # If any step returns something that doesn't match {:ok, _}, the `else`
    # block catches it. This is much cleaner than nested case statements.
    with {:ok, token_data} <- LineClient.exchange_token(code),
         access_token = Map.get(token_data, "access_token"),
         {:ok, profile} <- LineClient.get_profile(access_token),
         {:ok, user} <- create_or_update_user(profile) do
      Logger.info("LINE OAuth success for user: #{user.display_name}")

      # Store the user's database ID in the session.
      # This is how we know the user is logged in on subsequent requests.
      conn
      |> put_session(:line_user_id, user.id)
      # Clean up the OAuth state from the session (no longer needed)
      |> delete_session(:line_oauth_state)
      |> put_flash(:info, "Welcome, #{user.display_name}!")
      |> redirect(to: ~p"/subscribe")
    else
      {:error, reason} ->
        Logger.error("LINE OAuth flow failed: #{inspect(reason)}")

        conn
        |> put_flash(:error, "Login failed. Please try again.")
        |> redirect(to: ~p"/subscribe")
    end
  end

  # Creates or updates a LINE user from their profile data.
  @spec create_or_update_user(map()) :: {:ok, struct()} | {:error, any()}
  defp create_or_update_user(profile) do
    Subscriptions.find_or_create_line_user(%{
      line_user_id: Map.get(profile, "userId"),
      display_name: Map.get(profile, "displayName"),
      picture_url: Map.get(profile, "pictureUrl")
    })
  end
end
