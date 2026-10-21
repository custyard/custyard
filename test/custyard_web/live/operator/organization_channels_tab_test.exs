defmodule CustyardWeb.Operator.OrganizationChannelsTabTest do
  @moduledoc """
  Channels tab on `CustyardWeb.Operator.OrganizationDetailLive`: tab rename
  and `?tab=routes` alias, channel cards (state, masked ingress, health),
  audited reveal, lifecycle actions, and live reload on channel PubSub.

  The setup wizard has its own tests in
  `CustyardWeb.Operator.ChannelSetupComponentTest`.
  """
  use CustyardWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{AuditEvent, InboundChannels, OperatorAccount, Repo}

  setup %{conn: conn} do
    org = insert_organization(name: "Channels Org")

    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{
        email: "admin-#{System.unique_integer([:positive])}@example.com",
        password: "password123",
        role: "admin",
        organization_id: org.id
      })
      |> Repo.insert!()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(operator.id)

    {:ok, conn: conn, org: org, operator: operator}
  end

  defp open_channels(conn, org) do
    {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=channels")
    view
  end

  describe "tab" do
    test "channels tab replaces the routes tab", %{conn: conn, org: org} do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}")

      assert has_element?(view, "[data-testid=org-tab-channels]", "Channels")
      refute has_element?(view, "[data-testid=org-tab-routes]")

      view |> element("[data-testid=org-tab-channels]") |> render_click()
      assert has_element?(view, "[data-testid=org-channels-list]")
      assert has_element?(view, "[data-testid=org-routes-advanced]")
    end

    test "?tab=routes is an alias for the channels tab", %{conn: conn, org: org} do
      route = insert_inbound_route(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=routes")

      assert has_element?(view, "[data-testid=org-channels-list]")

      assert has_element?(
               view,
               "[data-testid=org-routes-advanced] [data-testid=route-card-#{route.id}]"
             )
    end

    test "empty state offers the New channel button", %{conn: conn, org: org} do
      view = open_channels(conn, org)

      assert has_element?(view, "[data-testid=org-channels-empty]")
      assert has_element?(view, "[data-testid=new-channel-btn]")
    end
  end

  describe "channel cards" do
    test "render public address, state, provider, scope, masked ingress and health", %{
      conn: conn,
      org: org
    } do
      project = insert_project(organization_id: org.id, title: "Billing")

      route =
        insert_inbound_route(
          organization_id: org.id,
          route_type: :project,
          project_id: project.id,
          lettermint_route_domain: "r1234567890.lettermint.app"
        )

      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "billing@acme.example.com",
          display_name: "Acme Billing",
          provider: :proton,
          state: :active,
          last_received_at:
            DateTime.utc_now() |> DateTime.add(-2 * 3600, :second) |> DateTime.truncate(:second)
        )

      view = open_channels(conn, org)
      card = view |> element("[data-testid=channel-card-#{channel.id}]") |> render()

      assert card =~ "billing@acme.example.com"
      assert card =~ "Acme Billing"
      assert card =~ "Proton Mail"
      assert card =~ "Billing"
      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=active]")

      masked = view |> element("[data-testid=channel-ingress-masked-#{channel.id}]") |> render()
      assert masked =~ "billing+#{String.slice(channel.ingress_token, 0, 4)}"
      assert masked =~ "@r1234567890.lettermint.app"
      refute masked =~ channel.ingress_token

      assert view |> element("[data-testid=channel-last-received-#{channel.id}]") |> render() =~
               "last received 2h ago"

      refute has_element?(view, "[data-testid=channel-quiet-#{channel.id}]")

      assert has_element?(
               view,
               "[data-testid=channel-domain-#{channel.id}][data-summary=unchecked]"
             )

      assert has_element?(view, "[data-testid=check-domain-#{channel.id}]")
    end

    test "organization-wide scope, no mail yet, and the quiet-window note", %{
      conn: conn,
      org: org
    } do
      quiet =
        insert_inbound_channel(
          organization_id: org.id,
          state: :active,
          last_received_at:
            DateTime.utc_now() |> DateTime.add(-80 * 3600, :second) |> DateTime.truncate(:second)
        )

      fresh = insert_inbound_channel(organization_id: org.id, state: :awaiting_first_message)

      view = open_channels(conn, org)

      assert view |> element("[data-testid=channel-scope-#{quiet.id}]") |> render() =~
               "Organization-wide"

      assert has_element?(view, "[data-testid=channel-quiet-#{quiet.id}]")

      assert view |> element("[data-testid=channel-last-received-#{fresh.id}]") |> render() =~
               "no mail yet"

      refute has_element?(view, "[data-testid=channel-quiet-#{fresh.id}]")

      # The wizard stays reachable once active: it is where reply identity
      # and the sending-domain check are changed.
      assert view |> element("[data-testid=setup-channel-#{fresh.id}]") |> render() =~ "Setup"
      assert view |> element("[data-testid=setup-channel-#{quiet.id}]") |> render() =~ "Settings"
    end

    test "a revoked channel offers no setup entry point", %{conn: conn, org: org} do
      revoked = insert_inbound_channel(organization_id: org.id, state: :revoked)

      view = open_channels(conn, org)

      refute has_element?(view, "[data-testid=setup-channel-#{revoked.id}]")
    end

    test "the ingress token never appears in the list without a reveal", %{conn: conn, org: org} do
      channel = insert_inbound_channel(organization_id: org.id)

      view = open_channels(conn, org)

      refute render(view) =~ channel.ingress_token
    end
  end

  describe "reveal" do
    test "shows the full ingress address with a copy button and writes an audit event", %{
      conn: conn,
      org: org,
      operator: operator
    } do
      channel = insert_inbound_channel(organization_id: org.id)
      full = InboundChannels.ingress_address(channel)

      view = open_channels(conn, org)

      view |> element("[data-testid=reveal-channel-#{channel.id}]") |> render_click()

      assert view |> element("[data-testid=channel-ingress-#{channel.id}]") |> render() =~ full

      assert has_element?(
               view,
               "[data-testid=copy-ingress-#{channel.id}][data-clipboard-text='#{full}']"
             )

      [event] =
        Repo.all(from(a in AuditEvent, where: a.event_type == :channel_token_revealed))

      assert event.payload["channel_id"] == channel.id
      assert event.payload["operator_id"] == operator.id

      view |> element("[data-testid=hide-channel-#{channel.id}]") |> render_click()
      assert has_element?(view, "[data-testid=channel-ingress-masked-#{channel.id}]")
      refute render(view) =~ channel.ingress_token
    end
  end

  describe "lifecycle actions" do
    test "pause and resume", %{conn: conn, org: org} do
      channel =
        insert_inbound_channel(
          organization_id: org.id,
          state: :active,
          last_received_at: DateTime.truncate(DateTime.utc_now(), :second)
        )

      view = open_channels(conn, org)

      view |> element("[data-testid=pause-channel-#{channel.id}]") |> render_click()
      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=paused]")
      assert InboundChannels.get_channel(channel.id).state == :paused
      refute has_element?(view, "[data-testid=pause-channel-#{channel.id}]")

      view |> element("[data-testid=resume-channel-#{channel.id}]") |> render_click()
      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=active]")
    end

    test "rotate token needs confirmation and keeps the public address", %{conn: conn, org: org} do
      channel = insert_inbound_channel(organization_id: org.id, state: :active)

      view = open_channels(conn, org)

      refute has_element?(view, "[data-testid=confirm-rotate-channel-#{channel.id}]")
      view |> element("[data-testid=rotate-channel-#{channel.id}]") |> render_click()
      assert has_element?(view, "[data-testid=confirm-rotate-channel-#{channel.id}]")

      view |> element("[data-testid=cancel-channel-action-#{channel.id}]") |> render_click()
      refute has_element?(view, "[data-testid=confirm-rotate-channel-#{channel.id}]")

      view |> element("[data-testid=rotate-channel-#{channel.id}]") |> render_click()

      html =
        view |> element("[data-testid=confirm-rotate-channel-#{channel.id}]") |> render_click()

      assert html =~ "Token rotated"
      rotated = InboundChannels.get_channel(channel.id)
      assert rotated.ingress_token != channel.ingress_token
      assert rotated.previous_ingress_token == channel.ingress_token
      assert rotated.public_address == channel.public_address
    end

    test "revoke needs confirmation and removes the actions", %{conn: conn, org: org} do
      channel = insert_inbound_channel(organization_id: org.id, state: :active)

      view = open_channels(conn, org)

      view |> element("[data-testid=revoke-channel-#{channel.id}]") |> render_click()
      view |> element("[data-testid=confirm-revoke-channel-#{channel.id}]") |> render_click()

      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=revoked]")
      refute has_element?(view, "[data-testid=pause-channel-#{channel.id}]")
      refute has_element?(view, "[data-testid=rotate-channel-#{channel.id}]")
      refute has_element?(view, "[data-testid=revoke-channel-#{channel.id}]")
      refute has_element?(view, "[data-testid=check-domain-#{channel.id}]")
    end

    test "acting on a channel that no longer exists shows a notice", %{conn: conn, org: org} do
      insert_inbound_channel(organization_id: org.id)
      view = open_channels(conn, org)

      html = render_click(view, "pause_channel", %{"id" => "999999"})
      assert html =~ "no longer exists"
      assert Process.alive?(view.pid)
    end

    test "a channel from another organization is not reachable", %{conn: conn, org: org} do
      insert_inbound_channel(organization_id: org.id)
      foreign = insert_inbound_channel(state: :active)
      view = open_channels(conn, org)

      html = render_click(view, "pause_channel", %{"id" => to_string(foreign.id)})
      assert html =~ "no longer exists"
      assert InboundChannels.get_channel(foreign.id).state == :active
    end
  end

  describe "live updates" do
    test "channel PubSub reloads the cards", %{conn: conn, org: org} do
      channel = insert_inbound_channel(organization_id: org.id, state: :awaiting_first_message)
      view = open_channels(conn, org)

      assert has_element?(
               view,
               "[data-testid=channel-state-#{channel.id}][data-state=awaiting_first_message]"
             )

      {:ok, _} = InboundChannels.mark_received(channel)

      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=active]")

      assert view |> element("[data-testid=channel-last-received-#{channel.id}]") |> render() =~
               "last received just now"
    end
  end
end
