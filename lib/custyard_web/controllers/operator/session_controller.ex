defmodule CustyardWeb.Operator.SessionController do
  use CustyardWeb, :controller

  alias Custyard.{Repo, OperatorAccount}

  def new(conn, _params) do
    render(conn, :new, error: nil, layout: {CustyardWeb.Layouts, :root})
  end

  def create(conn, %{"email" => email, "password" => password}) do
    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        # Timing attack protection
        OperatorAccount.verify_password(nil, password)

        render(conn, :new,
          error: "Invalid email or password",
          layout: {CustyardWeb.Layouts, :root}
        )

      operator ->
        if OperatorAccount.verify_password(operator, password) do
          conn
          |> put_session(:operator_id, operator.id)
          |> put_flash(:info, "Welcome back")
          |> redirect(to: ~p"/operator")
        else
          render(conn, :new,
            error: "Invalid email or password",
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
