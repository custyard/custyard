defmodule CustyardWeb.Operator.OrganizationsLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{Organization, Repo}

  setup %{conn: conn} do
    staff = insert_operator_account(role: "admin")
    %{conn: conn |> init_test_session(%{}) |> put_operator_session(staff), staff: staff}
  end

  test "customer list only contains tenant customers and no workspace configuration", %{
    conn: conn
  } do
    own = insert_organization(name: "Visible customer")
    insert_organization(tenant_id: insert_tenant().id, name: "Foreign customer")
    {:ok, _, html} = live(conn, "/app/customers")
    assert html =~ own.name
    refute html =~ "Foreign customer"
    refute html =~ "Custom domain"
    refute html =~ "Primary Color"
    refute html =~ "Portal link"
  end

  test "tenant admin creates and edits a customer", %{conn: conn, staff: staff} do
    {:ok, view, _} = live(conn, "/app/customers")
    render_click(view, "show_form")

    view
    |> form("#customer-form",
      customer: %{name: "New customer", domain: "new.example.com", tier: "enterprise"}
    )
    |> render_submit()

    customer = Repo.get_by!(Organization, name: "New customer", tenant_id: staff.tenant_id)
    assert customer.identity_kind == :domain
    render_click(view, "edit_org", %{"id" => to_string(customer.id)})

    view
    |> form("#customer-form",
      customer: %{name: "Updated customer", domain: "new.example.com", tier: "standard"}
    )
    |> render_submit()

    assert Repo.reload!(customer).name == "Updated customer"
  end

  test "agents can browse but cannot create customer records", %{conn: conn} do
    agent = insert_operator_account(role: "agent")
    conn = conn |> put_operator_session(agent)
    {:ok, view, html} = live(conn, "/app/customers")
    refute html =~ "Add customer"
    render_submit(view, "save_org", %{"customer" => %{"name" => "Forged"}})
    refute Repo.get_by(Organization, name: "Forged")
  end
end
