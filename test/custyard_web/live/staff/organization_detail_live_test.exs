defmodule CustyardWeb.Staff.OrganizationDetailLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{PortalCredentials, Repo, Scope}

  setup %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    %{conn: conn |> init_test_session(%{}) |> put_staff_session(staff), staff: staff}
  end

  test "customer details contain customer work without email infrastructure", %{conn: conn} do
    customer = insert_organization(name: "Acme")
    contact = insert_contact(organization_id: customer.id, name: "Alice")
    thread = insert_thread(organization_id: customer.id, subject: "Onboarding question")
    project = insert_project(organization_id: customer.id, title: "Launch")
    {:ok, _, html} = live(conn, "/app/customers/#{customer.public_id}")

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
    {:ok, view, _} = live(conn, "/app/customers/#{customer.public_id}")
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
             live(conn, "/app/customers/#{customer.public_id}")
  end

  test "customer history includes resolved threads ordered by last update", %{conn: conn} do
    customer = insert_organization()

    oldest =
      insert_thread(organization_id: customer.id, subject: "Recently answered", state: :resolved)

    newest = insert_thread(organization_id: customer.id, subject: "Recently created")
    hidden = insert_thread(organization_id: insert_organization().id, subject: "Another customer")
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.update!(
      Ecto.Changeset.change(oldest, inserted_at: DateTime.add(now, -3600), updated_at: now)
    )

    Repo.update!(Ecto.Changeset.change(newest, updated_at: DateTime.add(now, -60)))

    {:ok, view, _} = live(conn, "/app/customers/#{customer.public_id}")

    rows =
      view
      |> element("#customer-thread-history")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("li")

    assert Enum.map(rows, &Floki.attribute(&1, "id")) == [
             ["customer-thread-#{oldest.id}"],
             ["customer-thread-#{newest.id}"]
           ]

    assert has_element?(view, "#customer-thread-#{oldest.id}", "resolved")
    assert has_element?(view, "#customer-thread-#{oldest.id} time[datetime]")
    refute has_element?(view, "#customer-thread-#{hidden.id}")
  end

  test "customer routes reject internal numeric IDs and unknown public IDs", %{conn: conn} do
    customer = insert_organization()
    assert {:ok, _} = Ecto.UUID.cast(customer.public_id)

    for id <- [to_string(customer.id), Ecto.UUID.generate()] do
      assert {:error, {:redirect, %{to: "/app/customers"}}} = live(conn, "/app/customers/#{id}")
    end
  end
end
