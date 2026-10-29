defmodule CustyardWeb.Admin.SessionControllerTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  import Swoosh.TestAssertions
  alias Custyard.{Auth.Account, InstanceAdmins, Repo, Tenants}

  @moduletag :explicit_tenant_hosts

  setup do
    {:created, admin} =
      InstanceAdmins.create_admin("instance-#{System.unique_integer([:positive])}@example.com")

    %{admin: admin}
  end

  test "rate limits successful and unknown requests by IP", c do
    ip = {10, 73, 1, 1}
    for _ <- 1..5, do: assert(request_login(ip, c.admin.email).status == 200)
    token = Repo.reload!(c.admin).login_token
    denied = request_login(ip, c.admin.email)
    assert denied.status == 429
    assert get_resp_header(denied, "retry-after") != []
    assert Repo.reload!(c.admin).login_token == token
  end

  test "email limits apply across IPs and case variants without exposing account existence", c do
    for {email, n} <-
          Enum.with_index(
            [
              c.admin.email,
              String.upcase(c.admin.email),
              "  " <> c.admin.email,
              c.admin.email,
              c.admin.email
            ],
            1
          ) do
      assert request_login({10, 73, 2, n}, email).status == 200
    end

    assert request_login({10, 73, 2, 6}, c.admin.email).status == 429
    unknown = "unknown-#{System.unique_integer([:positive])}@example.com"
    for n <- 1..5, do: assert(request_login({10, 73, 3, n}, unknown).status == 200)
    assert request_login({10, 73, 3, 6}, unknown).status == 429
    refute InstanceAdmins.get_by_email(unknown)
  end

  test "re-sends the current link and replaces it only after expiry", c do
    assert request_login({10, 73, 4, 1}, c.admin.email).status == 200
    original = Repo.reload!(c.admin)
    assert is_binary(original.login_token)

    assert_email_sent(fn email ->
      String.contains?(email.text_body, "/admin/login/verify/#{original.login_token}")
    end)

    assert request_login({10, 73, 4, 2}, c.admin.email).status == 200
    assert Repo.reload!(c.admin).login_token == original.login_token
    Repo.update!(Ecto.Changeset.change(original, login_token_expires_at: expired()))
    assert request_login({10, 73, 4, 3}, c.admin.email).status == 200
    refute Repo.reload!(c.admin).login_token == original.login_token
  end

  test "normalizes padded Unicode emails before lookup and binds the admin session" do
    {:created, admin} = InstanceAdmins.create_admin("Ünal@example.com")
    assert request_login({10, 73, 5, 1}, "  U\u0308NAL@EXAMPLE.COM ").status == 200
    token = Repo.reload!(admin).login_token
    conn = post(installation_conn(), "/admin/login/verify/#{token}")
    assert redirected_to(conn) == "/admin"
    assert get_session(conn, :instance_admin_id) == admin.id
    assert get_session(conn, :instance_admin_claim) == admin.session_claim
    refute get_session(conn, :staff_id)
  end

  test "GET is scanner safe, POST consumes once and logout drops the session", c do
    admin = Account.ensure_login_token(c.admin)

    for _ <- 1..2 do
      fetched = get(installation_conn(), "/admin/login/verify/#{admin.login_token}")
      assert html_response(fetched, 200) =~ "auth-verify-form"
      refute get_session(fetched, :instance_admin_id)
      assert Repo.reload!(admin).login_token == admin.login_token
    end

    logged_in = post(installation_conn(), "/admin/login/verify/#{admin.login_token}")
    assert redirected_to(logged_in) == "/admin"
    assert get_session(logged_in, :instance_admin_id) == admin.id
    assert is_nil(Repo.reload!(admin).login_token)
    assert html_response(get(recycle(logged_in), "/admin"), 200)
    reused = post(installation_conn(), "/admin/login/verify/#{admin.login_token}")
    assert html_response(reused, 200) =~ "Invalid or expired login link"
    refute get_session(reused, :instance_admin_id)
    logged_out = delete(recycle(logged_in), "/admin/logout")
    assert redirected_to(logged_out) == "/admin/login"
    refute get_session(logged_out, :instance_admin_id)
    assert redirected_to(get(recycle(logged_out), "/admin")) == "/admin/login"
  end

  test "expired, unknown and malformed tokens do not grant installation access", c do
    admin = Account.ensure_login_token(c.admin)
    Repo.update!(Ecto.Changeset.change(admin, login_token_expires_at: expired()))

    for token <- [admin.login_token, String.duplicate("x", 43), "malformed"] do
      fetched = get(installation_conn(), "/admin/login/verify/#{token}")
      posted = post(installation_conn(), "/admin/login/verify/#{token}")
      assert html_response(fetched, 200) =~ "Invalid or expired login link"
      assert html_response(posted, 200) =~ "Invalid or expired login link"
      refute get_session(posted, :instance_admin_id)
    end
  end

  test "tenant staff tokens and tenant hosts cannot enter the installation realm", c do
    tenant = insert_tenant()
    {:ok, _} = Tenants.add_host(tenant.id, "tenant-admin-test.example.com")
    staff = insert_staff_account(tenant_id: tenant.id) |> Account.ensure_login_token()
    refused = post(installation_conn(), "/admin/login/verify/#{staff.login_token}")
    assert html_response(refused, 200) =~ "Invalid or expired login link"
    refute get_session(refused, :instance_admin_id)
    admin = Account.ensure_login_token(c.admin)
    foreign_host = %{build_conn() | host: "tenant-admin-test.example.com"}
    assert get(foreign_host, "/admin/login").status == 404
    assert post(foreign_host, "/admin/login/verify/#{admin.login_token}").status == 404
    assert Repo.reload!(admin).login_token == admin.login_token
  end

  test "a revoked administrator session cannot access the instance console", c do
    admin = Account.ensure_login_token(c.admin)
    logged_in = post(installation_conn(), "/admin/login/verify/#{admin.login_token}")
    assert redirected_to(logged_in) == "/admin"
    Repo.update!(Ecto.Changeset.change(admin, session_claim: Account.generate_session_claim()))
    assert redirected_to(get(recycle(logged_in), "/admin")) == "/admin/login"
  end

  defp expired, do: DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
  defp installation_conn, do: %{build_conn() | host: Tenants.app_host()}

  defp request_login(ip, email),
    do:
      installation_conn() |> Map.put(:remote_ip, ip) |> post("/admin/login", %{"email" => email})
end
