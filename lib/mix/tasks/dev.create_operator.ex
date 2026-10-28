defmodule Mix.Tasks.Dev.CreateOperator do
  @moduledoc """
  Create an installation administrator for email-only authentication.

  ## Usage

      mix dev.create_operator [--email EMAIL]

  Supply --email or INSTANCE_ADMIN_EMAIL explicitly. In development,
  /dev/mailbox receives login links. The email is stored lowercased.
  An existing account is reported and never modified.

  Starts only the Repo, not the application, so it works while
  `mix phx.server` is running.

  ## Examples

      mix dev.create_operator
      mix dev.create_operator --email ops@example.com
  """

  use Mix.Task

  alias Custyard.InstanceAdmins

  @shortdoc "Create an installation administrator"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [email: :string])

    email = Keyword.get(opts, :email) || System.get_env("INSTANCE_ADMIN_EMAIL")

    unless is_binary(email) and String.trim(email) != "",
      do: Mix.raise("Set INSTANCE_ADMIN_EMAIL or pass --email")

    Mix.Task.run("app.config")

    {:ok, result, _started} =
      Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
        InstanceAdmins.create_admin(email)
      end)

    case result do
      {:created, operator} ->
        Mix.shell().info("""

        ========================================
        INSTANCE ADMIN ACCOUNT CREATED
        ========================================
        Email: #{operator.email}

        Login at: /admin/login
        A magic link will be sent to this email address.
        ========================================
        """)

      {:exists, operator} ->
        Mix.shell().info(
          "Instance admin account already exists for: #{operator.email} " <>
            "(role #{"instance admin"}), not modified"
        )

      {:error, message} ->
        Mix.raise("Could not create instance admin: #{inspect(message)}")
    end
  end
end
