defmodule CmAqi.Repo.Migrations.CreateHourlyAverages do
  use Ecto.Migration

  def change do
    create table(:hourly_averages) do
      add :hour, :utc_datetime, null: false
      add :avg_aqi, :integer, null: false
      add :station_count, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hourly_averages, [:hour])
  end
end
