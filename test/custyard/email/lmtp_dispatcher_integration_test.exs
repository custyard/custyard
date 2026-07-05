defmodule Custyard.Email.LmtpDispatcherIntegrationTest do
  @moduledoc """
  Integration tests for the LMTP -> Dispatcher pipeline.

  Verifies that emails parsed by Parser and normalized by Adapters.Email
  dispatch correctly through the Webhooks.Dispatcher with proper route
  context (organization_id, project_id).

  These tests exercise the intended pipeline:
    Parser.parse -> Adapters.Email.normalize -> Dispatcher.dispatch(route, normalized)

  They do NOT start an actual LMTP server; they test the processing pipeline
  that handle_DATA delegates to.
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

  # Sample RFC 5322 email for testing (CRLF line endings)
  defp sample_email(from, to, opts \\ []) do
    subject = Keyword.get(opts, :subject, "Test email")

    message_id =
      Keyword.get(
        opts,
        :message_id,
        "<lmtp-int-#{System.unique_integer([:positive])}@example.com>"
      )

    in_reply_to = Keyword.get(opts, :in_reply_to)
    body = Keyword.get(opts, :body, "This is a test email body.")

    headers =
      [
        "From: #{from}\r\n",
        "To: #{to}\r\n",
        "Subject: #{subject}\r\n",
        "Message-ID: #{message_id}\r\n",
        "MIME-Version: 1.0\r\n",
        "Content-Type: text/plain; charset=utf-8\r\n"
      ]

    headers =
      if in_reply_to do
        headers ++ ["In-Reply-To: #{in_reply_to}\r\n"]
      else
        headers
      end

    Enum.join(headers) <> "\r\n" <> body <> "\r\n"
  end

  # Runs the full pipeline: parse -> normalize -> dispatch
  defp parse_normalize_dispatch(raw_email, route) do
    with {:ok, parsed} <- Parser.parse(raw_email),
         {:ok, normalized} <- EmailAdapter.normalize(parsed) do
      Dispatcher.dispatch(route, normalized)
    end
  end

  describe "LMTP email creates conversation with correct organization_id" do
    test "conversation is scoped to the org that owns the route" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      route = create_route_with_webhook(%{organization_id: org.id, route_type: :general})

      raw = sample_email("alice@acme.example.com", "support@custyard.test")
      assert {:ok, conversation} = parse_normalize_dispatch(raw, route)

      assert conversation.organization_id == org.id
      assert conversation.state == :new
    end
  end

  describe "LMTP email with project route" do
    test "conversation gets project_id from project route" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      project = insert_project(organization_id: org.id, title: "Website Redesign")

      route =
        create_route_with_webhook(%{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project
        })

      raw =
        sample_email("alice@acme.example.com", "support@custyard.test",
          subject: "Project-scoped email"
        )

      assert {:ok, conversation} = parse_normalize_dispatch(raw, route)
      assert conversation.project_id == project.id
      assert conversation.organization_id == org.id
    end
  end

  describe "route auto-creation via find_or_create_general_route" do
    test "org without a general route gets one auto-created" do
      org = insert_organization(domain: "neworg.example.com")

      # No route exists yet
      assert InboundRoutes.get_general_route(org.id) == nil

      # find_or_create_general_route creates one
      assert {:ok, route} = InboundRoutes.find_or_create_general_route(org.id)
      assert route.route_type == :general
      assert route.organization_id == org.id

      # Second call returns the same route
      assert {:ok, same_route} = InboundRoutes.find_or_create_general_route(org.id)
      assert same_route.id == route.id
    end
  end

  describe "cross-org scoping" do
    test "email dispatched to org-A route does not create conversation in org-B" do
      org_a = insert_organization(domain: "alpha.example.com")
      org_b = insert_organization(domain: "beta.example.com")
      _contact_a = insert_contact(organization_id: org_a.id, email: "alice@alpha.example.com")
      _contact_b = insert_contact(organization_id: org_b.id, email: "bob@beta.example.com")

      route_a = create_route_with_webhook(%{organization_id: org_a.id, route_type: :general})

      # Alice sends email, dispatched through org_a's route
      raw =
        sample_email("alice@alpha.example.com", "support@custyard.test",
          subject: "Org-A scoped message"
        )

      assert {:ok, conversation} = parse_normalize_dispatch(raw, route_a)
      assert conversation.organization_id == org_a.id
      refute conversation.organization_id == org_b.id
    end

    test "same sender email on different org routes creates separate conversations" do
      org_a = insert_organization(domain: "alpha.example.com")
      org_b = insert_organization(domain: "beta.example.com")

      # The sender exists in both orgs (shared email)
      _contact_a = insert_contact(organization_id: org_a.id, email: "shared@external.com")
      _contact_b = insert_contact(organization_id: org_b.id, email: "shared@external.com")

      route_a = create_route_with_webhook(%{organization_id: org_a.id, route_type: :general})
      route_b = create_route_with_webhook(%{organization_id: org_b.id, route_type: :general})

      raw_a =
        sample_email("shared@external.com", "support-a@custyard.test",
          subject: "Message for org A"
        )

      raw_b =
        sample_email("shared@external.com", "support-b@custyard.test",
          subject: "Message for org B"
        )

      assert {:ok, conv_a} = parse_normalize_dispatch(raw_a, route_a)
      assert {:ok, conv_b} = parse_normalize_dispatch(raw_b, route_b)

      assert conv_a.organization_id == org_a.id
      assert conv_b.organization_id == org_b.id
      refute conv_a.id == conv_b.id
    end
  end

  describe "threading: reply via LMTP threads to existing conversation" do
    test "reply with In-Reply-To threads to existing conversation in same org" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      route = create_route_with_webhook(%{organization_id: org.id, route_type: :general})

      # Create initial conversation via the pipeline
      original_msg_id = "<original-#{System.unique_integer([:positive])}@acme.example.com>"

      raw_original =
        sample_email("alice@acme.example.com", "support@custyard.test",
          subject: "Original thread",
          message_id: original_msg_id,
          body: "Initial message"
        )

      assert {:ok, original_conv} = parse_normalize_dispatch(raw_original, route)

      # Send a reply referencing the original
      raw_reply =
        sample_email("alice@acme.example.com", "support@custyard.test",
          subject: "Re: Original thread",
          message_id: "<reply-#{System.unique_integer([:positive])}@acme.example.com>",
          in_reply_to: original_msg_id,
          body: "This is my reply"
        )

      assert {:ok, reply_conv} = parse_normalize_dispatch(raw_reply, route)

      # Reply should thread to the same conversation
      assert reply_conv.id == original_conv.id

      # Verify both messages exist on the conversation
      messages = Custyard.Conversations.list_public_messages(reply_conv.id)
      assert length(messages) == 2
    end
  end
end
