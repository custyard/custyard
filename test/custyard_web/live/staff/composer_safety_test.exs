defmodule CustyardWeb.Staff.ComposerSafetyTest do
  use CustyardWeb.ConnCase, async: true
  import Custyard.Factory
  import Phoenix.LiveViewTest
  alias Custyard.{Message, MessageDrafts, Repo, Scope, Tenants, Threads}
  require Ecto.Query

  setup %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    channel = insert_inbound_channel(state: :active)
    org = insert_organization()
    contact = insert_contact(organization_id: org.id)

    thread =
      insert_thread(
        organization_id: org.id,
        contact_id: contact.id,
        inbound_channel_id: channel.id
      )

    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    %{conn: conn, thread: thread, channel: channel, staff: staff}
  end

  test "reply and private-note drafts survive reconnect without sharing text", c do
    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")

    view
    |> form("#staff-reply-form", body: "Unsent reply", cc: "review@example.org")
    |> render_change()

    view |> element("[data-testid=composer-mode-note]") |> render_click()
    view |> form("#staff-note-form", body: "Private draft") |> render_change()
    {:ok, restored, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(restored, "#staff-reply-textarea", "Unsent reply")
    assert has_element?(restored, "[data-testid=draft-status]", "restored")
    restored |> element("[data-testid=composer-mode-note]") |> render_click()
    assert has_element?(restored, "#staff-note-input", "Private draft")
    refute has_element?(restored, "#staff-reply-textarea")
  end

  test "new activity blocks a stale reply until explicitly reviewed", c do
    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    view |> form("#staff-reply-form", body: "Draft reply") |> render_change()

    insert_message(
      thread_id: c.thread.id,
      body: "New customer context",
      source: :email,
      sender_email: "new@example.org"
    )

    view |> form("#staff-reply-form", body: "Draft reply") |> render_submit()
    assert has_element?(view, "[data-testid=conversation-needs-review]")
    refute Repo.exists?(Ecto.Query.from(m in Message, where: m.source == :staff))
    view |> element("button[phx-click=review_latest_activity]") |> render_click()
    view |> form("#staff-reply-form", body: "Reviewed reply") |> render_submit()

    assert Repo.exists?(
             Ecto.Query.from(m in Message,
               where: m.body == "Reviewed reply" and m.author_staff_id == ^c.staff.id
             )
           )

    refute has_element?(view, "[data-testid=conversation-needs-review]")
  end

  test "two tabs do not overwrite a private draft", c do
    {:ok, first, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    {:ok, second, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    first |> form("#staff-reply-form", body: "Keep this") |> render_change()
    second |> form("#staff-reply-form", body: "Other draft") |> render_change()
    assert has_element?(second, "[data-testid=draft-status]", "another tab")
    second |> form("#staff-reply-form", body: "Other draft") |> render_submit()
    refute Repo.exists?(Ecto.Query.from(m in Message, where: m.source == :staff))
  end

  test "a tab cannot directly submit after another tab changes the saved draft", c do
    {:ok, first, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    first |> form("#staff-reply-form", body: "Version one") |> render_change()
    {:ok, stale, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    first |> form("#staff-reply-form", body: "Version two") |> render_change()
    stale |> form("#staff-reply-form", body: "Version one") |> render_submit()
    assert has_element?(stale, "[data-testid=draft-status]", "another tab")
    refute Repo.exists?(Ecto.Query.from(m in Message, where: m.source == :staff))
  end

  test "reconnecting after a committed reply does not restore it as a draft", c do
    scope = Scope.for_staff(c.staff, Tenants.get_tenant!(c.staff.tenant_id))

    {:ok, draft} =
      MessageDrafts.save(
        scope,
        c.thread.id,
        %{reply_text: "Already submitted reply", note_text: "Still private and unsent"},
        0
      )

    # Simulate the LiveView dying immediately after the context commits.
    # There is deliberately no UI callback or later draft-persistence call.
    assert {:ok, _} =
             Threads.send_reply(c.thread, "Already submitted reply",
               staff: c.staff,
               expected_draft_version: draft.lock_version,
               reply_channel_id: c.channel.id
             )

    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    refute has_element?(view, "#staff-reply-textarea", "Already submitted reply")
    view |> element("[data-testid=composer-mode-note]") |> render_click()
    assert has_element?(view, "#staff-note-input", "Still private and unsent")
  end

  test "reconnecting after a saved note does not restore it over an unsent reply", c do
    scope = Scope.for_staff(c.staff, Tenants.get_tenant!(c.staff.tenant_id))

    {:ok, draft} =
      MessageDrafts.save(
        scope,
        c.thread.id,
        %{reply_text: "Still unsent reply", note_text: "Already saved private note"},
        0
      )

    assert {:ok, _} =
             Threads.add_internal_note(c.thread, "Already saved private note",
               staff: c.staff,
               expected_draft_version: draft.lock_version
             )

    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(view, "#staff-reply-textarea", "Still unsent reply")
    view |> element("[data-testid=composer-mode-note]") |> render_click()
    refute has_element?(view, "#staff-note-input", "Already saved private note")
  end

  test "the live composer adopts the submission version for its next private edit", c do
    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    view |> form("#staff-reply-form", body: "First reply") |> render_change()
    view |> form("#staff-reply-form", body: "First reply") |> render_submit()
    view |> form("#staff-reply-form", body: "Next unsent reply") |> render_change()
    assert has_element?(view, "[data-testid=draft-status]", "Draft saved privately")
    {:ok, restored, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(restored, "#staff-reply-textarea", "Next unsent reply")
  end

  test "a CC-only draft survives reconnect before a reply body is written", c do
    insert_customer_cc(c, "default@example.org")
    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(view, "input[name=cc][value='default@example.org']")
    view |> form("#staff-reply-form", body: "", cc: "chosen@example.org") |> render_change()
    {:ok, restored, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(restored, "input[name=cc][value='chosen@example.org']")
    refute has_element?(restored, "#staff-reply-textarea", "Already submitted")
  end

  test "choosing nobody in CC survives reconnect even before writing a body", c do
    insert_customer_cc(c, "default@example.org")
    {:ok, view, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    view |> form("#staff-reply-form", body: "", cc: "") |> render_change()
    insert_customer_cc(c, "new-default@example.org")
    {:ok, restored, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(restored, "input[name=cc][value='']")
  end

  test "a submitted draft receipt restores current reply-all defaults", c do
    insert_customer_cc(c, "original-default@example.org")
    scope = Scope.for_staff(c.staff, Tenants.get_tenant!(c.staff.tenant_id))

    {:ok, draft} =
      MessageDrafts.save(
        scope,
        c.thread.id,
        %{reply_text: "Submitted reply", reply_cc: "chosen-for-old-reply@example.org"},
        0
      )

    assert {:ok, _} =
             Threads.send_reply(c.thread, "Submitted reply",
               staff: c.staff,
               expected_draft_version: draft.lock_version,
               reply_channel_id: c.channel.id
             )

    insert_customer_cc(c, "new-default@example.org")
    {:ok, restored, _} = live(c.conn, "/app/threads/#{c.thread.id}")
    assert has_element?(restored, "input[name=cc][value='new-default@example.org']")
    refute has_element?(restored, "#staff-reply-textarea", "Submitted reply")
  end

  defp insert_customer_cc(c, cc) do
    contact = Repo.get!(Custyard.Contact, c.thread.contact_id)

    insert_message(
      thread_id: c.thread.id,
      source: :email,
      sender_email: contact.email,
      cc_addresses: [cc],
      to_addresses: [c.channel.public_address]
    )
  end
end
