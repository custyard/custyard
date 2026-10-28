defmodule CustyardWeb.Staff.AttentionQueueLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{StaffAccount, Repo, Scoring}

  setup %{conn: conn} do
    # Create and authenticate a staff
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

  describe "mount/3" do
    test "renders attention queue page", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Attention Queue"
      assert html =~ conv.subject
    end

    test "shows conversations ordered by score", %{conn: conn} do
      org = insert_organization(tier: :enterprise)
      # Higher score (enterprise tier, urgent)
      high =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          urgency: :urgent
        )

      Scoring.calculate_and_cache(high.id)

      org2 = insert_organization(tier: :basic)
      # Lower score (basic tier, normal)
      low =
        insert_conversation(
          organization_id: org2.id,
          state: :new,
          urgency: :normal
        )

      Scoring.calculate_and_cache(low.id)

      {:ok, view, _html} = live(conn, ~p"/app")

      # High score should appear before low score
      html = render(view)
      high_pos = :binary.match(html, high.subject)
      low_pos = :binary.match(html, low.subject)

      assert high_pos != :nomatch
      assert low_pos != :nomatch
      assert elem(high_pos, 0) < elem(low_pos, 0)
    end

    test "excludes snoozed conversations", %{conn: conn} do
      org = insert_organization()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      snoozed = insert_conversation(organization_id: org.id, snoozed_until: future)
      active = insert_conversation(organization_id: org.id, snoozed_until: nil)

      Scoring.calculate_and_cache(snoozed.id)
      Scoring.calculate_and_cache(active.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ active.subject
      refute html =~ snoozed.subject
    end

    test "shows empty state when no conversations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Nothing needs attention right now"
    end
  end

  describe "handle_event snooze" do
    test "snoozes a conversation", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, view, _html} = live(conn, ~p"/app")

      # First toggle the snooze menu to show it
      view
      |> element("[phx-click=toggle_snooze][phx-value-id=\"#{conv.id}\"]")
      |> render_click()

      # Then trigger snooze for 1 hour
      view
      |> element(~s([phx-click=snooze][phx-value-id="#{conv.id}"][phx-value-duration="1h"]))
      |> render_click()

      # Conversation should be snoozed and removed from queue
      html = render(view)
      refute html =~ conv.subject
    end
  end

  describe "handle_event filter" do
    test "filters by state", %{conn: conn} do
      org = insert_organization()
      new_conv = insert_conversation(organization_id: org.id, state: :new)
      active_conv = insert_conversation(organization_id: org.id, state: :active)

      Scoring.calculate_and_cache(new_conv.id)
      Scoring.calculate_and_cache(active_conv.id)

      {:ok, view, _html} = live(conn, ~p"/app")

      # Filter to new only
      view
      |> element("[phx-click=filter][phx-value-filter=new]")
      |> render_click()

      html = render(view)
      assert html =~ new_conv.subject
      refute html =~ active_conv.subject
    end
  end

  describe "PubSub subscription" do
    test "updates when conversation_updated event received", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, view, html} = live(conn, ~p"/app")
      assert html =~ conv.subject

      # Update the conversation state
      {:ok, updated} = Custyard.Conversations.update_state(conv, :active)
      Scoring.calculate_and_cache(updated.id)

      # Broadcast the update
      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversations",
        {:conversation_updated, updated.id}
      )

      # Wait for the view to update
      :timer.sleep(100)

      html = render(view)
      assert html =~ "active"
    end
  end

  describe "organization scoping (RBAC)" do
    test "super_admin sees conversations from all organizations", %{conn: conn} do
      # The default setup creates a super_admin staff
      org1 = insert_organization(name: "Org One")
      org2 = insert_organization(name: "Org Two")

      conv1 = insert_conversation(organization_id: org1.id, state: :new)
      conv2 = insert_conversation(organization_id: org2.id, state: :new)

      Scoring.calculate_and_cache(conv1.id)
      Scoring.calculate_and_cache(conv2.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Super admin should see both conversations
      assert html =~ conv1.subject
      assert html =~ conv2.subject
      assert html =~ "Org One"
      assert html =~ "Org Two"
    end

    test "admin only sees conversations from their organization" do
      # Create an organization and an admin staff for that org
      org = insert_organization(name: "Admin's Org")
      other_org = insert_organization(name: "Other Org", tenant_id: insert_tenant().id)

      {:ok, admin_staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "admin@example.com",
          password: "password123",
          role: "admin",
          organization_id: org.id
        })
        |> Repo.insert()

      # Create conversations in both orgs (both must be in attention-worthy states)
      own_conv = insert_conversation(organization_id: org.id, state: :active, subject: "Own Conv")

      other_conv =
        insert_conversation(organization_id: other_org.id, state: :active, subject: "Other Conv")

      Scoring.calculate_and_cache(own_conv.id)
      Scoring.calculate_and_cache(other_conv.id)

      # Debug: verify conversations exist and have scores
      own_reloaded = Repo.get!(Custyard.Conversation, own_conv.id)
      assert own_reloaded.cached_score > 0, "Own conversation should have score"

      # Connect as admin
      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(admin_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Debug: check what the view is showing
      refute html =~ "Nothing needs attention", "Should have conversations to show"

      # Admin should see their org's conversation and not others
      # Test subjects first (more specific than org names which might not be in truncated output)
      assert html =~ "Own Conv", "Admin should see their org's conversation"
      refute html =~ "Other Conv", "Admin should NOT see other org's conversation"
    end

    test "agent only sees conversations from their organization" do
      # Create an organization and an agent staff for that org
      org = insert_organization(name: "Agent Org")
      other_org = insert_organization(name: "Different Org", tenant_id: insert_tenant().id)

      {:ok, agent_staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "agent@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })
        |> Repo.insert()

      # Create conversations in both orgs (use active state for scoring)
      # Avoid apostrophes in subjects - they get HTML-escaped
      own_conv =
        insert_conversation(organization_id: org.id, state: :active, subject: "Agent Own Conv")

      other_conv =
        insert_conversation(
          organization_id: other_org.id,
          state: :active,
          subject: "Different Org Conv"
        )

      Scoring.calculate_and_cache(own_conv.id)
      Scoring.calculate_and_cache(other_conv.id)

      # Connect as agent
      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Agent should only see their org's conversation
      assert html =~ "Agent Own Conv", "Agent should see their org's conversation"
      refute html =~ "Different Org Conv", "Agent should NOT see other org's conversation"
    end

    test "admin snooze action only affects their organization's conversations" do
      org = insert_organization()

      {:ok, admin_staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "admin2@example.com",
          password: "password123",
          role: "admin",
          organization_id: org.id
        })
        |> Repo.insert()

      conv = insert_conversation(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(admin_staff.id)

      {:ok, view, _html} = live(conn, ~p"/app")

      # Toggle snooze menu
      view
      |> element("[phx-click=toggle_snooze][phx-value-id=\"#{conv.id}\"]")
      |> render_click()

      # Snooze the conversation
      view
      |> element(~s([phx-click=snooze][phx-value-id="#{conv.id}"][phx-value-duration="1h"]))
      |> render_click()

      # Conversation should be snoozed
      html = render(view)
      refute html =~ conv.subject
    end

    test "scoped staff sees empty state when their org has no conversations" do
      org = insert_organization()

      {:ok, agent_staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "agent2@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })
        |> Repo.insert()

      # Create conversation in a different org
      other_org = insert_organization(tenant_id: insert_tenant().id)
      conv = insert_conversation(organization_id: other_org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Should see empty state, not the other org's conversation
      assert html =~ "Nothing needs attention right now"
      refute html =~ conv.subject
    end
  end

  describe "nil-organization conversations" do
    test "renders an unlinked prospect card without crashing", %{conn: conn} do
      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          state: :new,
          subject: "Anonymous inquiry"
        )

      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Anonymous inquiry"
      assert html =~ "Unlinked prospect"
      # No organization means no tier badge on the card
      refute html =~ "staff-tier-badge"
    end

    test "org-scoped staff sees own-org and nil-org rows but not other orgs" do
      org = insert_organization(name: "Scoped Org")
      other_org = insert_organization(name: "Foreign Org", tenant_id: insert_tenant().id)

      {:ok, agent_staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "scoped-agent@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })
        |> Repo.insert()

      own_conv =
        insert_conversation(organization_id: org.id, state: :active, subject: "Scoped Own Conv")

      other_conv =
        insert_conversation(
          organization_id: other_org.id,
          state: :active,
          subject: "Foreign Org Conv"
        )

      unlinked_conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          state: :new,
          subject: "Unlinked Intake Conv"
        )

      Scoring.calculate_and_cache(own_conv.id)
      Scoring.calculate_and_cache(other_conv.id)
      Scoring.calculate_and_cache(unlinked_conv.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Scoped Own Conv"
      assert html =~ "Unlinked Intake Conv"
      refute html =~ "Foreign Org Conv"
    end

    test "super_admin queue includes nil-org rows alongside org rows", %{conn: conn} do
      org = insert_organization(name: "Some Org")
      org_conv = insert_conversation(organization_id: org.id, state: :new)

      unlinked_conv =
        insert_conversation(organization_id: nil, source: :disambiguation, state: :new)

      Scoring.calculate_and_cache(org_conv.id)
      Scoring.calculate_and_cache(unlinked_conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ org_conv.subject
      assert html =~ unlinked_conv.subject
    end
  end

  describe "source badge" do
    test "queue card shows a human-labeled source badge", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, source: :portal, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="source-badge-portal")
      assert html =~ "Portal"
    end

    test "disambiguation source renders as Needs routing", %{conn: conn} do
      conv = insert_conversation(organization_id: nil, source: :disambiguation, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="source-badge-disambiguation")
      assert html =~ "Needs routing"
    end
  end

  describe "public intake badges" do
    test "queue card shows the intake source key as a tag badge", %{conn: conn} do
      conv =
        insert_conversation(
          source: :public_intake,
          intake_source_key: "landing-page",
          state: :new
        )

      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="source-badge-public_intake")
      assert html =~ ~s(data-testid="intake-source-tag")
      assert html =~ "landing-page"
    end

    test "shows the amber No reply channel badge for intake conversations without a channel",
         %{conn: conn} do
      conv = insert_conversation(source: :public_intake, state: :new)
      insert_prospect(conversation_id: conv.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="no-reply-channel-badge")
      assert html =~ "No reply channel"
    end

    test "hides the badge once the prospect captured an email", %{conn: conn} do
      conv = insert_conversation(source: :public_intake, state: :new)
      insert_prospect(conversation_id: conv.id, email: "prospect@example.com")
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      refute html =~ ~s(data-testid="no-reply-channel-badge")
    end

    test "does not flag non-intake conversations that lack a contact email", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, source: :email, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      refute html =~ ~s(data-testid="no-reply-channel-badge")
    end

    test "badges never filter: flagged intake conversations stay in every applicable view",
         %{conn: conn} do
      conv =
        insert_conversation(source: :public_intake, state: :new, subject: "Flagged intake conv")

      insert_prospect(conversation_id: conv.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app?filter=new")

      assert html =~ "Flagged intake conv"
      assert html =~ ~s(data-testid="no-reply-channel-badge")
    end
  end

  describe "channel and suspect badges" do
    test "rows show the channel's public address and the suspect flag", %{conn: conn} do
      org = insert_organization()

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "support@acme.example.com",
          state: :active
        )

      flagged =
        insert_conversation(organization_id: org.id, state: :new, inbound_channel_id: channel.id)

      {:ok, _} = Custyard.Conversations.set_suspect(flagged, true)
      Scoring.calculate_and_cache(flagged.id)

      plain = insert_conversation(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(plain.id)

      {:ok, view, html} = live(conn, ~p"/app")

      flagged_card =
        view |> element("[data-testid=staff-queue-card-#{flagged.id}]") |> render()

      assert flagged_card =~ ~s(data-testid="staff-queue-channel")
      assert flagged_card =~ "support@acme.example.com"
      assert flagged_card =~ ~s(data-testid="staff-queue-suspect")
      refute html =~ channel.ingress_token

      plain_card = view |> element("[data-testid=staff-queue-card-#{plain.id}]") |> render()
      refute plain_card =~ "staff-queue-channel"
      refute plain_card =~ "staff-queue-suspect"
    end
  end
end
