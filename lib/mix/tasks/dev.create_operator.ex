defmodule Mix.Tasks.Dev.CreateOperator do
  @moduledoc """
  Create an operator account for email-only authentication.

  ## Usage

      mix dev.create_operator [--email EMAIL]

  If no email is provided, uses admin@custyard.local (the dev mailbox at
  /dev/mailbox receives its login links). The email is stored lowercased.
  An existing account is reported and never modified.

  Starts only the Repo, not the application, so it works while
  `mix phx.server` is running.

  ## Examples

      mix dev.create_operator
      mix dev.create_operator --email ops@example.com
  """

  use Mix.Task

  alias Custyard.OperatorAccounts

  @shortdoc "Create an operator account"

  @default_email "admin@custyard.local"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [email: :string])

    email = Keyword.get(opts, :email, @default_email)

    Mix.Task.run("app.config")

    {:ok, result, _started} =
      Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
        OperatorAccounts.create_operator(email, via: "mix", allow_placeholder: true)
      end)

    case result do
      {:created, operator} ->
        Mix.shell().info("""

        ========================================
        OPERATOR ACCOUNT CREATED
        ========================================
        Email: #{operator.email}

        Login at: /operator/login
        A magic link will be sent to this email address.
        ========================================
        """)

      {:exists, operator} ->
        Mix.shell().info(
          "Operator account already exists for: #{operator.email} " <>
            "(role #{operator.role}), not modified"
        )

      {:error, message} ->
        Mix.raise("Could not create operator: #{message}")
    end
  end
end
