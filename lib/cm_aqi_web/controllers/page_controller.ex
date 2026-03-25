defmodule CmAqiWeb.PageController do
  use CmAqiWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
