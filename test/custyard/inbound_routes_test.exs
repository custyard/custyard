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

    test "callback_url includes source=email for routes with source: :email" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          source: :email
        })

      url = InboundRoutes.callback_url(route)
      assert url =~ "/api/webhook/route/#{route.callback_token}"
      assert url =~ "source=email"
    end

    test "callback_url includes source=lettermint for routes with source: :lettermint" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          source: :lettermint
        })

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

    test "disable_webhook/2 is idempotent when no webhook record exists (returns ok)", %{route: route} do
      assert {:ok, nil} = InboundRoutes.disable_webhook(route, :sender_matching)
    end

    test "disable_webhook/2 is idempotent on repeated calls for same purpose", %{route: route} do
      # First enable, then disable, then disable again — the second disable
      # should succeed idempotently even though the webhook is already disabled.
      {:ok, _} = InboundRoutes.enable_webhook(route, :enrichment)
      {:ok, disabled} = InboundRoutes.disable_webhook(route, :enrichment)
      assert disabled.enabled == false

      # Disable again — should still succeed (idempotent update)
      {:ok, still_disabled} = InboundRoutes.disable_webhook(route, :enrichment)
      assert still_disabled.enabled == false
      assert still_disabled.id == disabled.id
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

  describe "find_or_create_general_route with source parameter" do
    test "creates route with source: :email when passed as option" do
      org = Factory.insert_organization()

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id, source: :email)

      assert route.route_type == :general
      assert route.organization_id == org.id
      assert route.source == :email
    end

    test "defaults to source: :lettermint when no source option is given" do
      org = Factory.insert_organization()

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)

      assert route.route_type == :general
      assert route.organization_id == org.id
      assert route.source == :lettermint
    end

    test "returns existing route regardless of source option" do
      org = Factory.insert_organization()

      # Create route without explicit source (defaults to :lettermint)
      {:ok, existing} = InboundRoutes.find_or_create_general_route(org.id)

      # Calling again with source: :email should return the same existing route
      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id, source: :email)

      assert route.id == existing.id
    end
  end

  describe "find_or_create_general_route webhook seeding" do
    test "creates sender_matching and notification webhook records on new route" do
      org = Factory.insert_organization()

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)

      webhooks = InboundRoutes.list_webhooks_for_route(route.id)
      purposes = Enum.map(webhooks, & &1.purpose) |> Enum.sort()

      assert :sender_matching in purposes
      assert :notification in purposes

      # All seeded webhooks should be enabled
      assert Enum.all?(webhooks, & &1.enabled)
    end

    test "calling find_or_create_general_route again does not duplicate webhook records" do
      org = Factory.insert_organization()

      {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)
      initial_webhooks = InboundRoutes.list_webhooks_for_route(route.id)

      # Call again -- should return the same route with the same webhooks
      {:ok, same_route} = InboundRoutes.find_or_create_general_route(org.id)
      assert same_route.id == route.id

      later_webhooks = InboundRoutes.list_webhooks_for_route(route.id)
      assert length(later_webhooks) == length(initial_webhooks)

      # Same webhook IDs
      initial_ids = Enum.map(initial_webhooks, & &1.id) |> Enum.sort()
      later_ids = Enum.map(later_webhooks, & &1.id) |> Enum.sort()
      assert initial_ids == later_ids
    end

    test "route is returned successfully even when no webhooks were seeded" do
      # Simulates the aftermath of a seeding failure: a general route exists
      # in the DB but has zero webhook records. Calling find_or_create_general_route
      # should still return {:ok, route} because seeding failures are non-fatal.
      #
      # The production code logs a warning on seeding failures (see
      # seed_default_webhooks/1) but always returns the route from the `with`
      # chain in find_or_create_general_route/2.
      org = Factory.insert_organization()

      # Create route directly (bypasses seed_default_webhooks entirely)
      {:ok, bare_route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      # Manually delete any webhooks that may have been auto-created
      # to simulate a state where seeding failed completely
      webhooks = InboundRoutes.list_webhooks_for_route(bare_route.id)

      for wh <- webhooks do
        InboundRoutes.delete_webhook(wh)
      end

      assert InboundRoutes.list_webhooks_for_route(bare_route.id) == []

      # Now find_or_create_general_route should find the existing route and
      # return it, regardless of missing webhooks
      {:ok, found_route} = InboundRoutes.find_or_create_general_route(org.id)

      assert found_route.id == bare_route.id
      assert found_route.route_type == :general

      # The route is returned successfully; webhooks may or may not be present
      # depending on whether the "find" path re-seeds. The key guarantee is
      # that {:ok, route} is returned, not an error.
      assert %Custyard.InboundRoute{} = found_route
    end

    test "find_or_create_general_route returns {:ok, route} with partial webhook seeding" do
      # Verifies the structural guarantee: even if only some webhook purposes
      # were seeded (partial failure), the route is still returned successfully.
      org = Factory.insert_organization()

      # Create route directly and seed only one of the two default purposes
      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      # Remove all webhooks first
      for wh <- InboundRoutes.list_webhooks_for_route(route.id) do
        InboundRoutes.delete_webhook(wh)
      end

      # Manually seed only sender_matching (simulating notification seeding failure)
      {:ok, _} = InboundRoutes.enable_webhook(route, :sender_matching)

      webhooks = InboundRoutes.list_webhooks_for_route(route.id)
      assert length(webhooks) == 1
      assert hd(webhooks).purpose == :sender_matching

      # find_or_create_general_route should return the route even with
      # incomplete webhook seeding
      {:ok, found_route} = InboundRoutes.find_or_create_general_route(org.id)

      assert found_route.id == route.id
      assert found_route.route_type == :general
    end
  end

  describe "create_route validation-first behavior" do
    test "returns changeset error without calling API when attrs are invalid" do
      org = Factory.insert_organization()

      # Use the FailingMockClient to detect if API was called
      # If API is called, it would return an error tuple, not a changeset
      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      # Missing organization_id - validation should fail before API call
      {:error, changeset} = InboundRoutes.create_route(%{route_type: :general})

      # Should be a changeset error (validation failed), not an API error
      assert %Ecto.Changeset{} = changeset
      assert %{organization_id: ["can't be blank"]} = errors_on(changeset)

      # Verify no route was created
      assert [] = InboundRoutes.list_for_organization(org.id)
    end

    test "returns changeset error for project route without project_id before calling API" do
      org = Factory.insert_organization()

      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      {:error, changeset} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project
          # Missing project_id
        })

      assert %Ecto.Changeset{} = changeset
      assert %{project_id: ["is required for project routes"]} = errors_on(changeset)
    end

    test "returns changeset error for short callback_token before calling API" do
      org = Factory.insert_organization()

      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      {:error, changeset} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general,
          callback_token: "too-short"
        })

      assert %Ecto.Changeset{} = changeset
      assert %{callback_token: [msg]} = errors_on(changeset)
      assert msg =~ "at least 32 characters"
    end

    test "returns API error when validation passes but API fails" do
      org = Factory.insert_organization()

      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      # Valid attrs - should pass validation and call API, which will fail
      {:error, reason} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      # Should be an API error tuple, not a changeset
      assert {:api_error, 503, "Service Unavailable"} = reason
    end
  end

  describe "delete_route failure handling" do
    test "returns error and preserves local record when API deletion fails" do
      org = Factory.insert_organization()

      # First create a route with the normal mock client
      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      # Verify route exists with a lettermint_route_id
      assert route.lettermint_route_id != nil
      route_id = route.id

      # Now switch to failing mock client for delete
      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      # Attempt to delete - should fail
      {:error, reason} = InboundRoutes.delete_route(route)

      # Should return the API error
      assert {:api_error, 503, "Service Unavailable"} = reason

      # Local record should still exist
      assert InboundRoutes.get_route(route_id) != nil
    end

    test "returns specific API error when remote deletion fails with custom error" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :general
        })

      route_id = route.id

      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      # Configure a specific error
      Process.put(
        {:failing_mock_client, :delete_route},
        {:error, {:api_error, 500, "Internal Server Error"}}
      )

      {:error, reason} = InboundRoutes.delete_route(route)

      assert {:api_error, 500, "Internal Server Error"} = reason
      assert InboundRoutes.get_route(route_id) != nil
    end

    test "succeeds when route has no lettermint_route_id" do
      org = Factory.insert_organization()

      # Create a route directly in DB without lettermint_route_id
      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general,
          lettermint_route_id: nil
        })
        |> Repo.insert!()

      # Switch to failing mock - but it shouldn't be called
      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)

      on_exit(fn ->
        Application.put_env(:custyard, :lettermint, original_config)
      end)

      # Should succeed because no remote route to delete
      {:ok, deleted} = InboundRoutes.delete_route(route)

      assert deleted.id == route.id
      assert InboundRoutes.get_route(route.id) == nil
    end
  end

  describe "is_last_general_route?/1" do
    test "returns true when route is the only general route for its org" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      assert InboundRoutes.is_last_general_route?(route)
    end

    test "returns false when there are multiple general routes for the org" do
      org = Factory.insert_organization()

      {:ok, route1} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, route2} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      refute InboundRoutes.is_last_general_route?(route1)
      refute InboundRoutes.is_last_general_route?(route2)
    end

    test "returns false for project routes" do
      org = Factory.insert_organization()
      project = Factory.insert_project(organization_id: org.id)

      {:ok, route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      refute InboundRoutes.is_last_general_route?(route)
    end

    test "returns false for disambiguation routes" do
      org = Factory.insert_organization()

      {:ok, route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :disambiguation})

      refute InboundRoutes.is_last_general_route?(route)
    end

    test "does not count general routes from other organizations" do
      org1 = Factory.insert_organization()
      org2 = Factory.insert_organization()

      {:ok, route1} =
        InboundRoutes.create_route(%{organization_id: org1.id, route_type: :general})

      {:ok, route2} =
        InboundRoutes.create_route(%{organization_id: org2.id, route_type: :general})

      # Each org has exactly one general route, so each is the "last" one
      assert InboundRoutes.is_last_general_route?(route1)
      assert InboundRoutes.is_last_general_route?(route2)
    end

    test "does not count project routes when determining last general route" do
      org = Factory.insert_organization()
      project = Factory.insert_project(organization_id: org.id)

      {:ok, general_route} =
        InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

      {:ok, _project_route} =
        InboundRoutes.create_route(%{
          organization_id: org.id,
          route_type: :project,
          project_id: project.id
        })

      # The general route is still the only general route despite having a project route
      assert InboundRoutes.is_last_general_route?(general_route)
    end
  end
end
