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

  alias Custyard.Email.ThreadHeaders
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
    new()
    |> to(recipient)
    |> from(from_address)
    |> subject(compose_subject(conversation))
    |> text_body(message.body)
    |> html_body(wrap_html(message.body))
    |> put_threading_headers(message)
    |> put_message_id_header(message)
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
    # Priority: message sender_email > app config fallback
    if is_binary(message.sender_email) and message.sender_email != "" do
      {:ok, {from_name(conversation), message.sender_email}}
    else
      fallback = Application.get_env(:custyard, :email_from_address, "support@custyard.local")
      {:ok, {from_name(conversation), fallback}}
    end
  end

  # Threading headers per RFC 5322 section 3.6.4: In-Reply-To points at the
  # parent (the last customer message), References carries the chain of prior
  # Message-IDs in the thread. Values that don't normalize to a real msg-id
  # (synthetic webhook ids, header-injection attempts) are dropped.
  defp put_threading_headers(email, message) do
    case ThreadHeaders.normalize_msg_id(message.in_reply_to) do
      nil ->
        email

      in_reply_to ->
        email
        |> header("In-Reply-To", in_reply_to)
        |> header("References", build_references(message, in_reply_to))
    end
  end

  defp put_message_id_header(email, message) do
    case ThreadHeaders.normalize_msg_id(message.message_id) do
      nil -> email
      message_id -> header(email, "Message-ID", message_id)
    end
  end

  # Full chain of prior msg-ids in the thread, excluding the reply's own
  # Message-ID (a message must not reference itself). Falls back to the
  # parent id alone when no other stored ids qualify.
  defp build_references(message, in_reply_to) do
    message.conversation_id
    |> ThreadHeaders.for_conversation(exclude_message_id: message.message_id)
    |> Map.get("References", in_reply_to)
  end

  defp from_name(conversation) do
    name =
      case conversation.organization do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "Custyard"
      end

    name |> sanitize_header_text() |> quote_display_name()
  end

  # RFC 5322 display names containing specials (comma, parens, quotes, ...)
  # must be quoted-string wrapped, or "Acme, Inc. <a@b>" parses as two
  # addresses. Plain atext-and-space names pass through unquoted.
  defp quote_display_name(name) do
    if name =~ ~r/^[a-zA-Z0-9!#$%&'*+\/=?^_`{|}~. -]*$/ do
      name
    else
      escaped = String.replace(name, ~r/["\\]/, fn char -> "\\" <> char end)
      "\"#{escaped}\""
    end
  end

  defp compose_subject(conversation) do
    base =
      case sanitize_header_text(conversation.subject || "") do
        "" -> "Your conversation"
        subject -> subject
      end

    # Prefix with Re: unless a reply prefix (any casing) is already present
    if base =~ ~r/^re:/i do
      base
    else
      "Re: #{base}"
    end
  end

  # Header values must never contain CR/LF or other control characters
  # (CWE-93 header injection); inbound subjects can carry them through the
  # webhook JSON path, and Swoosh does not sanitize header values.
  defp sanitize_header_text(text) do
    text
    |> String.replace(~r/[\x00-\x1F\x7F]+/, " ")
    |> String.trim()
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
