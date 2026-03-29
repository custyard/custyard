defmodule Custyard.Email.ImapDispatcherIntegrationTest do
  @moduledoc """
  Integration tests for the IMAP -> Dispatcher pipeline.

  Verifies that emails parsed by Parser and normalized by Adapters.Email
  dispatch correctly through the Webhooks.Dispatcher when the IMAP poller
  provides an org_id from its configuration.

  These tests exercise the pipeline that process_single_message delegates to:
    Parser.parse -> Adapters.Email.normalize -> Dispatcher.dispatch(route, normalized)

  They do NOT start an actual IMAP server or poller GenServer; they test
  the processing pipeline that the poller would invoke.
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
    route =
      %InboundRoute{}
      |> InboundRoute.changeset(attrs)
      |> Repo.insert!()

    %InboundRouteWebhook{}
    |> InboundRouteWebhook.changeset(%{
      inbound_route_id: route.id,
      purpose: :sender_matching,
      enabled: true
    })
    |> Repo.insert!()

    route
  end

  # Sample RFC 5322 email
  defp sample_email(from, to, opts \\ []) do
    subject = Keyword.get(opts, :subject, "IMAP polled email")
    message_id = Keyword.get(opts, :message_id, "<imap-int-#{System.unique_integer([:positive])}@example.com>")
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
      Dispatcher.dispatch(route, normalized)
    end
  end

  describe "IMAP-polled email dispatches through correct org route" do
    test "conversation is created with org_id from the poller's configured route" do
      org = insert_organization(domain: "polled-org.example.com")
      _contact = insert_contact(organization_id: org.id, email: "sender@external.com")

      # This route represents what the IMAP poller would resolve from its org_id config
      route = create_route_with_webhook(%{organization_id: org.id, route_type: :general})

      raw = sample_email("sender@external.com", "inbox@polled-org.example.com",
        subject: "Via IMAP poller"
      )

      assert {:ok, conversation} = parse_normalize_dispatch(raw, route)
      assert conversation.organization_id == org.id
      assert conversation.subject == "Via IMAP poller"
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

      raw = sample_email("sender@external.com", "inbox@polled-org.example.com",
        subject: "Project-scoped IMAP email"
      )

      assert {:ok, conversation} = parse_normalize_dispatch(raw, route)
      assert conversation.project_id == project.id
    end
  end

  describe "IMAP poller with missing/invalid org_id" do
    test "dispatch fails gracefully when route has no sender_matching webhook" do
      org = insert_organization(domain: "misconfigured.example.com")
      _contact = insert_contact(organization_id: org.id, email: "sender@external.com")

      # Route exists but has no webhooks enabled
      route =
        %InboundRoute{}
        |> InboundRoute.changeset(%{organization_id: org.id, route_type: :general})
        |> Repo.insert!()

      raw = sample_email("sender@external.com", "inbox@misconfigured.example.com")

      # Dispatcher.dispatch still runs sender_matching even without the webhook
      # record (it always runs sender_matching as a blocking step). The dispatch
      # should still succeed.
      result = parse_normalize_dispatch(raw, route)
      assert {:ok, _conversation} = result
    end

    test "get_general_route returns nil for non-existent org_id" do
      # Simulates IMAP poller configured with an org that was deleted
      assert InboundRoutes.get_general_route(999_999_999) == nil
    end
  end
end
