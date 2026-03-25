defmodule CmAqi.Subscriptions.LineSubscription do
  @moduledoc """
  Ecto schema for LINE notification subscriptions.

  Each subscription links a LINE user to their notification preferences.
  Users choose a minimum AQI threshold — they'll only receive alerts when
  the AQI crosses above (or clears below) that threshold.

  ## Alert Thresholds

  | Threshold | Category                       | Meaning                              |
  |-----------|--------------------------------|--------------------------------------|
  | 101       | Unhealthy for Sensitive Groups | Alert when air becomes risky         |
  | 151       | Unhealthy                      | Alert when air is unhealthy for all  |
  | 201       | Very Unhealthy                 | Alert for serious health effects     |
  | 301       | Hazardous                      | Alert for health emergencies only    |

  Lower thresholds = more notifications. Most users in Chiang Mai during burn
  season would want 101 or 151.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "line_subscriptions" do
    # `belongs_to` is the inverse of `has_many` — it defines the "child" side
    # of the relationship. This subscription belongs to one LINE user.
    belongs_to :line_user, CmAqi.Subscriptions.LineUser

    field :alert_threshold, :integer, default: 151
    field :active, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for a subscription.

  Validates that the alert threshold is one of the predefined levels.
  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:line_user_id, :alert_threshold, :active])
    |> validate_required([:line_user_id, :alert_threshold])
    # Only allow the predefined threshold values
    |> validate_inclusion(:alert_threshold, [101, 151, 201, 301],
      message: "must be 101, 151, 201, or 301"
    )
    # Ensure the referenced line_user actually exists in the database
    |> foreign_key_constraint(:line_user_id)
    # One subscription per user
    |> unique_constraint(:line_user_id, name: :line_subscriptions_user_unique)
  end
end
