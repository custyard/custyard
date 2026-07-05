defmodule Custyard.InboundRouteTest do
  use Custyard.DataCase, async: true

  alias Custyard.{InboundRoute, InboundRouteWebhook}

  import Custyard.Factory

  describe "changeset/2" do
    test "valid general route" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :general
        })

      assert changeset.valid?
      assert get_field(changeset, :callback_token) != nil
    end

    test "auto-generates callback_token" do
      org = insert_organization()

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{organization_id: org.id, route_type: :general})
        |> Repo.insert!()

      assert route.callback_token != nil
      assert String.length(route.callback_token) > 0
    end

    test "requires organization_id" do
      changeset = InboundRoute.changeset(%InboundRoute{}, %{route_type: :general})
      refute changeset.valid?
      assert errors_on(changeset)[:organization_id]
    end

    test "project route requires project_id" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :project
        })

      refute changeset.valid?
      assert errors_on(changeset)[:project_id]
    end

    test "valid project route with project_id" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project
        })

      assert changeset.valid?
    end

    test "accepts from_address with valid email" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :general,
          from_address: "support@example.com"
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :from_address) == "support@example.com"
    end

    test "from_address is optional (nil is allowed)" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :general
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :from_address) == nil
    end

    test "rejects from_address without @ sign" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :general,
          from_address: "not-an-email"
        })

      refute changeset.valid?
      assert "must be a valid email address" in errors_on(changeset).from_address
    end

    test "rejects from_address with spaces" do
      org = insert_organization()

      changeset =
        InboundRoute.changeset(%InboundRoute{}, %{
          organization_id: org.id,
          route_type: :general,
          from_address: "bad email@example.com"
        })

      refute changeset.valid?
      assert "must be a valid email address" in errors_on(changeset).from_address
    end

    test "enforces unique callback_token" do
      org = insert_organization()

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general,
          callback_token: "unique-token-secure-32-chars-xyz"
        })
        |> Repo.insert!()

      {:error, changeset} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          route_type: :general,
          callback_token: route.callback_token
        })
        |> Repo.insert()

      assert errors_on(changeset)[:callback_token]
    end
  end

  describe "webhook associations" do
    test "can add webhooks to a route" do
      org = insert_organization()

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{organization_id: org.id, route_type: :general})
        |> Repo.insert!()

      webhook =
        %InboundRouteWebhook{}
        |> InboundRouteWebhook.changeset(%{
          inbound_route_id: route.id,
          purpose: :sender_matching,
          enabled: true
        })
        |> Repo.insert!()

      assert webhook.inbound_route_id == route.id
      assert webhook.purpose == :sender_matching
    end

    test "enforces unique purpose per route" do
      org = insert_organization()

      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{organization_id: org.id, route_type: :general})
        |> Repo.insert!()

      %InboundRouteWebhook{}
      |> InboundRouteWebhook.changeset(%{
        inbound_route_id: route.id,
        purpose: :sender_matching
      })
      |> Repo.insert!()

      {:error, changeset} =
        %InboundRouteWebhook{}
        |> InboundRouteWebhook.changeset(%{
          inbound_route_id: route.id,
          purpose: :sender_matching
        })
        |> Repo.insert()

      assert errors_on(changeset)[:inbound_route_id]
    end
  end
end
