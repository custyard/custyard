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

end
