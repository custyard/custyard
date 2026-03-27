defmodule Mix.Tasks.Dev.ResetOperatorPassword do
  @moduledoc """
  Reset the password for a dev operator account.

  ## Usage

      mix dev.reset_operator_password [password] [--email EMAIL]

  If no password is provided, generates a random one.
  If no email is provided, uses admin@custyard.local.

  ## Examples

      mix dev.reset_operator_password
      mix dev.reset_operator_password mysecretpassword
      mix dev.reset_operator_password --email other@example.com
  """

  use Mix.Task

  @shortdoc "Reset dev operator password"

  @default_email "admin@custyard.local"

  @impl Mix.Task
  def run(args) do
    {opts, positional, _} = OptionParser.parse(args, strict: [email: :string])

    email = Keyword.get(opts, :email, @default_email)
    password = List.first(positional) || generate_password()

    Mix.Task.run("app.start")

    alias Custyard.{OperatorAccount, Repo}

    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        Mix.shell().error("No operator account found with email: #{email}")

      operator ->
        operator
        |> OperatorAccount.changeset(%{password: password})
        |> Repo.update!()

        Mix.shell().info("""

        ========================================
        OPERATOR PASSWORD RESET
        ========================================
        Email:    #{email}
        Password: #{password}

        Login at: /operator/login
        ========================================
        """)
    end
  end

  defp generate_password do
    :crypto.strong_rand_bytes(12) |> Base.url_encode64() |> binary_part(0, 16)
  end
end
