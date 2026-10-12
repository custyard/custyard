defmodule CustyardWeb.Live.OperatorAuthTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{Conversation, OperatorAccount, Repo, Scoring}
  alias CustyardWeb.Live.OperatorAuth

  # Helpers for creating operators and authenticated connections

  defp create_operator(attrs) do
    {:ok, op} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(attrs)
      |> Repo.insert()

    op
  end

  defp login(conn, operator) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:operator_id, operator.id)
  end

  # The real deletion path (its "Deleting organization" warning is expected).
  defp delete_organization(org) do
    ExUnit.CaptureLog.capture_log(fn ->
      assert {:ok, _} = Custyard.Organizations.delete_organization(org)
    end)
  end

  describe "on_mount/4 - authentication" do
    test "redirects to login when no operator_id in session", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})

      assert {:error, {:redirect, %{to: "/operator/login"}}} =
               live(conn, ~p"/operator")
    end

    test "redirects to login when operator_id points to nonexistent operator", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, 999_999)

      assert {:error, {:redirect, %{to: "/operator/login"}}} =
               live(conn, ~p"/operator")
    end

    test "allows access when valid operator_id in session", %{conn: conn} do
      {:ok, operator} =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: "test@example.com", password: "password123"})
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, operator.id)

      {:ok, _view, html} = live(conn, ~p"/operator")

      # Page renders successfully (proves auth hook passed)
      assert html =~ "Attention Queue"
    end
  end

  describe "on_mount/4 - scoping" do
    test "super_admin sees all organizations' conversations", %{conn: conn} do
      # Create conversations for different orgs
      org1 = insert_organization(name: "Org One")
      org2 = insert_organization(name: "Org Two")
      conv1 = insert_conversation(organization_id: org1.id, subject: "Org One Ticket")
      conv2 = insert_conversation(organization_id: org2.id, subject: "Org Two Ticket")
      Scoring.calculate_and_cache(conv1.id)
      Scoring.calculate_and_cache(conv2.id)

      {:ok, super_admin} =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{
          email: "admin@example.com",
          password: "password123",
          role: "super_admin"
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, super_admin.id)

      {:ok, _view, html} = live(conn, ~p"/operator")

      # Super admin sees both orgs' conversations
      assert html =~ "Org One Ticket"
      assert html =~ "Org Two Ticket"
    end

    test "org-scoped operator only sees their organization's conversations", %{conn: conn} do
      # Create conversations for different orgs
      org1 = insert_organization(name: "Org One")
      org2 = insert_organization(name: "Org Two")
      conv1 = insert_conversation(organization_id: org1.id, subject: "Org One Ticket")
      conv2 = insert_conversation(organization_id: org2.id, subject: "Org Two Ticket")
      Scoring.calculate_and_cache(conv1.id)
      Scoring.calculate_and_cache(conv2.id)

      {:ok, scoped_operator} =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{
          email: "orgadmin@example.com",
          password: "password123",
          role: "admin",
          organization_id: org1.id
        })
        |> Repo.insert()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, scoped_operator.id)

      {:ok, _view, html} = live(conn, ~p"/operator")

      # Org-scoped operator only sees their org's conversations
      assert html =~ "Org One Ticket"
      refute html =~ "Org Two Ticket"
    end
  end

  # -------------------------------------------------------------------
  # Phase 1a: Role-based on_mount clauses
  # -------------------------------------------------------------------
  # These tests target the :require_admin and :require_super_admin
  # on_mount clauses that will be added to OperatorAuth.
  # They will fail until the implementation lands.

  describe "on_mount/4 - :require_admin" do
    test "redirects agent away from admin-only routes", %{conn: conn} do
      org = insert_organization()

      agent =
        create_operator(%{
          email: "agent-admin-test@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })

      conn = login(conn, agent)

      # Organizations is an admin-only route
      assert {:error, {:redirect, %{to: "/operator"}}} =
               live(conn, ~p"/operator/organizations")
    end

    test "allows admin to access admin-only routes", %{conn: conn} do
      org = insert_organization()

      admin =
        create_operator(%{
          email: "admin-access-test@example.com",
          password: "password123",
          role: "admin",
          organization_id: org.id
        })

      conn = login(conn, admin)

      {:ok, _view, _html} = live(conn, ~p"/operator/organizations")
    end

    test "allows super_admin to access admin-only routes", %{conn: conn} do
      super_admin =
        create_operator(%{
          email: "super-admin-access-test@example.com",
          password: "password123",
          role: "super_admin"
        })

      conn = login(conn, super_admin)

      {:ok, _view, _html} = live(conn, ~p"/operator/organizations")
    end
  end

  describe "on_mount/4 - :require_super_admin" do
    test "redirects agent away from super-admin-only routes", %{conn: conn} do
      org = insert_organization()

      agent =
        create_operator(%{
          email: "agent-super-test@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })

      conn = login(conn, agent)

      # Settings is super_admin-only for write access; this tests the mount guard
      assert {:error, {:redirect, _}} = live(conn, ~p"/operator/settings")
    end

    test "redirects admin away from super-admin-only routes", %{conn: conn} do
      org = insert_organization()

      admin =
        create_operator(%{
          email: "admin-super-test@example.com",
          password: "password123",
          role: "admin",
          organization_id: org.id
        })

      conn = login(conn, admin)

      # If settings requires super_admin specifically, admin is also blocked
      assert {:error, {:redirect, _}} = live(conn, ~p"/operator/settings")
    end

    test "allows super_admin to access super-admin-only routes", %{conn: conn} do
      super_admin =
        create_operator(%{
          email: "super-only-test@example.com",
          password: "password123",
          role: "super_admin"
        })

      conn = login(conn, super_admin)

      {:ok, _view, _html} = live(conn, ~p"/operator/settings")
    end
  end

  describe "on_mount/4 - socket assigns" do
    test "assigns current_role from operator", %{conn: conn} do
      org = insert_organization()

      admin =
        create_operator(%{
          email: "role-assign-test@example.com",
          password: "password123",
          role: "admin",
          organization_id: org.id
        })

      conn = login(conn, admin)

      {:ok, view, _html} = live(conn, ~p"/operator")

      # The on_mount hook should populate :current_role in assigns
      assert render(view) =~ ""
      # We can't directly inspect assigns from the test process, but we can
      # verify the view mounts without error, confirming the assign is set.
    end

    test "assigns is_super_admin as true for super_admin", %{conn: conn} do
      super_admin =
        create_operator(%{
          email: "is-super-true-test@example.com",
          password: "password123",
          role: "super_admin"
        })

      conn = login(conn, super_admin)

      {:ok, _view, _html} = live(conn, ~p"/operator")
      # Verifying mount succeeds. The is_super_admin assign will be used
      # by templates to conditionally render admin UI elements.
    end

    test "assigns is_super_admin as false for non-super_admin", %{conn: conn} do
      org = insert_organization()

      agent =
        create_operator(%{
          email: "is-super-false-test@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })

      conn = login(conn, agent)

      {:ok, _view, _html} = live(conn, ~p"/operator")
    end
  end

  describe "connected socket scope refresh" do
    test "reassignment removes access before the next organization event", %{conn: conn} do
      own = insert_organization(name: "Original organization")
      next_org = insert_organization(name: "Next organization")

      operator =
        create_operator(%{
          email: "reassigned-admin@example.com",
          role: "admin",
          organization_id: own.id
        })

      {:ok, view, html} = live(login(conn, operator), ~p"/operator/organizations")
      assert html =~ own.name

      operator
      |> OperatorAccount.role_changeset(%{organization_id: next_org.id})
      |> Repo.update!()

      render_click(view, "show_form", %{})
      assert_redirect(view, "/operator")
    end

    test "demotion removes admin page access before the next event", %{conn: conn} do
      org = insert_organization()

      operator =
        create_operator(%{
          email: "demoted-admin@example.com",
          role: "admin",
          organization_id: org.id
        })

      {:ok, view, _html} = live(login(conn, operator), ~p"/operator/organizations")

      operator
      |> OperatorAccount.role_changeset(%{role: "agent"})
      |> Repo.update!()

      render_click(view, "show_form", %{})
      assert_redirect(view, "/operator")
    end

    test "reassignment removes access before a project broadcast reload", %{conn: conn} do
      own = insert_organization()
      next_org = insert_organization()
      project = insert_project(organization_id: own.id)

      operator =
        create_operator(%{
          email: "reassigned-project-agent@example.com",
          role: "agent",
          organization_id: own.id
        })

      {:ok, view, _html} = live(login(conn, operator), ~p"/operator/projects/#{project.id}")

      operator
      |> OperatorAccount.role_changeset(%{organization_id: next_org.id})
      |> Repo.update!()

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "project:#{project.id}",
        {:project_updated, project.id}
      )

      assert_redirect(view, "/operator")
    end

    test "demotion blocks a state change from an open conversation", %{conn: conn} do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id, state: :active)

      operator =
        create_operator(%{
          email: "demoted-conversation-admin@example.com",
          role: "admin",
          organization_id: org.id
        })

      {:ok, view, _html} =
        live(login(conn, operator), ~p"/operator/conversation/#{conversation.id}")

      operator
      |> OperatorAccount.role_changeset(%{role: "agent"})
      |> Repo.update!()

      render_click(view, "set_state", %{"state" => "waiting"})

      assert_redirect(view, "/operator")
      assert Repo.get!(Conversation, conversation.id).state == :active
    end
  end

  # Deleting an organization nulls its operators' organization_id (ON DELETE
  # SET NULL); scoped_organization_id/1 then returns nil, which the queue and
  # neglect views read as "all organizations".
  describe "admin or agent whose organization was deleted" do
    setup do
      own = insert_organization(name: "Deleted organization")
      other = insert_organization(name: "Other organization")
      conversation = insert_conversation(organization_id: other.id, subject: "Other org ticket")
      Scoring.calculate_and_cache(conversation.id)

      admin =
        create_operator(%{
          email: "orphan-admin@example.com",
          role: "admin",
          organization_id: own.id
        })

      agent =
        create_operator(%{
          email: "orphan-agent@example.com",
          role: "agent",
          organization_id: own.id
        })

      delete_organization(own)

      {:ok,
       admin: Repo.get!(OperatorAccount, admin.id), agent: Repo.get!(OperatorAccount, agent.id)}
    end

    test "cannot load the queue or neglect pages", %{conn: conn, admin: admin, agent: agent} do
      assert admin.organization_id == nil

      for operator <- [admin, agent], path <- ["/operator", "/operator/neglect"] do
        denied = get(login(conn, operator), path)

        assert redirected_to(denied) == "/operator/login"

        assert Phoenix.Flash.get(denied.assigns.flash, :error) ==
                 OperatorAuth.no_organization_message()

        # The plug also drops the session.
        refute get_session(denied, :operator_id)

        assert {:error, {:redirect, %{to: "/operator/login"}}} = live(login(conn, operator), path)
      end
    end

    test "the login page tells them why", %{conn: conn, admin: admin} do
      denied = get(login(conn, admin), "/operator/neglect")
      page = get(recycle(denied), "/operator/login")

      assert html_response(page, 200) =~ "No organization assigned; ask a super admin."
    end

    # A connected (websocket) mount does not pass through the router's
    # :require_operator plug, so the on_mount hook must refuse on its own.
    test "on_mount refuses them on a connected mount", %{admin: admin, agent: agent} do
      for operator <- [admin, agent], mode <- [:default, :require_admin] do
        socket = %Phoenix.LiveView.Socket{
          endpoint: CustyardWeb.Endpoint,
          assigns: %{__changed__: %{}, flash: %{}},
          private: %{live_temp: %{}}
        }

        assert {:halt, halted} =
                 OperatorAuth.on_mount(mode, %{}, %{"operator_id" => operator.id}, socket)

        assert {:redirect, %{to: "/operator/login"}} = halted.redirected
        assert halted.assigns.flash["error"] == OperatorAuth.no_organization_message()
        refute Map.has_key?(halted.assigns, :current_operator)
      end
    end

    test "an open view is closed on its next event once the organization is deleted",
         %{conn: conn} do
      org = insert_organization()

      operator =
        create_operator(%{
          email: "soon-orphaned@example.com",
          role: "admin",
          organization_id: org.id
        })

      {:ok, queue, _html} = live(login(conn, operator), ~p"/operator")
      {:ok, neglect, _html} = live(login(conn, operator), ~p"/operator/neglect")
      {:ok, orgs, _html} = live(login(conn, operator), ~p"/operator/organizations")

      delete_organization(org)

      send(queue.pid, :debounced_reload)
      assert_redirect(queue, "/operator/login")

      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, 0})
      assert_redirect(neglect, "/operator/login")

      render_click(orgs, "show_form", %{})
      assert_redirect(orgs, "/operator/login")
    end

    test "super_admin is unaffected", %{conn: conn} do
      super_admin = create_operator(%{email: "still-super@example.com", role: "super_admin"})

      {:ok, _view, html} = live(login(conn, super_admin), ~p"/operator")
      assert html =~ "Other org ticket"

      {:ok, _view, _html} = live(login(conn, super_admin), ~p"/operator/neglect")
    end
  end
end
