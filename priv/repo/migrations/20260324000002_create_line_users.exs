defmodule CmAqi.Repo.Migrations.CreateLineUsers do
  use Ecto.Migration

  def change do
    create table(:line_users) do
      # line_user_id: The unique user ID from LINE (starts with "U" followed by hex characters)
      # This is how LINE identifies each user globally
      add :line_user_id, :string, null: false

      # display_name: The user's LINE display name (can change, so we store it for convenience)
      add :display_name, :string

      # picture_url: URL to the user's LINE profile picture
      add :picture_url, :string

      timestamps(type: :utc_datetime)
    end

    # Each LINE user should only appear once in our system
    create unique_index(:line_users, [:line_user_id])
  end
end
