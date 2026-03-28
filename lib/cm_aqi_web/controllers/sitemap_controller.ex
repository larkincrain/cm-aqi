defmodule CmAqiWeb.SitemapController do
  @moduledoc """
  Generates a dynamic XML sitemap including all static pages and
  individual sensor detail pages for active stations.
  """

  use CmAqiWeb, :controller

  alias CmAqi.AqiReadings

  def index(conn, _params) do
    readings = AqiReadings.list_latest_readings()

    station_ids =
      readings
      |> Enum.map(& &1.station_id)
      |> Enum.uniq()

    conn
    |> put_resp_content_type("application/xml")
    |> send_resp(200, build_sitemap(station_ids))
  end

  defp build_sitemap(station_ids) do
    base = CmAqiWeb.Endpoint.url()
    today = Date.utc_today() |> Date.to_iso8601()

    static_urls =
      [
        {"/", "always", "1.0"},
        {"/sensors", "always", "0.9"},
        {"/weekly", "daily", "0.8"},
        {"/subscribe", "monthly", "0.7"},
        {"/about", "monthly", "0.5"}
      ]
      |> Enum.map(fn {path, freq, priority} ->
        url_entry(base <> path, today, freq, priority)
      end)

    sensor_urls =
      Enum.map(station_ids, fn id ->
        url_entry("#{base}/sensors/#{id}", today, "always", "0.8")
      end)

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
    #{Enum.join(static_urls ++ sensor_urls, "\n")}
    </urlset>
    """
  end

  defp url_entry(loc, lastmod, changefreq, priority) do
    """
      <url>
        <loc>#{loc}</loc>
        <lastmod>#{lastmod}</lastmod>
        <changefreq>#{changefreq}</changefreq>
        <priority>#{priority}</priority>
      </url>\
    """
  end
end
