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
      Organization: #{organization_display(conversation.organization)}
      Contact: #{contact_display(conversation.contact)}
    """)

    :ok
  end

  defp send_neglect_alert(conversation, level) do
    import Swoosh.Email

    operator_email = Application.get_env(:custyard, :operator_email, "operator@example.com")
    from_name = Application.get_env(:custyard, :email_from_name, "Custyard Alerts")
    from_email = Application.get_env(:custyard, :email_from_address, "alerts@custyard.local")

    email =
      new()
      |> to(operator_email)
      |> from({from_name, from_email})
      |> subject("[#{String.upcase(to_string(level))}] Neglect alert: #{conversation.subject}")
      |> html_body(neglect_alert_html(conversation, level))
      |> text_body(neglect_alert_text(conversation, level))

    case Custyard.Mailer.deliver(email) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send neglect alert email: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp neglect_alert_html(conversation, level) do
    safe_subject = html_escape(conversation.subject)
    safe_org_name = html_escape(organization_display(conversation.organization))
    safe_contact = html_escape(contact_display(conversation.contact))

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <div style="background: #{level_color(level)}; color: white; padding: 16px; border-radius: 8px 8px 0 0;">
        <h2 style="margin: 0;">#{String.upcase(to_string(level))} Neglect Alert</h2>
      </div>
      <div style="padding: 16px; border: 1px solid #e5e7eb; border-top: none; border-radius: 0 0 8px 8px;">
        <p><strong>Conversation:</strong> #{safe_subject}</p>
        <p><strong>Organization:</strong> #{safe_org_name}</p>
        <p><strong>Contact:</strong> #{safe_contact}</p>
        <p><strong>Last activity:</strong> #{format_datetime(last_activity(conversation))}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #6b7280; font-size: 14px;">
          This conversation requires attention. Please review and respond promptly.
        </p>
      </div>
    </body>
    </html>
    """
  end

  defp neglect_alert_text(conversation, level) do
    """
    #{String.upcase(to_string(level))} NEGLECT ALERT

    Conversation: #{conversation.subject}
    Organization: #{organization_display(conversation.organization)}
    Contact: #{contact_display(conversation.contact)}
    Last activity: #{format_datetime(last_activity(conversation))}

    This conversation requires attention. Please review and respond promptly.
    """
  end

  defp level_color(:warning), do: "#f59e0b"
  defp level_color(:critical), do: "#ef4444"
  defp level_color(_), do: "#6b7280"

  defp format_datetime(nil), do: "Unknown"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M UTC")

  # Returns the most recent activity timestamp (customer or operator action)
  defp last_activity(conversation) do
    [conversation.last_customer_action_at, conversation.last_operator_action_at]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  defp contact_display(nil), do: "Unknown"
  defp contact_display(contact), do: contact.name || contact.email

  # Conversations without an organization (unlinked prospects) can now reach
  # neglect notifications; render a neutral label instead of crashing.
  defp organization_display(nil), do: "Unlinked prospect"
  defp organization_display(organization), do: organization.name

  defp html_escape(value) when is_binary(value) do
    # Use Phoenix.HTML.html_escape/1 which returns {:safe, iodata}
    # Extract the iodata and convert to binary string
    case Phoenix.HTML.html_escape(value) do
      {:safe, iodata} -> IO.iodata_to_binary(iodata)
      # Fallback for already-safe content
      iodata when is_list(iodata) or is_binary(iodata) -> IO.iodata_to_binary(iodata)
    end
  end

  defp html_escape(nil), do: ""
end
