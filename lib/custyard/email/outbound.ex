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
        {:error, :no_consent, message} -> # delivery_status is now :withheld
        {:error, reason, message} -> # delivery_status is now :failed
      end
  """

  require Logger

  alias Custyard.Email.{Headers, ThreadHeaders}
  alias Custyard.{Conversations, Message, Repo, Settings}
  import Swoosh.Email

  @doc """
  Deliver an outbound email for a message.

  The message's conversation, contact, organization, and prospect are
  force-preloaded, so the consent re-check always reads current DB state even
  when a caller passes a message with stale associations already loaded.
  Recipient resolution falls back contact.email -> prospect.email -> no
  recipient; the prospect channel additionally requires the prospect's
  reply-notification opt-in (consent gate, secondary layer —
  `Conversations.send_reply/3` is the primary). A prospect-channel recipient
  without opt-in marks the message `:withheld` and returns
  `{:error, :no_consent, updated_message}`, so no caller can bypass policy.

  Returns `{:ok, updated_message}` on success or
  `{:error, reason, updated_message}` on failure.
  """
  def deliver(%Message{} = message) do
    # force: true — the consent re-check must read committed consent state;
    # without it a caller passing a preloaded conversation would silently
    # turn this defense-in-depth layer into a stale-read no-op.
    message =
      Repo.preload(message, [conversation: [:contact, :organization, :prospect]], force: true)

    conversation = message.conversation

    with {:ok, recipient} <- resolve_recipient(conversation),
         {:ok, from_addr} <- resolve_from_address(message, conversation),
         email <- compose(message, conversation, recipient, from_addr),
         {:ok, metadata} <- Custyard.Mailer.deliver(email) do
      updated =
        message
        |> mark_status(:sent, provider_attrs(metadata))
        |> broadcast_delivery_update()

      {:ok, updated}
    else
      # Consent withheld is an expected state, not a delivery failure — the
      # reply stays visible to the prospect via the resume link.
      {:error, :no_consent} ->
        Logger.info(
          "Outbound email withheld for message #{message.id}: prospect has not opted in"
        )

        {:error, :no_consent, message |> mark_status(:withheld) |> broadcast_delivery_update()}

      {:error, reason} ->
        Logger.error(
          "Outbound email delivery failed for message #{message.id}: #{inspect(reason)}"
        )

        {:error, reason, message |> mark_status(:failed) |> broadcast_delivery_update()}
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

  # Recipient fallback: contact.email -> prospect.email -> no recipient.
  # The contact channel delivers unconditionally (established-customer path).
  # reply_channel/1 already excludes revoked prospects and empty emails, so
  # the prospect channel only needs the consent check here.
  defp resolve_recipient(conversation) do
    case Conversations.reply_channel(conversation) do
      {:contact, email} -> {:ok, email}
      {:prospect, email} -> prospect_recipient(conversation.prospect, email)
      :none -> {:error, :no_recipient_email}
    end
  end

  defp prospect_recipient(%{notify_on_reply: true}, email), do: {:ok, email}
  defp prospect_recipient(_prospect, _email), do: {:error, :no_consent}

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

  # Public-intake mail always carries the instance branding display name,
  # keyed on the conversation's source — linking the conversation to an
  # organization later must not change the From identity (source-keyed rule
  # in the public intake spec).
  defp from_name(%{source: :public_intake}), do: header_safe_name(branding_name())

  defp from_name(conversation) do
    name =
      case conversation.organization do
        %{name: name} when is_binary(name) and name != "" -> name
        _ -> "Custyard"
      end

    header_safe_name(name)
  end

  defp header_safe_name(name), do: name |> sanitize_header_text() |> quote_display_name()

  # Instance branding display name for public-intake mail; "Custyard" when no
  # branding name is configured.
  defp branding_name do
    case Settings.get_branding() do
      %{name: name} when is_binary(name) and name != "" -> name
      _ -> "Custyard"
    end
  end

  # Delegates to the shared Custyard.Email.Headers (extracted from this
  # module's privates; behavior byte-identical).
  defp quote_display_name(name), do: Headers.quote_display_name(name)

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

  # Delegates to the shared Custyard.Email.Headers (extracted from this
  # module's privates; behavior byte-identical).
  defp sanitize_header_text(text), do: Headers.sanitize_header_text(text)

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

  defp mark_status(message, status, extra_attrs \\ %{}) do
    case message
         |> Message.delivery_status_changeset(status, extra_attrs)
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

  # Swoosh.Adapters.Lettermint returns {:ok, %{id: message_id, status: status}}.
  # Persist the id so provider status webhooks (delivered/bounced) can be
  # correlated back to this message. Other adapters may not include an id.
  defp provider_attrs(%{id: id}) when is_binary(id), do: %{lettermint_message_id: id}
  defp provider_attrs(_metadata), do: %{}

  # Nudge subscribed LiveViews (ConversationLive) to refresh the delivery
  # indicator once the async delivery lands on :sent or :failed.
  defp broadcast_delivery_update(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{message.conversation_id}",
      {:message_updated, message.conversation_id}
    )

    message
  end
end
