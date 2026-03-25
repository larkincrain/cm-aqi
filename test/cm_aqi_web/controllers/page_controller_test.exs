defmodule CmAqiWeb.PageControllerTest do
  use CmAqiWeb.ConnCase

  test "GET / renders the AQI dashboard", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Chiang Mai Air Quality"
  end
end
