defmodule CustyardWeb.Operator.ChannelSetupComponentTest do
  @moduledoc """
  Setup wizard for inbound channels, driven through the organization page
  (`CustyardWeb.Operator.OrganizationDetailLive`, channels tab).

  Not async: the sending-domain step stages Lettermint domains through
  `Application.put_env(:custyard, :lettermint_mock_domains, ...)`.
  """
  use CustyardWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{AuditEvent, InboundChannels, InboundRoutes, OperatorAccount, Repo}

  setup %{conn: conn} do
    org = insert_organization(name: "Wizard Org")

    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{
        email: "admin-#{System.unique_integer([:positive])}@example.com",
        password: "password123",
        role: "admin",
        organization_id: org.id
      })
      |> Repo.insert!()

    # The mock Lettermint client gives the route a catch-all domain.
    {:ok, route} = InboundRoutes.create_route(%{organization_id: org.id, route_type: :general})

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(operator.id)

    on_exit(fn -> Application.delete_env(:custyard, :lettermint_mock_domains) end)

    {:ok, conn: conn, org: org, operator: operator, route: route}
  end

  defp open_wizard(conn, org) do
    {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=channels")
    view |> element("[data-testid=new-channel-btn]") |> render_click()
    view
  end

  defp create_channel(view, route, attrs) do
    view
    |> form("#channel-create-form",
      channel:
        Map.merge(
          %{
            "public_address" => "support@acme.example.com",
            "display_name" => "Acme Support",
            "inbound_route_id" => to_string(route.id),
            "provider" => "google"
          },
          attrs
        )
        |> Map.reject(fn {_key, value} -> is_nil(value) end)
    )
    |> render_submit()

    [channel] = InboundChannels.list_for_organization(route.organization_id)
    channel
  end

  describe "step 1: create" do
    test "lists routes, disabling those without a synced domain", %{
      conn: conn,
      org: org,
      route: route
    } do
      project = insert_project(organization_id: org.id, title: "Onboarding")

      unsynced =
        insert_inbound_route(
          organization_id: org.id,
          route_type: :project,
          project_id: project.id,
          lettermint_route_domain: nil
        )

      view = open_wizard(conn, org)

      assert has_element?(view, "[data-testid=channel-setup]")
      assert has_element?(view, "[data-testid=channel-setup-step-1][aria-current=step]")

      general = view |> element("[data-testid=channel-route-option-#{route.id}]") |> render()
      assert general =~ "Organization-wide"
      assert general =~ "@#{route.lettermint_route_domain}"
      refute general =~ "disabled"

      project_option =
        view |> element("[data-testid=channel-route-option-#{unsynced.id}]") |> render()

      assert project_option =~ "Onboarding"
      assert project_option =~ "domain not synced"
      assert project_option =~ "disabled"
    end

    test "creates a pending_verification channel and moves to the forwarding step", %{
      conn: conn,
      org: org,
      route: route
    } do
      view = open_wizard(conn, org)
      channel = create_channel(view, route, %{})

      assert channel.state == :pending_verification
      assert channel.public_address == "support@acme.example.com"
      assert channel.display_name == "Acme Support"
      assert channel.provider == :google
      assert channel.inbound_route_id == route.id

      assert has_element?(view, "[data-testid=channel-setup-step-2][aria-current=step]")
      assert has_element?(view, "[data-testid=channel-forward-step]")

      full = InboundChannels.ingress_address(channel)
      assert view |> element("[data-testid=channel-setup-ingress-address]") |> render() =~ full

      assert has_element?(
               view,
               "[data-testid=channel-setup-copy-ingress][data-clipboard-text='#{full}']"
             )

      assert view |> element("[data-testid=channel-provider-help]") |> render() =~
               "Forwarding and POP/IMAP"

      assert has_element?(view, "[data-testid=channel-verification-waiting]")

      # Showing the full address is a reveal (D7) and is audited once.
      assert [_event] =
               Repo.all(from(a in AuditEvent, where: a.event_type == :channel_token_revealed))

      # The card list behind the wizard picked the new channel up over PubSub.
      assert has_element?(view, "[data-testid=channel-card-#{channel.id}]")
    end

    test "shows changeset errors inline", %{conn: conn, org: org, route: route} do
      view = open_wizard(conn, org)

      html =
        view
        |> form("#channel-create-form",
          channel: %{
            "public_address" => "not-an-address",
            "inbound_route_id" => to_string(route.id),
            "provider" => "google"
          }
        )
        |> render_submit()

      assert html =~ "must be a valid email address"
      assert has_element?(view, "[data-testid=channel-error-public_address]")
      assert InboundChannels.list_for_organization(org.id) == []
    end

    test "closing the wizard returns to the list", %{conn: conn, org: org} do
      view = open_wizard(conn, org)
      view |> element("[data-testid=channel-setup-close]") |> render_click()

      refute has_element?(view, "[data-testid=channel-setup]")
      assert has_element?(view, "[data-testid=new-channel-btn]")
    end
  end

  describe "step 2: forward" do
    test "a captured confirmation shows the code and link live", %{
      conn: conn,
      org: org,
      route: route
    } do
      view = open_wizard(conn, org)
      channel = create_channel(view, route, %{})

      refute has_element?(view, "[data-testid=channel-verification-code]")

      {:ok, _} =
        InboundChannels.capture_verification(channel, %{
          code: "482913",
          link: "https://mail-settings.google.com/mail/vf-abc123"
        })

      assert view |> element("[data-testid=channel-verification-code]") |> render() =~ "482913"

      link = view |> element("[data-testid=channel-verification-link]") |> render()
      assert link =~ ~s(href="https://mail-settings.google.com/mail/vf-abc123")
      assert link =~ ~s(target="_blank")
      assert link =~ "noopener"
      assert render(view) =~ "expires 24 hours"
    end

    test "Proton shows the end-to-end encryption notice", %{conn: conn, org: org} do
      channel =
        insert_inbound_channel(organization_id: org.id, provider: :proton, display_name: nil)

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=channels")
      view |> element("[data-testid=setup-channel-#{channel.id}]") |> render_click()

      assert has_element?(view, "[data-testid=channel-setup-step-2][aria-current=step]")
      assert view |> element("[data-testid=channel-provider-help]") |> render() =~ "Auto forward"

      assert view |> element("[data-testid=channel-proton-e2ee-notice]") |> render() =~
               "disables end-to-end encryption"
    end

    test "confirming forwarding moves to the test step", %{conn: conn, org: org, route: route} do
      view = open_wizard(conn, org)
      channel = create_channel(view, route, %{})

      view |> element("[data-testid=channel-confirm-forwarding]") |> render_click()

      assert InboundChannels.get_channel(channel.id).state == :awaiting_first_message
      assert has_element?(view, "[data-testid=channel-setup-step-3][aria-current=step]")

      assert view |> element("[data-testid=channel-test-prompt]") |> render() =~
               channel.public_address
    end
  end

  describe "step 3: test" do
    test "the first delivery completes the setup", %{conn: conn, org: org, route: route} do
      view = open_wizard(conn, org)
      channel = create_channel(view, route, %{})
      view |> element("[data-testid=channel-confirm-forwarding]") |> render_click()

      refute has_element?(view, "[data-testid=channel-setup-complete]")

      {:ok, _} = InboundChannels.mark_received(InboundChannels.get_channel(channel.id))

      assert has_element?(view, "[data-testid=channel-setup-complete]")
      assert has_element?(view, "[data-testid=channel-state-#{channel.id}][data-state=active]")
    end
  end

  describe "step 4: reply identity" do
    setup %{org: org} do
      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "support@acme.example.com",
          state: :active,
          last_received_at: DateTime.truncate(DateTime.utc_now(), :second)
        )

      {:ok, channel: channel}
    end

    defp open_reply_step(conn, org, channel) do
      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=channels")
      render_click(view, "open_channel_setup", %{"id" => to_string(channel.id)})
      assert has_element?(view, "[data-testid=channel-setup-step-4][aria-current=step]")
      view
    end

    test "a verified domain reports replies from the public address", %{
      conn: conn,
      org: org,
      channel: channel
    } do
      Application.put_env(:custyard, :lettermint_mock_domains, [
        %{"id" => "d1", "domain" => "acme.example.com", "status" => "verified"}
      ])

      view = open_reply_step(conn, org, channel)

      assert has_element?(
               view,
               "[data-testid=channel-domain-#{channel.id}][data-summary=unchecked]"
             )

      view |> element("[data-testid=channel-setup-check-domain]") |> render_click()

      assert has_element?(
               view,
               "[data-testid=channel-domain-#{channel.id}][data-summary=verified]"
             )

      assert view |> element("[data-testid=channel-domain-explanation]") |> render() =~
               "Replies go out as support@acme.example.com"

      assert InboundChannels.get_channel(channel.id).sending_domain_status == "verified"
    end

    test "a missing domain explains the DNS records and offers the fallback", %{
      conn: conn,
      org: org,
      channel: channel
    } do
      Application.put_env(:custyard, :lettermint_mock_domains, [])

      view = open_reply_step(conn, org, channel)
      view |> element("[data-testid=channel-setup-check-domain]") |> render_click()

      assert has_element?(
               view,
               "[data-testid=channel-domain-#{channel.id}][data-summary=not_found]"
             )

      explanation = view |> element("[data-testid=channel-domain-explanation]") |> render()
      assert explanation =~ "DKIM"
      assert explanation =~ "SPF"

      refute has_element?(view, "[data-testid=channel-reply-from-toggle][checked]")
      view |> element("[data-testid=channel-reply-from-toggle]") |> render_click()

      assert has_element?(view, "[data-testid=channel-reply-from-toggle][checked]")
      assert InboundChannels.get_channel(channel.id).reply_from == :ingress_address
      assert render(view) =~ InboundChannels.ingress_address(channel)

      view |> element("[data-testid=channel-reply-from-toggle]") |> render_click()
      assert InboundChannels.get_channel(channel.id).reply_from == :public_address
    end

    test "the archive copy and attachment cap are set from the identity step", %{
      conn: conn,
      org: org,
      channel: channel
    } do
      view = open_reply_step(conn, org, channel)

      refute has_element?(view, "[data-testid=channel-archive-copy-toggle][checked]")
      view |> element("[data-testid=channel-archive-copy-toggle]") |> render_click()
      assert has_element?(view, "[data-testid=channel-archive-copy-toggle][checked]")
      assert InboundChannels.get_channel(channel.id).archive_copy == true
      assert render(view) =~ "A copy of each reply is BCC&#39;d to support@acme.example.com"

      view |> element("[data-testid=channel-archive-copy-toggle]") |> render_click()
      assert InboundChannels.get_channel(channel.id).archive_copy == false

      view
      |> element("form[phx-change=set_attachment_limit]")
      |> render_change(%{"attachment_limit_mb" => "25"})

      assert InboundChannels.get_channel(channel.id).attachment_limit_mb == 25
      assert has_element?(view, ~s([data-testid=channel-attachment-limit][value="25"]))

      assert Custyard.Repo.exists?(
               Ecto.Query.from(e in Custyard.AuditEvent, where: e.event_type == :channel_updated)
             )
    end

    test "the data path panel names the processing hops", %{
      conn: conn,
      org: org,
      channel: channel
    } do
      view = open_reply_step(conn, org, channel)

      text = view |> element("[data-testid=channel-data-path]") |> render()
      assert text =~ "Lettermint B.V., Zwolle"
      assert text =~ "Art. 28"
      assert text =~ "this Custyard instance"
      assert text =~ "support@acme.example.com"
      assert has_element?(view, "[data-testid=channel-copy-data-path][data-clipboard-text]")
    end
  end

  describe "direct MX" do
    setup do
      on_exit(fn -> Application.delete_env(:custyard, :lettermint_mock_inbound_verification) end)
      :ok
    end

    defp create_mx_channel(conn, org, route) do
      view = open_wizard(conn, org)

      view
      |> form("#channel-create-form", channel: %{"ingress_kind" => "mx"})
      |> render_change()

      assert has_element?(view, "[data-testid=channel-mx-hint]")
      refute has_element?(view, "[data-testid=channel-provider-select]")

      channel =
        create_channel(view, route, %{
          "public_address" => "support@help.acme.example.com",
          "ingress_kind" => "mx",
          "provider" => nil
        })

      {view, channel}
    end

    test "creating shows the MX record to publish, not an ingress address", %{
      conn: conn,
      org: org,
      route: route
    } do
      {view, channel} = create_mx_channel(conn, org, route)

      assert channel.ingress_kind == :mx
      assert channel.provider == nil
      assert has_element?(view, "[data-testid=channel-setup-step-2][aria-current=step]")
      assert view |> element("[data-testid=channel-setup-step-2]") |> render() =~ "DNS"

      record = view |> element("[data-testid=channel-mx-record]") |> render()
      assert record =~ "help.acme.example.com"
      assert record =~ "lettermint.mx"
      refute has_element?(view, "[data-testid=channel-setup-ingress-address]")
      assert Repo.all(from(a in AuditEvent, where: a.event_type == :channel_token_revealed)) == []
    end

    test "an unverified check reports what Lettermint found", %{
      conn: conn,
      org: org,
      route: route
    } do
      {view, channel} = create_mx_channel(conn, org, route)

      Application.put_env(
        :custyard,
        :lettermint_mock_inbound_verification,
        {:ok, %{"verified" => false, "found_mx_records" => ["10 mx.other.net"]}}
      )

      view |> element("[data-testid=channel-check-mx]") |> render_click()

      assert view |> element("[data-testid=channel-setup-flash]") |> render() =~
               "Lettermint found 10 mx.other.net"

      assert InboundChannels.get_channel!(channel.id).state == :pending_verification
    end

    test "a verified check moves to the test step", %{conn: conn, org: org, route: route} do
      {view, channel} = create_mx_channel(conn, org, route)

      view |> element("[data-testid=channel-check-mx]") |> render_click()

      assert has_element?(view, "[data-testid=channel-setup-step-3][aria-current=step]")
      assert InboundChannels.get_channel!(channel.id).state == :awaiting_first_message
    end

    test "the replies step has no ingress fallback or archive copy", %{conn: conn, org: org} do
      channel =
        insert_inbound_channel(
          organization_id: org.id,
          ingress_kind: :mx,
          public_address: "support@help.acme.example.com",
          state: :active,
          last_received_at: DateTime.truncate(DateTime.utc_now(), :second)
        )

      {:ok, view, _html} = live(conn, ~p"/operator/organizations/#{org.id}?tab=channels")
      render_click(view, "open_channel_setup", %{"id" => to_string(channel.id)})

      assert has_element?(view, "[data-testid=channel-reply-step]")
      refute has_element?(view, "[data-testid=channel-reply-from-toggle]")
      refute has_element?(view, "[data-testid=channel-archive-copy-toggle]")
      assert has_element?(view, "[data-testid=channel-attachment-limit]")

      assert view |> element("[data-testid=channel-data-path]") |> render() =~
               "the MX record for help.acme.example.com delivers the message directly"

      # The card offers neither a token reveal nor a rotation.
      assert view |> element("[data-testid=channel-provider-#{channel.id}]") |> render() =~
               "Direct MX"

      assert has_element?(view, "[data-testid=channel-mx-#{channel.id}]")
      refute has_element?(view, "[data-testid=reveal-channel-#{channel.id}]")
      refute has_element?(view, "[data-testid=rotate-channel-#{channel.id}]")
    end
  end
end
