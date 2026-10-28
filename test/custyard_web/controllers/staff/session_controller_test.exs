defmodule CustyardWeb.Staff.SessionControllerTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.{StaffAccount, Repo}

  test "limits all login-link requests from one address, including successful redirects" do
    staff = insert_staff_account(role: "admin")
    ip = {10, 44, 3, 1}

    for _ <- 1..5 do
      assert request_login(ip, staff.email).status == 302
    end

    before_denied = Repo.get!(StaffAccount, staff.id).login_token
    denied = request_login(ip, staff.email)

    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
    assert Repo.get!(StaffAccount, staff.id).login_token == before_denied
  end

  test "limits requests to an address across client IPs without revealing account existence" do
    staff = insert_staff_account(role: "admin")

    for n <- 1..5 do
      assert request_login({10, 44, 4, n}, staff.email).status == 302
    end

    assert request_login({10, 44, 4, 6}, staff.email).status == 429

    unknown = "missing-#{System.unique_integer([:positive])}@example.com"

    for n <- 1..5 do
      assert request_login({10, 44, 5, n}, unknown).status == 302
    end

    assert request_login({10, 44, 5, 6}, unknown).status == 429
  end

  test "re-sends the outstanding link instead of rotating a still-valid token" do
    staff = insert_staff_account(role: "admin")

    assert request_login({10, 44, 6, 1}, staff.email).status == 302
    first = Repo.get!(StaffAccount, staff.id).login_token
    assert is_binary(first)

    assert request_login({10, 44, 6, 2}, staff.email).status == 302
    assert Repo.get!(StaffAccount, staff.id).login_token == first
  end

  test "mints a new token once the previous one has expired" do
    staff = insert_staff_account(role: "admin")
    assert request_login({10, 44, 7, 1}, staff.email).status == 302
    first = Repo.get!(StaffAccount, staff.id)

    expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

    first
    |> Ecto.Changeset.change(login_token_expires_at: expired)
    |> Repo.update!()

    assert request_login({10, 44, 7, 2}, staff.email).status == 302
    assert Repo.get!(StaffAccount, staff.id).login_token != first.login_token
  end

  test "logs in an account that was created with a mixed-case email" do
    n = System.unique_integer([:positive])

    staff =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "Ops-#{n}@Example.com"
      })
      |> Repo.insert!()

    assert request_login({10, 44, 8, 1}, "Ops-#{n}@Example.com").status == 302
    token = Repo.get!(StaffAccount, staff.id).login_token
    assert is_binary(token)

    conn = post(build_conn(), "/app/login/verify/#{token}")
    assert redirected_to(conn) == "/app"
    assert get_session(conn, :staff_id) == staff.id
  end

  test "logs in a non-ASCII address typed in a different case and composition" do
    n = System.unique_integer([:positive])

    staff =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "Ünal-#{n}@Bücher.de"
      })
      |> Repo.insert!()

    # Uppercase, with each umlaut as "U"/"u" followed by U+0308 COMBINING DIAERESIS
    typed = "U\u0308NAL-#{n}@BU\u0308CHER.DE"

    assert request_login({10, 44, 9, 1}, typed).status == 302
    token = Repo.get!(StaffAccount, staff.id).login_token
    assert is_binary(token)

    conn = post(build_conn(), "/app/login/verify/#{token}")
    assert get_session(conn, :staff_id) == staff.id
  end

  describe "magic link verification" do
    setup do
      staff =
        insert_staff_account(role: "admin")
        |> StaffAccount.login_token_changeset()
        |> Repo.update!()

      {:ok, staff: staff, token: staff.login_token}
    end

    test "GET peeks without consuming the token or starting a session",
         %{conn: conn, staff: staff, token: token} do
      conn = get(conn, "/app/login/verify/#{token}")

      assert html_response(conn, 200) =~ "auth-verify-form"
      refute get_session(conn, :staff_id)
      assert Repo.get!(StaffAccount, staff.id).login_token == token

      # A scanner can fetch the link any number of times
      assert html_response(get(build_conn(), "/app/login/verify/#{token}"), 200) =~
               "auth-verify-form"
    end

    test "POST consumes the token and starts the session",
         %{conn: conn, staff: staff, token: token} do
      conn = post(conn, "/app/login/verify/#{token}")

      assert redirected_to(conn) == "/app"
      assert get_session(conn, :staff_id) == staff.id
      # Binds the session to this account, not just to its (reusable) id.
      assert get_session(conn, :staff_claim) == StaffAccount.session_claim(staff)
      assert Repo.get!(StaffAccount, staff.id).login_token == nil

      # The session it issued is accepted
      assert html_response(get(recycle(conn), "/app"), 200)

      # The link works once
      again = post(build_conn(), "/app/login/verify/#{token}")
      assert html_response(again, 200) =~ "Invalid or expired login link"
      refute get_session(again, :staff_id)
    end

    test "an expired token is refused on GET and POST", %{
      conn: conn,
      staff: staff,
      token: token
    } do
      expired = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      staff
      |> Ecto.Changeset.change(login_token_expires_at: expired)
      |> Repo.update!()

      assert html_response(get(conn, "/app/login/verify/#{token}"), 200) =~ "has expired"
      posted = post(build_conn(), "/app/login/verify/#{token}")
      assert html_response(posted, 200) =~ "has expired"
      refute get_session(posted, :staff_id)
    end

    test "unknown and malformed tokens render the same invalid page", %{conn: conn} do
      unknown = get(conn, "/app/login/verify/" <> String.duplicate("a", 43))
      malformed = get(build_conn(), "/app/login/verify/not%20a%20token")

      assert html_response(unknown, 200) =~ "Invalid or expired login link"
      assert html_response(malformed, 200) =~ "Invalid or expired login link"
    end
  end

  describe "email normalization" do
    test "a mixed-case, padded email finds the account" do
      staff = insert_staff_account(email: "casey@example.com")

      assert request_login({10, 44, 8, 1}, "  Casey@Example.COM ").status == 302
      assert is_binary(Repo.get!(StaffAccount, staff.id).login_token)
    end

    test "case variants share one per-email rate-limit bucket" do
      staff = insert_staff_account(role: "admin")
      variants = [staff.email, String.upcase(staff.email), " " <> staff.email]

      for {email, n} <- Enum.with_index(Stream.cycle(variants) |> Enum.take(5), 1) do
        assert request_login({10, 44, 9, n}, email).status == 302
      end

      assert request_login({10, 44, 9, 6}, String.upcase(staff.email)).status == 429
    end
  end

  describe "login page" do
    test "shows the flash that sent the staff there", %{conn: conn} do
      denied = get(conn, "/app")
      assert redirected_to(denied) == "/app/login"

      login = get(recycle(denied), "/app/login")
      assert html_response(login, 200) =~ "Please sign in to this workspace"
    end
  end

  defp request_login(ip, email) do
    build_conn()
    |> Map.put(:remote_ip, ip)
    |> post("/app/login", %{"email" => email})
  end
end
