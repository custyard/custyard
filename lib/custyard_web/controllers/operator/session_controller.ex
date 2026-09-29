defmodule CustyardWeb.Operator.SessionController do
  use CustyardWeb, :controller

  alias Custyard.{OperatorAccount, RateLimit, Repo}
  alias Custyard.Auth.LoginEmail

  require Logger

  # Base64url character class for validating token format
  @token_pattern ~r/^[A-Za-z0-9_-]+$/

  plug CustyardWeb.Plugs.PublicRateLimit,
       [bucket: :operator_login_ip] when action == :create

  def new(conn, _params) do
    render(conn, :new, error: nil, email: nil, info: nil, layout: {CustyardWeb.Layouts, :root})
  end

  def create(conn, %{"email" => email}) when is_binary(email) and email != "" do
    email = email |> String.trim() |> String.downcase()

    case RateLimit.check_rate(:operator_login_email, email) do
      {:deny, retry_after_ms} ->
        retry_after_s = max(div(retry_after_ms + 999, 1000), 1)

        conn
        |> put_resp_header("retry-after", Integer.to_string(retry_after_s))
        |> put_status(429)
        |> put_view(CustyardWeb.ErrorHTML)
        |> render("429.html")

      {:allow, _count} ->
        deliver_login_link(conn, email)
    end
  end

  def create(conn, _params) do
    render(conn, :new,
      error: "Email is required.",
      email: nil,
      info: nil,
      layout: {CustyardWeb.Layouts, :root}
    )
  end

  defp deliver_login_link(conn, email) do
    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        # Don't reveal whether the email exists — always show success page
        Logger.debug("Login attempt for non-existent email: #{email}")

      operator ->
        updated_operator =
          operator
          |> OperatorAccount.login_token_changeset()
          |> Repo.update!()

        login_url =
          CustyardWeb.Endpoint.url() <>
            ~p"/operator/login/verify/#{updated_operator.login_token}"

        LoginEmail.deliver_login_link(updated_operator, login_url)
    end

    # Keep the response identical whether the account exists or not.
    conn
    |> put_session(:login_sent_email, email)
    |> redirect(to: ~p"/operator/login/sent")
  end

  def sent(conn, _params) do
    email = get_session(conn, :login_sent_email)

    conn
    |> delete_session(:login_sent_email)
    |> render(:sent, email: email || "", layout: {CustyardWeb.Layouts, :root})
  end

  def verify(conn, %{"token" => token}) do
    if String.match?(token, @token_pattern) do
      case Repo.get_by(OperatorAccount, login_token: token) do
        nil ->
          render_invalid_token(conn)

        operator ->
          if OperatorAccount.verify_login_token(operator, token) do
            # Clear the token so it can't be reused
            operator
            |> OperatorAccount.clear_login_token_changeset()
            |> Repo.update!()

            conn
            |> configure_session(renew: true)
            |> put_session(:operator_id, operator.id)
            |> put_flash(:info, "Welcome back")
            |> redirect(to: ~p"/operator")
          else
            render(conn, :new,
              error: "This login link has expired. Please request a new one.",
              email: nil,
              info: nil,
              layout: {CustyardWeb.Layouts, :root}
            )
          end
      end
    else
      render_invalid_token(conn)
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:operator_id)
    |> put_flash(:info, "Logged out")
    |> redirect(to: ~p"/operator/login")
  end

  defp render_invalid_token(conn) do
    render(conn, :new,
      error: "Invalid or expired login link. Please request a new one.",
      email: nil,
      info: nil,
      layout: {CustyardWeb.Layouts, :root}
    )
  end
end
