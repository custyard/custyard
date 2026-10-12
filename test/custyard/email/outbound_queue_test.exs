defmodule Custyard.Email.OutboundQueueTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.{Conversations, Message, Repo}
  alias Custyard.Email.OutboundQueue
  alias Custyard.PubSub
  alias Ecto.Adapters.SQL.Sandbox

  # Background delivery must report email to the test owner, not the GenServer mailbox.
  setup :set_swoosh_global

  test "recovers a pending reply and delivers it once" do
    org = insert_organization()
    contact = insert_contact(organization_id: org.id)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)

    assert {:ok, message} = Conversations.send_reply(conversation, "Hello from the queue")
    assert Repo.get!(Message, message.id).delivery_status == :pending

    assert OutboundQueue.drain_pending() == 1
    assert Repo.get!(Message, message.id).delivery_status == :sent
    assert_email_sent(to: contact.email)

    assert OutboundQueue.drain_pending() == 0
  end

  test "delivery remains recoverable when unrelated task slots are full" do
    supervisor = Custyard.TaskSupervisor

    pids =
      for _ <- 1..100 do
        {:ok, pid} =
          Task.Supervisor.start_child(supervisor, fn ->
            receive do
              :stop -> :ok
            end
          end)

        pid
      end

    on_exit(fn -> Enum.each(pids, &Process.exit(&1, :kill)) end)

    org = insert_organization()
    contact = insert_contact(organization_id: org.id)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)

    assert {:ok, message} = Conversations.send_reply(conversation, "Delivery survives saturation")
    assert Repo.get!(Message, message.id).delivery_status == :pending

    assert OutboundQueue.drain_pending() == 1
    assert Repo.get!(Message, message.id).delivery_status == :sent
    assert_email_sent(to: contact.email)
  end

  test "the supervised worker wakes after a committed reply" do
    org = insert_organization()
    contact = insert_contact(organization_id: org.id)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)
    Phoenix.PubSub.subscribe(PubSub, "conversation:#{conversation.id}")

    {:ok, worker} = OutboundQueue.start_link([])
    Sandbox.allow(Repo, self(), worker)
    on_exit(fn -> if Process.alive?(worker), do: GenServer.stop(worker) end)

    assert {:ok, message} = Conversations.send_reply(conversation, "Worker handles this reply")
    assert_receive {:message_updated, id}, 2_000
    assert id == conversation.id
    assert Repo.get!(Message, message.id).delivery_status == :sent
    assert_email_sent(to: contact.email)
    assert Process.alive?(worker)
    assert OutboundQueue.drain_pending() == 0
  end

  describe "replies interrupted mid-delivery" do
    import Ecto.Query

    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id)
      conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)
      {:ok, message} = Conversations.send_reply(conversation, "Interrupted reply")
      {:ok, message: message, contact: contact}
    end

    test "a stale :sending row is failed, never re-sent", %{message: message} do
      long_ago = DateTime.utc_now() |> DateTime.add(-1200, :second) |> DateTime.truncate(:second)

      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [delivery_status: :sending, updated_at: long_ago])

      assert OutboundQueue.drain_pending() == 0
      assert Repo.get!(Message, message.id).delivery_status == :failed
      assert_no_email_sent()
    end

    test "a :sending row inside the grace period is left to its attempt", %{message: message} do
      from(m in Message, where: m.id == ^message.id)
      |> Repo.update_all(set: [delivery_status: :sending])

      assert OutboundQueue.drain_pending() == 0
      assert Repo.get!(Message, message.id).delivery_status == :sending
      assert_no_email_sent()
    end
  end
end
