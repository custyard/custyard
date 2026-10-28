defmodule CustyardWeb.Admin.SessionController do
  use CustyardWeb, :controller
  alias Custyard.{Auth.Account, Auth.LoginEmail, InstanceAdmin, InstanceAdmins, Repo, Tenants}
  plug CustyardWeb.Plugs.PublicRateLimit, [bucket: :account_login_ip] when action == :create
  plug :installation_host

  defp installation_host(conn, _) do
    if Tenants.normalize_host(conn.host) == Tenants.normalize_host(Tenants.app_host()),
      do: conn,
      else: conn |> send_resp(404, "Not found") |> halt()
  end

  def new(conn, _), do: login_form(conn, nil)

  def create(conn, %{"email" => email}) when is_binary(email) do
    case Custyard.RateLimit.check_rate(
           :account_login_email,
           {:instance_admin, Account.normalize_email(email)}
         ) do
      {:allow, _} ->
        if admin = InstanceAdmins.get_by_email(email) do
          admin = Account.ensure_login_token(admin)

          LoginEmail.deliver_login_link(
            admin,
            CustyardWeb.Endpoint.url() <> "/admin/login/verify/" <> admin.login_token
          )
        end

        conn
        |> put_view(CustyardWeb.Staff.SessionHTML)
        |> render(:sent,
          email: email,
          auth_base: "/admin",
          auth_title: "Instance admin sign in",
          layout: false
        )

      {:deny, _} ->
        conn |> put_status(429) |> html("Too many login requests")
    end
  end

  def create(conn, _), do: login_form(conn, "Enter an email address")

  def verify(conn, %{"token" => token}) do
    with %InstanceAdmin{} = admin <- lookup(token),
         true <- Account.verify_login_token(admin, token) do
      conn
      |> put_view(CustyardWeb.Staff.SessionHTML)
      |> render(:verify,
        token: token,
        auth_base: "/admin",
        auth_title: "Instance admin sign in",
        layout: false
      )
    else
      _ -> login_form(conn, "Invalid or expired login link")
    end
  end

  def consume(conn, %{"token" => token}) do
    with %InstanceAdmin{} = admin <- lookup(token),
         true <- Account.verify_login_token(admin, token),
         :ok <- Account.consume_login_token(admin, token) do
      conn
      |> configure_session(renew: true)
      |> put_session(:instance_admin_id, admin.id)
      |> put_session(:instance_admin_claim, admin.session_claim)
      |> redirect(to: "/admin")
    else
      _ -> login_form(conn, "Invalid or expired login link")
    end
  end

  def delete(conn, _),
    do: conn |> clear_session() |> configure_session(drop: true) |> redirect(to: "/admin/login")

  defp lookup(token) when is_binary(token) and byte_size(token) == 43,
    do: Repo.get_by(InstanceAdmin, login_token: token)

  defp lookup(_), do: nil

  defp login_form(conn, error) do
    conn
    |> put_view(CustyardWeb.Staff.SessionHTML)
    |> render(:new,
      error: error,
      email: nil,
      info: nil,
      auth_base: "/admin",
      auth_title: "Instance admin sign in",
      layout: false
    )
  end
end
