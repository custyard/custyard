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

  describe "dispatch_legacy/1" do
    test "processes legacy webhook without route context" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      normalized = %{
        from: "alice@acme.example.com",
        to: "support@custyard.test",
        subject: "Legacy webhook",
        body: "Hello from legacy",
        message_id: nil,
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      assert {:ok, conversation} = Dispatcher.dispatch_legacy(normalized)
      assert conversation.subject == "Legacy webhook"
      assert conversation.organization_id == org.id
    end

    test "emits [:custyard, :webhook, :legacy, :stop] telemetry event" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      # Attach a telemetry handler that sends a message to the test process
      test_pid = self()
      handler_id = "test-legacy-telemetry-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:custyard, :webhook, :legacy, :stop],
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      normalized = %{
        from: "alice@acme.example.com",
        to: "support@custyard.test",
        subject: "Telemetry test",
        body: "Testing telemetry emission",
        message_id: nil,
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email,
        metadata: %{}
      }

      Dispatcher.dispatch_legacy(normalized)

      assert_receive {:telemetry_event, [:custyard, :webhook, :legacy, :stop], measurements,
                      metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert Map.has_key?(metadata, :result)
    end
  end
end
