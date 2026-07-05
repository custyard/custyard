defmodule Custyard.Auth.LoginEmail do
  @moduledoc """
  Composes magic link login emails for operator authentication.
  """

  import Swoosh.Email

  require Logger

  def deliver_login_link(operator, login_url) do
    email =
      new()
      |> to(operator.email)
      |> from({"Custyard", from_address()})
      |> subject("Your Custyard login link")
      |> html_body(login_html(login_url))
      |> text_body(login_text(login_url))

    case Custyard.Mailer.deliver(email) do
      {:ok, _} = result ->
        Logger.info("Login link email sent to #{operator.email}")
        result

      {:error, reason} = error ->
        Logger.error("Failed to send login email to #{operator.email}: #{inspect(reason)}")
        error
    end
  end

  defp from_address do
    Application.get_env(:custyard, :email_from_address, "noreply@custyard.local")
  end

  defp login_html(login_url) do
    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 20px;">
      <div style="text-align: center; margin-bottom: 24px;">
        <h1 style="color: #1f2937; margin: 0;">Custyard</h1>
      </div>
      <div style="background: #f9fafb; border: 1px solid #e5e7eb; border-radius: 8px; padding: 24px;">
        <p style="color: #374151; font-size: 16px; margin-top: 0;">Click the button below to log in to your operator account:</p>
        <div style="text-align: center; margin: 24px 0;">
          <a href="#{login_url}" style="display: inline-block; background: #4f46e5; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Log in to Custyard
          </a>
        </div>
        <p style="color: #6b7280; font-size: 14px;">Or copy and paste this link into your browser:</p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{login_url}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">
          This link expires in #{Custyard.OperatorAccount.login_token_ttl_minutes()} minutes.
          If you didn't request this, you can safely ignore this email.
        </p>
      </div>
    </body>
    </html>
    """
  end

  defp login_text(login_url) do
    """
    Log in to Custyard

    Click this link to log in to your operator account:

    #{login_url}

    This link expires in #{Custyard.OperatorAccount.login_token_ttl_minutes()} minutes.
    If you didn't request this, you can safely ignore this email.
    """
  end
end
