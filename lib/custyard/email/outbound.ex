defmodule Custyard.Email.Outbound do
  @moduledoc """
  Composes and delivers outbound emails for operator replies.

  Builds a `Swoosh.Email` struct from a persisted Message (with preloaded
  conversation, contact, and organization), delivers it via
  `Custyard.Mailer`, and updates the message's `delivery_status`.

  ## Usage

  Called after `Conversations.send_reply/3` inserts a message with
  `delivery_status: :pending`. Can be invoked synchronously or from
  a `start_async` callback in a LiveView.

      case Custyard.Email.Outbound.deliver(message) do
        {:ok, message} -> # delivery_status is now :sent
        {:error, reason, message} -> # delivery_status is now :failed
      end
  """

  require Logger

  alias Custyard.{Message, Repo}
  import Swoosh.Email

  @doc """
  Deliver an outbound email for a message.

  The message must be preloaded with `conversation.contact` and
  `conversation.organization` (or at minimum have a `sender_email`
  and conversation with a contact email).

  Returns `{:ok, updated_message}` on success or
  `{:error, reason, updated_message}` on failure.
  """
  def deliver(%Message{} = message) do
    message = Repo.preload(message, conversation: [:contact, :organization])
    conversation = message.conversation

    with {:ok, recipient} <- resolve_recipient(conversation),
         {:ok, from_addr} <- resolve_from_address(message, conversation),
         email <- compose(message, conversation, recipient, from_addr),
         {:ok, _metadata} <- Custyard.Mailer.deliver(email) do
      {:ok, mark_status(message, :sent)}
    else
      {:error, reason} ->
        Logger.error(
          "Outbound email delivery failed for message #{message.id}: #{inspect(reason)}"
        )

        {:error, reason, mark_status(message, :failed)}
    end
  end

  @doc """
  Compose a Swoosh.Email struct without delivering.
  Useful for previewing or testing email composition.
  """
  def compose(%Message{} = message, conversation, recipient, from_address) do
    subject = compose_subject(conversation)

    email =
      new()
      |> to(recipient)
      |> from(from_address)
      |> subject(subject)
      |> text_body(message.body)
      |> html_body(wrap_html(message.body))

    # Add threading headers if the message has in_reply_to
    email =
      if message.in_reply_to do
        email
        |> header("In-Reply-To", message.in_reply_to)
        |> header("References", build_references(message))
      else
        email
      end

    # Set Message-ID header if message has one
    if message.message_id do
      header(email, "Message-ID", message.message_id)
    else
      email
    end
  end

  # --- Private ---

  defp resolve_recipient(conversation) do
    case conversation.contact do
      %{email: email} when is_binary(email) and email != "" ->
        {:ok, email}

      _ ->
        {:error, :no_recipient_email}
    end
  end

  defp resolve_from_address(message, conversation) do
    # Priority: message sender_email > route from_address > app config fallback
    cond do
      is_binary(message.sender_email) and message.sender_email != "" ->
        {:ok, {from_name(conversation), message.sender_email}}

      true ->
        fallback = Application.get_env(:custyard, :email_from_address, "support@custyard.local")
        {:ok, {from_name(conversation), fallback}}
    end
  end

  defp from_name(conversation) do
    case conversation.organization do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Custyard"
    end
  end

  defp compose_subject(conversation) do
    base = conversation.subject || "Your conversation"
    # Prefix with Re: if not already present
    if String.starts_with?(base, "Re: ") do
      base
    else
      "Re: #{base}"
    end
  end

  defp wrap_html(text_body) do
    escaped =
      text_body
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()
      |> String.replace("\n", "<br>\n")

    """
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 16px;">
    #{escaped}
    </body>
    </html>
    """
  end

  defp build_references(message) do
    # For now, just use in_reply_to as the reference chain.
    # A more complete implementation would build the full chain from
    # all prior messages in the thread.
    message.in_reply_to || ""
  end

  defp mark_status(message, status) do
    case message
         |> Message.delivery_status_changeset(status)
         |> Repo.update() do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error(
          "Failed to update delivery_status to #{status} for message #{message.id}: #{inspect(changeset.errors)}"
        )

        # Return the message with the status set in memory even if DB update fails
        %{message | delivery_status: status}
    end
  end
end
