defmodule CustyardWeb.Operator.SessionController do
  use CustyardWeb, :controller

  alias Custyard.{OperatorAccount, Repo}
  alias Custyard.Auth.LoginEmail

  require Logger

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
        changeset = OperatorAccount.login_token_changeset(operator)

        case Repo.update(changeset) do
          {:ok, updated_operator} ->
            login_url = url(conn, ~p"/operator/login/verify/#{updated_operator.login_token}")
            LoginEmail.deliver_login_link(updated_operator, login_url)

          {:error, reason} ->
            Logger.error("Failed to generate login token: #{inspect(reason)}")
        end

        render(conn, :sent,
          email: email,
          layout: {CustyardWeb.Layouts, :root}
        )
    end
  end

  def verify(conn, %{"token" => token}) do
    case Repo.get_by(OperatorAccount, login_token: token) do
      nil ->
        render(conn, :new,
          error: "Invalid or expired login link. Please request a new one.",
          email: nil,
          info: nil,
          layout: {CustyardWeb.Layouts, :root}
        )

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
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:operator_id)
    |> put_flash(:info, "Logged out")
    |> redirect(to: ~p"/operator/login")
  end
end
