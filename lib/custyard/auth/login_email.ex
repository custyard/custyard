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

    Logger.info("operator_login_delivery_started", operator_id: operator.id)

    case Custyard.Mailer.deliver(email) do
      {:ok, _} = result ->
        # Provider acceptance does not establish inbox delivery.
        Logger.info("operator_login_provider_accepted", operator_id: operator.id)
        result

      {:error, reason} = error ->
        Logger.info(
          "operator_login_provider_rejected",
          [operator_id: operator.id] ++ failure_metadata(reason)
        )

        error
    end
  end

  # Provider errors can echo the email body, including the magic link. Only
  # emit a numeric HTTP status or a fixed, known reason; never inspect them.
  defp failure_metadata({status, _response}) when is_integer(status) and status in 100..599 do
    [reason: :provider_response, provider_status: status]
  end

  defp failure_metadata(reason)
       when reason in [:timeout, :closed, :econnrefused, :nxdomain, :from_not_set] do
    [reason: reason]
  end

  defp failure_metadata(_reason), do: [reason: :delivery_error]

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
        <p style="color: #374151; font-size: 16px; margin-top: 0;">Click the button below to log in to your account:</p>
        <div style="text-align: center; margin: 24px 0;">
          <a href="#{login_url}" style="display: inline-block; background: #4f46e5; color: white; padding: 12px 32px; border-radius: 6px; text-decoration: none; font-weight: 600; font-size: 16px;">
            Log in to Custyard
          </a>
        </div>
        <p style="color: #6b7280; font-size: 14px;">Or copy and paste this link into your browser:</p>
        <p style="color: #4f46e5; font-size: 14px; word-break: break-all;">#{login_url}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #9ca3af; font-size: 12px; margin-bottom: 0;">
          This link expires in #{Custyard.Auth.Account.login_token_ttl_minutes()} minutes.
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

    Click this link to log in to your account:

    #{login_url}

    This link expires in #{Custyard.Auth.Account.login_token_ttl_minutes()} minutes.
    If you didn't request this, you can safely ignore this email.
    """
  end
end
