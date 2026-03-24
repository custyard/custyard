defmodule CustyardWeb.Operator.OrganizationsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo, Organization}

  setup %{conn: conn} do
    # Create and authenticate an operator
    {:ok, operator} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "test@example.com", password: "password123"})
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, conn: conn, operator: operator}
  end

  describe "mount/3" do
    test "renders organizations list", %{conn: conn} do
      insert_organization(name: "Acme Corp", tier: :enterprise)
      insert_organization(name: "Beta LLC", tier: :standard)

      {:ok, _view, html} = live(conn, ~p"/operator/organizations")

      assert html =~ "Organizations"
      assert html =~ "Acme Corp"
      assert html =~ "Beta LLC"
      assert html =~ "enterprise"
    end

    test "shows conversation counts", %{conn: conn} do
      org = insert_organization(name: "Busy Corp")
      insert_conversation(organization_id: org.id)
      insert_conversation(organization_id: org.id)
      insert_conversation(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/operator/organizations")

      assert html =~ "3 conversations"
    end

    test "shows singular conversation for count of 1", %{conn: conn} do
      org = insert_organization(name: "Small Corp")
      insert_conversation(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/operator/organizations")

      assert html =~ "1 conversation"
    end

    test "shows portal token link", %{conn: conn} do
      insert_organization(token: "test-portal-token")

      {:ok, _view, html} = live(conn, ~p"/operator/organizations")

      assert html =~ "/p/test-portal-token"
    end
  end

  describe "show_form event" do
    test "displays new organization form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      html =
        view
        |> element("button", "Add organization")
        |> render_click()

      assert html =~ "New organization"
      assert html =~ "Name"
      assert html =~ "Domain"
      assert html =~ "Tier"
    end
  end

  describe "hide_form event" do
    test "hides the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      # Show form first
      view
      |> element("button", "Add organization")
      |> render_click()

      # Then hide it
      html =
        view
        |> element("button", "Cancel")
        |> render_click()

      refute html =~ "New organization"
    end
  end

  describe "edit_org event" do
    test "populates form with organization data", %{conn: conn} do
      org =
        insert_organization(
          name: "Edit Me Corp",
          domain: "editme.com",
          tier: :enterprise,
          custom_domain: "support.editme.com"
        )

      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      html =
        view
        |> element("[phx-click=edit_org][phx-value-id=\"#{org.id}\"]")
        |> render_click()

      assert html =~ "Edit organization"
      assert html =~ "Edit Me Corp"
      assert html =~ "editme.com"
      assert html =~ "support.editme.com"
    end
  end

  describe "save_org event - create" do
    test "creates new organization", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      # Show form
      view
      |> element("button", "Add organization")
      |> render_click()

      # Update form field using the correct event structure
      render_hook(view, "update_form", %{"field" => "name", "value" => "New Corp"})

      # Submit
      html =
        view
        |> element("form")
        |> render_submit()

      assert html =~ "New Corp"

      # Verify in database
      assert Repo.get_by(Organization, name: "New Corp")
    end

    test "creates organization with all fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      view
      |> element("button", "Add organization")
      |> render_click()

      # Fill fields using update_form events
      render_hook(view, "update_form", %{"field" => "name", "value" => "Full Corp"})
      render_hook(view, "update_form", %{"field" => "domain", "value" => "full.example.com"})

      render_hook(view, "update_form", %{
        "field" => "custom_domain",
        "value" => "support.full.com"
      })

      render_hook(view, "update_form", %{"field" => "tier", "value" => "enterprise"})

      view
      |> element("form")
      |> render_submit()

      org = Repo.get_by(Organization, name: "Full Corp")
      assert org.domain == "full.example.com"
      assert org.custom_domain == "support.full.com"
      assert org.tier == :enterprise
    end
  end

  describe "save_org event - update" do
    test "updates existing organization", %{conn: conn} do
      org = insert_organization(name: "Original Name")

      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      # Click edit
      view
      |> element("[phx-click=edit_org][phx-value-id=\"#{org.id}\"]")
      |> render_click()

      # Change name
      render_hook(view, "update_form", %{"field" => "name", "value" => "Updated Name"})

      # Submit
      html =
        view
        |> element("form")
        |> render_submit()

      assert html =~ "Updated Name"
      refute html =~ "Original Name"

      updated = Repo.get!(Organization, org.id)
      assert updated.name == "Updated Name"
    end
  end

  describe "branding section" do
    test "displays branding fields in form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      html =
        view
        |> element("button", "Add organization")
        |> render_click()

      assert html =~ "Branding"
      assert html =~ "Logo"
      assert html =~ "Primary Color"
      assert html =~ "Secondary Color"
    end

    test "can set branding colors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      view
      |> element("button", "Add organization")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "name", "value" => "Branded Corp"})
      render_hook(view, "update_form", %{"field" => "primary_color", "value" => "#ff0000"})
      render_hook(view, "update_form", %{"field" => "secondary_color", "value" => "#00ff00"})

      view
      |> element("form")
      |> render_submit()

      org = Repo.get_by(Organization, name: "Branded Corp")
      assert org.primary_color == "#ff0000"
      assert org.secondary_color == "#00ff00"
    end

    test "shows existing logo when editing", %{conn: conn} do
      org = insert_organization(name: "Logo Corp")

      # Manually set logo_url (simulating previous upload)
      org
      |> Organization.changeset(%{logo_url: "/uploads/logos/existing.png"})
      |> Repo.update!()

      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      html =
        view
        |> element("[phx-click=edit_org][phx-value-id=\"#{org.id}\"]")
        |> render_click()

      assert html =~ "/uploads/logos/existing.png"
      assert html =~ "Current"
    end
  end

  describe "custom_domain field" do
    test "can set custom domain", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      view
      |> element("button", "Add organization")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "name", "value" => "Domain Corp"})

      render_hook(view, "update_form", %{
        "field" => "custom_domain",
        "value" => "portal.domaincorp.com"
      })

      view
      |> element("form")
      |> render_submit()

      org = Repo.get_by(Organization, name: "Domain Corp")
      assert org.custom_domain == "portal.domaincorp.com"
    end

    test "shows CNAME instruction text", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations")

      html =
        view
        |> element("button", "Add organization")
        |> render_click()

      assert html =~ "CNAME"
      assert html =~ "White-label portal domain"
    end
  end

  describe "tier badges" do
    test "displays correct tier badges", %{conn: conn} do
      insert_organization(name: "Enterprise Org", tier: :enterprise)
      insert_organization(name: "Standard Org", tier: :standard)
      insert_organization(name: "Basic Org", tier: :basic)

      {:ok, _view, html} = live(conn, ~p"/operator/organizations")

      assert html =~ "enterprise"
      assert html =~ "standard"
      assert html =~ "basic"
    end
  end
end
