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
    test "email setup completion refreshes from the tenant's setup events", %{
      conn: conn,
      staff: staff
    } do
      {:ok, connection} = Custyard.EmailSetup.ensure_connection(staff, staff.tenant_id)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.update!(
        Ecto.Changeset.change(connection,
          project_id: "tenant-project",
          last_signed_inbound_at: now,
          last_reply_delivered_at: now,
          last_returning_reply_at: now
        )
      )

      {:ok, view, _} = live(conn, ~p"/app")
      assert has_element?(view, "[data-testid=email-setup-prompt]", "Finish email setup")

      assert has_element?(
               view,
               "[data-testid=email-setup-missing-evidence] li",
               "A reply sent from Custyard"
             )

      refute has_element?(
               view,
               "[data-testid=email-setup-missing-evidence] li",
               "A new email received"
             )

      thread = insert_thread()

      outgoing =
        insert_message(
          thread_id: thread.id,
          source: :staff,
          lettermint_message_id: "accepted-message"
        )

      Custyard.EmailSetup.record_reply_accepted(outgoing)
      refute has_element?(view, "[data-testid=email-setup-prompt]")

      Custyard.EmailSetup.invalidate_receiving(staff.tenant_id)
      assert has_element?(view, "[data-testid=email-setup-prompt]")
    end

    test "renders attention queue page", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Attention Queue"
      assert html =~ conv.subject
    end

    test "shows threads ordered by score", %{conn: conn} do
      org = insert_organization(tier: :enterprise)
      # Higher score (enterprise tier, urgent)
      high =
        insert_thread(
          organization_id: org.id,
          state: :new,
          urgency: :urgent
        )

      Scoring.calculate_and_cache(high.id)

      org2 = insert_organization(tier: :basic)
      # Lower score (basic tier, normal)
      low =
        insert_thread(
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

    test "excludes snoozed threads", %{conn: conn} do
      org = insert_organization()
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      snoozed = insert_thread(organization_id: org.id, snoozed_until: future)
      active = insert_thread(organization_id: org.id, snoozed_until: nil)

      Scoring.calculate_and_cache(snoozed.id)
      Scoring.calculate_and_cache(active.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ active.subject
      refute html =~ snoozed.subject
    end

    test "shows empty state when no threads", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ "Nothing needs attention right now"
    end
  end

  describe "handle_event snooze" do
    test "snoozes a thread", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
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

      # Thread should be snoozed and removed from queue
      html = render(view)
      refute html =~ conv.subject
    end
  end

  describe "handle_event filter" do
    test "filters by state", %{conn: conn} do
      org = insert_organization()
      new_conv = insert_thread(organization_id: org.id, state: :new)
      active_conv = insert_thread(organization_id: org.id, state: :active)

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
    test "updates when thread_updated event received", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, view, html} = live(conn, ~p"/app")
      assert html =~ conv.subject

      # Update the thread state
      {:ok, updated} = Custyard.Threads.update_state(conv, :active)
      Scoring.calculate_and_cache(updated.id)

      # Broadcast the update
      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "threads",
        {:thread_updated, updated.id}
      )

      # Wait for the view to update
      :timer.sleep(100)

      html = render(view)
      assert html =~ "active"
    end

    test "an open queue stops previewing a message deleted elsewhere", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      message = insert_message(thread_id: conv.id, body: "Card number 4111 1111")

      {:ok, view, _html} = live(conn, ~p"/app")
      snippet = "[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-snippet]"
      assert has_element?(view, snippet, "Card number 4111 1111")

      {:ok, _} = Custyard.Threads.soft_delete_message(message, staff)

      # The reload is debounced, so the row changes a moment after the broadcast.
      assert Enum.any?(1..40, fn _ ->
               Process.sleep(50)
               has_element?(view, snippet, "Message deleted")
             end)

      refute render(view) =~ "4111 1111"
    end
  end

  describe "organization scoping (RBAC)" do
    test "super_admin sees threads from all organizations", %{conn: conn} do
      # The default setup creates a super_admin staff
      org1 = insert_organization(name: "Org One")
      org2 = insert_organization(name: "Org Two")

      conv1 = insert_thread(organization_id: org1.id, state: :new)
      conv2 = insert_thread(organization_id: org2.id, state: :new)

      Scoring.calculate_and_cache(conv1.id)
      Scoring.calculate_and_cache(conv2.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Super admin should see both threads
      assert html =~ conv1.subject
      assert html =~ conv2.subject
      assert html =~ "Org One"
      assert html =~ "Org Two"
    end

    test "admin only sees threads from their organization" do
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

      # Create threads in both orgs (both must be in attention-worthy states)
      own_conv = insert_thread(organization_id: org.id, state: :active, subject: "Own Conv")

      other_conv =
        insert_thread(organization_id: other_org.id, state: :active, subject: "Other Conv")

      Scoring.calculate_and_cache(own_conv.id)
      Scoring.calculate_and_cache(other_conv.id)

      # Debug: verify threads exist and have scores
      own_reloaded = Repo.get!(Custyard.Thread, own_conv.id)
      assert own_reloaded.cached_score > 0, "Own thread should have score"

      # Connect as admin
      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(admin_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Debug: check what the view is showing
      refute html =~ "Nothing needs attention", "Should have threads to show"

      # Admin should see their org's thread and not others
      # Test subjects first (more specific than org names which might not be in truncated output)
      assert html =~ "Own Conv", "Admin should see their org's thread"
      refute html =~ "Other Conv", "Admin should NOT see other org's thread"
    end

    test "agent only sees threads from their organization" do
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

      # Create threads in both orgs (use active state for scoring)
      # Avoid apostrophes in subjects - they get HTML-escaped
      own_conv =
        insert_thread(organization_id: org.id, state: :active, subject: "Agent Own Conv")

      other_conv =
        insert_thread(
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

      # Agent should only see their org's thread
      assert html =~ "Agent Own Conv", "Agent should see their org's thread"
      refute html =~ "Different Org Conv", "Agent should NOT see other org's thread"
    end

    test "admin snooze action only affects their organization's threads" do
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

      conv = insert_thread(organization_id: org.id, state: :new)
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

      # Snooze the thread
      view
      |> element(~s([phx-click=snooze][phx-value-id="#{conv.id}"][phx-value-duration="1h"]))
      |> render_click()

      # Thread should be snoozed
      html = render(view)
      refute html =~ conv.subject
    end

    test "scoped staff sees empty state when their org has no threads" do
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

      # Create thread in a different org
      other_org = insert_organization(tenant_id: insert_tenant().id)
      conv = insert_thread(organization_id: other_org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent_staff.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      # Should see empty state, not the other org's thread
      assert html =~ "Nothing needs attention right now"
      refute html =~ conv.subject
    end
  end

  describe "nil-organization threads" do
    test "renders an unlinked prospect card without crashing", %{conn: conn} do
      conv =
        insert_thread(
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
        insert_thread(organization_id: org.id, state: :active, subject: "Scoped Own Conv")

      other_conv =
        insert_thread(
          organization_id: other_org.id,
          state: :active,
          subject: "Foreign Org Conv"
        )

      unlinked_conv =
        insert_thread(
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
      org_conv = insert_thread(organization_id: org.id, state: :new)

      unlinked_conv =
        insert_thread(organization_id: nil, source: :disambiguation, state: :new)

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
      conv = insert_thread(organization_id: org.id, source: :portal, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="source-badge-portal")
      assert html =~ "Portal"
    end

    test "disambiguation source renders as Needs routing", %{conn: conn} do
      conv = insert_thread(organization_id: nil, source: :disambiguation, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="source-badge-disambiguation")
      assert html =~ "Needs routing"
    end
  end

  describe "public intake badges" do
    test "queue card shows the intake source key as a tag badge", %{conn: conn} do
      conv =
        insert_thread(
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

    test "shows the amber No reply channel badge for intake threads without a channel",
         %{conn: conn} do
      conv = insert_thread(source: :public_intake, state: :new)
      insert_prospect(thread_id: conv.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      assert html =~ ~s(data-testid="no-reply-channel-badge")
      assert html =~ "No reply channel"
    end

    test "hides the badge once the prospect captured an email", %{conn: conn} do
      conv = insert_thread(source: :public_intake, state: :new)
      insert_prospect(thread_id: conv.id, email: "prospect@example.com")
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      refute html =~ ~s(data-testid="no-reply-channel-badge")
    end

    test "does not flag non-intake threads that lack a contact email", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, source: :email, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app")

      refute html =~ ~s(data-testid="no-reply-channel-badge")
    end

    test "badges never filter: flagged intake threads stay in every applicable view",
         %{conn: conn} do
      conv =
        insert_thread(source: :public_intake, state: :new, subject: "Flagged intake conv")

      insert_prospect(thread_id: conv.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app?filter=new")

      assert html =~ "Flagged intake conv"
      assert html =~ ~s(data-testid="no-reply-channel-badge")
    end
  end

  describe "inbox rows" do
    test "a row previews the latest message as escaped plain text", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: conv.id, body: "First question")

      insert_message(
        thread_id: conv.id,
        body: "Second line\n<script>alert(1)</script> & more",
        html_body: "<p>Second <b>line</b></p>"
      )

      {:ok, view, _html} = live(conn, ~p"/app")

      snippet =
        view
        |> element("[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-snippet]")
        |> render()

      assert snippet =~ "Second line &lt;script&gt;alert(1)&lt;/script&gt; &amp; more"
      refute snippet =~ "<script>"
      refute snippet =~ "<b>"
      refute snippet =~ "First question"
    end

    test "a row without messages and a row whose latest message was deleted say so", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization()
      empty = insert_thread(organization_id: org.id, state: :active)
      deleted = insert_thread(organization_id: org.id, state: :active)
      message = insert_message(thread_id: deleted.id, body: "Card number 4111 1111")
      {:ok, _} = Custyard.Threads.soft_delete_message(message, staff)

      {:ok, view, html} = live(conn, ~p"/app")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{empty.id}] [data-testid=staff-queue-snippet]",
               "No messages yet"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{deleted.id}] [data-testid=staff-queue-snippet]",
               "Message deleted"
             )

      refute html =~ "4111 1111"
    end

    test "shows who has to act next", %{conn: conn, staff: staff} do
      org = insert_organization()
      needs_reply = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: needs_reply.id, source: :staff, body: "Could you send a log?")
      insert_message(thread_id: needs_reply.id, body: "Here is the log")

      insert_message(
        thread_id: needs_reply.id,
        source: :staff,
        is_internal_note: true,
        body: "Looks like the cache bug"
      )

      replied = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: replied.id, body: "Is this fixed?")
      reply = insert_message(thread_id: replied.id, source: :staff, body: "Yes, since Monday")

      Repo.update!(Ecto.Changeset.change(reply, author_staff_id: staff.id))

      parked = insert_thread(organization_id: org.id, state: :waiting)
      insert_message(thread_id: parked.id, body: "I will check with my team")

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{needs_reply.id}][data-turn=ours] [data-testid=staff-queue-turn]",
               "Needs reply"
             )

      # The note is previewed, but it is not a reply to the customer.
      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{needs_reply.id}] [data-testid=staff-queue-snippet]",
               "Note: Looks like the cache bug"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{replied.id}][data-turn=theirs] [data-testid=staff-queue-turn]",
               "Waiting on customer"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{replied.id}] [data-testid=staff-queue-snippet]",
               "You: Yes, since Monday"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{parked.id}][data-turn=theirs] [data-testid=staff-queue-turn]",
               "Waiting on customer"
             )
    end

    test "the whole row links to the conversation and the row actions sit outside the link", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active, subject: "Opens on click")

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(
               view,
               "li[data-testid=staff-queue-card-#{conv.id}] a[data-testid=staff-queue-row-link][href='/app/threads/#{conv.id}?pos=0']",
               "Opens on click"
             )

      refute has_element?(view, "a[data-testid=staff-queue-row-link] button")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{conv.id}] button[data-testid=staff-queue-score-toggle][aria-label='Why this rank?'][aria-expanded=false]"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{conv.id}] button[data-testid=staff-queue-snooze-btn][aria-label=Snooze]"
             )
    end

    test "values that say nothing stay off the row and move into Why this rank", %{conn: conn} do
      org = insert_organization(name: "Plain Customer", tier: :standard)

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "billing@acme.example.com",
          state: :active
        )

      old = DateTime.add(DateTime.utc_now(), -30, :day) |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :active,
          source: :lettermint,
          inbound_channel_id: channel.id,
          last_staff_action_at: old
        )

      insert_message(thread_id: conv.id, body: "Still waiting")
      Scoring.calculate_and_cache(conv.id)
      score = Repo.get!(Custyard.Thread, conv.id).cached_score

      {:ok, view, _html} = live(conn, ~p"/app")
      card = "[data-testid=staff-queue-card-#{conv.id}]"
      row = view |> element(card) |> render()

      refute row =~ "staff-tier-badge"
      refute row =~ "source-badge-lettermint"
      refute row =~ "staff-neglect-badge"
      refute row =~ "staff-queue-score\""
      refute row =~ "Score #{score}"

      # Neglect is an accent on the row and a sentence for screen readers.
      assert has_element?(view, "#{card}[data-neglect=critical]")
      assert has_element?(view, "#{card} [data-testid=staff-queue-age]", "Neglected")

      # The mailbox is shortened; the full address is one hover away.
      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-channel][title='Received at billing@acme.example.com']",
               "billing@"
             )

      refute view |> element("#{card} [data-testid=staff-queue-channel]") |> render() =~
               ">billing@acme.example.com<"

      view |> element("#{card} [data-testid=staff-queue-score-toggle]") |> render_click()

      assert has_element?(view, "#{card} [data-testid=staff-queue-score]", "Score #{score}")

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-rank] [data-testid=source-badge-lettermint]"
             )

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-rank] [data-testid=staff-tier-badge-standard]"
             )

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-rank] [data-testid=staff-neglect-badge-critical]"
             )

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-score-toggle][aria-expanded=true]"
             )
    end

    test "Why this rank builds velocity from the last 24 hours of messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      last_week = DateTime.add(DateTime.utc_now(:second), -8, :day)

      for body <- ["One", "Two", "Three", "Four"] do
        message = insert_message(thread_id: conv.id, body: body)
        Repo.update!(Ecto.Changeset.change(message, inserted_at: last_week))
      end

      insert_message(thread_id: conv.id, body: "Today")

      recent = Scoring.breakdown(conv, message_count: 1).velocity
      total = Scoring.breakdown(conv, message_count: 5).velocity
      # The panel can only tell the two counts apart if they score differently.
      assert recent != total

      {:ok, view, _html} = live(conn, ~p"/app")
      card = "[data-testid=staff-queue-card-#{conv.id}]"
      view |> element("#{card} [data-testid=staff-queue-score-toggle]") |> render_click()

      # A breakdown row is its label, a bar and its value.
      assert view
             |> element("#{card} [data-testid=staff-score-breakdown] > div", "velocity")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.text(sep: " ")
             |> String.split() == ["velocity", to_string(recent)]
    end

    test "a non-default tier stays on the row", %{conn: conn} do
      org = insert_organization(tier: :enterprise)
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-chips] [data-testid=staff-tier-badge-enterprise]"
             )
    end

    test "the snooze and the labels come before the tier and the mailbox", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization(tier: :enterprise)

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "billing@acme.example.com",
          state: :active
        )

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :active,
          inbound_channel_id: channel.id,
          snoozed_until: DateTime.add(now, 3600)
        )

      # A due task keeps the snoozed row in the unfiltered list.
      {:ok, _} =
        Custyard.Threads.create_task(%{
          title: "Overdue",
          thread_id: conv.id,
          due_at: DateTime.add(now, -60)
        })

      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
      {:ok, label} = Custyard.Labels.create_and_assign(scope, conv, "Billing")

      {:ok, view, _html} = live(conn, ~p"/app")
      chips = "[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-chips]"
      html = view |> element(chips) |> render()

      positions =
        for testid <- [
              "staff-queue-snoozed",
              "queue-label-#{label.id}",
              "staff-tier-badge-enterprise",
              "staff-queue-channel"
            ] do
          {position, _} = :binary.match(html, ~s(data-testid="#{testid}"))
          position
        end

      assert positions == Enum.sort(positions)

      # Below md the chip is the one word; the time stays in its title.
      assert has_element?(
               view,
               "#{chips} [data-testid=staff-queue-snoozed][title^='Snoozed until ']"
             )

      assert has_element?(
               view,
               "#{chips} [data-testid=staff-queue-snoozed] span[class='hidden md:inline']",
               "until"
             )
    end

    test "leads with the contact and names the customer only when it adds something", %{
      conn: conn
    } do
      named_org = insert_organization(name: "yorb.tech")

      named =
        insert_contact(organization_id: named_org.id, name: "Zef Sowman", email: "zef@yorb.tech")

      with_name =
        insert_thread(organization_id: named_org.id, contact_id: named.id, state: :active)

      same_org = insert_organization(name: "onetime.example")

      same =
        insert_contact(organization_id: same_org.id, name: nil, email: "secure@onetime.example")

      redundant = insert_thread(organization_id: same_org.id, contact_id: same.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{with_name.id}] [data-testid=staff-queue-who]",
               "Zef Sowman"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{with_name.id}] [data-testid=staff-queue-org-name]",
               "yorb.tech"
             )

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{redundant.id}] [data-testid=staff-queue-who]",
               "secure@onetime.example"
             )

      refute has_element?(
               view,
               "[data-testid=staff-queue-card-#{redundant.id}] [data-testid=staff-queue-org-name]"
             )
    end
  end

  describe "filter counts" do
    test "each filter chip shows how many conversations it lists", %{conn: conn} do
      org = insert_organization()
      later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      insert_thread(organization_id: org.id, state: :new)
      insert_thread(organization_id: org.id, state: :new)
      insert_thread(organization_id: org.id, state: :active)
      insert_thread(organization_id: org.id, state: :waiting)
      insert_thread(organization_id: org.id, state: :resolved)
      insert_thread(organization_id: org.id, state: :active, snoozed_until: later)

      {:ok, view, _html} = live(conn, ~p"/app")

      for {filter, count} <- [
            {"all", 4},
            {"new", 2},
            {"active", 1},
            {"waiting", 1},
            {"dormant", 0},
            {"snoozed", 1},
            {"due_tasks", 0}
          ] do
        assert view
               |> element("[data-testid=staff-queue-filter-count-#{filter}]")
               |> render()
               |> Floki.parse_fragment!()
               |> Floki.text()
               |> String.trim() == to_string(count),
               "count on the #{filter} chip"
      end

      # The counts do not depend on the filter being viewed.
      view |> element("[phx-click=filter][phx-value-filter=new]") |> render_click()
      assert has_element?(view, "[data-testid=staff-queue-filter-count-all]", "4")
      assert has_element?(view, "[data-testid=staff-queue-count]", "2 conversations")
    end

    test "counts follow the label filter", %{conn: conn, staff: staff} do
      org = insert_organization()
      labelled = insert_thread(organization_id: org.id, state: :new)
      insert_thread(organization_id: org.id, state: :new)

      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
      {:ok, label} = Custyard.Labels.create_and_assign(scope, labelled, "Billing")

      {:ok, view, _html} = live(conn, ~p"/app?label=#{label.id}")

      assert has_element?(view, "[data-testid=staff-queue-filter-count-all]", "1")
      assert has_element?(view, "[data-testid=staff-queue-filter-count-new]", "1")
    end
  end

  describe "snoozed rows" do
    test "can be un-snoozed from the snoozed filter", %{conn: conn} do
      org = insert_organization()
      later = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      conv = insert_thread(organization_id: org.id, state: :active, snoozed_until: later)

      {:ok, view, _html} = live(conn, ~p"/app?filter=snoozed")
      card = "[data-testid=staff-queue-card-#{conv.id}]"

      assert has_element?(view, "#{card} [data-testid=staff-queue-snoozed]", "snoozed until")
      refute has_element?(view, "#{card} [data-testid=staff-queue-snooze-btn]")

      view |> element("#{card} [data-testid=staff-queue-unsnooze-btn]") |> render_click()

      refute has_element?(view, card)
      assert Repo.get!(Custyard.Thread, conv.id).snoozed_until == nil
    end
  end

  describe "loading" do
    test "the queue is loaded once per render", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: conv.id, body: "Hello")

      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "queue-single-load-#{inspect(ref)}",
        [:custyard, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          # One preview query (the only one that cuts bodies) per queue load.
          if self() == test_pid and metadata.query =~ "substr(",
            do: send(test_pid, {ref, :queue_loaded})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("queue-single-load-#{inspect(ref)}") end)

      # A plain GET renders the page once: mount, then handle_params.
      assert html_response(get(conn, ~p"/app"), 200) =~ conv.subject
      assert_received {^ref, :queue_loaded}
      refute_received {^ref, :queue_loaded}
    end

    test "label changes made elsewhere still appear after a reload", %{conn: conn, staff: staff} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app")
      refute has_element?(view, "#queue-label-filter")

      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
      {:ok, label} = Custyard.Labels.create_and_assign(scope, conv, "Billing")
      send(view.pid, :debounced_reload)

      assert has_element?(view, "#queue-label option[value='#{label.id}']", "Billing")
    end
  end

  describe "needs reply filter" do
    test "the chip lists and counts the conversations waiting on staff", %{conn: conn} do
      org = insert_organization()
      waiting_on_us = insert_thread(organization_id: org.id, state: :active, subject: "Ours")
      insert_message(thread_id: waiting_on_us.id, body: "Any news?")

      replied = insert_thread(organization_id: org.id, state: :active, subject: "Theirs")
      insert_message(thread_id: replied.id, body: "Question")
      insert_message(thread_id: replied.id, source: :staff, body: "Answer")

      parked = insert_thread(organization_id: org.id, state: :waiting, subject: "Parked")
      insert_message(thread_id: parked.id, body: "Will check")

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(view, "[data-testid=staff-queue-filter-needs_reply]", "needs reply")
      assert has_element?(view, "[data-testid=staff-queue-filter-count-needs_reply]", "1")
      assert has_element?(view, "[data-testid=staff-queue-filter-count-all]", "3")

      view |> element("[data-testid=staff-queue-filter-needs_reply]") |> render_click()
      assert_patch(view, ~p"/app?filter=needs_reply&label=")

      assert has_element?(view, "[data-testid=staff-queue-filter-needs_reply][aria-pressed=true]")

      assert has_element?(
               view,
               "[data-testid=staff-queue-card-#{waiting_on_us.id}][data-turn=ours]"
             )

      refute has_element?(view, "[data-testid=staff-queue-card-#{replied.id}]")
      refute has_element?(view, "[data-testid=staff-queue-card-#{parked.id}]")
      assert has_element?(view, "[data-testid=staff-queue-count]", "1 conversation")

      # Every listed row says "Needs reply": the chip and the rows share a rule.
      refute has_element?(view, "[data-testid^=staff-queue-card-][data-turn=theirs]")
    end
  end

  describe "snooze menu" do
    test "the button toggles the menu and sits inside its click-away area", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app")
      area = "[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-snooze]"
      button = "#{area} > button[data-testid=staff-queue-snooze-btn]"

      # Closed: nothing listens for outside clicks.
      refute has_element?(view, "#{area}[phx-click-away]")
      refute has_element?(view, "[phx-click-away]")

      view |> element(button) |> render_click()

      assert has_element?(
               view,
               "#{area}[phx-click-away=close_snooze] [data-testid=staff-queue-snooze-menu]"
             )

      assert has_element?(view, "#{button}[aria-expanded=true]")

      # The button is not outside the area, so this click is the only event.
      view |> element(button) |> render_click()
      refute has_element?(view, "[data-testid=staff-queue-snooze-menu]")
      assert has_element?(view, "#{button}[aria-expanded=false]")
    end

    test "an outside click or Escape closes it", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app")
      area = "[data-testid=staff-queue-card-#{conv.id}] [data-testid=staff-queue-snooze]"

      view |> element("#{area} [data-testid=staff-queue-snooze-btn]") |> render_click()
      assert has_element?(view, "#{area}[phx-window-keydown=close_snooze][phx-key=escape]")

      render_click(view, "close_snooze", %{})
      refute has_element?(view, "[data-testid=staff-queue-snooze-menu]")
      assert Repo.get!(Custyard.Thread, conv.id).snoozed_until == nil
    end
  end

  describe "keyboard triage" do
    test "rows are a keyboard-navigable list and carry their place in the queue", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization()
      first = insert_thread(organization_id: org.id, state: :active, cached_score: 90)
      second = insert_thread(organization_id: org.id, state: :active, cached_score: 50)
      insert_message(thread_id: first.id, body: "One")
      insert_message(thread_id: second.id, body: "Two")

      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
      {:ok, label} = Custyard.Labels.create_and_assign(scope, first, "Billing")
      {:ok, _} = Custyard.Labels.assign(scope, second, label.id)

      {:ok, view, _html} = live(conn, ~p"/app")

      assert has_element?(view, "ul#staff-queue-list[phx-hook=QueueKeys]")
      refute has_element?(view, "ul#staff-queue-list[data-select]")
      assert has_element?(view, "[data-testid=staff-queue-keys]", "move")

      assert has_element?(
               view,
               "li#queue-row-#{first.id} a[data-row-link][href='/app/threads/#{first.id}?pos=0&before=#{second.id}']"
             )

      assert has_element?(
               view,
               "li#queue-row-#{second.id} a[data-row-link][href='/app/threads/#{second.id}?pos=1&after=#{first.id}']"
             )

      # Under a filter and a label, the links say which queue they belong to.
      {:ok, filtered, _html} = live(conn, ~p"/app?filter=needs_reply&label=#{label.id}")

      assert has_element?(
               filtered,
               "li#queue-row-#{second.id} a[data-row-link][href='/app/threads/#{second.id}?filter=needs_reply&label=#{label.id}&pos=1&after=#{first.id}']"
             )
    end

    test "coming back from a conversation selects its row", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app?at=#{conv.id}")
      assert has_element?(view, "ul#staff-queue-list[data-select='#{conv.id}']")

      # Changing the filter starts a fresh pass through the list.
      view |> element("[phx-click=filter][phx-value-filter=active]") |> render_click()
      refute has_element?(view, "ul#staff-queue-list[data-select]")

      {:ok, junk, _html} = live(conn, ~p"/app?at=not-a-number")
      refute has_element?(junk, "ul#staff-queue-list[data-select]")
    end
  end

  describe "row message count" do
    test "counts messages exchanged with the customer, not internal notes", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: conv.id, body: "Question")
      insert_message(thread_id: conv.id, source: :staff, body: "Answer")
      insert_message(thread_id: conv.id, source: :staff, is_internal_note: true, body: "Memo")
      insert_message(thread_id: conv.id, source: :staff, is_internal_note: true, body: "Memo 2")

      noted = insert_thread(organization_id: org.id, state: :active)
      insert_message(thread_id: noted.id, body: "Only message")
      insert_message(thread_id: noted.id, source: :staff, is_internal_note: true, body: "Memo")

      {:ok, view, _html} = live(conn, ~p"/app")
      card = "[data-testid=staff-queue-card-#{conv.id}]"

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-msg-count][title='2 messages exchanged with the customer']",
               "2"
             )

      # One exchanged message: no count on the row.
      refute has_element?(
               view,
               "[data-testid=staff-queue-card-#{noted.id}] [data-testid=staff-queue-msg-count]"
             )

      view |> element("#{card} [data-testid=staff-queue-score-toggle]") |> render_click()

      assert has_element?(
               view,
               "#{card} [data-testid=staff-queue-rank-messages]",
               "2 exchanged with the customer, 2 internal or automatic"
             )
    end
  end

  describe "staff navigation" do
    test "keeps every destination and the account group", %{conn: conn, staff: staff} do
      {:ok, view, _html} = live(conn, ~p"/app")

      for {testid, text, href} <- [
            {"staff-nav-queue", "Attention Queue", "/app"},
            {"staff-nav-neglect", "Neglect Report", "/app/neglect"},
            {"staff-nav-orgs", "Customers", "/app/customers"},
            {"staff-nav-projects", "Projects", "/app/projects"},
            {"staff-nav-intake-sources", "Intake Sources", "/app/settings/intake"},
            {"staff-nav-slugs", "Slugs", "/app/settings/slugs"},
            {"staff-nav-acknowledgments", "Acknowledgments", "/app/settings/integrations"},
            {"staff-nav-settings", "Settings", "/app/settings/workflow"}
          ] do
        assert has_element?(
                 view,
                 "nav[aria-label=Staff] a[data-testid=#{testid}][href='#{href}']",
                 text
               )
      end

      assert has_element?(view, "[data-testid=staff-identity]", "Staff · #{staff.email}")

      # Shown as an icon on narrower screens; the name is still its text.
      assert has_element?(
               view,
               "a[data-testid=staff-nav-instance-admin][href$='/admin/login'][title='Instance admin sign in']",
               "Instance admin sign in"
             )

      assert has_element?(view, "a[data-testid=staff-nav-logout][href='/app/logout']", "Log out")

      assert has_element?(
               view,
               "#mobile-menu a[data-testid=staff-nav-mobile-instance-admin][href$='/admin/login']",
               "Instance admin sign in"
             )
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
        insert_thread(organization_id: org.id, state: :new, inbound_channel_id: channel.id)

      {:ok, _} = Custyard.Threads.set_suspect(flagged, true)
      Scoring.calculate_and_cache(flagged.id)

      plain = insert_thread(organization_id: org.id, state: :new)
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
