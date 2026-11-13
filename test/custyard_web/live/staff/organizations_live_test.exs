defmodule CustyardWeb.Staff.OrganizationsLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{Organization, Repo}

  setup %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    %{conn: conn |> init_test_session(%{}) |> put_staff_session(staff), staff: staff}
  end

  test "customer list only contains tenant customers and no workspace configuration", %{
    conn: conn
  } do
    own = insert_organization(name: "Visible customer")
    insert_organization(tenant_id: insert_tenant().id, name: "Foreign customer")
    {:ok, view, html} = live(conn, "/app/customers")
    assert html =~ own.name
    assert has_element?(view, "a[href='/app/customers/#{own.public_id}']", own.name)
    refute has_element?(view, "a[href='/app/customers/#{own.id}']")
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
    agent = insert_staff_account(role: "agent")
    conn = conn |> put_staff_session(agent)
    {:ok, view, html} = live(conn, "/app/customers")
    refute html =~ "Add customer"
    render_submit(view, "save_org", %{"customer" => %{"name" => "Forged"}})
    refute Repo.get_by(Organization, name: "Forged")
  end

  defp count_text(view) do
    view
    |> element("[data-testid=staff-customers-count]")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  describe "list" do
    test "each customer is one row that links to the customer", %{conn: conn} do
      acme = insert_organization(name: "Acme", domain: "acme.example.com", tier: :enterprise)

      pat =
        insert_organization(
          name: "Pat Personal",
          domain: nil,
          identity_kind: :email,
          identity_value: "pat@mail.example.com"
        )

      manual = insert_organization(name: "Walk-in", domain: nil)

      {:ok, view, _html} = live(conn, "/app/customers")

      assert has_element?(view, "h1[data-testid=staff-customers-heading]", "Customers")

      rows =
        view
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.find("ul[data-testid=staff-customers-list] > li")

      # Sorted by name, as the context returns them.
      assert Enum.map(rows, &Floki.attribute(&1, "id")) == [
               ["customer-#{acme.id}"],
               ["customer-#{pat.id}"],
               ["customer-#{manual.id}"]
             ]

      row = "[data-testid=staff-customer-row-#{acme.id}]"
      link = "#{row} a[data-testid=staff-customer-link][href='/app/customers/#{acme.public_id}']"

      assert has_element?(view, "#{link} [data-testid=staff-customer-name]", "Acme")

      assert has_element?(
               view,
               "#{link} [data-testid=staff-customer-identity]",
               "acme.example.com"
             )

      assert has_element?(view, "#{link} [data-testid=staff-tier-badge-enterprise]", "enterprise")

      # A personal sender is known by the address.
      assert has_element?(
               view,
               "[data-testid=staff-customer-row-#{pat.id}] [data-testid=staff-customer-identity]",
               "pat@mail.example.com"
             )

      assert has_element?(
               view,
               "[data-testid=staff-customer-row-#{pat.id}] [data-testid=staff-tier-badge-standard]"
             )

      # A customer added by hand has no identity to show, only a generated one.
      refute has_element?(
               view,
               "[data-testid=staff-customer-row-#{manual.id}] [data-testid=staff-customer-identity]"
             )

      refute render(view) =~ manual.identity_value
    end

    test "the heading row counts the customers", %{conn: conn} do
      insert_organization()
      {:ok, view, _html} = live(conn, "/app/customers")
      assert count_text(view) == "1 customer"

      insert_organization()
      {:ok, view, _html} = live(conn, "/app/customers")
      assert count_text(view) == "2 customers"
    end

    test "says so when there are no customers", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/app/customers")

      assert has_element?(view, "[data-testid=staff-customers-empty]", "No customers yet.")
      assert count_text(view) == "0 customers"
      refute has_element?(view, "[data-testid=staff-customers-list]")
    end
  end

  describe "admin actions" do
    test "the add button opens an empty form and cancel closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/app/customers")

      refute has_element?(view, "#customer-form")
      view |> element("button[phx-click=show_form]", "Add customer") |> render_click()

      assert has_element?(view, "[data-testid=staff-customer-form-card] h2", "Add customer")
      assert has_element?(view, "#customer-form input[name='customer[name]'][value='']")

      view |> element("[data-testid=staff-customer-cancel-btn]", "Cancel") |> render_click()
      refute has_element?(view, "#customer-form")
    end

    test "the row's edit button opens the form with that customer", %{conn: conn} do
      org = insert_organization(name: "Acme", domain: "acme.example.com", tier: :enterprise)
      {:ok, view, _html} = live(conn, "/app/customers")

      edit =
        "[data-testid=staff-customer-row-#{org.id}] button[data-testid=staff-customer-edit-#{org.id}]"

      assert has_element?(view, "#{edit}[aria-label='Edit Acme'][title='Edit customer']")
      # Beside the row link, never inside it.
      refute has_element?(view, "a button")

      view |> element(edit) |> render_click()

      assert has_element?(view, "[data-testid=staff-customer-form-card] h2", "Edit customer")
      assert has_element?(view, "#customer-form input[name='customer[name]'][value='Acme']")

      assert has_element?(
               view,
               "#customer-form input[name='customer[domain]'][value='acme.example.com']"
             )

      assert has_element?(
               view,
               "#customer-form select[name='customer[tier]'] option[value=enterprise][selected]"
             )

      view |> form("#customer-form", customer: %{name: "Acme Ltd"}) |> render_submit()

      refute has_element?(view, "#customer-form")

      assert has_element?(
               view,
               "[data-testid=staff-customer-row-#{org.id}] [data-testid=staff-customer-name]",
               "Acme Ltd"
             )
    end

    test "an agent gets the list without the add and edit actions", %{conn: conn} do
      org = insert_organization(name: "Acme")
      conn = put_staff_session(conn, insert_staff_account(role: "agent"))
      {:ok, view, _html} = live(conn, "/app/customers")

      assert has_element?(
               view,
               "[data-testid=staff-customer-row-#{org.id}] a[href='/app/customers/#{org.public_id}']",
               "Acme"
             )

      refute has_element?(view, "button[phx-click=show_form]")
      refute has_element?(view, "button[phx-click=edit_org]")

      # Hiding the buttons is not the guard: a forged save is refused.
      render_click(view, "edit_org", %{"id" => to_string(org.id)})

      view
      |> render_submit("save_org", %{"customer" => %{"name" => "Renamed by agent"}})

      assert Repo.reload!(org).name == "Acme"
    end
  end
end
