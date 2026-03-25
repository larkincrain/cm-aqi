defmodule CmAqi.AqiReadings.Reading do
  @moduledoc """
  Ecto schema for air quality readings stored in the `aqi_readings` database table.

  ## What is an Ecto Schema?

  In Elixir/Phoenix, an Ecto schema is a module that maps a database table to an
  Elixir struct. Think of it like an ORM model in other frameworks (like Django's
  Model or Rails' ActiveRecord). It defines:

  1. Which database table this module maps to
  2. What fields (columns) exist and their types
  3. Validation rules (called "changesets" in Ecto)

  ## What is a Changeset?

  A changeset is Ecto's way of validating and tracking changes to data BEFORE
  it hits the database. Instead of modifying data directly, you create a changeset
  that describes the change, validate it, and then apply it. This makes it easy
  to show validation errors to users and ensures data integrity.

  ## Fields

  | Field        | Type     | Description                                    |
  |-------------|----------|------------------------------------------------|
  | station_id  | string   | OpenAQ station identifier                      |
  | station_name| string   | Human-readable station name                    |
  | parameter   | string   | "pm25" or "pm10"                               |
  | value       | float    | Raw concentration in µg/m³                     |
  | aqi_value   | integer  | Computed EPA AQI index (0-500)                 |
  | category    | string   | AQI category label                             |
  | unit        | string   | Measurement unit (default: "µg/m³")            |
  | latitude    | float    | Station GPS latitude                           |
  | longitude   | float    | Station GPS longitude                          |
  | measured_at | datetime | When the reading was taken (from OpenAQ)       |
  """

  # `use Ecto.Schema` brings in the `schema` macro and field definition functions.
  # `import Ecto.Changeset` makes changeset functions available without the module prefix.
  use Ecto.Schema
  import Ecto.Changeset

  # This defines the struct and its mapping to the database table.
  # `schema "aqi_readings"` tells Ecto this module maps to the "aqi_readings" table.
  schema "aqi_readings" do
    field :station_id, :string
    field :station_name, :string
    field :parameter, :string
    field :value, :float
    field :aqi_value, :integer
    field :category, :string
    field :unit, :string, default: "µg/m³"
    field :latitude, :float
    field :longitude, :float
    field :measured_at, :utc_datetime

    # timestamps() adds :inserted_at and :updated_at fields automatically.
    # The `type: :utc_datetime` ensures times are stored in UTC.
    timestamps(type: :utc_datetime)
  end

  @doc """
  Creates a changeset for validating and inserting/updating a reading.

  A changeset is like a "proposed change" to the database. It:
  1. Takes existing data (or an empty struct) and proposed changes
  2. Casts (converts) the changes to the correct types
  3. Runs validations
  4. Returns a changeset struct that can be passed to `Repo.insert/1` or `Repo.update/1`

  ## Parameters

  - `reading` - An existing `%Reading{}` struct (or a new empty one)
  - `attrs` - A map of attributes to apply (e.g., `%{station_id: "123", value: 45.2}`)

  ## Example

      iex> changeset = Reading.changeset(%Reading{}, %{station_id: "abc", value: 42.0, ...})
      iex> changeset.valid?
      true

  """
  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(reading, attrs) do
    reading
    # `cast/3` takes the struct, the attributes map, and a list of allowed fields.
    # It converts the map values to the correct types defined in the schema.
    # Fields NOT in this list are silently ignored (security measure).
    |> cast(attrs, [
      :station_id,
      :station_name,
      :parameter,
      :value,
      :aqi_value,
      :category,
      :unit,
      :latitude,
      :longitude,
      :measured_at
    ])
    # `validate_required/2` ensures these fields are present and not nil.
    # If any are missing, the changeset becomes invalid (changeset.valid? == false).
    |> validate_required([:station_id, :station_name, :parameter, :value, :measured_at])
    # `validate_inclusion/3` ensures the value is one of the allowed options.
    |> validate_inclusion(:parameter, ["pm25", "pm10"], message: "must be either pm25 or pm10")
    # `validate_number/3` ensures the value is within a sensible range.
    |> validate_number(:value, greater_than_or_equal_to: 0, message: "must be non-negative")
  end
end
