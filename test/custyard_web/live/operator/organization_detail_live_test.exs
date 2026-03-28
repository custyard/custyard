defmodule CustyardWeb.Operator.OrganizationDetailLiveTest do
  @moduledoc """
  Tests for the Routes tab on the Organization Detail LiveView.

  These tests are written ahead of implementation (Phase 1b, issue #27).
  They will fail until OrganizationDetailLive is implemented with:
  - Routes tab showing route cards with callback URLs, badges, webhook toggles
  - Inline create form for project routes (admin/super_admin only)
  - Delete with confirmation, disabled for last general route
  - View-only mode for agents (no mutation controls)

  Note: The current router places OrganizationDetailLive under :operator_admin
  (require_admin). Phase 1b may need to move it to :operator so agents can
  access it in view-only mode, or implement role-based rendering within the
  admin-only session.
  """
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{InboundRoutes, OperatorAccount, Repo}

  # --- Helper functions ---

  defp authenticate_conn(conn, operator) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:operator_id, operator.id)
  end

  defp create_operator(attrs) do
    %OperatorAccount{}
    |> OperatorAccount.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_super_admin do
    create_operator(%{
      email: "superadmin-#{System.unique_integer([:positive])}@example.com",
      password: "password123",
      role: "super_admin"
    })
  end

  defp create_admin(org) do
    create_operator(%{
      email: "admin-#{System.unique_integer([:positive])}@example.com",
      password: "password123",
      role: "admin",
      organization_id: org.id
    })
  end

  defp create_agent(org) do
    create_operator(%{
      email: "agent-#{System.unique_integer([:positive])}@example.com",
      password: "password123",
      role: "agent",
      organization_id: org.id
    })
  end

  # --- Test setup ---

  describe "Routes tab rendering" do
    setup %{conn: conn} do
      org = insert_organization(name: "Routes Test Org")
      operator = create_super_admin()

      {:ok, general_route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, _webhook} = InboundRoutes.enable_webhook(general_route, :sender_matching)
      {:ok, _webhook} = InboundRoutes.enable_webhook(general_route, :enrichment)

      conn = authenticate_conn(conn, operator)

      {:ok, conn: conn, org: org, operator: operator, general_route: general_route}
    end

    test "routes tab is visible in organization detail", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      # The Routes tab should exist alongside Conversations, Contacts, Projects
      assert has_element?(view, "[data-testid=org-tab-routes]")
    end

    test "routes tab shows route cards with callback URLs", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      # Click the Routes tab to show route content
      html = view |> element("a", "Routes") |> render_click()

      # Callback URL should be displayed in the route card
      assert html =~ "/api/webhook/route/"
    end

    test "routes tab shows route type badge", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # General route should have a route_type_badge showing "general"
      assert html =~ "general"
    end

    test "routes tab shows source badge", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Default source is lettermint
      assert html =~ "lettermint"
    end

    test "routes tab shows webhook purpose toggles", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Should show toggle controls for webhook purposes
      assert html =~ "sender_matching" or html =~ "Sender Matching"
      assert html =~ "enrichment" or html =~ "Enrichment"
    end

    test "shows multiple routes when org has project routes", %{conn: conn, org: org} do
      project = insert_project(organization_id: org.id)

      {:ok, _project_route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Should show both general and project route cards
      assert html =~ "general"
      assert html =~ "project"
    end
  end

  describe "Route creation" do
    setup %{conn: conn} do
      org = insert_organization(name: "Create Routes Org")

      {:ok, _general_route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      _project = insert_project(organization_id: org.id, title: "Target Project")

      {:ok, org: org}
    end

    test "admin can see create route button", %{conn: conn, org: org} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Admin should see a button/link to create a new route
      assert html =~ "Add route" or html =~ "New route" or html =~ "Create route"
    end

    test "super_admin can see create route button", %{conn: conn, org: org} do
      operator = create_super_admin()
      conn = authenticate_conn(conn, operator)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      assert html =~ "Add route" or html =~ "New route" or html =~ "Create route"
    end

    test "admin can open create route form", %{conn: conn, org: org} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      # Navigate to routes tab
      view |> element("a", "Routes") |> render_click()

      # Click the create button to show the inline form
      html =
        view
        |> element("[data-testid=show-create-route-form]")
        |> render_click()

      # Form should appear with project select and source select
      assert html =~ "project" or html =~ "Project"
      assert html =~ "source" or html =~ "Source"
    end

    test "admin can create a project route", %{conn: conn, org: org} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)
      project = insert_project(organization_id: org.id, title: "New Project Route Target")

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      # Navigate to routes tab
      view |> element("a", "Routes") |> render_click()

      # Open create form
      view
      |> element("[data-testid=show-create-route-form]")
      |> render_click()

      # Fill and submit the form
      html =
        view
        |> element("[data-testid=create-route-form]")
        |> render_submit(%{
          "route" => %{
            "route_type" => "project",
            "project_id" => to_string(project.id),
            "source" => "lettermint"
          }
        })

      # New route should appear in the list
      assert html =~ "project"
      assert html =~ "New Project Route Target" or html =~ to_string(project.id)

      # Verify route was created in database
      routes = InboundRoutes.list_for_organization(org.id)
      project_routes = Enum.filter(routes, &(&1.route_type == :project))
      assert length(project_routes) >= 1
    end

    test "agent cannot see create route button", %{conn: conn, org: org} do
      agent = create_agent(org)
      conn = authenticate_conn(conn, agent)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Agent should not see any create/add route controls
      refute html =~ "Add route"
      refute html =~ "New route"
      refute html =~ "Create route"
      refute has_element?(view, "[data-testid=show-create-route-form]")
    end
  end

  describe "Webhook toggling" do
    setup %{conn: conn} do
      org = insert_organization(name: "Webhook Toggle Org")

      {:ok, route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      # Start with sender_matching enabled, notification disabled
      {:ok, _enabled_webhook} = InboundRoutes.enable_webhook(route, :sender_matching)

      {:ok, org: org, route: route}
    end

    test "admin can toggle webhook purpose on", %{conn: conn, org: org, route: route} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # Toggle the notification webhook on
      view
      |> element("[data-testid=toggle-webhook-#{route.id}-notification]")
      |> render_click()

      # Verify webhook was enabled in database
      webhooks = InboundRoutes.list_webhooks_for_route(route.id)

      notification_webhook =
        Enum.find(webhooks, &(&1.purpose == :notification))

      assert notification_webhook != nil
      assert notification_webhook.enabled == true
    end

    test "admin can toggle webhook purpose off", %{conn: conn, org: org, route: route} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # Toggle the sender_matching webhook off (it was enabled in setup)
      view
      |> element("[data-testid=toggle-webhook-#{route.id}-sender_matching]")
      |> render_click()

      # Verify webhook was disabled in database
      webhooks = InboundRoutes.list_webhooks_for_route(route.id)

      sender_webhook =
        Enum.find(webhooks, &(&1.purpose == :sender_matching))

      assert sender_webhook.enabled == false
    end

    test "agent sees read-only webhook toggles", %{conn: conn, org: org, route: route} do
      agent = create_agent(org)
      conn = authenticate_conn(conn, agent)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Agent should see webhook status but toggles should be disabled
      assert html =~ "sender_matching" or html =~ "Sender Matching"

      # The toggle elements for agents should be disabled or absent
      refute has_element?(view, "[data-testid=toggle-webhook-#{route.id}-sender_matching]")
    end
  end

  describe "Route deletion" do
    setup %{conn: conn} do
      org = insert_organization(name: "Delete Routes Org")

      {:ok, general_route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      project = insert_project(organization_id: org.id, title: "Deletable Project")

      {:ok, project_route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      {:ok,
       org: org, general_route: general_route, project_route: project_route, project: project}
    end

    test "admin can delete a project route", %{
      conn: conn,
      org: org,
      project_route: project_route
    } do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # Click delete on the project route
      view
      |> element("[data-testid=delete-route-#{project_route.id}]")
      |> render_click()

      # Confirm deletion
      html =
        view
        |> element("[data-testid=confirm-delete-route-#{project_route.id}]")
        |> render_click()

      # Route should no longer appear in the page
      refute html =~ "Deletable Project"

      # Verify route was removed from database
      assert InboundRoutes.get_route(project_route.id) == nil
    end

    test "cannot delete the last general route", %{
      conn: conn,
      org: org,
      general_route: general_route
    } do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # The delete button for the last general route should be disabled or absent
      refute has_element?(view, "[data-testid=delete-route-#{general_route.id}]")

      # Verify the route still exists
      assert InboundRoutes.get_route(general_route.id) != nil
    end

    test "delete button is enabled when there are multiple general routes", %{
      conn: conn,
      org: org,
      general_route: general_route
    } do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      # Create a second general route so neither is the "last"
      {:ok, _second_general} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # Now the delete button should be present for the first general route
      assert has_element?(view, "[data-testid=delete-route-#{general_route.id}]")
    end

    test "agent cannot see delete button", %{conn: conn, org: org, project_route: project_route} do
      agent = create_agent(org)
      conn = authenticate_conn(conn, agent)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # Agent should not see any delete buttons
      refute has_element?(view, "[data-testid=delete-route-#{project_route.id}]")
    end
  end

  describe "Callback URL copy button" do
    setup %{conn: conn} do
      org = insert_organization(name: "Copy URL Org")
      operator = create_super_admin()

      {:ok, route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      conn = authenticate_conn(conn, operator)

      {:ok, conn: conn, org: org, route: route}
    end

    test "copy button is present next to callback URL", %{conn: conn, org: org, route: route} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      view |> element("a", "Routes") |> render_click()

      # A copy button (using the CopyToClipboard JS hook) should be next to the URL
      assert has_element?(view, "[data-testid=copy-callback-url-#{route.id}]")
    end

    test "callback URL contains the route's token", %{conn: conn, org: org, route: route} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      assert html =~ route.callback_token
    end
  end

  describe "Role-based access" do
    setup %{conn: conn} do
      org = insert_organization(name: "RBAC Test Org")

      {:ok, _route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, org: org}
    end

    test "super_admin can access any organization's detail page and see routes tab", %{
      conn: conn,
      org: org
    } do
      operator = create_super_admin()
      conn = authenticate_conn(conn, operator)

      {:ok, view, html} = live(conn, ~p"/operator/organizations/#{org.id}")

      assert html =~ org.name
      # Routes tab should be available
      assert has_element?(view, "[data-testid=org-tab-routes]")
    end

    test "admin can access their own organization's detail page and see routes tab", %{
      conn: conn,
      org: org
    } do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, html} = live(conn, ~p"/operator/organizations/#{org.id}")

      assert html =~ org.name
      assert has_element?(view, "[data-testid=org-tab-routes]")
    end

    test "admin sees mutation controls on their organization", %{conn: conn, org: org} do
      admin = create_admin(org)
      conn = authenticate_conn(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Admin should see create and toggle controls
      assert has_element?(view, "[data-testid=show-create-route-form]")
    end

    test "agent can view organization detail but has no mutation controls", %{
      conn: conn,
      org: org
    } do
      agent = create_agent(org)
      conn = authenticate_conn(conn, agent)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      html = view |> element("a", "Routes") |> render_click()

      # Agent can see route information
      assert html =~ "general"

      # But has no mutation controls
      refute has_element?(view, "[data-testid=show-create-route-form]")
    end
  end
end
