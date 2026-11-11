defmodule CustyardWeb.Layouts do
  @moduledoc """
  This module holds different layouts used by your application.

  See the `layouts` directory for all templates available.
  The "root" layout is a skeleton rendered as part of the
  application router. The "app" layout is set as the default
  layout on both `use CustyardWeb, :controller` and
  `use CustyardWeb, :live_view`.
  """
  use CustyardWeb, :html

  embed_templates "layouts/*"

  def root_branding(assigns) do
    conn_assigns = if assigns[:conn], do: assigns.conn.assigns, else: %{}

    tenant =
      assigns[:host_tenant] || conn_assigns[:host_tenant]

    if tenant do
      %{
        tenant?: true,
        name: tenant.name,
        logo: tenant.logo_url,
        color: tenant.primary_color || "#4f46e5",
        description: "Customer support for #{tenant.name}"
      }
    else
      %{
        tenant?: false,
        name: "Custyard",
        logo: nil,
        color: "#FD4F00",
        description: "Customer service and support platform"
      }
    end
  end
end
