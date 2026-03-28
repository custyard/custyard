defmodule CustyardWeb.Live.OperatorAuthTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo, Scoring}

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
end
