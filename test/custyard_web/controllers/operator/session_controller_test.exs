defmodule CustyardWeb.Operator.SessionControllerTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo}

  test "limits all login-link requests from one address, including successful redirects" do
    operator = insert_operator_account()
    ip = {10, 44, 3, 1}

    for _ <- 1..5 do
      assert request_login(ip, operator.email).status == 302
    end

    before_denied = Repo.get!(OperatorAccount, operator.id).login_token
    denied = request_login(ip, operator.email)

    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
    assert Repo.get!(OperatorAccount, operator.id).login_token == before_denied
  end

  test "limits requests to an address across client IPs without revealing account existence" do
    operator = insert_operator_account()

    for n <- 1..5 do
      assert request_login({10, 44, 4, n}, operator.email).status == 302
    end

    assert request_login({10, 44, 4, 6}, operator.email).status == 429

    unknown = "missing-#{System.unique_integer([:positive])}@example.com"

    for n <- 1..5 do
      assert request_login({10, 44, 5, n}, unknown).status == 302
    end

    assert request_login({10, 44, 5, 6}, unknown).status == 429
  end

  test "re-sends the outstanding link instead of rotating a still-valid token" do
    operator = insert_operator_account()

    assert request_login({10, 44, 6, 1}, operator.email).status == 302
    first = Repo.get!(OperatorAccount, operator.id).login_token
    assert is_binary(first)

    assert request_login({10, 44, 6, 2}, operator.email).status == 302
    assert Repo.get!(OperatorAccount, operator.id).login_token == first
  end

  test "mints a new token once the previous one has expired" do
    operator = insert_operator_account()
    assert request_login({10, 44, 7, 1}, operator.email).status == 302
    first = Repo.get!(OperatorAccount, operator.id)

    expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    first
    |> Ecto.Changeset.change(login_token_expires_at: expired)
    |> Repo.update!()

    assert request_login({10, 44, 7, 2}, operator.email).status == 302
    assert Repo.get!(OperatorAccount, operator.id).login_token != first.login_token
  end

  test "logs in an account that was created with a mixed-case email" do
    n = System.unique_integer([:positive])

    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "Ops-#{n}@Example.com"})
      |> Repo.insert!()

    assert request_login({10, 44, 8, 1}, "Ops-#{n}@Example.com").status == 302
    token = Repo.get!(OperatorAccount, operator.id).login_token
    assert is_binary(token)

    conn = post(build_conn(), "/operator/login/verify/#{token}")
    assert redirected_to(conn) == "/operator"
    assert get_session(conn, :operator_id) == operator.id
  end

  test "logs in a non-ASCII address typed in a different case and composition" do
    n = System.unique_integer([:positive])

    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "Ünal-#{n}@Bücher.de"})
      |> Repo.insert!()

    # Uppercase, with each umlaut as "U"/"u" followed by U+0308 COMBINING DIAERESIS
    typed = "U\u0308NAL-#{n}@BU\u0308CHER.DE"

    assert request_login({10, 44, 9, 1}, typed).status == 302
    token = Repo.get!(OperatorAccount, operator.id).login_token
    assert is_binary(token)

    conn = post(build_conn(), "/operator/login/verify/#{token}")
    assert get_session(conn, :operator_id) == operator.id
  end

  describe "magic link verification" do
    setup do
      operator =
        insert_operator_account()
        |> OperatorAccount.login_token_changeset()
        |> Repo.update!()

      {:ok, operator: operator, token: operator.login_token}
    end

    test "GET peeks without consuming the token or starting a session",
         %{conn: conn, operator: operator, token: token} do
      conn = get(conn, "/operator/login/verify/#{token}")

      assert html_response(conn, 200) =~ "auth-verify-form"
      refute get_session(conn, :operator_id)
      assert Repo.get!(OperatorAccount, operator.id).login_token == token

      # A scanner can fetch the link any number of times
      assert html_response(get(build_conn(), "/operator/login/verify/#{token}"), 200) =~
               "auth-verify-form"
    end

    test "POST consumes the token and starts the session",
         %{conn: conn, operator: operator, token: token} do
      conn = post(conn, "/operator/login/verify/#{token}")

      assert redirected_to(conn) == "/operator"
      assert get_session(conn, :operator_id) == operator.id
      assert Repo.get!(OperatorAccount, operator.id).login_token == nil

      # The link works once
      again = post(build_conn(), "/operator/login/verify/#{token}")
      assert html_response(again, 200) =~ "Invalid or expired login link"
      refute get_session(again, :operator_id)
    end

    test "an expired token is refused on GET and POST", %{
      conn: conn,
      operator: operator,
      token: token
    } do
      expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      operator
      |> Ecto.Changeset.change(login_token_expires_at: expired)
      |> Repo.update!()

      assert html_response(get(conn, "/operator/login/verify/#{token}"), 200) =~ "has expired"
      posted = post(build_conn(), "/operator/login/verify/#{token}")
      assert html_response(posted, 200) =~ "has expired"
      refute get_session(posted, :operator_id)
    end

    test "unknown and malformed tokens render the same invalid page", %{conn: conn} do
      unknown = get(conn, "/operator/login/verify/" <> String.duplicate("a", 43))
      malformed = get(build_conn(), "/operator/login/verify/not%20a%20token")

      assert html_response(unknown, 200) =~ "Invalid or expired login link"
      assert html_response(malformed, 200) =~ "Invalid or expired login link"
    end
  end

  defp request_login(ip, email) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> post("/operator/login", %{"email" => email})
  end
end
