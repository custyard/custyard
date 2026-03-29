defmodule Mix.Tasks.Dev.ResetOperatorPassword do
  @moduledoc """
  This task is deprecated. Custyard now uses email-only authentication
  with magic links. Operators log in by requesting a login link via email.

  To create a new operator account, use:

      mix dev.create_operator --email operator@example.com

  ## Usage (legacy, kept for compatibility)

      mix dev.reset_operator_password [password] [--email EMAIL]
  """

  use Mix.Task

  @shortdoc "Deprecated: Custyard now uses email-only auth"

  @impl Mix.Task
  def run(_args) do
    Mix.shell().info("""

    ========================================
    DEPRECATED
    ========================================
    Custyard now uses email-only authentication.
    Operators log in via magic link — no passwords needed.

    To create a new operator account:
      mix dev.create_operator --email operator@example.com
    ========================================
    """)
  end
end
