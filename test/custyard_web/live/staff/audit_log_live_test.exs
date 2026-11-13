defmodule CustyardWeb.Staff.AuditLogLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory
  import Ecto.Query, only: [from: 2]

  alias Custyard.{AuditLog, Repo, Scope, Tenants, Thread, Threads}
  alias CustyardWeb.Staff.AuditLogLive

  @path "/app/settings/audit"
  @sender "sender@acme.test"

  # What the "filters" tests list, newest first: a workspace event after a
  # state change, and one mail event.
  @actions ["Paused outbound replies", "Changed the state from active to waiting"]
  @mail ["Received an inbound message"]

  defp sign_in(conn, role, attrs \\ []) do
    staff = insert_staff_account([role: role] ++ attrs)
    conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> put_staff_session(staff)
    scope = Scope.for_staff(staff, Tenants.get_tenant!(staff.tenant_id))
    %{conn: conn, staff: staff, scope: scope}
  end

  defp document(view), do: view |> render() |> Floki.parse_fragment!()

  # The timeline as the page lists it, newest first. A link is {text, href},
  # nil when the row has none.
  defp rows(view) do
    for row <- Floki.find(document(view), "[data-testid=audit-timeline] > li") do
      %{
        actor: text(row, "audit-entry-actor"),
        summary: text(row, "audit-entry-summary"),
        thread: link(row, "audit-entry-thread"),
        customer: link(row, "audit-entry-customer")
      }
    end
  end

  defp summaries(view), do: Enum.map(rows(view), & &1.summary)

  # The entry ids in the order the page lists them.
  defp ids(view) do
    ~r/data-testid="audit-entry-(\d+)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
  end

  defp text(node, testid),
    do: node |> Floki.find("[data-testid=#{testid}]") |> Floki.text() |> String.trim()

  defp link(node, testid) do
    case Floki.find(node, "[data-testid=#{testid}]") do
      [] -> nil
      [link | _] -> {link |> Floki.text() |> String.trim(), href(link)}
    end
  end

  defp href(node), do: node |> Floki.attribute("href") |> List.first()

  # The link with this test id anywhere on the page.
  defp page_link(view, testid), do: link(document(view), testid)

  # The test ids of the chips that are pressed.
  defp pressed(view) do
    document(view)
    |> Floki.find("[data-testid=staff-audit-filters] button[aria-pressed=true]")
    |> Enum.flat_map(&Floki.attribute(&1, "data-testid"))
  end

  defp chip(id), do: "[data-testid=staff-audit-filter-#{id}]"
  defp testid(id), do: "[data-testid=#{id}]"

  defp mail_event(thread),
    do: insert_audit_event(event_type: :webhook_received, thread_id: thread.id)

  defp workspace_event,
    do: insert_audit_event(event_type: :outbound_pause_changed, source: "staff")

  # A second tenant with one state change of its own.
  defp other_tenant do
    tenant = insert_tenant(name: "Contoso")
    staff = insert_staff_account(tenant_id: tenant.id, role: "admin", email: "eve@contoso.test")
    org = insert_organization(tenant_id: tenant.id, name: "Other customer")
    thread = insert_thread(organization_id: org.id, state: :active, subject: "Their secret")
    {:ok, _} = Threads.set_state(Scope.for_staff(staff, tenant), thread.id, :waiting)
    %{tenant: tenant, staff: staff, org: org, thread: thread}
  end

  describe "access" do
    test "an agent is sent to the queue", %{conn: conn} do
      %{conn: conn} = sign_in(conn, "agent")

      assert {:error, {:redirect, %{to: "/app"}}} = live(conn, @path)
    end

    test "a signed-out visitor is sent to the login page", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/app/login"}}} = live(conn, @path)
    end

    test "a refusal by the audit log sends the reader to the queue" do
      # The route lets only admins in, so the page's own check is reached by
      # calling it directly, as the slugs page test does.
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_scope: staff_scope(nil, "agent")}
      }

      assert {:noreply, refused} = AuditLogLive.handle_params(%{}, @path, socket)
      assert {:redirect, %{to: "/app"}} = refused.redirected
      refute Map.has_key?(refused.assigns, :entries)
    end
  end

  describe "for an admin" do
    setup %{conn: conn} do
      signed_in = sign_in(conn, "admin", email: "ada@northwind.test")
      org = insert_organization(name: "Acme Fittings")
      contact = insert_contact(organization_id: org.id, email: @sender)

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          state: :active,
          subject: "Refund request"
        )

      Map.merge(signed_in, %{org: org, contact: contact, thread: thread})
    end

    test "a state change names who made it, the conversation and the customer", c do
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :resolved)

      {:ok, view, _html} = live(c.conn, @path)

      assert page_title(view) =~ "Audit log"
      assert view |> element(testid("staff-audit-heading")) |> render() =~ "Audit log"

      assert has_element?(
               view,
               testid("staff-audit-page"),
               "Who did what in this workspace. Times are UTC."
             )

      assert [row] = rows(view)
      assert row.actor == "ada@northwind.test"
      assert row.summary == "Changed the state from active to resolved"
      assert row.thread == {"Refund request", "/app/threads/#{c.thread.id}"}
      # The customer page is opened by the public id, never the row id.
      assert row.customer == {"Acme Fittings", "/app/customers/#{c.org.public_id}"}

      {:ok, _customer_page, html} = live(c.conn, elem(row.customer, 1))
      assert html =~ "Acme Fittings"

      # The plain page has no conversation banner and a single page.
      refute has_element?(view, testid("staff-audit-thread-filter"))
      refute has_element?(view, testid("staff-audit-newest-link"))
      refute has_element?(view, testid("audit-older-link"))
    end

    test "an ignored sender and a dismissal are listed, newest first", c do
      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      {:ok, view, _html} = live(c.conn, @path)

      assert summaries(view) == [
               "Added an internal note",
               "Changed the state from active to resolved",
               "Ignored the sender #{@sender}"
             ]

      assert Enum.all?(rows(view), &(&1.actor == "ada@northwind.test"))
    end

    test "another tenant's events never appear", c do
      other = other_tenant()
      insert_audit_event(tenant_id: other.tenant.id, event_type: :slug_released, source: "staff")
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :resolved)

      for query <- ["", "?filter=everything", "?filter=customers"] do
        {:ok, _view, html} = live(c.conn, @path <> query)

        refute html =~ "Their secret"
        refute html =~ "Other customer"
        refute html =~ "eve@contoso.test"
        refute html =~ "Released"
        refute html =~ ~s(href="/app/threads/#{other.thread.id}")
      end

      {:ok, view, _html} = live(c.conn, @path <> "?filter=everything")
      assert summaries(view) == ["Changed the state from active to resolved"]
    end

    test "with no events the page says so", c do
      {:ok, view, _html} = live(c.conn, @path)

      assert has_element?(view, testid("audit-empty"), "No events to show.")
      refute has_element?(view, testid("audit-timeline"))
      refute has_element?(view, testid("audit-older-link"))
    end

    test "a subject with markup in it is shown as text", c do
      subject = ~s|<script>alert("x")</script>|
      thread = insert_thread(organization_id: c.org.id, state: :active, subject: subject)
      {:ok, _} = Threads.set_state(c.scope, thread.id, :resolved)

      {:ok, view, html} = live(c.conn, @path <> "?thread=#{thread.id}")

      refute html =~ "<script>alert"
      assert html =~ "&lt;script&gt;alert"
      assert Floki.find(document(view), "[data-testid=staff-audit-page] script") == []

      # Once in the banner and once in the row.
      assert page_link(view, "staff-audit-thread-link") == {subject, "/app/threads/#{thread.id}"}
      assert [%{thread: {^subject, _href}}] = rows(view)
    end
  end

  describe "filters" do
    setup %{conn: conn} do
      signed_in = sign_in(conn, "admin")
      thread = insert_thread(state: :active, subject: "Refund request")

      {:ok, _} = Threads.set_state(signed_in.scope, thread.id, :waiting)
      mail_event(thread)
      workspace_event()

      Map.put(signed_in, :thread, thread)
    end

    test "one chip for every filter, in order", c do
      {:ok, view, _html} = live(c.conn, @path)

      chips =
        document(view)
        |> Floki.find("[data-testid=staff-audit-filters] button")
        |> Enum.map(fn chip ->
          {chip |> Floki.attribute("data-testid") |> List.first(),
           chip |> Floki.text() |> String.trim()}
        end)

      assert chips ==
               for(
                 %{id: id, label: label} <- AuditLog.categories(),
                 do: {"staff-audit-filter-#{id}", label}
               )

      assert length(chips) == 7
    end

    test "the default filter is pressed and leaves mail events out", c do
      {:ok, view, _html} = live(c.conn, @path)

      assert pressed(view) == ["staff-audit-filter-actions"]
      assert summaries(view) == @actions
    end

    test "the mail chip patches the address and lists only mail events", c do
      {:ok, view, _html} = live(c.conn, @path)

      view |> element(chip("mail")) |> render_click()

      assert_patch(view, "/app/settings/audit?filter=mail")
      assert pressed(view) == ["staff-audit-filter-mail"]
      assert summaries(view) == @mail

      view |> element(chip("everything")) |> render_click()

      assert_patch(view, "/app/settings/audit?filter=everything")
      assert pressed(view) == ["staff-audit-filter-everything"]

      assert summaries(view) == [
               "Paused outbound replies",
               "Received an inbound message",
               "Changed the state from active to waiting"
             ]

      # The default filter keeps the plain address.
      view |> element(chip("actions")) |> render_click()

      assert_patch(view, "/app/settings/audit")
      assert summaries(view) == @actions
    end

    test "an unknown filter behaves as the default", c do
      for filter <- ["nonsense", "installation", ""] do
        {:ok, view, _html} = live(c.conn, @path <> "?filter=#{filter}")

        assert pressed(view) == ["staff-audit-filter-actions"]
        assert summaries(view) == @actions
      end
    end

    test "a filter event with an unknown filter goes to the default", c do
      {:ok, view, _html} = live(c.conn, @path <> "?filter=mail")

      render_click(view, "filter", %{"filter" => "nonsense"})

      assert_patch(view, "/app/settings/audit")
      assert pressed(view) == ["staff-audit-filter-actions"]
    end
  end

  describe "the events of one conversation" do
    setup %{conn: conn} do
      signed_in = sign_in(conn, "admin")
      org = insert_organization(name: "Acme Fittings")
      thread = insert_thread(organization_id: org.id, state: :active, subject: "Refund request")
      other = insert_thread(organization_id: org.id, state: :active, subject: "Other matter")

      {:ok, _} = Threads.set_state(signed_in.scope, thread.id, :waiting)
      {:ok, _} = Threads.set_state(signed_in.scope, other.id, :resolved)
      mail_event(thread)
      workspace_event()

      Map.merge(signed_in, %{thread: thread, other: other})
    end

    test "the banner names the conversation and the list holds only its events", c do
      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.thread.id}&filter=everything")

      assert has_element?(view, testid("staff-audit-thread-filter"), "Events of the conversation")

      assert page_link(view, "staff-audit-thread-link") ==
               {"Refund request", "/app/threads/#{c.thread.id}"}

      assert summaries(view) == [
               "Received an inbound message",
               "Changed the state from active to waiting"
             ]

      assert Enum.all?(
               rows(view),
               &(&1.thread == {"Refund request", "/app/threads/#{c.thread.id}"})
             )

      assert pressed(view) == ["staff-audit-filter-everything"]
    end

    test "the clear link drops the conversation and keeps the filter", c do
      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.thread.id}&filter=everything")

      assert page_link(view, "staff-audit-thread-clear") ==
               {"Show every conversation", "/app/settings/audit?filter=everything"}

      view |> element(testid("staff-audit-thread-clear")) |> render_click()

      assert_patch(view, "/app/settings/audit?filter=everything")
      refute has_element?(view, testid("staff-audit-thread-filter"))
      assert length(rows(view)) == 4
    end

    test "with the default filter the clear link is the plain address", c do
      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.thread.id}")

      assert summaries(view) == ["Changed the state from active to waiting"]

      assert page_link(view, "staff-audit-thread-clear") ==
               {"Show every conversation", "/app/settings/audit"}
    end

    test "a chip keeps the conversation", c do
      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.thread.id}")

      view |> element(chip("mail")) |> render_click()

      assert_patch(view, "/app/settings/audit?filter=mail&thread=#{c.thread.id}")
      assert has_element?(view, testid("staff-audit-thread-filter"), "Refund request")
      assert summaries(view) == ["Received an inbound message"]
    end

    test "a conversation without a subject is named as such", c do
      Repo.update_all(from(t in Thread, where: t.id == ^c.thread.id), set: [subject: ""])

      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.thread.id}")

      assert page_link(view, "staff-audit-thread-link") ==
               {"(no subject)", "/app/threads/#{c.thread.id}"}
    end

    test "another tenant's conversation is not found and lists nothing", c do
      other = other_tenant()

      {:ok, view, html} = live(c.conn, @path <> "?thread=#{other.thread.id}&filter=everything")

      assert has_element?(
               view,
               testid("staff-audit-thread-filter"),
               "This conversation was not found."
             )

      refute has_element?(view, testid("staff-audit-thread-link"))
      refute html =~ "Their secret"
      assert rows(view) == []
      assert has_element?(view, testid("audit-empty"))

      assert page_link(view, "staff-audit-thread-clear") ==
               {"Show every conversation", "/app/settings/audit?filter=everything"}
    end

    test "a conversation that does not exist is not found", c do
      {:ok, view, _html} = live(c.conn, @path <> "?thread=#{c.other.id + 1000}")

      assert has_element?(
               view,
               testid("staff-audit-thread-filter"),
               "This conversation was not found."
             )

      assert rows(view) == []
    end

    test "a thread or a before that is not a positive integer is ignored", c do
      huge = String.duplicate("9", 30)

      for {thread, before} <- [
            {"abc", "xyz"},
            {"0", "-3"},
            {"1.5", "12abc"},
            {"", ""},
            {huge, huge}
          ] do
        {:ok, view, _html} =
          live(c.conn, @path <> "?thread=#{thread}&before=#{before}&filter=everything")

        refute has_element?(view, testid("staff-audit-thread-filter"))
        refute has_element?(view, testid("staff-audit-newest-link"))
        assert length(rows(view)) == 4
      end
    end
  end

  describe "pages" do
    setup %{conn: conn} do
      signed_in = sign_in(conn, "admin")
      Map.put(signed_in, :thread, insert_thread(state: :active, subject: "Refund request"))
    end

    test "fifty rows, then the rest behind the older link, with filter and thread kept", c do
      for _ <- 1..(AuditLog.page_size() + 5), do: mail_event(c.thread)
      own = "/app/settings/audit?filter=mail&thread=#{c.thread.id}"

      {:ok, view, _html} = live(c.conn, own)

      first = ids(view)
      assert length(first) == 50
      refute has_element?(view, testid("staff-audit-newest-link"))

      assert {"Older events", older} = page_link(view, "audit-older-link")
      assert %URI{path: @path, query: query} = URI.parse(older)

      assert URI.decode_query(query) == %{
               "filter" => "mail",
               "thread" => to_string(c.thread.id),
               "before" => to_string(List.last(first))
             }

      view |> element(testid("audit-older-link")) |> render_click()

      assert_patch(view, older)
      second = ids(view)
      assert length(second) == 5
      refute has_element?(view, testid("audit-older-link"))
      assert has_element?(view, testid("staff-audit-thread-filter"), "Refund request")
      assert pressed(view) == ["staff-audit-filter-mail"]

      listed = first ++ second
      assert listed == Enum.sort(listed, :desc)
      assert listed == Enum.uniq(listed)

      assert page_link(view, "staff-audit-newest-link") == {"Back to the newest events", own}

      view |> element(testid("staff-audit-newest-link")) |> render_click()

      assert_patch(view, own)
      assert ids(view) == first
      refute has_element?(view, testid("staff-audit-newest-link"))
    end

    test "the older link of the plain page carries only before", c do
      for _ <- 1..(AuditLog.page_size() + 1), do: workspace_event()

      {:ok, view, _html} = live(c.conn, @path)

      first = ids(view)
      assert length(first) == 50

      assert page_link(view, "audit-older-link") ==
               {"Older events", "/app/settings/audit?before=#{List.last(first)}"}
    end

    test "a page opened by its address shows the newest link, and a chip starts again", c do
      for _ <- 1..(AuditLog.page_size() + 1), do: workspace_event()
      mail_event(c.thread)

      {:ok, view, _html} = live(c.conn, @path)
      before = List.last(ids(view))

      {:ok, view, _html} = live(c.conn, @path <> "?before=#{before}")

      assert length(ids(view)) == 1

      assert page_link(view, "staff-audit-newest-link") ==
               {"Back to the newest events", "/app/settings/audit"}

      view |> element(chip("mail")) |> render_click()

      assert_patch(view, "/app/settings/audit?filter=mail")
      refute has_element?(view, testid("staff-audit-newest-link"))
      assert summaries(view) == ["Received an inbound message"]
    end

    test "exactly one page has no older link", c do
      for _ <- 1..AuditLog.page_size(), do: workspace_event()

      {:ok, view, _html} = live(c.conn, @path)

      assert length(ids(view)) == 50
      refute has_element?(view, testid("audit-older-link"))
    end
  end
end
