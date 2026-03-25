defmodule CmAqi.Repo.Migrations.CreateLineSubscriptions do
  use Ecto.Migration

  def change do
    create table(:line_subscriptions) do
      # references(:line_users) creates a foreign key relationship.
      # This means every subscription MUST belong to an existing line_user.
      # on_delete: :delete_all means if we delete a user, their subscriptions go too.
      add :line_user_id, references(:line_users, on_delete: :delete_all), null: false

      # alert_threshold: The minimum AQI value at which the user wants notifications.
      # Options: 101 (Unhealthy for Sensitive Groups), 151 (Unhealthy),
      #          201 (Very Unhealthy), 301 (Hazardous)
      add :alert_threshold, :integer, null: false, default: 151

      # active: Whether this subscription is currently active.
      # Users can "pause" notifications without deleting their subscription.
      add :active, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    # Index on line_user_id for fast lookups when querying a user's subscriptions
    create index(:line_subscriptions, [:line_user_id])

    # Each user should only have one subscription
    create unique_index(:line_subscriptions, [:line_user_id],
             name: :line_subscriptions_user_unique
           )
  end
end
