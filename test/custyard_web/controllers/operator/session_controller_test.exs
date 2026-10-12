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
      # Binds the session to this account, not just to its (reusable) id.
      assert get_session(conn, :operator_claim) == OperatorAccount.session_claim(operator)
      assert Repo.get!(OperatorAccount, operator.id).login_token == nil

      # The session it issued is accepted
      assert html_response(get(recycle(conn), "/operator"), 200)

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

  describe "email normalization" do
    test "a mixed-case, padded email finds the account" do
      operator = insert_operator_account(email: "casey@example.com")

      assert request_login({10, 44, 8, 1}, "  Casey@Example.COM ").status == 302
      assert is_binary(Repo.get!(OperatorAccount, operator.id).login_token)
    end

    test "case variants share one per-email rate-limit bucket" do
      operator = insert_operator_account()
      variants = [operator.email, String.upcase(operator.email), " " <> operator.email]

      for {email, n} <- Enum.with_index(Stream.cycle(variants) |> Enum.take(5), 1) do
        assert request_login({10, 44, 9, n}, email).status == 302
      end

      assert request_login({10, 44, 9, 6}, String.upcase(operator.email)).status == 429
    end
  end

  describe "admin or agent whose organization was deleted" do
    setup do
      org = insert_organization()
      admin = insert_operator_account(role: "admin", organization_id: org.id)
      Repo.delete!(org)
      orphan = Repo.get!(OperatorAccount, admin.id)
      assert orphan.organization_id == nil

      {:ok, orphan: orphan}
    end

    test "gets no login link, and the response matches an unknown email", %{orphan: orphan} do
      orphaned = request_login({10, 44, 10, 1}, orphan.email)
      unknown = request_login({10, 44, 10, 2}, "nobody-#{orphan.id}@example.com")

      assert redirected_to(orphaned) == "/operator/login/sent"
      assert redirected_to(unknown) == "/operator/login/sent"
      assert Repo.get!(OperatorAccount, orphan.id).login_token == nil

      sent = get(recycle(orphaned), "/operator/login/sent")
      unknown_sent = get(recycle(unknown), "/operator/login/sent")

      # Identical apart from the echoed address and the per-session CSRF token.
      normalize = fn html, email ->
        html
        |> String.replace(email, "EMAIL")
        |> String.replace(~r/name="csrf-token" content="[^"]+"/, "CSRF")
      end

      assert normalize.(html_response(sent, 200), orphan.email) ==
               normalize.(html_response(unknown_sent, 200), "nobody-#{orphan.id}@example.com")
    end

    test "a link minted before the deletion never yields a session", %{conn: conn, orphan: orphan} do
      %{login_token: token} =
        orphan |> OperatorAccount.login_token_changeset() |> Repo.update!()

      peek = get(conn, "/operator/login/verify/#{token}")
      assert html_response(peek, 200) =~ "No organization assigned; ask a super admin."
      refute html_response(peek, 200) =~ "auth-verify-form"

      posted = post(build_conn(), "/operator/login/verify/#{token}")
      assert html_response(posted, 200) =~ "No organization assigned; ask a super admin."
      refute get_session(posted, :operator_id)
    end
  end

  test "logout clears the operator id and its claim", %{conn: conn} do
    operator = insert_operator_account()

    conn =
      conn
      |> init_test_session(%{})
      |> put_operator_session(operator)
      |> delete("/operator/logout")

    assert redirected_to(conn) == "/operator/login"
    refute get_session(conn, :operator_id)
    refute get_session(conn, :operator_claim)
  end

  describe "login page" do
    test "shows the flash that sent the operator there", %{conn: conn} do
      denied = get(conn, "/operator")
      assert redirected_to(denied) == "/operator/login"

      login = get(recycle(denied), "/operator/login")
      assert html_response(login, 200) =~ "Please log in"
    end
  end

  defp request_login(ip, email) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> post("/operator/login", %{"email" => email})
  end
end
