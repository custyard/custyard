defmodule Custyard.InboundRoutesTest do
  use Custyard.DataCase, async: true

  alias Custyard.InboundRoutes
  alias Custyard.InboundRoute
  alias Custyard.InboundRouteWebhook
  alias Custyard.Factory

  describe "route operations" do
    test "list_for_organization returns routes for the given org" do
      org = Factory.insert_organization()
      other_org = Factory.insert_organization()

      {:ok, route1} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, _route2} =
        InboundRoutes.create_route(%{organization_id: other_org.id, route_type: :general})

      routes = InboundRoutes.list_for_organization(org.id)

      assert length(routes) == 1
      assert hd(routes).id == route1.id
    end

    test "get_route returns route with preloads" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      fetched = InboundRoutes.get_route(route.id)

      assert fetched.id == route.id
      assert Ecto.assoc_loaded?(fetched.organization)
      assert Ecto.assoc_loaded?(fetched.webhooks)
    end

    test "get_route returns nil for non-existent route" do
      assert InboundRoutes.get_route(999_999) == nil
    end

    test "get_route! raises for non-existent route" do
      assert_raise Ecto.NoResultsError, fn ->
        InboundRoutes.get_route!(999_999)
      end
    end

    test "get_by_callback_token finds route by token" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      fetched = InboundRoutes.get_by_callback_token(route.callback_token)

      assert fetched.id == route.id
    end

    test "get_by_callback_token returns nil for unknown token" do
      assert InboundRoutes.get_by_callback_token("nonexistent-token") == nil
    end

    test "create_route generates callback_token if not provided" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      assert is_binary(route.callback_token)
      assert String.length(route.callback_token) > 20
    end

    test "create_route sets lettermint_route_id from API response" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      assert route.lettermint_route_id != nil
      assert String.starts_with?(route.lettermint_route_id, "lm_route_")
    end

    test "create_route accepts custom callback_token" do
      org = Factory.insert_organization()
      # Token must be at least 32 chars for security
      custom_token = "custom-token-with-sufficient-length-123456"

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          callback_token: custom_token
        })

      assert route.callback_token == custom_token
    end

    test "create_route rejects short callback_token" do
      org = Factory.insert_organization()

      {:error, changeset} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          callback_token: "short-token"
        })

      assert %{callback_token: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "at least 32 characters"
    end

    test "create_route validates project_id for project routes" do
      org = Factory.insert_organization()

      {:error, changeset} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project
          # Missing project_id
        })

      assert %{project_id: ["is required for project routes"]} = errors_on(changeset)
    end

    test "create_route creates project route with project_id" do
      org = Factory.insert_organization()
      project = Factory.insert_project(organization_id: org.id)

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      assert route.route_type == :project
      assert route.project_id == project.id
    end

    test "create_route creates disambiguation route" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :disambiguation
        })

      assert route.route_type == :disambiguation
    end

    test "update_route updates attributes" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, updated} = InboundRoutes.update_route(route, %{lettermint_route_id: "lm-123"})

      assert updated.lettermint_route_id == "lm-123"
    end

    test "delete_route removes the route" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, _} = InboundRoutes.delete_route(route)

      assert InboundRoutes.get_route(route.id) == nil
    end

    test "delete_route cascades deletion to webhooks" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})
      {:ok, webhook} = InboundRoutes.enable_webhook(route, :sender_matching)

      InboundRoutes.delete_route(route)

      assert Custyard.Repo.get(InboundRouteWebhook, webhook.id) == nil
    end

    test "change_route returns changeset" do
      changeset = InboundRoutes.change_route(%InboundRoute{})

      assert %Ecto.Changeset{} = changeset
    end

    test "callback_url returns URL with callback_token" do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      url = InboundRoutes.callback_url(route)
      assert url =~ "/api/webhook/route/#{route.callback_token}"
      assert url =~ "source=lettermint"
    end
  end

  describe "webhook operations" do
    setup do
      org = Factory.insert_organization()
      {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})
      {:ok, route: route}
    end

    test "list_webhooks_for_route returns webhooks", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :sender_matching
        })

      webhooks = InboundRoutes.list_webhooks_for_route(route.id)

      assert length(webhooks) == 1
      assert hd(webhooks).id == webhook.id
    end

    test "create_webhook creates with valid attrs", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :enrichment,
          endpoint_url: "https://example.com/hook"
        })

      assert webhook.purpose == :enrichment
      assert webhook.endpoint_url == "https://example.com/hook"
      assert webhook.enabled == true
    end

    test "create_webhook validates required fields" do
      {:error, changeset} = InboundRoutes.create_webhook(%{})

      assert %{purpose: ["can't be blank"], inbound_route_id: ["can't be blank"]} =
               errors_on(changeset)
    end

    test "update_webhook updates attributes", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :notification
        })

      {:ok, updated} =
        InboundRoutes.update_webhook(webhook, %{
          endpoint_url: "https://new.example.com/hook"
        })

      assert updated.endpoint_url == "https://new.example.com/hook"
    end

    test "enable_webhook/1 sets enabled to true", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :audit,
          enabled: false
        })

      {:ok, enabled} = InboundRoutes.enable_webhook(webhook)

      assert enabled.enabled == true
    end

    test "enable_webhook/2 creates webhook if not exists", %{route: route} do
      {:ok, webhook} = InboundRoutes.enable_webhook(route, :sender_matching)

      assert webhook.purpose == :sender_matching
      assert webhook.enabled == true
      assert webhook.inbound_route_id == route.id
    end

    test "enable_webhook/2 re-enables disabled webhook", %{route: route} do
      {:ok, _} = InboundRoutes.enable_webhook(route, :notification)
      {:ok, _} = InboundRoutes.disable_webhook(route, :notification)

      {:ok, webhook} = InboundRoutes.enable_webhook(route, :notification)
      assert webhook.enabled == true
    end

    test "enable_webhook/2 supports all webhook purposes", %{route: route} do
      for purpose <- [:sender_matching, :enrichment, :notification, :audit, :disambiguation] do
        {:ok, webhook} = InboundRoutes.enable_webhook(route, purpose)
        assert webhook.purpose == purpose
      end
    end

    test "disable_webhook/1 sets enabled to false", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :audit,
          enabled: true
        })

      {:ok, disabled} = InboundRoutes.disable_webhook(webhook)

      assert disabled.enabled == false
    end

    test "disable_webhook/2 disables existing webhook", %{route: route} do
      {:ok, _} = InboundRoutes.enable_webhook(route, :sender_matching)

      {:ok, webhook} = InboundRoutes.disable_webhook(route, :sender_matching)
      assert webhook.enabled == false
    end

    test "disable_webhook/2 returns error when webhook does not exist", %{route: route} do
      assert {:error, :not_found} = InboundRoutes.disable_webhook(route, :sender_matching)
    end

    test "delete_webhook removes the webhook", %{route: route} do
      {:ok, webhook} =
        InboundRoutes.create_webhook(%{
          inbound_route_id: route.id,
          purpose: :sender_matching
        })

      {:ok, _} = InboundRoutes.delete_webhook(webhook)

      assert InboundRoutes.get_webhook(webhook.id) == nil
    end
  end

  describe "convenience functions" do
    test "find_or_create_general_route creates if not exists" do
      org = Factory.insert_organization()

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)

      assert route.route_type == :general
      assert route.organization_id == org.id
    end

    test "find_or_create_general_route returns existing route" do
      org = Factory.insert_organization()

      {:ok, existing} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)

      assert route.id == existing.id
    end

    test "get_general_route returns general route" do
      org = Factory.insert_organization()
      {:ok, _route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      route = InboundRoutes.get_general_route(org.id)

      assert route.route_type == :general
    end

    test "get_general_route returns nil when no general route exists" do
      org = Factory.insert_organization()

      assert InboundRoutes.get_general_route(org.id) == nil
    end

    test "get_project_route returns project route" do
      org = Factory.insert_organization()
      project = Factory.insert_project(organization_id: org.id)

      {:ok, _route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      route = InboundRoutes.get_project_route(project.id)

      assert route.route_type == :project
      assert route.project_id == project.id
    end
  end
end
