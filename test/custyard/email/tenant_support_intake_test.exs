defmodule Custyard.Email.TenantSupportIntakeTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Conversations, InboundRoute, Organization, Repo, Tenant}
  alias Custyard.Email.{Outbound, SenderMatcher, ThreadMatcher}
  alias Custyard.Webhooks.Purposes.SenderMatching
  alias Custyard.Webhooks.Dispatcher

  defp tenant do
    %Tenant{}
    |> Tenant.changeset(%{name: "Service", slug: "service-#{System.unique_integer([:positive])}"})
    |> Repo.insert!()
  end

  defp message(sender, opts \\ []) do
    Map.merge(
      %{
        from: sender,
        to: "support@service.example",
        subject: "Help with billing",
        body: "A customer question",
        message_id: "<#{System.unique_integer([:positive])}@customer.example>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint,
        metadata: %{to: ["support@service.example"], cc: []}
      },
      Map.new(opts)
    )
  end

  defp receive_email(tenant, normalized) do
    SenderMatching.process(normalized, %{tenant_id: tenant.id, organization_id: nil})
  end

  defp shared_channel(tenant) do
    route =
      %InboundRoute{}
      |> InboundRoute.changeset(%{tenant_id: tenant.id, route_type: :general})
      |> Repo.insert!()

    insert_inbound_channel(
      inbound_route_id: route.id,
      organization_id: nil,
      tenant_id: tenant.id,
      public_address: "support@service.example",
      display_name: "Service Support",
      state: :active
    )
  end

  test "a shared inbox creates customer organizations inside its tenant" do
    tenant = tenant()
    assert {:ok, alice} = receive_email(tenant, message("Alice <alice@acme.example>"))
    assert {:ok, beta} = receive_email(tenant, message("Bob <bob@beta.example>"))
    assert alice.organization_id != beta.organization_id
    assert Repo.get!(Organization, alice.organization_id).domain == "acme.example"
    assert Repo.get!(Organization, beta.organization_id).tenant_id == tenant.id

    assert {:ok, coworker} = receive_email(tenant, message("carol@acme.example"))
    assert coworker.organization_id == alice.organization_id
  end

  test "personal addresses create individually named organizations and exact contacts are reused" do
    tenant = tenant()
    assert {:ok, alice} = receive_email(tenant, message("Alice Chen <alice@gmail.com>"))
    assert {:ok, bob} = receive_email(tenant, message("Bob Chen <bob@gmail.com>"))
    assert {:ok, again} = receive_email(tenant, message("Alice Changed <alice@gmail.com>"))
    org = Repo.get!(Organization, alice.organization_id)
    assert org.name == "Alice Chen"
    assert org.domain == nil
    assert org.intake_key == "email:alice@gmail.com"
    assert again.organization_id == alice.organization_id
    assert again.contact_id == alice.contact_id
    assert bob.organization_id != alice.organization_id
  end

  test "same sender and forged thread headers never cross receiving tenants" do
    first = tenant()
    second = tenant()
    mail = message("alice@acme.example")
    assert {:ok, original} = receive_email(first, mail)

    assert {:ok, separate} =
             receive_email(second, message("alice@acme.example", in_reply_to: mail.message_id))

    assert separate.id != original.id
    assert separate.organization_id != original.organization_id
    assert separate.tenant_id == second.id
    assert {:contact, contact} = SenderMatcher.resolve_existing("alice@acme.example", second.id)
    assert contact.organization_id == separate.organization_id
  end

  test "headers preserve the customer thread when a second sender joins and reply-all includes both" do
    tenant = tenant()
    original = message("Alice <alice@acme.example>")
    assert {:ok, conversation} = receive_email(tenant, original)

    bob =
      message("Bob <bob@partner.example>",
        in_reply_to: original.message_id,
        metadata: %{to: ["support@service.example"], cc: ["alice@acme.example"], reply_to: nil}
      )

    assert {:ok, continued} = receive_email(tenant, bob)
    assert continued.id == conversation.id
    assert continued.organization_id == conversation.organization_id
    assert {:ok, "bob@partner.example"} = Outbound.reply_recipient(continued)

    # Without a channel, pass the operator identity so the service's support
    # address remains our side of the reply-all envelope.
    assert Conversations.default_reply_cc(continued, operator_email: "support@service.example") ==
             ["alice@acme.example"]

    assert {:ok, no_headers} =
             receive_email(
               tenant,
               message("Bob <bob@partner.example>", subject: "Re: Help with billing")
             )

    assert no_headers.id == conversation.id
  end

  test "subject fallback requires reply intent, same sender and one unambiguous customer thread" do
    tenant = tenant()
    assert {:ok, original} = receive_email(tenant, message("alice@acme.example"))

    assert {:ok, continuation} =
             receive_email(
               tenant,
               message("alice@acme.example", subject: "RE:  Help with billing")
             )

    assert continuation.id == original.id

    assert {:ok, other_sender} =
             receive_email(tenant, message("bob@acme.example", subject: "Re: Help with billing"))

    assert other_sender.id != original.id

    assert {:ok, new_topic} = receive_email(tenant, message("alice@acme.example"))
    assert new_topic.id != original.id

    assert {:ok, ambiguous} =
             receive_email(
               tenant,
               message("alice@acme.example", subject: "Re: Help with billing")
             )

    assert ambiguous.id not in [original.id, new_topic.id]
  end

  test "an explicit customer route keeps its customer organization" do
    tenant = tenant()
    organization = insert_organization(tenant_id: tenant.id)

    assert {:ok, conversation} =
             SenderMatching.process(message("alice@acme.example"), %{
               tenant_id: tenant.id,
               organization_id: organization.id
             })

    assert conversation.organization_id == organization.id
  end

  test "lookup-only public capture never creates an organization" do
    tenant = tenant()
    before_count = Repo.aggregate(Organization, :count)
    assert :none = SenderMatcher.resolve_existing("unknown@acme.example", tenant.id)
    assert Repo.aggregate(Organization, :count) == before_count
  end

  test "dispatcher keeps the tenant's channel on each customer conversation" do
    tenant = tenant()

    route =
      %InboundRoute{}
      |> InboundRoute.changeset(%{tenant_id: tenant.id, route_type: :general})
      |> Repo.insert!()

    channel =
      insert_inbound_channel(
        inbound_route_id: route.id,
        organization_id: nil,
        tenant_id: tenant.id,
        public_address: "support@service.example",
        display_name: "Service Support",
        state: :active
      )

    assert {:ok, alice} =
             Dispatcher.dispatch(route, message("alice@acme.example"), channel: channel)

    assert {:ok, bob} = Dispatcher.dispatch(route, message("bob@beta.example"), channel: channel)
    assert alice.organization_id != bob.organization_id
    assert alice.inbound_channel_id == channel.id
    assert bob.inbound_channel_id == channel.id
    assert alice.tenant_id == tenant.id

    assert Conversations.reply_identity(alice) == %{
             address: "support@service.example",
             name: "Service Support",
             source: :channel
           }
  end

  test "an ambiguous contact uses deterministic domain identity for new unthreaded mail" do
    tenant = tenant()
    customer = insert_organization(tenant_id: tenant.id, domain: "acme.example")
    other = insert_organization(tenant_id: tenant.id, domain: "other.example")
    insert_contact(organization_id: customer.id, email: "alice@acme.example")
    insert_contact(organization_id: other.id, email: "alice@acme.example")
    assert {:ok, conversation} = receive_email(tenant, message("alice@acme.example"))
    assert conversation.organization_id == customer.id
  end

  test "missing sender remains visible without creating an undeliverable contact" do
    tenant = tenant()
    assert {:ok, conversation} = receive_email(tenant, message(nil))
    assert conversation.tenant_id == tenant.id
    assert is_nil(conversation.contact_id)
    assert {:error, :no_recipient_email} = Outbound.reply_recipient(conversation)
  end

  test "ambiguous references create a new conversation even when one subject matches" do
    tenant = tenant()
    first = message("alice@acme.example", subject: "First question")
    second = message("alice@acme.example", subject: "Second question")
    assert {:ok, one} = receive_email(tenant, first)
    assert {:ok, two} = receive_email(tenant, second)

    assert {:ok, ambiguous} =
             receive_email(
               tenant,
               message("alice@acme.example",
                 references: first.message_id <> " " <> second.message_id,
                 subject: "Re: First question"
               )
             )

    assert ambiguous.id not in [one.id, two.id]
  end

  test "ineligible public references cannot hide an ambiguous customer match" do
    tenant = tenant()
    public_thread = insert_conversation(source: :public_intake, tenant_id: tenant.id)
    insert_prospect(conversation_id: public_thread.id, email: "other@customer.example")

    public_message =
      insert_message(
        conversation_id: public_thread.id,
        message_id: "<public-#{System.unique_integer([:positive])}@customer.example>"
      )

    first = message("alice@acme.example")
    second = message("bob@beta.example")
    assert {:ok, _first} = receive_email(tenant, first)
    assert {:ok, _second} = receive_email(tenant, second)

    references = Enum.join([public_message.message_id, first.message_id, second.message_id], " ")

    assert :ambiguous =
             ThreadMatcher.find_in_tenant(
               message("alice@acme.example", references: references),
               tenant.id
             )
  end

  test "ineligible public references cannot hide a later eligible customer match" do
    tenant = tenant()

    public_ids =
      for index <- 1..3 do
        public_thread = insert_conversation(source: :public_intake, tenant_id: tenant.id)
        insert_prospect(conversation_id: public_thread.id, email: "other@customer.example")

        insert_message(
          conversation_id: public_thread.id,
          message_id: "<public-#{index}-#{System.unique_integer([:positive])}@customer.example>"
        ).message_id
      end

    original = message("alice@acme.example")
    assert {:ok, conversation} = receive_email(tenant, original)

    assert {:ok, matched} =
             ThreadMatcher.find_in_tenant(
               message("alice@acme.example",
                 references: Enum.join(public_ids ++ [original.message_id], " ")
               ),
               tenant.id
             )

    assert matched.id == conversation.id
  end

  test "header threading can follow a customer across two shared routes in the same tenant" do
    tenant = tenant()
    original = message("alice@acme.example")

    assert {:ok, first} =
             SenderMatching.process(original, %{
               tenant_id: tenant.id,
               organization_id: nil,
               route_id: 1001
             })

    assert {:ok, reply} =
             SenderMatching.process(
               message("alice@acme.example", in_reply_to: original.message_id),
               %{tenant_id: tenant.id, organization_id: nil, route_id: 1002}
             )

    assert reply.id == first.id
  end

  test "tenant public intake snapshots support identity and receives the captured sender's email reply" do
    tenant = tenant()
    channel = shared_channel(tenant)
    conversation = insert_conversation(source: :public_intake, tenant_id: tenant.id)

    prospect =
      insert_prospect(
        conversation_id: conversation.id,
        email: "alice@acme.example",
        notify_on_reply: true
      )

    assert {:ok, outgoing} =
             Conversations.send_reply(conversation, "Here is how to get started.",
               operator_email: "private@operator.example"
             )

    assert outgoing.sender_email == channel.public_address
    assert outgoing.inbound_channel_id == channel.id
    assert outgoing.to_addresses == [prospect.email]

    assert {:ok, unrelated} =
             receive_email(
               tenant,
               message("wrong@other.example", in_reply_to: outgoing.message_id)
             )

    assert unrelated.id != conversation.id

    assert {:ok, continued} =
             receive_email(tenant, message(prospect.email, in_reply_to: outgoing.message_id))

    assert continued.id == conversation.id
    assert continued.source == :public_intake
    assert continued.organization_id != nil
    assert continued.contact_id != nil

    assert Repo.get!(Custyard.Prospect, prospect.id).access_token_hash ==
             prospect.access_token_hash
  end

  test "tenant portal replies use the default support channel and preserve email threads" do
    tenant = tenant()
    channel = shared_channel(tenant)
    organization = insert_organization(tenant_id: tenant.id)
    contact = insert_contact(organization_id: organization.id)

    conversation =
      insert_conversation(
        source: :portal,
        organization_id: organization.id,
        contact_id: contact.id
      )

    assert {:ok, outgoing} = Conversations.send_reply(conversation, "An answer")
    assert outgoing.sender_email == channel.public_address
    assert outgoing.inbound_channel_id == channel.id

    assert {:ok, continued} =
             receive_email(tenant, message(contact.email, in_reply_to: outgoing.message_id))

    assert continued.id == conversation.id
  end

  test "archive copies of unlinked public replies are own echoes within their tenant" do
    tenant = tenant()
    channel = shared_channel(tenant)

    assert {:ok, channel} =
             Custyard.InboundChannels.update_channel(channel, %{archive_copy: true})

    conversation = insert_conversation(source: :public_intake, tenant_id: tenant.id)

    insert_prospect(
      conversation_id: conversation.id,
      email: "alice@acme.example",
      notify_on_reply: true
    )

    assert {:ok, outgoing} = Conversations.send_reply(conversation, "Here is how to get started.")

    archived =
      message(channel.public_address,
        message_id: outgoing.message_id,
        subject: "Re: Getting started",
        body: outgoing.body
      )

    before_count = Repo.aggregate(Custyard.Conversation, :count)

    assert {:ignored, :own_echo} =
             Dispatcher.dispatch(channel.inbound_route, archived, channel: channel)

    assert Repo.aggregate(Custyard.Conversation, :count) == before_count

    other_channel = shared_channel(tenant())

    assert {:ok, other_conversation} =
             Dispatcher.dispatch(other_channel.inbound_route, archived, channel: other_channel)

    assert other_conversation.tenant_id == other_channel.tenant_id
    assert other_conversation.id != conversation.id
  end

  test "a tenant without a sending identity never falls back to the instance or operator address" do
    tenant = tenant()
    conversation = insert_conversation(source: :public_intake, tenant_id: tenant.id)

    insert_prospect(
      conversation_id: conversation.id,
      email: "alice@acme.example",
      notify_on_reply: true
    )

    assert {:ok, outgoing} =
             Conversations.send_reply(conversation, "An answer",
               operator_email: "private@operator.example"
             )

    assert outgoing.sender_email == nil
    assert {:error, :from_not_set, failed} = Outbound.deliver(outgoing)
    assert failed.delivery_failure_kind == :configuration

    channel = shared_channel(tenant)
    operator = insert_operator_account(role: "super_admin")
    assert {:ok, pending} = Outbound.retry(failed, operator)
    assert pending.sender_email == channel.public_address
    assert pending.inbound_channel_id == channel.id
    assert pending.to_addresses == outgoing.to_addresses
  end
end
