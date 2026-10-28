defmodule Custyard.Email.ImapDispatcherIntegrationTest do
  @moduledoc """
  Integration tests for the IMAP -> Dispatcher pipeline.

  Verifies that emails parsed by Parser and normalized by Adapters.Email
  dispatch correctly through the Webhooks.Dispatcher on a route without
  channels.

  These tests exercise the pipeline an IMAP channel import runs
  (`Custyard.Email.ImapPoll`):
    Parser.parse -> Adapters.Email.normalize -> Dispatcher.dispatch(route, normalized, channel: hd(Custyard.InboundChannels.list_for_route(route.id)))

  They do NOT start an IMAP server or poller; `ImapPollTest` covers the
  channel path.
  """
  use Custyard.DataCase, async: true

  alias Custyard.{InboundRoute, InboundRouteWebhook}
  alias Custyard.Email.Parser
  alias Custyard.InboundRoutes
  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter
  alias Custyard.Webhooks.Dispatcher

  import Custyard.Factory

  # Helper: build a route with sender_matching enabled
  defp create_route_with_webhook(attrs) do
    org = Repo.get!(Custyard.Organization, attrs.organization_id)

    route =
      %InboundRoute{}
      |> InboundRoute.changeset(%{tenant_id: org.tenant_id})
      |> Repo.insert!()

    %InboundRouteWebhook{}
    |> InboundRouteWebhook.changeset(%{
      inbound_route_id: route.id,
      purpose: :sender_matching,
      enabled: true
    })
    |> Repo.insert!()

    insert_inbound_channel(
      tenant_id: org.tenant_id,
      inbound_route_id: route.id,
      default_organization_id: org.id,
      default_project_id: attrs[:project_id],
      state: :active
    )

    route
  end

  # Sample RFC 5322 email
  defp sample_email(from, to, opts \\ []) do
    subject = Keyword.get(opts, :subject, "IMAP polled email")

    message_id =
      Keyword.get(
        opts,
        :message_id,
        "<imap-int-#{System.unique_integer([:positive])}@example.com>"
      )

    body = Keyword.get(opts, :body, "Email body fetched via IMAP.")

    "From: #{from}\r\n" <>
      "To: #{to}\r\n" <>
      "Subject: #{subject}\r\n" <>
      "Message-ID: #{message_id}\r\n" <>
      "MIME-Version: 1.0\r\n" <>
      "Content-Type: text/plain; charset=utf-8\r\n" <>
      "\r\n" <>
      body <> "\r\n"
  end

  # Runs the full pipeline: parse -> normalize -> dispatch
  defp parse_normalize_dispatch(raw_email, route) do
    with {:ok, parsed} <- Parser.parse(raw_email),
         {:ok, normalized} <- EmailAdapter.normalize(parsed) do
      Dispatcher.dispatch(route, normalized,
        channel: hd(Custyard.InboundChannels.list_for_route(route.id))
      )
    end
  end

  describe "IMAP-polled email dispatches through correct org route" do
    test "thread is created with org_id from the poller's configured route" do
      org = insert_organization(domain: "polled-org.example.com")
      _contact = insert_contact(organization_id: org.id, email: "sender@external.com")

      # This route represents what the IMAP poller would resolve from its org_id config
      route = create_route_with_webhook(%{organization_id: org.id, route_type: :general})

      raw =
        sample_email("sender@external.com", "inbox@polled-org.example.com",
          subject: "Via IMAP poller"
        )

      assert {:ok, thread} = parse_normalize_dispatch(raw, route)
      assert thread.organization_id == org.id
      assert thread.subject == "Via IMAP poller"
    end

    test "IMAP-polled email with project route sets project_id" do
      org = insert_organization(domain: "polled-org.example.com")
      _contact = insert_contact(organization_id: org.id, email: "sender@external.com")
      project = insert_project(organization_id: org.id, title: "IMAP Project")

      route =
        create_route_with_webhook(%{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project
        })

      raw =
        sample_email("sender@external.com", "inbox@polled-org.example.com",
          subject: "Project-scoped IMAP email"
        )

      assert {:ok, thread} = parse_normalize_dispatch(raw, route)
      assert thread.project_id == project.id
    end
  end

  describe "IMAP poller with missing/invalid org_id" do
    test "dispatch fails gracefully when route has no sender_matching webhook" do
      org = insert_organization(domain: "misconfigured.example.com")
      _contact = insert_contact(organization_id: org.id, email: "sender@external.com")

      # Route exists but has no webhooks enabled
      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{tenant_id: org.tenant_id})
        |> Repo.insert!()

      insert_inbound_channel(
        tenant_id: org.tenant_id,
        inbound_route_id: route.id,
        default_organization_id: org.id,
        state: :active
      )

      raw = sample_email("sender@external.com", "inbox@misconfigured.example.com")

      # Dispatcher.dispatch still runs sender_matching even without the webhook
      # record (it always runs sender_matching as a blocking step). The dispatch
      # should still succeed.
      result = parse_normalize_dispatch(raw, route)
      assert {:ok, _thread} = result
    end

    test "no route exists for a nonexistent tenant" do
      # Simulates IMAP poller configured with an org that was deleted
      assert InboundRoutes.list_for_tenant(999_999_999) == []
    end
  end
end
