defmodule CmAqi.Repo do
  use Ecto.Repo,
    otp_app: :cm_aqi,
    adapter: Ecto.Adapters.Postgres
end
