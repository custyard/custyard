defmodule CustyardWeb.HomeLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Custyard.{OperatorAccount, Repo}

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

  describe "GET /" do
    test "renders the public landing page for anonymous visitors", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "home-container"
      assert html =~ "home-operator-login-link"
    end

    test "redirects an authenticated operator to the dashboard", %{conn: conn} do
      operator =
        create_operator(%{email: "home-redirect-test@example.com", password: "password123"})

      conn = login(conn, operator)

      assert {:error, {:redirect, %{to: "/operator"}}} = live(conn, ~p"/")
    end

    test "a stale session (deleted operator) keeps the landing page", %{conn: conn} do
      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:operator_id, 999_999)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "home-container"
    end
  end
end
