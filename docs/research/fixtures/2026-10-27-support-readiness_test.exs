defmodule Custyard.AuditReplyAllTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Threads, Repo}
  alias Custyard.Email.Outbound
  alias Custyard.Webhooks.Purposes.SenderMatching

  # Audit reproducer retained outside the normal test suite. These expectations
  # describe the support workflow and use the current tenant-scoped API.
  test "reply-all includes the participant who most recently replied to an existing thread" do
    org = insert_organization(name: "Support inbox owner")
    route = insert_inbound_route(tenant_id: org.tenant_id, source: :lettermint)

    channel =
      insert_inbound_channel(
        inbound_route_id: route.id,
        public_address: "support@service.example",
        state: :active
      )

    context = %{
      tenant_id: org.tenant_id,
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
    cc = Threads.default_reply_cc(continued, staff_email: "agent@service.example")

    assert %{to: recipient, cc: cc} == %{
             to: "bob@customer.example",
             cc: ["alice@customer.example"]
           }
  end

  test "an overdue unfinished task remains in attention after its thread is resolved" do
    org = insert_organization()
    thread = insert_thread(organization_id: org.id, state: :resolved)

    assert {:ok, _task} =
             Threads.create_task(%{
               title: "Follow up on promised fix",
               thread_id: thread.id,
               portal_visible: false,
               due_at: DateTime.utc_now() |> DateTime.add(-86_400) |> DateTime.truncate(:second)
             })

    staff = insert_staff_account(tenant_id: org.tenant_id)
    scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))
    attention = Threads.list(scope, organization_id: org.id)
    assert Enum.any?(attention, &(&1.thread.id == thread.id))
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
