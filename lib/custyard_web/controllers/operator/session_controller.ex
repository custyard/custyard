defmodule CustyardWeb.Operator.SessionController do
  use CustyardWeb, :controller

  alias Custyard.{OperatorAccount, Repo}
  alias Custyard.Auth.LoginEmail

  require Logger

  # Base64url character class for validating token format
  @token_pattern ~r/^[A-Za-z0-9_-]+$/

  plug CustyardWeb.Plugs.LoginRateLimit,
       [max_attempts: 5, window_ms: 60_000] when action == :create

  def new(conn, _params) do
    render(conn, :new, error: nil, email: nil, info: nil, layout: {CustyardWeb.Layouts, :root})
  end

  def create(conn, %{"email" => email}) do
    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        # Don't reveal whether the email exists — always show success message
        Logger.debug("Login attempt for non-existent email: #{email}")

        render(conn, :sent,
          email: email,
          layout: {CustyardWeb.Layouts, :root}
        )

      operator ->
        updated_operator =
          operator
          |> OperatorAccount.login_token_changeset()
          |> Repo.update!()

        login_url =
          CustyardWeb.Endpoint.url() <>
            ~p"/operator/login/verify/#{updated_operator.login_token}"

        LoginEmail.deliver_login_link(updated_operator, login_url)

        render(conn, :sent,
          email: email,
          layout: {CustyardWeb.Layouts, :root}
        )
    end
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
