defmodule Custyard.Threads.AttentionQueueTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Labels, Threads}
  alias Custyard.Threads.{QueueNav, QueuePreview}

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id)
    org = insert_organization(tenant_id: tenant.id)

    {:ok, tenant: tenant, staff: staff, org: org, scope: Custyard.Scope.for_staff(staff, tenant)}
  end

  describe "queue_previews/2" do
    test "returns the newest message as a one-line snippet", c do
      thread = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: thread.id, body: "First message")

      insert_message(
        thread_id: thread.id,
        body: "Second   message\n\nspread over\tlines",
        sender_email: "alice@example.com"
      )

      assert %{snippet: "Second message spread over lines", snippet_from: :customer} =
               Threads.queue_previews(c.scope, [thread.id])[thread.id]
    end

    test "threads without messages are absent", c do
      thread = insert_thread(organization_id: c.org.id)
      assert Threads.queue_previews(c.scope, [thread.id]) == %{}
      assert Threads.queue_previews(c.scope, []) == %{}
    end

    test "the customer is the last speaker until staff reply", c do
      thread = insert_thread(organization_id: c.org.id)
      customer = insert_message(thread_id: thread.id, body: "Where is my invoice?")

      preview = Threads.queue_previews(c.scope, [thread.id])[thread.id]
      assert preview.last_speaker == :customer
      assert preview.last_spoke_at == customer.inserted_at

      insert_message(thread_id: thread.id, source: :staff, body: "Attached, sorry for the wait")

      assert %{last_speaker: :staff, snippet_from: :staff, snippet: "Attached, sorry" <> _} =
               Threads.queue_previews(c.scope, [thread.id])[thread.id]
    end

    test "a reply sent from the staff mailbox counts as staff speaking", c do
      thread = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: thread.id, body: "Question")
      insert_message(thread_id: thread.id, body: "Answered by mail", triage_class: :staff_sent)

      assert %{last_speaker: :staff, snippet_from: :staff} =
               Threads.queue_previews(c.scope, [thread.id])[thread.id]
    end

    test "internal notes and automatic replies are previewed but never take the turn", c do
      noted = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: noted.id, body: "Please refund me")

      insert_message(
        thread_id: noted.id,
        source: :staff,
        is_internal_note: true,
        body: "Asked finance"
      )

      auto = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: auto.id, source: :staff, body: "We have refunded you")

      insert_message(
        thread_id: auto.id,
        body: "I am out of office",
        triage_class: :auto_response
      )

      previews = Threads.queue_previews(c.scope, [noted.id, auto.id])

      assert %{snippet: "Asked finance", snippet_from: :note, last_speaker: :customer} =
               previews[noted.id]

      assert %{snippet: "I am out of office", snippet_from: :auto_reply, last_speaker: :staff} =
               previews[auto.id]
    end

    test "a thread holding only notes has no last speaker", c do
      thread = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: thread.id, source: :staff, is_internal_note: true, body: "Memo")

      assert %{snippet: "Memo", last_speaker: nil, last_spoke_at: nil} =
               Threads.queue_previews(c.scope, [thread.id])[thread.id]
    end

    test "a deleted message never leaks its body", c do
      thread = insert_thread(organization_id: c.org.id)
      message = insert_message(thread_id: thread.id, body: "My password is hunter2")
      {:ok, _} = Threads.soft_delete_message(message, c.staff)

      preview = Threads.queue_previews(c.scope, [thread.id])[thread.id]
      assert preview.snippet == nil
      assert preview.snippet_from == :deleted
      # Who spoke is a fact about the thread, not the removed content.
      assert preview.last_speaker == :customer
    end

    test "long bodies are cut and markup stays text", c do
      thread = insert_thread(organization_id: c.org.id)

      insert_message(
        thread_id: thread.id,
        body: "<script>alert(1)</script> " <> String.duplicate("word ", 400)
      )

      %{snippet: snippet} = Threads.queue_previews(c.scope, [thread.id])[thread.id]
      assert String.starts_with?(snippet, "<script>alert(1)</script> word")
      assert String.length(snippet) == 180
    end

    test "ignores threads of another tenant and revoked scopes", c do
      foreign_tenant = insert_tenant()
      foreign = insert_thread(tenant_id: foreign_tenant.id, source: :public_intake)
      insert_message(thread_id: foreign.id, body: "Not yours")

      own = insert_thread(organization_id: c.org.id)
      insert_message(thread_id: own.id, body: "Yours")

      assert Map.keys(Threads.queue_previews(c.scope, [own.id, foreign.id])) == [own.id]

      Repo.delete!(c.staff)
      assert Threads.queue_previews(c.scope, [own.id]) == %{}
    end

    test "uses a fixed number of queries for any number of threads", c do
      threads =
        for _ <- 1..6 do
          thread = insert_thread(organization_id: c.org.id)
          insert_message(thread_id: thread.id)
          insert_message(thread_id: thread.id, source: :staff)
          thread
        end

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "queue-preview-queries",
        [:custyard, :repo, :query],
        fn _event, _measurements, _metadata, _config -> send(test_pid, {ref, :query}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("queue-preview-queries") end)

      assert map_size(QueuePreview.for_threads(c.tenant.id, Enum.map(threads, & &1.id))) == 6
      assert_received {^ref, :query}
      refute_received {^ref, :query}
    end
  end

  describe "QueuePreview.snippet/1" do
    test "keeps the answer and drops the quoted thread below it" do
      body = """
      Thanks, that fixed it!

      On Mon, Nov 9, 2026 at 11:21 PM Support <support@example.com> wrote:
      > Please try clearing the cache.
      > Let us know how it goes.
      """

      assert QueuePreview.snippet(body) == "Thanks, that fixed it!"
    end

    test "drops interleaved quote lines" do
      assert QueuePreview.snippet("> Is it fixed?\nYes.\n> And billing?\nAlso yes.") ==
               "Yes. Also yes."
    end

    test "falls back to the whole text when everything is quoted" do
      assert QueuePreview.snippet("---------- Forwarded message ----------\nFrom: a@b.example") ==
               "---------- Forwarded message ---------- From: a@b.example"
    end

    test "returns nil for blank or missing bodies" do
      assert QueuePreview.snippet(" \n\t ") == nil
      assert QueuePreview.snippet(nil) == nil
    end
  end

  describe "queue_counts/2" do
    setup c do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      later = DateTime.add(now, 86_400)

      threads = %{
        new: insert_thread(organization_id: c.org.id, state: :new),
        active: insert_thread(organization_id: c.org.id, state: :active),
        active_too: insert_thread(organization_id: c.org.id, state: :active),
        waiting: insert_thread(organization_id: c.org.id, state: :waiting),
        dormant: insert_thread(organization_id: c.org.id, state: :dormant),
        resolved: insert_thread(organization_id: c.org.id, state: :resolved),
        snoozed: insert_thread(organization_id: c.org.id, state: :active, snoozed_until: later),
        snoozed_due:
          insert_thread(organization_id: c.org.id, state: :waiting, snoozed_until: later),
        resolved_due: insert_thread(organization_id: c.org.id, state: :resolved),
        expired_snooze:
          insert_thread(
            organization_id: c.org.id,
            state: :new,
            snoozed_until: DateTime.add(now, -60)
          )
      }

      for key <- [:snoozed_due, :resolved_due] do
        {:ok, _} =
          Threads.create_task(%{
            title: "Overdue",
            thread_id: threads[key].id,
            due_at: DateTime.add(now, -60)
          })
      end

      {:ok, threads: threads}
    end

    test "counts what each filter lists", c do
      counts = Threads.queue_counts(c.scope)

      # None of these threads has a message, so every listed one that is
      # neither waiting nor resolved needs a reply.
      assert counts == %{
               "all" => 8,
               "needs_reply" => 5,
               "new" => 2,
               "active" => 2,
               "waiting" => 2,
               "dormant" => 1,
               "snoozed" => 2,
               "due_tasks" => 2,
               # The two overdue tasks are unfinished tasks as well.
               "open_tasks" => 2,
               "ignored" => 0,
               "resolved" => 2
             }

      assert Map.keys(counts) |> Enum.sort() == Enum.sort(Threads.queue_filters())

      for {filter, count} <- counts do
        assert length(Threads.list(c.scope, filter: filter)) == count, "filter #{filter}"
      end
    end

    test "agrees with the lists in the second a snooze ends", c do
      # Every read has to land in that second, so start over if the clock moved on.
      {counts, listed} =
        Enum.find_value(1..50, fn _ ->
          ending = DateTime.utc_now() |> DateTime.truncate(:second)
          {:ok, _} = Threads.snooze(c.threads.active, ending)

          counts = Threads.queue_counts(c.scope)

          listed =
            Map.new(counts, fn {filter, _} ->
              {filter, length(Threads.list(c.scope, filter: filter))}
            end)

          if DateTime.truncate(DateTime.utc_now(), :second) == ending, do: {counts, listed}
        end)

      assert counts == listed
      # Still snoozed for that second, as the snoozed list has it.
      assert counts["snoozed"] == 3
    end

    test "follows the label filter", c do
      {:ok, label} = Labels.create_and_assign(c.scope, c.threads.active, "Billing")
      {:ok, _} = Labels.assign(c.scope, c.threads.snoozed, label.id)

      counts = Threads.queue_counts(c.scope, label_id: label.id)
      assert %{"all" => 1, "active" => 1, "snoozed" => 1, "new" => 0} = counts

      for {filter, count} <- counts do
        assert length(Threads.list(c.scope, filter: filter, label_id: label.id)) == count
      end
    end

    test "is tenant scoped and empty for a revoked scope", c do
      other_tenant = insert_tenant()
      other_staff = insert_staff_account(role: "admin", tenant_id: other_tenant.id)
      other_scope = Custyard.Scope.for_staff(other_staff, other_tenant)

      assert %{"all" => 0, "snoozed" => 0} = Threads.queue_counts(other_scope)

      Repo.delete!(c.staff)

      assert %{"all" => 0, "new" => 0, "due_tasks" => 0, "needs_reply" => 0} =
               Threads.queue_counts(c.scope)
    end
  end

  describe "queue filters" do
    test "there are eleven, in chip order, and the queue opens on needs reply" do
      assert Threads.queue_filters() ==
               ~w(needs_reply all new active waiting dormant snoozed due_tasks open_tasks ignored resolved)

      assert Threads.default_queue_filter() == "needs_reply"
      assert Threads.default_queue_filter() in Threads.queue_filters()
    end
  end

  # One thread of every kind the filters tell apart: each state, snoozed,
  # with a task that is due, open or done, and the same again for a sender
  # staff ignore.
  defp insert_queue_world(c) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    later = DateTime.add(now, 86_400)
    ignored = insert_contact(organization_id: c.org.id)
    heard = insert_contact(organization_id: c.org.id)

    thread = fn attrs -> insert_thread([organization_id: c.org.id] ++ attrs) end

    task = fn thread, attrs ->
      {:ok, task} = Threads.create_task(Map.merge(%{title: "Task", thread_id: thread.id}, attrs))
      task
    end

    threads = %{
      new: thread.(state: :new),
      active: thread.(state: :active, contact_id: heard.id),
      answered: thread.(state: :active),
      waiting: thread.(state: :waiting),
      dormant: thread.(state: :dormant),
      resolved: thread.(state: :resolved),
      snoozed: thread.(state: :active, snoozed_until: later),
      open_task: thread.(state: :active),
      due_task: thread.(state: :waiting),
      done_task: thread.(state: :active),
      resolved_open_task: thread.(state: :resolved),
      resolved_due_task: thread.(state: :resolved, contact_id: heard.id),
      snoozed_open_task: thread.(state: :new, snoozed_until: later),
      snoozed_due_task: thread.(state: :active, snoozed_until: later),
      ignored: thread.(state: :new, contact_id: ignored.id),
      ignored_snoozed: thread.(state: :active, contact_id: ignored.id, snoozed_until: later),
      ignored_resolved: thread.(state: :resolved, contact_id: ignored.id),
      ignored_due_task: thread.(state: :active, contact_id: ignored.id),
      ignored_open_task: thread.(state: :waiting, contact_id: ignored.id),
      ignored_resolved_due_task: thread.(state: :resolved, contact_id: ignored.id)
    }

    insert_message(thread_id: threads.answered.id, body: "Question")
    insert_message(thread_id: threads.answered.id, source: :staff, body: "Answer")

    for key <- [:open_task, :resolved_open_task, :snoozed_open_task, :ignored_open_task] do
      task.(threads[key], %{})
    end

    for key <-
          [:due_task, :resolved_due_task, :snoozed_due_task] ++
            [:ignored_due_task, :ignored_resolved_due_task] do
      task.(threads[key], %{due_at: DateTime.add(now, -60)})
    end

    # A deadline that has not come yet is an open task, not a due one.
    task.(threads.open_task, %{due_at: later})
    {:ok, _} = threads.done_task |> task.(%{}) |> Threads.update_task_state(:done)

    ignore(ignored)
    threads
  end

  # The mark staff leave on a sender they ignore.
  defp ignore(contact, at \\ DateTime.utc_now(:second)) do
    Repo.update!(Custyard.Contact.ignore_changeset(contact, at))
  end

  defp listed(scope, opts) do
    scope |> Threads.list(opts) |> Enum.map(& &1.thread.id)
  end

  defp keys(threads, ids) do
    names = Map.new(threads, fn {name, thread} -> {thread.id, name} end)
    ids |> Enum.map(&Map.fetch!(names, &1)) |> Enum.sort()
  end

  describe "what each filter lists" do
    setup c do
      {:ok, threads: insert_queue_world(c)}
    end

    test "an ignored sender's threads are listed by the ignored filter only", c do
      ignored =
        ~w(ignored ignored_snoozed ignored_due_task ignored_open_task ignored_resolved ignored_resolved_due_task)a

      for filter <- Threads.queue_filters() -- ["ignored"] do
        names = keys(c.threads, listed(c.scope, filter: filter))
        assert names -- ignored == names, "filter #{filter} lists an ignored sender"
        assert names != [], "filter #{filter}"
      end

      # Unresolved ones, snoozed or not. A due task does not bring back a
      # resolved one.
      assert keys(c.threads, listed(c.scope, filter: "ignored")) ==
               ~w(ignored ignored_due_task ignored_open_task ignored_snoozed)a
    end

    test "open_tasks lists every thread with an unfinished task", c do
      assert keys(c.threads, listed(c.scope, filter: "open_tasks")) ==
               Enum.sort(
                 ~w(open_task due_task resolved_open_task resolved_due_task snoozed_open_task snoozed_due_task)a
               )

      rows = Map.new(Threads.list(c.scope, filter: "open_tasks"), &{&1.thread.id, &1})

      # Two unfinished tasks, neither at its deadline yet.
      assert %{open_task_count: 2, due_task_count: 0} = rows[c.threads.open_task.id]
      assert %{open_task_count: 1, due_task_count: 1} = rows[c.threads.due_task.id]

      # A finished task is not outstanding work.
      refute Map.has_key?(rows, c.threads.done_task.id)

      all = Map.new(Threads.list(c.scope), &{&1.thread.id, &1})
      assert %{open_task_count: 0, due_task_count: 0} = all[c.threads.done_task.id]
    end

    test "due_tasks still lists only threads with a task at its deadline", c do
      assert keys(c.threads, listed(c.scope, filter: "due_tasks")) ==
               ~w(due_task resolved_due_task snoozed_due_task)a
    end

    test "a task without a deadline does not bring a resolved or snoozed thread back", c do
      working = keys(c.threads, listed(c.scope, filter: "all"))

      refute :resolved_open_task in working
      refute :snoozed_open_task in working
      assert :resolved_due_task in working
      assert :snoozed_due_task in working
    end

    test "resolved lists resolved threads", c do
      assert keys(c.threads, listed(c.scope, filter: "resolved")) ==
               ~w(resolved resolved_due_task resolved_open_task)a
    end

    test "every count equals the length of its list, with and without a label", c do
      {:ok, label} = Labels.create_and_assign(c.scope, c.threads.active, "Billing")

      for key <- ~w(resolved snoozed open_task resolved_due_task ignored ignored_resolved)a do
        {:ok, _} = Labels.assign(c.scope, c.threads[key], label.id)
      end

      for opts <- [[], [label_id: label.id]] do
        counts = Threads.queue_counts(c.scope, opts)
        assert Map.keys(counts) |> Enum.sort() == Enum.sort(Threads.queue_filters())

        for filter <- Threads.queue_filters() do
          assert counts[filter] == length(Threads.list(c.scope, [filter: filter] ++ opts)),
                 "filter #{filter} with #{inspect(opts)}"
        end
      end

      assert %{"ignored" => 1, "resolved" => 2, "open_tasks" => 2, "all" => 3} =
               Threads.queue_counts(c.scope, label_id: label.id)
    end

    test "a sender who is no longer ignored is listed where the threads belong", c do
      Custyard.Contact |> Repo.get!(c.threads.ignored.contact_id) |> ignore(nil)

      assert listed(c.scope, filter: "ignored") == []
      assert Threads.queue_counts(c.scope)["ignored"] == 0

      assert c.threads.ignored.id in listed(c.scope, filter: "needs_reply")
      assert c.threads.ignored_snoozed.id in listed(c.scope, filter: "snoozed")
      assert c.threads.ignored_due_task.id in listed(c.scope, filter: "due_tasks")
      assert c.threads.ignored_open_task.id in listed(c.scope, filter: "open_tasks")
      assert c.threads.ignored_resolved.id in listed(c.scope, filter: "resolved")
      assert c.threads.ignored_resolved_due_task.id in listed(c.scope, filter: "all")
    end
  end

  describe "reverse order" do
    setup c do
      {:ok, threads: insert_queue_world(c)}
    end

    test "list/2 and queue_ids/2 return exactly the opposite order for every filter", c do
      {:ok, label} = Labels.create_and_assign(c.scope, c.threads.active, "Billing")
      {:ok, _} = Labels.assign(c.scope, c.threads.new, label.id)
      {:ok, _} = Labels.assign(c.scope, c.threads.due_task, label.id)

      for filter <- Threads.queue_filters(), opts <- [[], [label_id: label.id]] do
        opts = [filter: filter] ++ opts
        forward = listed(c.scope, opts)

        assert listed(c.scope, opts ++ [reverse: true]) == Enum.reverse(forward),
               "list with #{inspect(opts)}"

        assert Threads.queue_ids(c.scope, opts ++ [reverse: true]) == Enum.reverse(forward),
               "queue_ids with #{inspect(opts)}"

        assert Threads.queue_ids(c.scope, opts ++ [reverse: false]) == forward
      end

      # Enough rows that an order can be told from its reverse.
      assert length(listed(c.scope, filter: "all")) > 3
    end
  end

  describe "resolved filter order" do
    test "most recently updated first, and reverse flips it", c do
      at = fn thread, seconds_ago ->
        Repo.update_all(
          from(t in Custyard.Thread, where: t.id == ^thread.id),
          set: [updated_at: DateTime.add(DateTime.utc_now(:second), -seconds_ago)]
        )

        thread.id
      end

      # Scores would order these the other way round.
      oldest =
        at.(insert_thread(organization_id: c.org.id, state: :resolved, cached_score: 90), 300)

      newest =
        at.(insert_thread(organization_id: c.org.id, state: :resolved, cached_score: 10), 10)

      middle =
        at.(insert_thread(organization_id: c.org.id, state: :resolved, cached_score: 50), 100)

      insert_thread(organization_id: c.org.id, state: :active)

      assert listed(c.scope, filter: "resolved") == [newest, middle, oldest]
      assert Threads.queue_ids(c.scope, filter: "resolved") == [newest, middle, oldest]
      assert listed(c.scope, filter: "resolved", reverse: true) == [oldest, middle, newest]
    end

    test "threads updated in the same second list the newer one first", c do
      stamp = DateTime.add(DateTime.utc_now(:second), -60)

      [first, second] =
        for _ <- 1..2, do: insert_thread(organization_id: c.org.id, state: :resolved).id

      Repo.update_all(from(t in Custyard.Thread, where: t.id in ^[first, second]),
        set: [updated_at: stamp]
      )

      assert listed(c.scope, filter: "resolved") == [second, first]
    end
  end

  describe "needs_reply filter" do
    setup c do
      later = DateTime.utc_now() |> DateTime.add(86_400) |> DateTime.truncate(:second)
      thread = fn attrs -> insert_thread([organization_id: c.org.id] ++ attrs) end
      customer = fn t -> insert_message(thread_id: t.id, body: "From the customer") end
      staff = fn t -> insert_message(thread_id: t.id, source: :staff, body: "From staff") end

      note = fn t ->
        insert_message(thread_id: t.id, source: :staff, is_internal_note: true, body: "Memo")
      end

      auto = fn t ->
        insert_message(thread_id: t.id, body: "Out of office", triage_class: :auto_response)
      end

      mailbox = fn t ->
        insert_message(thread_id: t.id, body: "Sent from my mailbox", triage_class: :staff_sent)
      end

      # {name, thread attrs, messages in order, needs a reply?}
      cases = [
        {:unanswered, [state: :new], [customer], true},
        {:no_messages, [state: :active], [], true},
        {:only_notes, [state: :active], [note], true},
        {:customer_after_reply, [state: :active], [customer, staff, customer], true},
        {:note_after_customer, [state: :active], [customer, note], true},
        {:dormant_customer_last, [state: :dormant], [staff, customer], true},
        {:staff_replied, [state: :active], [customer, staff], false},
        {:replied_from_mailbox, [state: :active], [customer, mailbox], false},
        {:auto_reply_after_reply, [state: :active], [customer, staff, auto], false},
        {:note_after_reply, [state: :active], [customer, staff, note], false},
        {:parked_waiting, [state: :waiting], [customer], false},
        {:resolved, [state: :resolved], [customer], false},
        {:snoozed, [state: :active, snoozed_until: later], [customer], false}
      ]

      threads =
        Map.new(cases, fn {name, attrs, messages, _needs_reply?} ->
          t = thread.(attrs)
          Enum.each(messages, & &1.(t))
          {name, t}
        end)

      expected =
        for {name, _attrs, _messages, true} <- cases, into: MapSet.new(), do: threads[name].id

      {:ok, threads: threads, expected: expected}
    end

    test "lists the threads where the customer is waiting on staff", c do
      listed = Threads.list(c.scope, filter: "needs_reply")

      assert MapSet.new(listed, & &1.thread.id) == c.expected
      assert Threads.queue_counts(c.scope)["needs_reply"] == MapSet.size(c.expected)
    end

    test "agrees with the turn shown on each row", c do
      rows = Threads.list(c.scope)
      previews = Threads.queue_previews(c.scope, Enum.map(rows, & &1.thread.id))

      ours =
        for %{thread: thread} <- rows,
            QueuePreview.turn(thread, previews[thread.id]) == :ours,
            into: MapSet.new(),
            do: thread.id

      assert ours == c.expected
      assert ours == MapSet.new(Threads.list(c.scope, filter: "needs_reply"), & &1.thread.id)
    end

    test "combines with the label filter and stays inside the tenant", c do
      {:ok, label} = Labels.create_and_assign(c.scope, c.threads.unanswered, "Billing")
      {:ok, _} = Labels.assign(c.scope, c.threads.staff_replied, label.id)

      assert [%{thread: %{id: id}}] =
               Threads.list(c.scope, filter: "needs_reply", label_id: label.id)

      assert id == c.threads.unanswered.id
      assert Threads.queue_counts(c.scope, label_id: label.id)["needs_reply"] == 1

      other_tenant = insert_tenant()
      other_staff = insert_staff_account(role: "admin", tenant_id: other_tenant.id)
      other_scope = Custyard.Scope.for_staff(other_staff, other_tenant)
      assert Threads.list(other_scope, filter: "needs_reply") == []
    end

    test "a snoozed thread with a due task is listed like in every other view", c do
      {:ok, _} =
        Threads.create_task(%{
          title: "Overdue",
          thread_id: c.threads.snoozed.id,
          due_at: DateTime.utc_now() |> DateTime.add(-60) |> DateTime.truncate(:second)
        })

      ids = MapSet.new(Threads.list(c.scope, filter: "needs_reply"), & &1.thread.id)
      assert c.threads.snoozed.id in ids
      assert Threads.queue_counts(c.scope)["needs_reply"] == MapSet.size(ids)
    end
  end

  describe "row message counts" do
    test "exchange_count leaves out internal notes and automatic replies", c do
      thread = insert_thread(organization_id: c.org.id, state: :active)
      insert_message(thread_id: thread.id, body: "Question")
      insert_message(thread_id: thread.id, source: :staff, body: "Answer")
      insert_message(thread_id: thread.id, source: :staff, is_internal_note: true, body: "Memo")
      insert_message(thread_id: thread.id, body: "Away", triage_class: :auto_response)

      empty = insert_thread(organization_id: c.org.id, state: :active)

      rows = Map.new(Threads.list(c.scope), &{&1.thread.id, &1})
      assert %{message_count: 4, exchange_count: 2} = rows[thread.id]
      assert %{message_count: 0, exchange_count: 0} = rows[empty.id]
    end

    test "recent_count is the 24h count the score's velocity term uses", c do
      thread = insert_thread(organization_id: c.org.id, state: :active)
      old = insert_message(thread_id: thread.id, body: "Last week")
      insert_message(thread_id: thread.id, body: "Today")
      insert_message(thread_id: thread.id, source: :staff, is_internal_note: true, body: "Memo")
      insert_message(thread_id: thread.id, body: "Away", triage_class: :auto_response)

      Custyard.Repo.update_all(
        from(m in Custyard.Message, where: m.id == ^old.id),
        set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -8, :day)]
      )

      rows = Map.new(Threads.list(c.scope), &{&1.thread.id, &1})
      row = rows[thread.id]
      assert %{message_count: 4, recent_count: 2} = row

      # What the queue shows under "Why this rank?" is what the score is built from.
      assert Custyard.Scoring.breakdown(thread, message_count: row.recent_count) ==
               Custyard.Scoring.breakdown(thread)
    end
  end

  describe "queue_ids/2" do
    test "returns the ids of list/2 in the same order for every filter", c do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      # Equal scores throughout: only the id tie-break orders these.
      for state <- [:new, :active, :active, :waiting, :dormant, :new] do
        insert_thread(organization_id: c.org.id, state: state, cached_score: 40)
      end

      top = insert_thread(organization_id: c.org.id, state: :active, cached_score: 90)
      due = insert_thread(organization_id: c.org.id, state: :active, cached_score: 1)

      {:ok, _} =
        Threads.create_task(%{title: "Due", thread_id: due.id, due_at: DateTime.add(now, -60)})

      # Answered, so only the message facts keep it out of "needs_reply".
      insert_message(thread_id: top.id, body: "Question")
      insert_message(thread_id: top.id, source: :staff, body: "Answer")

      insert_thread(
        organization_id: c.org.id,
        state: :active,
        cached_score: 40,
        snoozed_until: DateTime.add(now, 86_400)
      )

      insert_thread(organization_id: c.org.id, state: :resolved, cached_score: 40)

      # The highest score of all, and listed under "ignored" only.
      contact = insert_contact(organization_id: c.org.id)

      muted =
        insert_thread(
          organization_id: c.org.id,
          state: :active,
          cached_score: 99,
          contact_id: contact.id
        )

      ignore(contact)

      for filter <- Threads.queue_filters() do
        listed = Threads.list(c.scope, filter: filter) |> Enum.map(& &1.thread.id)
        assert listed != [], "filter #{filter}"
        assert Threads.queue_ids(c.scope, filter: filter) == listed, "filter #{filter}"
      end

      assert Threads.queue_ids(c.scope, filter: "ignored") == [muted.id]
      refute top.id in Threads.queue_ids(c.scope, filter: "needs_reply")

      all = Threads.queue_ids(c.scope)
      assert Enum.take(all, 2) == [due.id, top.id]
      assert Enum.drop(all, 2) == Enum.sort(Enum.drop(all, 2))
    end

    test "is empty for a revoked scope and never crosses tenants", c do
      own = insert_thread(organization_id: c.org.id, state: :active)
      foreign_tenant = insert_tenant()
      insert_thread(tenant_id: foreign_tenant.id, source: :public_intake, state: :new)

      assert Threads.queue_ids(c.scope) == [own.id]

      Repo.delete!(c.staff)
      assert Threads.queue_ids(c.scope) == []
    end

    test "reads the message facts only for the filter that needs them", c do
      thread = insert_thread(organization_id: c.org.id, state: :active)
      insert_message(thread_id: thread.id, body: "Question")

      ref = make_ref()
      test_pid = self()

      :telemetry.attach(
        "queue-ids-queries-#{inspect(ref)}",
        [:custyard, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if self() == test_pid, do: send(test_pid, {ref, metadata.query})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("queue-ids-queries-#{inspect(ref)}") end)

      for filter <- Threads.queue_filters() do
        Threads.queue_ids(c.scope, filter: filter)

        queries =
          Stream.repeatedly(fn ->
            receive do
              {^ref, sql} -> sql
            after
              0 -> nil
            end
          end)
          |> Enum.take_while(& &1)

        assert Enum.any?(queries, &(&1 =~ ~s("threads"))), "filter #{filter}"

        assert Enum.any?(queries, &(&1 =~ ~s("messages"))) == (filter == "needs_reply"),
               "filter #{filter}"
      end
    end
  end

  describe "QueueNav.neighbors/4" do
    test "finds the neighbors of a listed conversation" do
      assert QueueNav.neighbors([10, 20, 30], 20) == %{
               prev: %{id: 10, pos: 0, after: [], before: [20, 30]},
               next: %{id: 30, pos: 2, after: [20, 10], before: []},
               position: 2,
               total: 3,
               place: %{pos: 1, after: [10], before: [30]}
             }

      assert %{prev: nil, next: %{id: 20, pos: 1}, position: 1} =
               QueueNav.neighbors([10, 20, 30], 10)

      assert %{prev: %{id: 20, pos: 1}, next: nil, position: 3} =
               QueueNav.neighbors([10, 20, 30], 30)
    end

    test "a hint that matches the current place changes nothing" do
      assert QueueNav.neighbors([10, 20, 30], 20, 1) == QueueNav.neighbors([10, 20, 30], 20)
    end

    test "keeps the place it was opened at when opening made it sink in the queue" do
      # 20 was second (position 1). Opening it dropped its score to the end.
      assert QueueNav.neighbors([10, 30, 40, 20], 20, 1) == %{
               prev: %{id: 10, pos: 0, after: [], before: [30, 40, 20]},
               next: %{id: 30, pos: 1, after: [10], before: [40, 20]},
               position: 2,
               total: 4,
               place: %{pos: 1, after: [10], before: [30, 40]}
             }

      # And when it rose instead.
      assert %{prev: %{id: 30, pos: 2}, next: %{id: 40, pos: 3}} =
               QueueNav.neighbors([20, 10, 30, 40], 20, 2)
    end

    test "follows the conversation listed before it when the queue changed above" do
      # The queue was 10..50 and 20 was being read: its link to 30 says third,
      # after 20 and before 40.
      link = [after: 20, before: 40]

      # A colleague resolved 10 meanwhile, so 30 is second.
      assert QueueNav.neighbors([20, 30, 40, 50], 30, 2, link) == %{
               prev: %{id: 20, pos: 0, after: [], before: [30, 40, 50]},
               next: %{id: 40, pos: 2, after: [30, 20], before: [50]},
               position: 2,
               total: 4,
               place: %{pos: 1, after: [20], before: [40, 50]}
             }

      # Or a new conversation arrived on top, so 30 is fourth and 20 is behind it.
      assert %{prev: %{id: 20}, next: %{id: 40}, position: 4, total: 6} =
               QueueNav.neighbors([5, 10, 20, 30, 40, 50], 30, 2, link)

      # Opening 30 also made it sink: the anchor still gives the place it had.
      assert %{prev: %{id: 20}, next: %{id: 40}, position: 2, total: 4} =
               QueueNav.neighbors([20, 40, 50, 30], 30, 2, link)
    end

    test "falls back to the conversation listed after it, then to the position" do
      # A first row has nothing before it. A new conversation arrived on top:
      # it is offered next, not passed by.
      assert %{prev: nil, next: %{id: 5}, position: 1} =
               QueueNav.neighbors([5, 10, 20, 30], 10, 0, before: 20)

      # The conversation listed after a first row sank instead: a colleague
      # opened it. What followed it is next.
      assert %{prev: nil, next: %{id: 30}, position: 1} =
               QueueNav.neighbors([30, 40, 20, 10], 10, 0, before: 20)

      # "new" filter: a colleague opened 10, opening 30 took it out as well.
      assert %{prev: nil, next: %{id: 40}, position: 1} =
               QueueNav.neighbors([40, 50], 30, 1, after: 10, before: 40)

      # Both have left: the position is all there is.
      assert QueueNav.neighbors([10, 50], 30, 1, after: 20, before: 40) ==
               QueueNav.neighbors([10, 50], 30, 1)
    end

    test "anchors that moved point at different places" do
      # The queue was 10..50 and 30 was third, after 20 and before 40.
      place = [after: 20, before: 40]

      # A colleague replied to 20, which sank; then 30 sank the same way.
      assert %{prev: %{id: 10}, next: %{id: 40}, position: 2, total: 5} =
               QueueNav.neighbors([10, 40, 50, 20, 30], 30, 2, place)

      # 20 sank and 30 stayed where it was.
      assert %{prev: %{id: 10}, next: %{id: 40}, position: 2} =
               QueueNav.neighbors([10, 30, 40, 50, 20], 30, 2, place)

      # The customer of 20 wrote again, which raised it to the top.
      assert %{prev: %{id: 10}, next: %{id: 40}, position: 3} =
               QueueNav.neighbors([20, 10, 40, 50, 30], 30, 2, place)

      # 40 sank instead: what followed it is next.
      assert %{prev: %{id: 20}, next: %{id: 50}, position: 3} =
               QueueNav.neighbors([10, 20, 50, 40, 30], 30, 2, place)
    end

    test "a conversation that arrived between the witnesses is offered next" do
      place = [after: 20, before: 40]

      assert %{prev: %{id: 20}, next: %{id: 25}, position: 3, total: 6} =
               QueueNav.neighbors([10, 20, 25, 30, 40, 50], 30, 2, place)

      # The same when 30 has left the list ("new" filter).
      assert %{prev: %{id: 20}, next: %{id: 25}} =
               QueueNav.neighbors([10, 20, 25, 40, 50], 30, 2, place)

      # No position to go by: the earliest place that fits.
      assert %{prev: %{id: 20}, next: %{id: 60}} =
               QueueNav.neighbors([20, 60, 70, 40], 30, nil, place)
    end

    test "a witness that moved is outvoted by the others" do
      # Third of five, remembered with two witnesses on each side. 40 rose to
      # the top and 20 sank to the end.
      assert %{prev: %{id: 10}, next: %{id: 50}, position: 3} =
               QueueNav.neighbors([40, 10, 30, 50, 20], 30, 2, after: [20, 10], before: [40, 50])

      # Fourth of five. 30 left the queue and 50 rose to the top.
      assert %{prev: %{id: 20}, next: nil, position: 4} =
               QueueNav.neighbors([50, 10, 20, 40], 40, 3, after: [30, 20, 10], before: [50])
    end

    test "place/2 names the witnesses around a row for a link to it" do
      ids = [10, 20, 30, 40, 50, 60, 70, 80, 90]

      assert QueueNav.place(ids, 4) == %{pos: 4, after: [40, 30, 20], before: [60, 70, 80]}
      assert QueueNav.place(ids, 0) == %{pos: 0, after: [], before: [20, 30, 40]}
      assert QueueNav.place(ids, 8) == %{pos: 8, after: [80, 70, 60], before: []}
      assert QueueNav.place([10], 0) == %{pos: 0, after: [], before: []}
    end

    test "the place it returns names the witnesses on each side, nearest first" do
      assert %{place: %{pos: 4, after: [40, 30, 20], before: [60, 70, 80]}} =
               QueueNav.neighbors([10, 20, 30, 40, 50, 60, 70, 80, 90], 50)

      assert %{place: %{pos: 0, after: [], before: [20]}} = QueueNav.neighbors([10, 20], 10)
      assert %{place: nil} = QueueNav.neighbors([10, 20], 30)
    end

    # One conversation arrives, leaves or moves while a reader sits in a gap
    # between the others. Returns the queue afterwards with the gaps that are
    # right: one, or two when the change landed exactly in the reader's gap.
    defp single_changes(others, gap) do
      arrivals =
        for at <- 0..length(others) do
          {List.insert_at(others, at, :arrival), after_insert(gap, at)}
        end

      departures =
        for at <- 0..(length(others) - 1)//1 do
          {List.delete_at(others, at), [after_delete(gap, at)]}
        end

      moves =
        for from <- 0..(length(others) - 1)//1, to <- 0..(length(others) - 1)//1, from != to do
          {mover, rest} = List.pop_at(others, from)
          {List.insert_at(rest, to, mover), after_insert(after_delete(gap, from), to)}
        end

      arrivals ++ departures ++ moves
    end

    defp after_delete(gap, at), do: if(at < gap, do: gap - 1, else: gap)
    defp after_insert(gap, at) when at < gap, do: [gap + 1]
    defp after_insert(gap, at) when at > gap, do: [gap]
    defp after_insert(gap, _at), do: [gap, gap + 1]

    test "after any one change it is right wherever the position alone is, and more often" do
      results =
        for size <- 1..6, gap <- 0..size, others = Enum.to_list(1..size) do
          # What a link carries, and the least it can: one witness a side.
          %{after: before_gap, before: after_gap} = QueueNav.neighbors(others, 0, gap).place

          places = [
            [after: before_gap, before: after_gap],
            [after: Enum.take(before_gap, 1), before: Enum.take(after_gap, 1)]
          ]

          for {queue, right} <- single_changes(others, gap), place <- places do
            # The reader's conversation is 0 and no longer listed itself.
            by_position = QueueNav.neighbors(queue, 0, gap).place.pos in right
            placed = QueueNav.neighbors(queue, 0, gap, place).place.pos in right

            assert placed or not by_position,
                   "#{inspect(others)} gap #{gap} became #{inspect(queue)}: wrong where the position alone is right"

            {by_position, placed}
          end
        end
        |> List.flatten()

      wrong = fn index -> Enum.count(results, &(not elem(&1, index))) end
      assert wrong.(1) * 4 < wrong.(0)
    end

    test "an anchor that is not listed counts as no anchor" do
      ids = [10, 20, 30]

      # An id from somewhere else, such as another tenant, or its own id.
      for anchors <- [[after: 99], [before: 99], [after: 99, before: 98], [after: 20, before: 20]] do
        assert QueueNav.neighbors(ids, 20, 1, anchors) == QueueNav.neighbors(ids, 20, 1)
        assert QueueNav.neighbors(ids, 20, nil, anchors) == QueueNav.neighbors(ids, 20)
      end

      assert QueueNav.neighbors(ids, 20, 1, after: nil, before: nil) ==
               QueueNav.neighbors(ids, 20, 1)

      assert QueueNav.neighbors([10, 30], 20, nil, after: 99, before: 98) ==
               %{prev: nil, next: nil, position: nil, total: 2, place: nil}
    end

    test "uses the position hint once the conversation has left the list" do
      # 20 was second (position 1) and is gone: 30 now sits where it was.
      assert QueueNav.neighbors([10, 30, 40], 20, 1) == %{
               prev: %{id: 10, pos: 0, after: [], before: [30, 40]},
               next: %{id: 30, pos: 1, after: [10], before: [40]},
               position: 2,
               total: 3,
               place: %{pos: 1, after: [10], before: [30, 40]}
             }

      assert %{prev: nil, next: %{id: 10, pos: 0}, position: 1} =
               QueueNav.neighbors([10, 30], 20, 0)

      # A hint past the end stops at the end.
      assert %{prev: %{id: 30, pos: 1}, next: nil, position: 2} =
               QueueNav.neighbors([10, 30], 20, 9)
    end

    test "offers nothing without a hint or without a queue" do
      assert %{prev: nil, next: nil, position: nil, total: 2, place: nil} =
               QueueNav.neighbors([10, 30], 20)

      assert %{prev: nil, next: nil, position: nil, total: 0} = QueueNav.neighbors([], 20, 3)
    end
  end
end
