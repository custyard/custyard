defmodule CustyardWeb.Plugs.PortalAuth do
  @moduledoc """
  Validates org token from URL path and assigns the organization.
  Used for portal routes /p/:org_token/*.
  """

  import Plug.Conn
  alias Custyard.{Repo, Organization}

  def init(opts), do: opts

  def call(conn, _opts) do
    token = conn.path_params["org_token"]

    case Repo.get_by(Organization, token: token) do
      nil ->
        conn
        |> put_status(404)
        |> Phoenix.Controller.put_view(CustyardWeb.ErrorHTML)
        |> Phoenix.Controller.render("404.html")
        |> halt()

      org ->
        assign(conn, :current_org, org)
    end
  end
end
