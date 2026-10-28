defmodule Custyard.Notifications.Email do
  @moduledoc """
  Operator email alerts for neglect, quiet channels, and delivery failures.
  Each tenant uses its staff recipients and sending credentials.
  """

  require Logger
  alias Custyard.Notifications.TenantDelivery

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

  @doc """
  Deliver the quiet-channel notice for an inbound channel
  (docs/design/spec-inbound-channels.md, D7): the channel was receiving mail
  and nothing has arrived for its quiet window. Expects `inbound_route` and
  `organization` preloaded, as `InboundChannels.list_quiet_channels/1`
  returns them. The notice names the public address and the window; it
  never carries message content, and the log stub never carries the address.
  """
  def deliver_channel_quiet(channel) do
    if email_enabled?() do
      send_channel_quiet(channel)
    else
      log_channel_quiet(channel)
    end
  end

  @doc """
  Tell the operator that a reply did not reach a recipient
  (spec-conversation-loop, "Bounce and Suppression Handling"). `status` is
  `:bounced` or `:suppressed`; `recipient` is the address the provider
  named and `role` which list it was on (`:to`, the customer's copy, or
  `:cc` / `:other`, a copy whose failure leaves the customer's delivery
  as it is). One notice goes out per recipient that fails. Expects
  `organization` and `contact` preloaded on the conversation. The log stub
  carries neither the address nor the subject.
  """
  def deliver_delivery_failure(conversation, status, recipient, role \\ :to)
      when status in [:bounced, :suppressed] do
    if email_enabled?() do
      send_delivery_failure(conversation, status, recipient, role)
    else
      log_delivery_failure(conversation, status)
    end
  end

  defp email_enabled? do
    Application.get_env(:custyard, :email_enabled, false)
  end

  defp log_channel_quiet(channel) do
    Logger.info(
      "[Email stub] Quiet channel notice would be sent: channel #{channel.id} " <>
        "quiet for more than #{channel.quiet_after_hours}h"
    )

    :ok
  end

  defp send_channel_quiet(channel) do
    import Swoosh.Email

    email =
      new()
      |> subject("Inbound channel quiet: #{channel.public_address}")
      |> html_body(channel_quiet_html(channel))
      |> text_body(channel_quiet_text(channel))

    case TenantDelivery.deliver(email, channel.tenant_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send quiet channel notice for channel #{channel.id}")

        {:error, reason}
    end
  end

  @channel_quiet_explanation "Forwarding rules get silently disabled when a mailbox password " <>
                               "changes or a plan lapses; a quiet channel is the only way Custyard " <>
                               "can tell. Check the forwarding rule at the mail provider and send " <>
                               "yourself a test message."

  defp channel_quiet_html(channel) do
    safe_address = html_escape(channel.public_address)
    safe_org_name = html_escape(tenant_display(channel.tenant_id))

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <div style="background: #f59e0b; color: white; padding: 16px; border-radius: 8px 8px 0 0;">
        <h2 style="margin: 0;">Inbound channel quiet</h2>
      </div>
      <div style="padding: 16px; border: 1px solid #e5e7eb; border-top: none; border-radius: 0 0 8px 8px;">
        <p><strong>Channel:</strong> #{safe_address}</p>
        <p><strong>Workspace:</strong> #{safe_org_name}</p>
        <p><strong>Last message received:</strong> #{format_datetime(channel.last_received_at)}</p>
        <p><strong>Quiet window:</strong> #{channel.quiet_after_hours} hours</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #6b7280; font-size: 14px;">
          #{@channel_quiet_explanation}
        </p>
      </div>
    </body>
    </html>
    """
  end

  defp channel_quiet_text(channel) do
    """
    INBOUND CHANNEL QUIET

    Channel: #{channel.public_address}
    Workspace: #{tenant_display(channel.tenant_id)}
    Last message received: #{format_datetime(channel.last_received_at)}
    Quiet window: #{channel.quiet_after_hours} hours

    #{@channel_quiet_explanation}
    """
  end

  defp log_delivery_failure(conversation, status) do
    Logger.info(
      "[Email stub] Delivery failure notice would be sent: conversation #{conversation.id} " <>
        "reply #{status}"
    )

    :ok
  end

  defp send_delivery_failure(conversation, status, recipient, role) do
    import Swoosh.Email

    email =
      new()
      |> subject("Reply #{status}: #{conversation.subject}")
      |> html_body(delivery_failure_html(conversation, status, recipient, role))
      |> text_body(delivery_failure_text(conversation, status, recipient, role))

    case TenantDelivery.deliver(email, conversation.tenant_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send delivery failure notice for conversation #{conversation.id}")

        {:error, reason}
    end
  end

  @contact_flag_note "If the address belongs to a contact, the contact is flagged until a " <>
                       "reply to it is delivered."

  defp delivery_failure_explanation(:bounced),
    do:
      "The recipient's mail server refused the reply. Check the address with the customer. " <>
        "Custyard does not stop sending to it. " <> @contact_flag_note

  defp delivery_failure_explanation(:suppressed),
    do:
      "The email provider did not send the reply because the address is on its suppression " <>
        "list, usually after earlier bounces or a spam complaint. " <> @contact_flag_note

  # A secondary recipient's failure says nothing about the customer's copy,
  # whose status the thread shows on its own.
  defp role_note(:to), do: ""

  defp role_note(_role),
    do:
      " This address was copied on the reply; the customer's own copy is tracked " <>
        "separately and is not affected."

  defp recipient_label(recipient, :to), do: recipient
  defp recipient_label(recipient, :cc), do: "#{recipient} (CC)"
  defp recipient_label(recipient, _role), do: "#{recipient} (copy)"

  defp delivery_failure_html(conversation, status, recipient, role) do
    safe_subject = html_escape(conversation.subject)
    safe_org_name = html_escape(organization_display(conversation.organization))
    safe_recipient = html_escape(recipient_label(recipient, role))

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto;">
      <div style="background: #ef4444; color: white; padding: 16px; border-radius: 8px 8px 0 0;">
        <h2 style="margin: 0;">Reply #{status}</h2>
      </div>
      <div style="padding: 16px; border: 1px solid #e5e7eb; border-top: none; border-radius: 0 0 8px 8px;">
        <p><strong>Conversation:</strong> #{safe_subject}</p>
        <p><strong>Organization:</strong> #{safe_org_name}</p>
        <p><strong>Recipient:</strong> #{safe_recipient}</p>
        <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 16px 0;">
        <p style="color: #6b7280; font-size: 14px;">
          #{delivery_failure_explanation(status)}#{role_note(role)}
        </p>
      </div>
    </body>
    </html>
    """
  end

  defp delivery_failure_text(conversation, status, recipient, role) do
    """
    REPLY #{String.upcase(to_string(status))}

    Conversation: #{conversation.subject}
    Organization: #{organization_display(conversation.organization)}
    Recipient: #{recipient_label(recipient, role)}

    #{delivery_failure_explanation(status)}#{role_note(role)}
    """
  end

  defp tenant_display(tenant_id), do: Custyard.Tenants.get_tenant!(tenant_id).name

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

    email =
      new()
      |> subject("[#{String.upcase(to_string(level))}] Neglect alert: #{conversation.subject}")
      |> html_body(neglect_alert_html(conversation, level))
      |> text_body(neglect_alert_text(conversation, level))

    case TenantDelivery.deliver(email, conversation.tenant_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to send neglect alert email")
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
