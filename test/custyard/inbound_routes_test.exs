defmodule Custyard.InboundRoutesTest do
  use Custyard.DataCase, async: true

  alias Custyard.{InboundRoutes, InboundRoute, InboundRouteWebhook}

  import Custyard.Factory

  describe "create_route/3" do
    test "creates a general route with lettermint_route_id" do
      org = insert_organization()

      assert {:ok, route} = InboundRoutes.create_route(org, :general)
      assert route.organization_id == org.id
      assert route.route_type == :general
      assert route.callback_token != nil
      assert route.lettermint_route_id != nil
      assert String.starts_with?(route.lettermint_route_id, "lm_route_")
    end

    test "creates a project route with project_id" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)

      assert {:ok, route} = InboundRoutes.create_route(org, :project, project_id: project.id)
      assert route.route_type == :project
      assert route.project_id == project.id
    end

    test "fails for project route without project_id" do
      org = insert_organization()

      assert {:error, changeset} = InboundRoutes.create_route(org, :project)
      assert errors_on(changeset)[:project_id]
    end

    test "creates a disambiguation route" do
      org = insert_organization()

      assert {:ok, route} = InboundRoutes.create_route(org, :disambiguation)
      assert route.route_type == :disambiguation
    end
  end

  describe "list_routes/1" do
    test "returns routes for the given organization" do
      org = insert_organization()
      {:ok, _route1} = InboundRoutes.create_route(org, :general)
      {:ok, _route2} = InboundRoutes.create_route(org, :disambiguation)

      routes = InboundRoutes.list_routes(org)
      assert length(routes) == 2
    end

    test "excludes routes from other organizations" do
      org1 = insert_organization()
      org2 = insert_organization()
      {:ok, _} = InboundRoutes.create_route(org1, :general)
      {:ok, _} = InboundRoutes.create_route(org2, :general)

      routes = InboundRoutes.list_routes(org1)
      assert length(routes) == 1
      assert hd(routes).organization_id == org1.id
    end

    test "preloads webhooks" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)
      InboundRoutes.enable_webhook(route, :sender_matching)

      [loaded_route] = InboundRoutes.list_routes(org)
      assert length(loaded_route.webhooks) == 1
    end

    test "returns empty list when no routes exist" do
      org = insert_organization()
      assert InboundRoutes.list_routes(org) == []
    end
  end

  describe "get_route!/1" do
    test "returns route with preloaded webhooks" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      result = InboundRoutes.get_route!(route.id)
      assert result.id == route.id
      assert is_list(result.webhooks)
    end

    test "raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        InboundRoutes.get_route!(999_999)
      end
    end
  end

  describe "delete_route/1" do
    test "deletes the route" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      assert {:ok, _deleted} = InboundRoutes.delete_route(route)

      assert_raise Ecto.NoResultsError, fn ->
        InboundRoutes.get_route!(route.id)
      end
    end

    test "cascades deletion to webhooks" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)
      {:ok, webhook} = InboundRoutes.enable_webhook(route, :sender_matching)

      InboundRoutes.delete_route(route)

      assert Repo.get(InboundRouteWebhook, webhook.id) == nil
    end
  end

  describe "enable_webhook/2" do
    test "creates a new webhook when none exists" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      assert {:ok, webhook} = InboundRoutes.enable_webhook(route, :sender_matching)
      assert webhook.purpose == :sender_matching
      assert webhook.enabled == true
      assert webhook.inbound_route_id == route.id
    end

    test "re-enables a disabled webhook" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)
      {:ok, _} = InboundRoutes.enable_webhook(route, :notification)
      {:ok, _} = InboundRoutes.disable_webhook(route, :notification)

      assert {:ok, webhook} = InboundRoutes.enable_webhook(route, :notification)
      assert webhook.enabled == true
    end

    test "supports all webhook purposes" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      for purpose <- [:sender_matching, :enrichment, :notification, :audit, :disambiguation] do
        assert {:ok, webhook} = InboundRoutes.enable_webhook(route, purpose)
        assert webhook.purpose == purpose
      end
    end
  end

  describe "disable_webhook/2" do
    test "disables an existing webhook" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)
      {:ok, _} = InboundRoutes.enable_webhook(route, :sender_matching)

      assert {:ok, webhook} = InboundRoutes.disable_webhook(route, :sender_matching)
      assert webhook.enabled == false
    end

    test "returns error when webhook does not exist" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      assert {:error, :not_found} = InboundRoutes.disable_webhook(route, :sender_matching)
    end
  end

  describe "callback_url/1" do
    test "returns URL with callback_token" do
      org = insert_organization()
      {:ok, route} = InboundRoutes.create_route(org, :general)

      url = InboundRoutes.callback_url(route)
      assert url =~ "/api/webhook/route/#{route.callback_token}"
      assert url =~ "source=lettermint"
    end
  end
end
