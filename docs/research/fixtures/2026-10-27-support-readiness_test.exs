defmodule Custyard.AuditReplyAllTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Conversations, Repo}
  alias Custyard.Email.Outbound
  alias Custyard.Webhooks.Purposes.SenderMatching

  # Audit reproducer, deliberately outside the normal test suite. These expectations describe the desired
  # support workflow and intentionally fail against the audited checkout.
  test "reply-all includes the participant who most recently replied to an existing thread" do
    org = insert_organization(name: "Support inbox owner")
    route = insert_inbound_route(organization_id: org.id, source: :lettermint)

    channel =
      insert_inbound_channel(
        inbound_route_id: route.id,
        public_address: "support@service.example",
        state: :active
      )

    context = %{
      organization_id: org.id,
      route_id: route.id,
      channel_id: channel.id,
      triage_class: :customer
    }

    alice = customer_message("alice@customer.example", "<alice-1@customer.example>")

    assert {:ok, original} = SenderMatching.process(alice, context)

    bob =
      customer_message("bob@customer.example", "<bob-2@customer.example>")
      |> Map.put(:in_reply_to, alice.message_id)
      |> Map.put(:references, alice.message_id)
      |> Map.put(:metadata, %{
        to: ["support@service.example"],
        cc: ["alice@customer.example"],
        reply_to: nil
      })

    assert {:ok, continued} = SenderMatching.process(bob, context)
    assert continued.id == original.id

    continued = Repo.preload(continued, [:contact, :prospect])
    assert continued.contact.email == "alice@customer.example"
    assert {:ok, recipient} = Outbound.reply_recipient(continued)
    cc = Conversations.default_reply_cc(continued, operator_email: "agent@service.example")

    assert %{to: recipient, cc: cc} == %{
             to: "bob@customer.example",
             cc: ["alice@customer.example"]
           }
  end

  test "an overdue unfinished task remains in attention after its conversation is resolved" do
    org = insert_organization()
    conversation = insert_conversation(organization_id: org.id, state: :resolved)

    assert {:ok, _task} =
             Conversations.create_task(%{
               title: "Follow up on promised fix",
               conversation_id: conversation.id,
               portal_visible: false,
               due_at: DateTime.utc_now() |> DateTime.add(-86_400) |> DateTime.truncate(:second)
             })

    attention = Conversations.list_for_attention_queue(organization_id: org.id)
    assert Enum.any?(attention, &(&1.conversation.id == conversation.id))
  end

  defp customer_message(sender, message_id) do
    %{
      from: sender,
      to: "support@service.example",
      subject: "Support question",
      body: "Please help with our account.",
      message_id: message_id,
      in_reply_to: nil,
      references: nil,
      headers: %{},
      source: :lettermint,
      metadata: %{to: ["support@service.example"], cc: [], reply_to: nil}
    }
  end
end
