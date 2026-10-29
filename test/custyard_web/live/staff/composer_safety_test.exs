defmodule CustyardWeb.Staff.ComposerSafetyTest do
  use CustyardWeb.ConnCase, async: true
  import Custyard.Factory
  import Phoenix.LiveViewTest
  alias Custyard.{Message, Repo}
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
end
