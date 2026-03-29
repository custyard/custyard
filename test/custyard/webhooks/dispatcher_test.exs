defmodule Custyard.Webhooks.DispatcherTest do
  use Custyard.DataCase, async: true

  alias Custyard.{InboundRoute, InboundRouteWebhook}
  alias Custyard.Webhooks.Dispatcher

  import Custyard.Factory

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

      # Allow async tasks to complete
      Process.sleep(100)

      # Verify audit event was created (audit purpose writes to DB)
      import Ecto.Query

      audit_events =
        from(ae in Custyard.AuditEvent,
          where: ae.conversation_id == ^conversation.id,
          where: ae.event_type == :webhook_received
        )
        |> Repo.all()

      assert length(audit_events) >= 1

      [event] = audit_events
      assert event.source == "email"
      assert event.organization_id == org.id
    end
  end
end
