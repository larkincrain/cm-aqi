defmodule CmAqi.Subscriptions.LineUser do
  @moduledoc """
  Ecto schema for LINE users who have logged in via LINE Login OAuth.

  When a user clicks "Login with LINE" on our subscribe page, LINE sends us
  their profile information (user ID, display name, profile picture). We store
  that information here so we can send them push notifications later.

  ## What is LINE?

  LINE is the dominant messaging app in Thailand (and Japan/Taiwan). It's like
  WhatsApp or iMessage but with a rich API for businesses. We use two LINE APIs:
  - LINE Login: Lets users authenticate with their LINE account (OAuth2)
  - LINE Messaging API: Lets us send push notifications to users

  ## Fields

  | Field         | Type   | Description                           |
  |---------------|--------|---------------------------------------|
  | line_user_id  | string | LINE's unique user identifier (U...)  |
  | display_name  | string | User's LINE display name              |
  | picture_url   | string | URL to their LINE profile picture     |
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "line_users" do
    field :line_user_id, :string
    field :display_name, :string
    field :picture_url, :string

    # `has_many` defines a one-to-many relationship.
    # One LINE user can have many subscriptions (though in practice, just one).
    # This lets us do things like `user.subscriptions` to load related records.
    has_many :subscriptions, CmAqi.Subscriptions.LineSubscription,
      foreign_key: :line_user_id,
      references: :id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a LINE user.

  Called after a successful LINE Login OAuth flow, when we receive the user's
  profile information from LINE's API.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(line_user, attrs) do
    line_user
    |> cast(attrs, [:line_user_id, :display_name, :picture_url])
    |> validate_required([:line_user_id])
    # unique_constraint tells Ecto to handle the database's unique index gracefully.
    # Instead of crashing on duplicate inserts, it adds an error to the changeset.
    |> unique_constraint(:line_user_id)
  end
end
