defmodule CmAqi.Subscriptions do
  @moduledoc """
  The Subscriptions context — manages LINE users and their notification preferences.

  This context handles:
  - Creating/finding LINE users after OAuth login
  - Managing subscription preferences (threshold, active/inactive)
  - Querying active subscribers for a given AQI threshold
  """

  import Ecto.Query
  alias CmAqi.Repo
  alias CmAqi.Subscriptions.LineUser
  alias CmAqi.Subscriptions.LineSubscription

  # ============================================================================
  # LINE User Operations
  # ============================================================================

  @doc """
  Finds or creates a LINE user by their LINE user ID.

  Called after a successful LINE Login OAuth flow. If the user has logged in
  before, we update their profile info. If they're new, we create a record.

  ## Parameters

  - `attrs` - Map with `:line_user_id`, `:display_name`, `:picture_url`
  """
  @spec find_or_create_line_user(map()) :: {:ok, LineUser.t()} | {:error, Ecto.Changeset.t()}
  def find_or_create_line_user(%{line_user_id: line_user_id} = attrs) do
    case Repo.get_by(LineUser, line_user_id: line_user_id) do
      nil ->
        # User doesn't exist yet — create them
        %LineUser{}
        |> LineUser.changeset(attrs)
        |> Repo.insert()

      existing_user ->
        # User exists — update their profile info (name/picture might change)
        existing_user
        |> LineUser.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets a LINE user by their LINE user ID.

  Returns nil if no user found.
  """
  @spec get_line_user_by_line_id(String.t()) :: LineUser.t() | nil
  def get_line_user_by_line_id(line_user_id) do
    Repo.get_by(LineUser, line_user_id: line_user_id)
  end

  @doc """
  Gets a LINE user by their database ID, preloading their subscriptions.
  """
  @spec get_line_user(integer()) :: LineUser.t() | nil
  def get_line_user(id) do
    LineUser
    |> Repo.get(id)
    |> Repo.preload(:subscriptions)
  end

  # ============================================================================
  # Subscription Operations
  # ============================================================================

  @doc """
  Creates or updates a subscription for a LINE user.

  Each user can only have one subscription (enforced by the unique index).
  If they already have one, we update it. Otherwise, we create a new one.

  ## Parameters

  - `line_user_id` - The database ID (not the LINE user ID string)
  - `attrs` - Map with `:alert_threshold` and optionally `:active`
  """
  @spec create_or_update_subscription(integer(), map()) ::
          {:ok, LineSubscription.t()} | {:error, Ecto.Changeset.t()}
  def create_or_update_subscription(line_user_id, attrs) do
    case get_subscription_for_user(line_user_id) do
      nil ->
        %LineSubscription{}
        |> LineSubscription.changeset(Map.put(attrs, :line_user_id, line_user_id))
        |> Repo.insert()

      existing ->
        existing
        |> LineSubscription.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Gets the subscription for a given LINE user (by database ID).
  """
  @spec get_subscription_for_user(integer()) :: LineSubscription.t() | nil
  def get_subscription_for_user(line_user_id) do
    Repo.get_by(LineSubscription, line_user_id: line_user_id)
  end

  @doc """
  Deactivates a user's subscription (soft unsubscribe).

  We don't delete the record — just set active to false. This way, if they
  resubscribe, their previous threshold preference is preserved.
  """
  @spec unsubscribe(integer()) :: {:ok, LineSubscription.t()} | {:error, Ecto.Changeset.t()} | nil
  def unsubscribe(line_user_id) do
    case get_subscription_for_user(line_user_id) do
      nil -> nil
      sub -> sub |> LineSubscription.changeset(%{active: false}) |> Repo.update()
    end
  end

  @doc """
  Reactivates a user's subscription.
  """
  @spec resubscribe(integer()) ::
          {:ok, LineSubscription.t()} | {:error, Ecto.Changeset.t()} | nil
  def resubscribe(line_user_id) do
    case get_subscription_for_user(line_user_id) do
      nil -> nil
      sub -> sub |> LineSubscription.changeset(%{active: true}) |> Repo.update()
    end
  end

  @doc """
  Returns all active subscribers whose alert threshold is at or below the given AQI value.

  For example, if the current AQI is 160 (Unhealthy), this returns all subscribers
  with threshold ≤ 160. That means subscribers with threshold 101 and 151 would
  be notified, but NOT those with threshold 201 or 301.

  ## Parameters

  - `aqi_value` - The current AQI value to check against

  ## Returns

  A list of `{line_user_id_string, display_name}` tuples.
  """
  @spec get_subscribers_for_threshold(integer()) :: [{String.t(), String.t()}]
  def get_subscribers_for_threshold(aqi_value) do
    from(s in LineSubscription,
      join: u in LineUser,
      on: s.line_user_id == u.id,
      where: s.active == true and s.alert_threshold <= ^aqi_value,
      select: {u.line_user_id, u.display_name}
    )
    |> Repo.all()
  end
end
