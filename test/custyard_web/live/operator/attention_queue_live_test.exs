defmodule CustyardWeb.Operator.AttentionQueueLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{Scoring, OperatorAccount, Repo}

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
    test "renders attention queue page", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :new)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/operator")

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

      {:ok, view, _html} = live(conn, ~p"/operator")

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

      {:ok, _view, html} = live(conn, ~p"/operator")

      assert html =~ active.subject
      refute html =~ snoozed.subject
    end

    test "shows empty state when no conversations", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operator")

      assert html =~ "Nothing needs attention right now"
    end
  end

  describe "handle_event snooze" do
    test "snoozes a conversation", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      Scoring.calculate_and_cache(conv.id)

      {:ok, view, _html} = live(conn, ~p"/operator")

      # First toggle the snooze menu to show it
      view
      |> element("[phx-click=toggle_snooze][phx-value-id=\"#{conv.id}\"]")
      |> render_click()

      # Then trigger snooze for 1 hour
      view
      |> element("[phx-click=snooze][phx-value-id=\"#{conv.id}\"][phx-value-duration=\"1h\"]")
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

      {:ok, view, _html} = live(conn, ~p"/operator")

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

      {:ok, view, html} = live(conn, ~p"/operator")
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
end
