defmodule CustyardWeb.Operator.OrganizationDetailLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{PortalCredentials, Repo, Scope}

  setup %{conn: conn} do
    staff = insert_operator_account(role: "admin")
    %{conn: conn |> init_test_session(%{}) |> put_operator_session(staff), staff: staff}
  end

  test "customer details contain customer work without email infrastructure", %{conn: conn} do
    customer = insert_organization(name: "Acme")
    contact = insert_contact(organization_id: customer.id, name: "Alice")
    thread = insert_conversation(organization_id: customer.id, subject: "Onboarding question")
    project = insert_project(organization_id: customer.id, title: "Launch")
    {:ok, _, html} = live(conn, "/app/customers/#{customer.id}")

    for text <- [customer.name, contact.name, thread.subject, project.title, "Portal access"] do
      assert html =~ text
    end

    refute html =~ "Advanced: routes"
    refute html =~ "Add support address"
    refute html =~ "Custom domain"
  end

  test "portal links are individually issued and revoked with optional contact attribution", %{
    conn: conn,
    staff: staff
  } do
    customer = insert_organization()
    contact = insert_contact(organization_id: customer.id)
    {:ok, view, _} = live(conn, "/app/customers/#{customer.id}")
    html = render_submit(view, "issue_portal", %{"contact_id" => to_string(contact.id)})
    assert html =~ "Copy this link now"

    [credential] =
      PortalCredentials.list(
        Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id)),
        customer.id
      )

    assert credential.contact_id == contact.id
    refute Map.has_key?(Map.from_struct(credential), :token)
    render_click(view, "revoke_portal", %{"id" => to_string(credential.id)})
    assert Repo.reload!(credential).revoked_at
  end

  test "foreign customer IDs fail closed", %{conn: conn} do
    customer = insert_organization(tenant_id: insert_tenant().id)

    assert {:error, {:redirect, %{to: "/app/customers"}}} =
             live(conn, "/app/customers/#{customer.id}")
  end
end
