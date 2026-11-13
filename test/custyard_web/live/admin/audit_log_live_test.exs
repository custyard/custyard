defmodule CustyardWeb.Admin.AuditLogLiveTest do
  use CustyardWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{AuditEvent, AuditLog, InstanceAdmins, Repo, StaffAccount, Tenants, Threads}

  # /admin is served on the installation host only.
  @moduletag :explicit_tenant_hosts

  @tenant_host "northwind.example.com"

  # What only the tenant may read.
  @subject "Refund for order 7731"
  @customer "Acme Fittings"
  @sender "digest@sender.example.com"
  @staff_email "ada@northwind.test"

  @page "[data-testid=instance-admin-audit-page]"
  @newest "[data-testid=instance-admin-audit-newest-link]"
  @older "[data-testid=audit-older-link]"

  setup do
    tenant = insert_tenant(name: "Northwind")
    Process.put(:factory_tenant_id, tenant.id)
    {:ok, _} = Tenants.add_host(tenant.id, @tenant_host)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id, email: @staff_email)
    {:created, admin} = InstanceAdmins.create_admin("root@install.test")

    {:ok, tenant: tenant, staff: staff, admin: admin}
  end

  defp installation_conn, do: %{build_conn() | host: Tenants.app_host()}

  defp admin_session(admin),
    do: %{instance_admin_id: admin.id, instance_admin_claim: admin.session_claim}

  defp staff_session(staff),
    do: %{staff_id: staff.id, staff_claim: StaffAccount.session_claim(staff)}

  defp sign_in(admin), do: init_test_session(installation_conn(), admin_session(admin))

  defp event!(type), do: Repo.get_by!(AuditEvent, event_type: type)

  # The ids of the listed entries, in page order.
  defp entry_ids(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find("li[data-testid^=audit-entry-]")
    |> Enum.map(fn row ->
      "audit-entry-" <> id = row |> Floki.attribute("data-testid") |> List.first()
      String.to_integer(id)
    end)
  end

  defp part(event_id, name),
    do: ~s([data-testid="audit-entry-#{event_id}"] [data-testid="audit-entry-#{name}"])

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
  end

  defp insert_installation_events(admin, count) do
    rows =
      for _ <- 1..count do
        %{
          tenant_id: nil,
          event_type: :installation_configured,
          source: "instance_admin",
          payload: %{"instance_admin_id" => admin.id},
          inserted_at: DateTime.utc_now(:second)
        }
      end

    {^count, _} = Repo.insert_all(AuditEvent, rows)
    :ok
  end

  defp all_event_ids, do: Repo.all(from e in AuditEvent, order_by: [desc: e.id], select: e.id)

  describe "access" do
    test "signed out, the page redirects to the instance admin login" do
      assert {:error, {:redirect, %{to: "/admin/login"}}} =
               live(installation_conn(), ~p"/admin/audit")
    end

    test "a session with a stale claim is refused", c do
      conn =
        init_test_session(installation_conn(), %{
          instance_admin_id: c.admin.id,
          instance_admin_claim: "stale"
        })

      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/audit")
    end

    test "a tenant staff session alone grants nothing", c do
      conn = init_test_session(installation_conn(), staff_session(c.staff))

      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/audit")
    end

    test "the page is not served on a tenant host, whoever asks", c do
      sessions = [
        %{},
        staff_session(c.staff),
        admin_session(c.admin),
        Map.merge(staff_session(c.staff), admin_session(c.admin))
      ]

      for session <- sessions do
        conn =
          %{build_conn() | host: @tenant_host}
          |> init_test_session(session)
          |> get(~p"/admin/audit")

        assert conn.status == 404
        refute conn.resp_body =~ "instance-admin-audit-page"
        refute conn.resp_body =~ "root@install.test"
      end
    end

    test "a socket that connects through a tenant host is refused", c do
      conn =
        c.admin
        |> sign_in()
        |> put_private(:live_view_connect_info, %{uri: %URI{host: @tenant_host}})

      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/audit")
    end
  end

  describe "the page" do
    test "has a title, says what it lists and that times are UTC", c do
      {:ok, view, _html} = live(sign_in(c.admin), ~p"/admin/audit")

      assert page_title(view) =~ "Audit log"
      assert text(view, "#{@page} h1") == "Audit log"

      assert text(view, "#{@page} header p") ==
               "Installation events and what instance admins did to a tenant. " <>
                 "What happens inside a tenant is in that workspace's own audit log, " <>
                 "under Settings. Times are UTC."

      assert has_element?(view, "#{@page} [data-testid=audit-timeline]")
    end

    test "lists the creation of the admin's own account and a tenant suspension", c do
      {:ok, _} = Tenants.set_status(c.admin, c.tenant.id, "suspended")
      created = event!(:instance_admin_created).id
      suspended = event!(:tenant_status_changed).id

      {:ok, view, html} = live(sign_in(c.admin), ~p"/admin/audit")

      # Newest first.
      assert entry_ids(html) == [suspended, created]

      assert text(view, part(created, "actor")) == "Installation"

      assert text(view, part(created, "summary")) ==
               "Created the instance admin account root@install.test"

      assert text(view, part(created, "topic")) == "Installation"

      # No tenant, so nothing in its place and no link.
      refute has_element?(
               view,
               ~s([data-testid="audit-entry-#{created}"] [data-testid=audit-entry-tenant])
             )

      refute has_element?(view, ~s([data-testid="audit-entry-#{created}"] a))

      assert text(view, part(suspended, "actor")) == "root@install.test"
      assert text(view, part(suspended, "summary")) == "Suspended the workspace"
      assert text(view, part(suspended, "topic")) == "Workspace"

      tenant_link =
        ~s([data-testid="audit-entry-#{suspended}"] ) <>
          ~s(a[data-testid=audit-entry-tenant][href="/admin/tenants/#{c.tenant.id}/settings"])

      assert text(view, tenant_link) == "Northwind"

      assert text(view, part(suspended, "time")) =~
               ~r/\A\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC\z/
    end

    test "the first render, before the socket connects, lists the same", c do
      {:ok, _} = Tenants.set_status(c.admin, c.tenant.id, "suspended")

      html = c.admin |> sign_in() |> get(~p"/admin/audit") |> html_response(200)

      assert entry_ids(html) ==
               [event!(:tenant_status_changed).id, event!(:instance_admin_created).id]

      assert html =~ "Suspended the workspace"
    end
  end

  describe "a tenant's own activity" do
    setup c do
      org = insert_organization(tenant_id: c.tenant.id, name: @customer)
      contact = insert_contact(organization_id: org.id, email: @sender)

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          state: :active,
          subject: @subject
        )

      scope = Custyard.Scope.for_staff(c.staff, c.tenant)
      {:ok, _} = Threads.set_state(scope, thread.id, :resolved)
      {:ok, _} = Threads.ignore_sender(scope, thread.id)

      insert_audit_event(
        tenant_id: c.tenant.id,
        event_type: :webhook_received,
        thread_id: thread.id
      )

      # What the tenant's own admin reads about these three events.
      {:ok, %{entries: entries}} = AuditLog.for_tenant(scope, category: "everything")

      assert Enum.map(entries, & &1.event_type) ==
               [:webhook_received, :sender_ignored, :thread_state_changed]

      {:ok, tenant_summaries: Enum.map(entries, & &1.summary)}
    end

    defp refute_tenant_activity(html, summaries) do
      for private <- [@subject, @customer, @sender, @staff_email] ++ summaries do
        refute html =~ private
      end

      for stem <- ["Changed the state", "Ignored the sender", "Received an inbound message"] do
        refute html =~ stem
      end
    end

    test "never appears", c do
      assert "Ignored the sender #{@sender}" in c.tenant_summaries

      conn = sign_in(c.admin)
      {:ok, view, html} = live(conn, ~p"/admin/audit")

      assert entry_ids(html) == [event!(:instance_admin_created).id]
      refute_tenant_activity(html, c.tenant_summaries)
      refute_tenant_activity(render(view), c.tenant_summaries)

      # The whole document of the first render, layouts included.
      document = conn |> get(~p"/admin/audit") |> html_response(200)
      assert document =~ "instance-admin-audit-page"
      refute_tenant_activity(document, c.tenant_summaries)
    end

    test "stays out when an instance admin acted on the same tenant", c do
      {:ok, _} = Tenants.set_status(c.admin, c.tenant.id, "suspended")

      {:ok, view, html} = live(sign_in(c.admin), ~p"/admin/audit")

      assert entry_ids(html) ==
               [event!(:tenant_status_changed).id, event!(:instance_admin_created).id]

      assert has_element?(view, "a[data-testid=audit-entry-tenant]", "Northwind")
      refute_tenant_activity(html, c.tenant_summaries)
    end

    test "is not reached by paging past the installation's events", c do
      newest = List.first(all_event_ids())

      {:ok, _view, html} = live(sign_in(c.admin), ~p"/admin/audit?#{[before: newest + 1]}")

      assert entry_ids(html) == [event!(:instance_admin_created).id]
      refute_tenant_activity(html, c.tenant_summaries)
    end
  end

  describe "paging" do
    test "a page holds 50 entries and links to the older ones and back", c do
      extra = 4
      insert_installation_events(c.admin, AuditLog.page_size() + extra)

      {first, rest} = Enum.split(all_event_ids(), AuditLog.page_size())
      older = List.last(first)
      assert length(first) == 50
      assert length(rest) == extra + 1

      {:ok, view, html} = live(sign_in(c.admin), ~p"/admin/audit")

      assert entry_ids(html) == first
      refute has_element?(view, @newest)

      assert has_element?(
               view,
               ~s(a#{@older}[href="/admin/audit?before=#{older}"]),
               "Older events"
             )

      html = view |> element(@older) |> render_click()
      assert_patch(view, "/admin/audit?before=#{older}")

      assert entry_ids(html) == rest
      refute has_element?(view, @older)

      assert has_element?(
               view,
               ~s(a#{@newest}[href="/admin/audit"]),
               "Back to the newest events"
             )

      html = view |> element(@newest) |> render_click()
      assert_patch(view, "/admin/audit")

      assert entry_ids(html) == first
      refute has_element?(view, @newest)
      assert has_element?(view, @older)
    end

    test "an older page opens from its own address", c do
      insert_installation_events(c.admin, AuditLog.page_size())
      {first, rest} = Enum.split(all_event_ids(), AuditLog.page_size())

      {:ok, view, html} =
        live(sign_in(c.admin), ~p"/admin/audit?#{[before: List.last(first)]}")

      assert entry_ids(html) == rest
      assert rest == [event!(:instance_admin_created).id]
      assert has_element?(view, @newest)
      refute has_element?(view, @older)
    end

    test "exactly one page of events has no older link", c do
      insert_installation_events(c.admin, AuditLog.page_size() - 1)

      {:ok, view, html} = live(sign_in(c.admin), ~p"/admin/audit")

      assert length(entry_ids(html)) == AuditLog.page_size()
      refute has_element?(view, @older)
    end

    test "before the oldest event there is nothing to show, and a way back", c do
      oldest = event!(:instance_admin_created).id

      {:ok, view, html} = live(sign_in(c.admin), ~p"/admin/audit?#{[before: oldest]}")

      assert entry_ids(html) == []
      assert text(view, "[data-testid=audit-empty]") == "No events to show."
      refute has_element?(view, "[data-testid=audit-timeline]")
      refute has_element?(view, @older)
      assert has_element?(view, @newest)
    end

    test "a before that is not a positive integer is ignored", c do
      conn = sign_in(c.admin)
      newest = [event!(:instance_admin_created).id]

      for bad <- ["abc", "", "0", "-3", "1.5", "12abc", " 7"] do
        {:ok, view, html} = live(conn, ~p"/admin/audit?#{[before: bad]}")

        assert entry_ids(html) == newest, "before=#{inspect(bad)}"
        refute has_element?(view, @newest), "before=#{inspect(bad)}"
      end

      {:ok, view, html} = live(conn, "/admin/audit?before[]=3")
      assert entry_ids(html) == newest
      refute has_element?(view, @newest)
    end

    # The database cannot bind a number wider than 64 bits: the query raises.
    test "a before too large to be an entry id is ignored", c do
      conn = sign_in(c.admin)
      newest = [event!(:instance_admin_created).id]

      for bad <- ["9223372036854775808", String.duplicate("9", 40)] do
        {:ok, view, html} = live(conn, ~p"/admin/audit?#{[before: bad]}")

        assert entry_ids(html) == newest, "before=#{bad}"
        refute has_element?(view, @newest), "before=#{bad}"
      end

      # The largest id there can be is still an id.
      {:ok, view, html} = live(conn, ~p"/admin/audit?#{[before: 9_223_372_036_854_775_807]}")
      assert entry_ids(html) == newest
      assert has_element?(view, @newest)
    end
  end

  describe "navigation" do
    test "the header of the admin layout links to the page", c do
      conn = sign_in(c.admin)
      {:ok, view, _html} = live(conn, ~p"/admin")

      link = ~s(a[data-testid=instance-admin-audit-link][href="/admin/audit"])
      assert text(view, link) == "Audit log"

      {:ok, audit, _html} =
        view |> element(link) |> render_click() |> follow_redirect(conn, ~p"/admin/audit")

      assert has_element?(audit, @page)
      assert has_element?(audit, link)
    end

    test "an admin removed while the page is open is sent to the login", c do
      {:created, _other} = InstanceAdmins.create_admin("second@install.test")
      newest = List.first(all_event_ids())

      conn = sign_in(c.admin)
      {:ok, view, _html} = live(conn, ~p"/admin/audit?#{[before: newest + 1]}")
      assert has_element?(view, @newest)

      {:ok, _removed} = InstanceAdmins.remove_admin(c.admin.email)

      view |> element(@newest) |> render_click()
      assert_redirect(view, "/admin/login")

      assert {:error, {:redirect, %{to: "/admin/login"}}} = live(conn, ~p"/admin/audit")
    end

    test "an admin whose session ended elsewhere is sent to the login", c do
      {:ok, view, _html} = live(sign_in(c.admin), ~p"/admin/audit")

      c.admin |> Ecto.Changeset.change(session_claim: Ecto.UUID.generate()) |> Repo.update!()

      render_patch(view, ~p"/admin/audit?#{[before: 1]}")
      assert_redirect(view, "/admin/login")
    end
  end
end
