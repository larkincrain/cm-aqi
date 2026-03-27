defmodule CmAqi.AqiReadings.HourlyAverage do
  @moduledoc """
  Schema for pre-computed hourly city-wide AQI averages.

  Instead of computing averages on the fly (which requires scanning all readings),
  the poller upserts an hourly average each time new data arrives. The dashboard
  reads directly from this table for the average chart.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "hourly_averages" do
    field :hour, :utc_datetime
    field :avg_aqi, :integer
    field :station_count, :integer

    timestamps(type: :utc_datetime)
  end

  @spec changeset(%__MODULE__{}, map()) :: Ecto.Changeset.t()
  def changeset(average, attrs) do
    average
    |> cast(attrs, [:hour, :avg_aqi, :station_count])
    |> validate_required([:hour, :avg_aqi, :station_count])
    |> unique_constraint(:hour)
  end
end
