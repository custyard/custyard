defmodule Custyard.Webhooks.DispatcherTest do
  use Custyard.DataCase, async: true

  alias Custyard.{InboundRoute, InboundRouteWebhook}
  alias Custyard.Webhooks.Dispatcher

  import Custyard.Factory

  # Polls a function until it returns {:ok, value} or raises after max attempts.
  # Replaces fixed Process.sleep for async assertions.
  defp poll_until(fun, opts \\ []) do
    interval = Keyword.get(opts, :interval, 10)
    max_attempts = Keyword.get(opts, :max_attempts, 50)

    result =
      Enum.reduce_while(1..max_attempts, :timeout, fn _i, _acc ->
        case fun.() do
          {:ok, value} -> {:halt, {:ok, value}}
          :retry ->
            Process.sleep(interval)
            {:cont, :timeout}
        end
      end)

    case result do
      {:ok, value} -> value
      :timeout -> flunk("poll_until exceeded #{max_attempts} attempts (#{max_attempts * interval}ms)")
    end
  end

  describe "dispatch/2" do
    test "creates conversation via routed webhook" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: true
      })
      |> Repo.insert!()

      normalized = %{
        from: "alice@acme.example.com",
        to: "support@custyard.test",
        subject: "Routed webhook test",
        body: "Hello from a routed webhook",
        message_id: "route-test@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.subject == "Routed webhook test"
      assert conversation.organization_id == org.id
    end

    test "sets project_id from project route" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      project = insert_project(organization_id: org.id, title: "Website Redesign")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project
        })
        |> Repo.insert!()

      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: true
      })
      |> Repo.insert!()

      normalized = %{
        from: "alice@acme.example.com",
        to: nil,
        subject: "Project-routed message",
        body: "This should be linked to the project",
        message_id: nil,
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.project_id == project.id
    end
  end

  describe "route_context propagation with source: :email" do
    test "general route populates route_context with organization_id" do
      org = insert_organization(domain: "email-route.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@email-route.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: true
      })
      |> Repo.insert!()

      normalized = %{
        from: "alice@email-route.example.com",
        to: "support@custyard.test",
        subject: "Email source general route",
        body: "Testing route context propagation",
        message_id: "<ctx-general-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.organization_id == org.id
      assert conversation.project_id == nil
    end

    test "project route populates route_context with organization_id and project_id" do
      org = insert_organization(domain: "email-route.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@email-route.example.com")
      project = insert_project(organization_id: org.id, title: "Email Project")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project
        })
        |> Repo.insert!()

      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: true
      })
      |> Repo.insert!()

      normalized = %{
        from: "alice@email-route.example.com",
        to: nil,
        subject: "Email source project route",
        body: "Testing project route context",
        message_id: "<ctx-project-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.organization_id == org.id
      assert conversation.project_id == project.id
    end

    test "async purposes fire when webhook purpose records exist on the route" do
      org = insert_organization(domain: "purposes.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@purposes.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      # Enable all four webhook purposes
      for purpose <- [:sender_matching, :enrichment, :notification, :audit] do
        %InboundRouteWebhook{}
        |> InboundRouteWebhook.changeset(%{
          inbound_route_id: route.id,
          purpose: purpose,
          enabled: true
        })
        |> Repo.insert!()
      end

      normalized = %{
        from: "alice@purposes.example.com",
        to: "support@custyard.test",
        subject: "All purposes test",
        body: "This should trigger enrichment, notification, and audit",
        message_id: "<purposes-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      # Dispatch should succeed (sender_matching creates conversation)
      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.organization_id == org.id

      # Poll the DB for the audit event created by the async audit purpose,
      # rather than using a fixed Process.sleep.
      import Ecto.Query

      audit_events =
        poll_until(fn ->
          events =
            from(ae in Custyard.AuditEvent,
              where: ae.conversation_id == ^conversation.id,
              where: ae.event_type == :webhook_received
            )
            |> Repo.all()

          if length(events) >= 1, do: {:ok, events}, else: :retry
        end)

      assert length(audit_events) >= 1

      [event] = audit_events
      assert event.source == "email"
      assert event.organization_id == org.id
    end
  end

  describe "sender_matching runs regardless of webhook enabled flag" do
    test "conversation is created even when sender_matching webhook is disabled" do
      # The Dispatcher always runs sender_matching synchronously to create
      # the conversation, regardless of whether a sender_matching webhook
      # record exists or is enabled. This is by design: run_sender_matching/3
      # ignores _enabled_purposes and calls SenderMatching.process directly.
      org = insert_organization(domain: "disabled-sm.example.com")
      _contact = insert_contact(organization_id: org.id, email: "bob@disabled-sm.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      # Create a sender_matching webhook but disable it
      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: false
      })
      |> Repo.insert!()

      normalized = %{
        from: "bob@disabled-sm.example.com",
        to: "support@custyard.test",
        subject: "Disabled webhook test",
        body: "Sender matching should still run",
        message_id: "<disabled-sm-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.subject == "Disabled webhook test"
      assert conversation.organization_id == org.id
    end

    test "conversation is created when no sender_matching webhook record exists at all" do
      # Even with zero webhook records on the route, the dispatcher still
      # runs sender_matching because it is hardcoded in the dispatch pipeline.
      org = insert_organization(domain: "no-webhook.example.com")
      _contact = insert_contact(organization_id: org.id, email: "carol@no-webhook.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      # No webhook records at all — route.webhooks will be empty
      assert [] =
               from(w in InboundRouteWebhook, where: w.inbound_route_id == ^route.id)
               |> Repo.all()

      normalized = %{
        from: "carol@no-webhook.example.com",
        to: "support@custyard.test",
        subject: "No webhook records test",
        body: "Should still create a conversation",
        message_id: "<no-wh-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)
      assert conversation.subject == "No webhook records test"
      assert conversation.organization_id == org.id
    end

    test "async purposes do not fire when their webhooks are disabled" do
      # Counterpart test: while sender_matching always runs, the async
      # purposes (enrichment, notification, audit) only fire when their
      # webhook records exist and are enabled. This test creates a route
      # with sender_matching disabled and no other webhook records, then
      # verifies no audit events are created (proving async purposes
      # respected the enabled flag).
      org = insert_organization(domain: "async-off.example.com")
      _contact = insert_contact(organization_id: org.id, email: "dave@async-off.example.com")

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general
        })
        |> Repo.insert!()

      # Only sender_matching exists, disabled. No audit/notification/enrichment.
      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching,
        enabled: false
      })
      |> Repo.insert!()

      normalized = %{
        from: "dave@async-off.example.com",
        to: "support@custyard.test",
        subject: "No async purposes test",
        body: "Async purposes should not fire",
        message_id: "<async-off-#{System.unique_integer([:positive])}@example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch(route, normalized)

      # Give async tasks a brief window to complete (if any were started)
      Process.sleep(100)

      # No audit events should exist for this conversation since no audit
      # webhook was enabled
      import Ecto.Query

      audit_events =
        from(ae in Custyard.AuditEvent,
          where: ae.conversation_id == ^conversation.id
        )
        |> Repo.all()

      assert audit_events == []
    end
  end
end
