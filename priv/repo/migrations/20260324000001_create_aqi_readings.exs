defmodule CmAqi.Repo.Migrations.CreateAqiReadings do
  use Ecto.Migration

  # Migrations are how Ecto (Elixir's database library) manages database schema changes.
  # Each migration file represents a change to the database structure.
  # When you run `mix ecto.migrate`, Ecto runs all pending migrations in order.

  def change do
    # `create table` generates a SQL CREATE TABLE statement.
    # The :aqi_readings atom becomes the table name "aqi_readings".
    create table(:aqi_readings) do
      # station_id: The unique identifier from OpenAQ for this monitoring station
      add :station_id, :string, null: false

      # station_name: Human-readable name like "Chiang Mai University"
      add :station_name, :string, null: false

      # parameter: What's being measured — "pm25" or "pm10"
      # PM2.5 = fine particulate matter (≤2.5 micrometers)
      # PM10 = coarse particulate matter (≤10 micrometers)
      add :parameter, :string, null: false

      # value: The raw measurement in µg/m³ (micrograms per cubic meter)
      add :value, :float, null: false

      # aqi_value: The computed US EPA Air Quality Index (0-500 scale)
      # This is calculated from the raw value using EPA breakpoint formulas
      add :aqi_value, :integer

      # category: Human-readable category like "Good", "Moderate", "Unhealthy"
      add :category, :string

      # unit: The measurement unit, typically "µg/m³"
      add :unit, :string, default: "µg/m³"

      # latitude/longitude: GPS coordinates of the monitoring station
      add :latitude, :float
      add :longitude, :float

      # measured_at: When the reading was actually taken (from OpenAQ)
      # This is different from inserted_at which is when WE stored it
      add :measured_at, :utc_datetime, null: false

      # timestamps() automatically adds inserted_at and updated_at columns
      # These track when the row was created/modified in OUR database
      timestamps(type: :utc_datetime)
    end

    # Indexes speed up database queries. Think of them like a book's index —
    # instead of scanning every row, the database can jump right to matching rows.

    # We query by station_id frequently (to get a specific station's readings)
    create index(:aqi_readings, [:station_id])

    # We query by measured_at to get recent readings and historical data
    create index(:aqi_readings, [:measured_at])

    # This UNIQUE index prevents duplicate readings. If we try to insert a reading
    # with the same station_id + parameter + measured_at, the database will reject it.
    # This is crucial for our "upsert" strategy (insert or update if exists).
    create unique_index(:aqi_readings, [:station_id, :parameter, :measured_at],
             name: :aqi_readings_station_param_time_index
           )
  end
end
