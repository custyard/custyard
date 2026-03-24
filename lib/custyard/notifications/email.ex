defmodule Custyard.Notifications.Email do
  @moduledoc """
  Email notification dispatch for the platform.

  This module provides a stub implementation that logs notifications.
  To enable actual email delivery, integrate with Swoosh:

  1. Add {:swoosh, "~> 1.5"} to mix.exs deps
  2. Configure a mailer in config/runtime.exs
  3. Replace the stub implementations below with Swoosh email composition

  See: https://hexdocs.pm/swoosh/readme.html
  """

  require Logger

  @doc """
  Deliver a neglect alert notification for a conversation.

  In production, this would compose and send an email to the configured
  operator notification address.
  """
  def deliver_neglect_alert(conversation, level) do
    if email_enabled?() do
      send_neglect_alert(conversation, level)
    else
      log_neglect_alert(conversation, level)
    end
  end

  defp email_enabled? do
    Application.get_env(:custyard, :email_enabled, false)
  end

  defp log_neglect_alert(conversation, level) do
    Logger.info("""
    [Email stub] Neglect alert would be sent:
      Level: #{level}
      Conversation: #{conversation.id} - #{conversation.subject}
      Organization: #{conversation.organization.name}
      Contact: #{contact_display(conversation.contact)}
    """)

    :ok
  end

  defp send_neglect_alert(_conversation, _level) do
    # TODO: Implement with Swoosh when email is configured
    #
    # Example implementation:
    #
    # import Swoosh.Email
    #
    # new()
    # |> to(Application.get_env(:custyard, :operator_email))
    # |> from({"Service Platform", "notifications@example.com"})
    # |> subject("[#{level}] Neglect alert: #{conversation.subject}")
    # |> html_body(neglect_alert_html(conversation, level))
    # |> text_body(neglect_alert_text(conversation, level))
    # |> Custyard.Mailer.deliver()

    :ok
  end

  defp contact_display(nil), do: "Unknown"
  defp contact_display(contact), do: contact.name || contact.email
end
