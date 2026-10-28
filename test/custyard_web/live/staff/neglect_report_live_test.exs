defmodule CustyardWeb.Staff.NeglectReportLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{StaffAccount, Repo}

  # Create a neglected conversation (idle for > 24 hours for standard tier = warning status)
  defp insert_neglected_conversation(org_id, hours_idle \\ 30) do
    past_time =
      DateTime.utc_now()
      |> DateTime.add(-hours_idle * 3600, :second)
      |> DateTime.truncate(:second)

    insert_conversation(
      organization_id: org_id,
      state: :new,
      last_staff_action_at: past_time
    )
  end

  describe "organization scoping" do
    test "super_admin sees conversations from all organizations", %{conn: conn} do
      # Create super_admin staff (default role)
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          role: "admin",
          tenant_id: Process.get(:factory_tenant_id),
          email: "super@example.com",
          password: "password123"
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      # Create two organizations with neglected conversations
      org1 = insert_organization(name: "Org One", tier: :standard)
      org2 = insert_organization(name: "Org Two", tier: :standard)

      conv1 = insert_neglected_conversation(org1.id)
      conv2 = insert_neglected_conversation(org2.id)

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      # Super admin should see both organizations' conversations
      assert html =~ "Org One"
      assert html =~ "Org Two"
      assert html =~ conv1.subject
      assert html =~ conv2.subject
    end

    test "admin sees only their organization's conversations", %{conn: conn} do
      # Create two organizations
      org1 = insert_organization(name: "Admin Org", tier: :standard)

      org2 =
        insert_organization(name: "Other Org", tier: :standard, tenant_id: insert_tenant().id)

      # Create admin staff scoped to org1
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "admin@example.com",
          password: "password123",
          role: "admin",
          organization_id: org1.id
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      # Create neglected conversations in both orgs
      conv1 = insert_neglected_conversation(org1.id)
      conv2 = insert_neglected_conversation(org2.id)

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      # Admin should only see their organization's conversations
      assert html =~ "Admin Org"
      assert html =~ conv1.subject
      refute html =~ "Other Org"
      refute html =~ conv2.subject
    end

    test "agent sees only their organization's conversations", %{conn: conn} do
      # Create two organizations
      org1 = insert_organization(name: "Agent Org", tier: :standard)

      org2 =
        insert_organization(name: "Another Org", tier: :standard, tenant_id: insert_tenant().id)

      # Create agent staff scoped to org1
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "agent@example.com",
          password: "password123",
          role: "agent",
          organization_id: org1.id
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      # Create neglected conversations in both orgs
      conv1 = insert_neglected_conversation(org1.id)
      conv2 = insert_neglected_conversation(org2.id)

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      # Agent should only see their organization's conversations
      assert html =~ "Agent Org"
      assert html =~ conv1.subject
      refute html =~ "Another Org"
      refute html =~ conv2.subject
    end
  end

  describe "mount/3" do
    setup %{conn: conn} do
      # Default setup with super_admin for basic functionality tests
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          role: "admin",
          tenant_id: Process.get(:factory_tenant_id),
          email: "test@example.com",
          password: "password123"
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      {:ok, conn: conn, staff: staff}
    end

    test "renders neglect report page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      assert html =~ "Neglect Report"
    end

    test "shows empty state when no neglected conversations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      assert html =~ "No items are currently past their neglect thresholds"
    end

    test "shows neglected conversations grouped by organization", %{conn: conn} do
      org = insert_organization(name: "Test Org", tier: :standard)
      conv = insert_neglected_conversation(org.id)

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      assert html =~ "Test Org"
      assert html =~ conv.subject
    end

    test "renders unlinked prospect group for nil-org conversations without crashing", %{
      conn: conn
    } do
      # Disambiguation is currently the only source that permits a nil organization
      past_time =
        DateTime.utc_now()
        |> DateTime.add(-25 * 3600, :second)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          state: :new,
          last_staff_action_at: past_time
        )

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      assert html =~ "Unlinked prospect"
      assert html =~ conv.subject
      # No organization means no tier badge for the group
      refute html =~ "staff-tier-badge"
    end

    test "shows warning and critical counts", %{conn: conn} do
      org = insert_organization(tier: :standard)
      # 30 hours idle = warning for standard tier (24-48 hours)
      _warning_conv = insert_neglected_conversation(org.id, 30)
      # 50 hours idle = critical for standard tier (> 48 hours)
      _critical_conv = insert_neglected_conversation(org.id, 50)

      {:ok, _view, html} = live(conn, ~p"/app/neglect")

      assert html =~ "critical"
      assert html =~ "warning"
    end
  end

  describe "PubSub subscription" do
    setup %{conn: conn} do
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          role: "admin",
          tenant_id: Process.get(:factory_tenant_id),
          email: "test@example.com",
          password: "password123"
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(staff.id)

      {:ok, conn: conn}
    end

    test "updates when conversation_updated event received", %{conn: conn} do
      org = insert_organization(tier: :standard)
      conv = insert_neglected_conversation(org.id)

      {:ok, view, html} = live(conn, ~p"/app/neglect")
      assert html =~ conv.subject

      # Broadcast update
      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversations",
        {:conversation_updated, conv.id}
      )

      # Give time for the update to process
      :timer.sleep(100)

      # View should still render (reload happened)
      html = render(view)
      assert html =~ conv.subject
    end
  end
end
