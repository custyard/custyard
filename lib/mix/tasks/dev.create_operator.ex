defmodule Mix.Tasks.Dev.CreateOperator do
  @moduledoc """
  Create an operator account for email-only authentication.

  ## Usage

      mix dev.create_operator [--email EMAIL]

  If no email is provided, uses admin@custyard.local.

  ## Examples

      mix dev.create_operator
      mix dev.create_operator --email ops@example.com
  """

  use Mix.Task

  @shortdoc "Create an operator account"

  @default_email "admin@custyard.local"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [email: :string])

    email = Keyword.get(opts, :email, @default_email)

    Mix.Task.run("app.start")

    alias Custyard.{OperatorAccount, Repo}

    case Repo.get_by(OperatorAccount, email: email) do
      nil ->
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: email})
        |> Repo.insert!()

        Mix.shell().info("""

        ========================================
        OPERATOR ACCOUNT CREATED
        ========================================
        Email: #{email}

        Login at: /operator/login
        A magic link will be sent to this email address.
        ========================================
        """)

      _existing ->
        Mix.shell().info("Operator account already exists for: #{email}")
    end
  end
end
