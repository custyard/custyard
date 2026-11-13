defmodule Custyard.Threads.IgnoreSenderTest do
  # SQLite doesn't support async tests due to database locking. The shared
  # sandbox also lets the dispatcher's purpose tasks read the database.
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Contact, InboundChannels, Settings, Threads}
  alias Custyard.Notifications.NeglectChecker
  alias Custyard.Webhooks.Dispatcher
  alias Custyard.Webhooks.Purposes.Notification

  @notifications "staff:notifications"

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id)
    org = insert_organization(tenant_id: tenant.id)
    contact = insert_contact(organization_id: org.id, email: "digest@sender.example.com")
    thread = insert_thread(organization_id: org.id, contact_id: contact.id, state: :active)

    {:ok,
     tenant: tenant,
     staff: staff,
     org: org,
     contact: contact,
     thread: thread,
     scope: Custyard.Scope.for_staff(staff, tenant)}
  end

  defp ignored_at(contact), do: Repo.get!(Contact, contact.id).ignored_at

  describe "ignore_sender/2 and unignore_sender/2" do
    test "mark and clear the thread's contact", c do
      assert ignored_at(c.contact) == nil
      refute Threads.sender_ignored?(c.thread)

      assert {:ok, %Contact{ignored_at: %DateTime{} = at}} =
               Threads.ignore_sender(c.scope, c.thread.id)

      assert ignored_at(c.contact) == at
      assert DateTime.diff(DateTime.utc_now(), at) in 0..5
      assert Threads.sender_ignored?(c.thread)
      assert Threads.sender_ignored?(Repo.preload(c.thread, :contact))

      assert {:ok, %Contact{ignored_at: nil}} = Threads.unignore_sender(c.scope, c.thread.id)
      assert ignored_at(c.contact) == nil
      refute Threads.sender_ignored?(c.thread)
      refute Threads.sender_ignored?(Repo.preload(c.thread, :contact))
    end

    test "ignoring again keeps the time of the first", c do
      first = ~U[2026-11-01 09:00:00Z]
      Repo.update!(Contact.ignore_changeset(c.contact, first))

      assert {:ok, %Contact{ignored_at: ^first}} = Threads.ignore_sender(c.scope, c.thread.id)
    end

    test "cover every thread of the sender, and no other sender", c do
      sibling = insert_thread(organization_id: c.org.id, contact_id: c.contact.id, state: :new)
      other = insert_contact(organization_id: c.org.id)
      unrelated = insert_thread(organization_id: c.org.id, contact_id: other.id, state: :new)

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)

      assert Threads.sender_ignored?(sibling)
      refute Threads.sender_ignored?(unrelated)
      assert ignored_at(other) == nil

      assert Enum.sort(Threads.queue_ids(c.scope, filter: "ignored")) ==
               Enum.sort([c.thread.id, sibling.id])

      assert Threads.queue_ids(c.scope, filter: "all") == [unrelated.id]

      # Stopped from any of the sender's threads.
      {:ok, _} = Threads.unignore_sender(c.scope, sibling.id)
      assert Threads.queue_ids(c.scope, filter: "ignored") == []
    end

    test "a thread without a contact has no sender to ignore", c do
      thread = insert_thread(tenant_id: c.tenant.id, source: :public_intake)

      assert Threads.ignore_sender(c.scope, thread.id) == {:error, :no_contact}
      assert Threads.unignore_sender(c.scope, thread.id) == {:error, :no_contact}
      refute Threads.sender_ignored?(thread)
    end

    test "are refused to staff who may not change thread state", c do
      agent = staff_scope(c.tenant.id, "agent")

      assert Threads.ignore_sender(agent, c.thread.id) == {:error, :unauthorized}
      assert ignored_at(c.contact) == nil

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      assert Threads.unignore_sender(agent, c.thread.id) == {:error, :unauthorized}
      assert %DateTime{} = ignored_at(c.contact)
    end

    test "are refused across tenants and to a removed staff account", c do
      foreign = staff_scope(insert_tenant().id)
      assert Threads.ignore_sender(foreign, c.thread.id) == {:error, :unauthorized}

      Repo.delete!(c.staff)
      assert Threads.ignore_sender(c.scope, c.thread.id) == {:error, :unauthorized}
      assert ignored_at(c.contact) == nil
    end

    test "broadcast like a state change, so open queues refresh", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{c.org.id}")
      id = c.thread.id

      {:ok, _} = Threads.ignore_sender(c.scope, id)
      assert_receive {:thread_updated, ^id}
      assert_receive {:thread_updated, ^id}

      {:ok, _} = Threads.unignore_sender(c.scope, id)
      assert_receive {:thread_updated, ^id}
      assert_receive {:thread_updated, ^id}

      # A refused call tells nobody.
      Threads.ignore_sender(staff_scope(c.tenant.id, "agent"), id)
      refute_receive {:thread_updated, _}, 50
    end
  end

  describe "the neglect report" do
    test "leaves out an ignored sender's threads", c do
      heard = insert_thread(organization_id: c.org.id, state: :active)
      ids = fn -> c.scope |> Threads.neglected() |> Enum.map(& &1.id) |> Enum.sort() end

      assert ids.() == Enum.sort([c.thread.id, heard.id])

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      assert ids.() == [heard.id]

      {:ok, _} = Threads.unignore_sender(c.scope, c.thread.id)
      assert ids.() == Enum.sort([c.thread.id, heard.id])
    end
  end

  describe "neglect notifications" do
    test "are not raised for an ignored sender's thread", c do
      thresholds = Settings.get_neglect_thresholds(c.tenant.id)
      {_warning, critical_hours} = thresholds.standard
      long_ago = DateTime.add(DateTime.utc_now(:second), -(critical_hours + 1), :hour)

      Repo.update_all(from(t in Custyard.Thread, where: t.id == ^c.thread.id),
        set: [last_staff_action_at: long_ago]
      )

      candidates = fn ->
        c.tenant.id
        |> NeglectChecker.list_notification_candidates(thresholds)
        |> Enum.map(& &1.id)
      end

      assert candidates.() == [c.thread.id]

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      assert candidates.() == []
      assert NeglectChecker.check_and_notify() == {:ok, 0}
      assert Repo.get!(Custyard.Thread, c.thread.id).last_neglect_notification == nil

      {:ok, _} = Threads.unignore_sender(c.scope, c.thread.id)
      assert candidates.() == [c.thread.id]
    end
  end

  describe "the new-message notification" do
    test "is not sent for an ignored sender's thread", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      id = c.thread.id

      assert Notification.process(c.thread, %{}, %{}) == :ok
      assert_receive {:new_message, ^id}

      {:ok, _} = Threads.ignore_sender(c.scope, id)
      assert Notification.process(c.thread, %{}, %{}) == :ok
      refute_receive {:new_message, _}, 50

      {:ok, _} = Threads.unignore_sender(c.scope, id)
      assert Notification.process(c.thread, %{}, %{}) == :ok
      assert_receive {:new_message, ^id}
    end

    test "is still sent for a thread without a contact", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      thread = insert_thread(tenant_id: c.tenant.id, source: :public_intake)
      id = thread.id

      assert Notification.process(thread, %{}, %{}) == :ok
      assert_receive {:new_message, ^id}
    end
  end

  describe "new mail from an ignored sender" do
    setup c do
      route =
        insert_inbound_route(
          organization_id: c.org.id,
          route_type: :general,
          source: :lettermint,
          lettermint_route_id: "lm_#{System.unique_integer([:positive])}",
          lettermint_route_domain: "r#{System.unique_integer([:positive])}.lettermint.app"
        )

      for purpose <- [:sender_matching, :enrichment, :notification, :audit] do
        insert_inbound_route_webhook(inbound_route_id: route.id, purpose: purpose, enabled: true)
      end

      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example.com",
          state: :active
        )

      {:ok, route: route, recipient: InboundChannels.ingress_address(channel)}
    end

    defp mail(recipient, from, overrides) do
      [_whole, address] = Regex.run(~r/<(.+)>/, from)
      [_local, domain] = String.split(address, "@")

      Map.merge(
        %{
          from: from,
          to: recipient,
          subject: "Hello",
          body: "Mail body",
          message_id: "<m-#{System.unique_integer([:positive])}@#{domain}>",
          in_reply_to: nil,
          references: nil,
          headers: %{},
          source: :lettermint,
          metadata: %{
            provider_delivery_id: "dlv-#{System.unique_integer([:positive])}",
            lettermint_message_id: "lm-#{System.unique_integer([:positive])}",
            recipient: recipient,
            subaddress: nil,
            mail_from: address,
            reply_to: nil,
            cc: [],
            authentication: %{dkim: "pass", dkim_domain: domain, spf: "pass", dmarc: "pass"},
            is_spam: false,
            spam_score: 0.3
          }
        },
        overrides
      )
    end

    # The purposes after sender matching run as supervised tasks. Wait for
    # them, so "no notification" is a fact and not a race.
    defp await_purposes do
      Custyard.TaskSupervisor
      |> Task.Supervisor.children()
      |> Enum.each(fn pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          2_000 -> flunk("a webhook purpose task did not finish")
        end
      end)
    end

    test "lands on the same contact, stays out of the queue and notifies nobody", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      sender = "Digest <digest@sender.example.com>"

      # Mail from the sender is heard until staff ignore them.
      assert {:ok, first} =
               Dispatcher.dispatch(c.route, mail(c.recipient, sender, %{subject: "Digest 1"}))

      first_id = first.id
      assert first.contact_id == c.contact.id
      assert_receive {:new_message, ^first_id}, 500
      assert first_id in Threads.queue_ids(c.scope, filter: "needs_reply")

      {:ok, _} = Threads.ignore_sender(c.scope, first_id)
      await_purposes()

      assert {:ok, second} =
               Dispatcher.dispatch(c.route, mail(c.recipient, sender, %{subject: "Digest 2"}))

      await_purposes()

      assert second.id != first_id
      assert second.contact_id == c.contact.id
      assert second.state == :new
      refute_received {:new_message, _}

      for filter <- Threads.queue_filters() do
        assert second.id in Threads.queue_ids(c.scope, filter: filter) == (filter == "ignored"),
               "filter #{filter}"
      end

      assert Threads.queue_counts(c.scope)["ignored"] == 3
      assert Threads.queue_counts(c.scope)["needs_reply"] == 0
      refute second.id in Enum.map(Threads.neglected(c.scope), & &1.id)

      # Somebody else writing to the same address is heard as before.
      assert {:ok, other} =
               Dispatcher.dispatch(
                 c.route,
                 mail(c.recipient, "Bob <bob@other.example.com>", %{subject: "Need help"})
               )

      other_id = other.id
      assert_receive {:new_message, ^other_id}, 500
      assert other_id in Threads.queue_ids(c.scope, filter: "needs_reply")
      await_purposes()
    end

    test "a later message in an ignored thread notifies nobody either", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      sender = "Digest <digest@sender.example.com>"
      first_mail = mail(c.recipient, sender, %{subject: "Digest"})

      assert {:ok, thread} = Dispatcher.dispatch(c.route, first_mail)
      thread_id = thread.id
      assert_receive {:new_message, ^thread_id}, 500

      {:ok, _} = Threads.ignore_sender(c.scope, thread_id)
      await_purposes()

      follow_up =
        mail(c.recipient, sender, %{subject: "Re: Digest", in_reply_to: first_mail.message_id})

      assert {:ok, %{id: ^thread_id}} = Dispatcher.dispatch(c.route, follow_up)
      await_purposes()

      refute_received {:new_message, _}

      assert Enum.sort(Threads.queue_ids(c.scope, filter: "ignored")) ==
               Enum.sort([c.thread.id, thread_id])
    end
  end
end
