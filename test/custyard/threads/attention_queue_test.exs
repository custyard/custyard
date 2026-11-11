defmodule Custyard.Threads.AttentionQueueTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Labels, Threads}
  alias Custyard.Threads.QueuePreview

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

      assert counts == %{
               "all" => 8,
               "new" => 2,
               "active" => 2,
               "waiting" => 2,
               "dormant" => 1,
               "snoozed" => 2,
               "due_tasks" => 2
             }

      for {filter, count} <- counts do
        assert length(Threads.list(c.scope, filter: filter)) == count, "filter #{filter}"
      end
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
      assert %{"all" => 0, "new" => 0, "due_tasks" => 0} = Threads.queue_counts(c.scope)
    end
  end
end
