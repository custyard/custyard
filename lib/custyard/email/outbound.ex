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

  alias Custyard.Email.{Headers, OutboundQueue, ReplyRecipients, ThreadHeaders}

  alias Custyard.{
    Conversations,
    InboundChannel,
    InboundChannels,
    Message,
    Repo,
    Tenant
  }

  # Swoosh.Email also exports from/2, so Ecto.Query is not imported here.
  require Ecto.Query
  import Swoosh.Email

  @doc """
  Deliver an outbound email for a message.

  The message is reloaded and its conversation, contact, organization, and
  prospect are preloaded inside the delivery claim transaction, so recipient
  and consent checks read current DB state even for a stale queue snapshot.
  Recipient resolution falls back contact.email -> prospect.email -> no
  recipient; the prospect channel additionally requires the prospect's
  reply-notification opt-in (consent gate, secondary layer —
  `Conversations.send_reply/3` is the primary). A prospect-channel recipient
  without opt-in marks the message `:withheld` and returns
  `{:error, :no_consent, updated_message}`, so no caller can bypass policy.

  On the contact channel, a valid `Reply-To` on the last customer message
  that differs from the contact's address is the recipient instead
  (spec-inbound-channels D5). Only messages triaged as customer mail are
  consulted; auto-responses and suspect messages never redirect a reply, and
  the prospect channel is never redirected.

  The From display name is the inbound channel's display name when the
  conversation arrived on a channel that has one, else the organization name
  (D3); public-intake mail keeps the instance branding name.

  Only a `:pending` message is delivered. The row is flipped to `:sending`
  before the email is handed to the mailer, so a message that is already
  claimed, sent, failed or withheld returns `{:error, :not_pending, message}`
  without contacting the provider.

  Returns `{:ok, updated_message}` on success or
  `{:error, reason, updated_message}` on failure.
  """
  def deliver(%Message{} = message) do
    case claim_for_delivery(message) do
      {:ok, {:ok, current, email}} -> deliver_claimed(current, email)
      {:ok, {:error, reason, current}} -> delivery_error(current, reason)
      {:ok, :not_pending} -> {:error, :not_pending, Repo.reload!(message)}
      {:error, reason} -> {:error, reason, Repo.reload!(message)}
    end
  end

  @doc "Unattempted configuration failures can retry; provider attempts retain the 24-hour deduplication window."
  def retryable?(%Message{} = message) do
    message.source == :operator and message.delivery_status == :failed and
      message.delivery_failure_kind in [:rejected, :configuration] and
      message.delivery_error_code != "envelope_changed" and
      retry_window_open?(message) and
      is_nil(message.deleted_at)
  end

  defp retry_window_open?(%Message{
         delivery_failure_kind: :configuration,
         delivery_attempted_at: nil
       }),
       do: true

  defp retry_window_open?(%Message{delivery_attempted_at: %DateTime{} = attempted_at}),
    do: DateTime.diff(DateTime.utc_now(), attempted_at) < 86_400

  defp retry_window_open?(_message), do: false

  @doc "Requeue a confirmed failed reply under current operator authorization. Unknown sends never retry blindly."
  def retry(%Custyard.Scope{} = scope, %Message{} = message) do
    result =
      Conversations.with_access(scope, message.conversation_id, fn conversation, _operator ->
        case Repo.get_by(Message, id: message.id, conversation_id: conversation.id) do
          %Message{} = current ->
            if retryable?(current) do
              current
              |> refresh_unattempted_identity(conversation)
              |> Message.delivery_status_changeset(:pending, %{
                delivery_failure_kind: nil,
                delivery_error_code: nil
              })
              |> Repo.update()
            else
              {:error, :reconciliation_required}
            end

          nil ->
            {:error, :not_found}
        end
      end)

    case result do
      {:ok, updated} ->
        OutboundQueue.wake()
        {:ok, broadcast_delivery_update(updated)}

      error ->
        error
    end
  end

  defp refresh_unattempted_identity(
         %Message{delivery_payload_hash: nil, sender_email: nil} = message,
         conversation
       ) do
    channel = Conversations.reply_sending_channel(conversation)

    Message.changeset(message, %{
      sender_email: Conversations.reply_identity(conversation).address,
      inbound_channel_id: channel && channel.id
    })
  end

  defp refresh_unattempted_identity(message, _conversation), do: message

  # Claim, reload current recipients and save the envelope under one write
  # transaction. A stale queue snapshot must not restore recipients erased
  # by a DSAR. The provider call happens only after this transaction commits.
  defp claim_for_delivery(%Message{id: id}) do
    Repo.transaction(fn ->
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      {claimed, _} =
        Ecto.Query.from(m in Message, where: m.id == ^id and m.delivery_status == :pending)
        |> Repo.update_all(set: [delivery_status: :sending, updated_at: now])

      if claimed == 1 do
        Message |> Repo.get!(id) |> prepare_delivery()
      else
        :not_pending
      end
    end)
  end

  defp prepare_delivery(message) do
    message =
      Repo.preload(message, [
        :inbound_channel,
        conversation: [:contact, :organization, :prospect, :inbound_channel]
      ])

    conversation =
      if message.inbound_channel &&
           message.inbound_channel.tenant_id == message.conversation.tenant_id,
         do: %{message.conversation | inbound_channel: message.inbound_channel},
         else: message.conversation

    with :ok <- active_tenant(conversation.tenant_id),
         {:ok, recipient} <- delivery_recipient(message, conversation),
         {:ok, from_addr} <- resolve_from_address(message, conversation),
         email <- compose(message, conversation, recipient, from_addr),
         email <- preserve_provider_message_id(email),
         {:ok, message} <- persist_delivery_facts(message, email) do
      {:ok, message, email}
    else
      {:error, reason} -> {:error, reason, message}
    end
  end

  # Lettermint rewrites Message-ID unless this provider control is included.
  # Snapshot it before fingerprinting so every retry uses the identical request.
  defp preserve_provider_message_id(email) do
    if is_binary(email.headers["Message-ID"]),
      do: header(email, "X-LM-Preserve-Message-ID", "true"),
      else: email
  end

  defp active_tenant(tenant_id) do
    case Repo.get(Tenant, tenant_id) do
      %Tenant{status: "active"} -> :ok
      _ -> {:error, :tenant_suspended}
    end
  end

  # Recheck consent and whether the relationship still exists, but never let a
  # later participant redirect an already reviewed reply. Erasure can clear the
  # locked list, in which case delivery stops instead of restoring an address.
  defp delivery_recipient(%Message{delivery_recipients_locked: true} = message, conversation) do
    with {:ok, _current} <- reply_recipient(conversation) do
      case message.to_addresses do
        [address] -> {:ok, address}
        _ -> {:error, :no_recipient_email}
      end
    end
  end

  defp delivery_recipient(_message, conversation), do: reply_recipient(conversation)

  defp deliver_claimed(message, email) do
    with {:ok, config} <- Custyard.EmailSetup.sending_config(message.conversation.tenant_id),
         :ok <- validate_delivery_config(config),
         {:ok, attempted} <- record_attempt(message) do
      deliver_attempted(attempted, email, config)
    else
      {:error, reason} -> delivery_error(message, reason)
    end
  end

  defp validate_delivery_config(config) do
    config |> Keyword.fetch!(:adapter) |> then(& &1.validate_config(config))
  rescue
    _error -> {:error, :sending_not_configured}
  end

  defp record_attempt(message) do
    message
    |> Ecto.Changeset.change(
      delivery_attempted_at:
        message.delivery_attempted_at || DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update()
  end

  defp deliver_attempted(message, email, config) do
    case deliver_with_config(email, config) do
      {:ok, metadata} ->
        updated =
          message
          |> mark_status(
            :sent,
            Map.merge(provider_attrs(metadata), %{
              delivery_failure_kind: nil,
              delivery_error_code: nil
            })
          )
          |> broadcast_delivery_update()

        Custyard.EmailSetup.record_reply_accepted(updated)

        {:ok, updated}

      {:error, reason} ->
        delivery_error(message, reason)
    end
  end

  defp deliver_with_config(email, config) do
    Custyard.Mailer.deliver(email, config)
  rescue
    # Adapter exceptions can contain request bodies and credentials. Treat
    # acceptance as unknown and retain only a bounded diagnostic code.
    _error -> {:error, :delivery_exception}
  end

  defp delivery_error(message, :no_consent) do
    Logger.info("Outbound email withheld for message #{message.id}: prospect has not opted in")
    {:error, :no_consent, message |> mark_status(:withheld) |> broadcast_delivery_update()}
  end

  defp delivery_error(message, reason) do
    {kind, code} = failure_category(reason)

    Logger.warning("outbound_delivery_failed",
      message_id: message.id,
      failure_kind: kind,
      error_code: code
    )

    attrs = %{
      delivery_failure_kind: kind,
      delivery_error_code: code
    }

    {:error, reason, message |> mark_status(:failed, attrs) |> broadcast_delivery_update()}
  end

  defp failure_category({status, _body}) when status in 400..499 and status not in [408, 409],
    do: {:rejected, "http_#{status}"}

  defp failure_category({status, _body}) when is_integer(status),
    do: {:unknown, "provider_response"}

  defp failure_category(reason)
       when reason in [
              :no_recipient_email,
              :from_not_set,
              :not_configured,
              :sending_not_configured,
              :project_token_missing,
              :connection_not_found,
              :envelope_changed
            ],
       do: {:configuration, Atom.to_string(reason)}

  defp failure_category(reason) when reason in [:timeout, :closed, :econnrefused, :nxdomain],
    do: {:unknown, Atom.to_string(reason)}

  defp failure_category(:tenant_suspended), do: {:configuration, "tenant_suspended"}
  defp failure_category(_reason), do: {:unknown, "delivery_error"}

  # Store actual participants before contacting the provider. The message was
  # read under the claim's write lock, so this cannot restore stale CC data.
  defp persist_delivery_facts(message, email) do
    envelope =
      {email.from, email.to, email.cc, email.bcc, email.subject, email.text_body, email.html_body,
       email.headers}

    # Reply-To is serialized outside email.headers. Its presence changes the
    # provider envelope and must block a retry after the return path changes.
    fingerprint =
      if(is_nil(email.reply_to), do: envelope, else: {envelope, {:reply_to, email.reply_to}})
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    if message.delivery_payload_hash && message.delivery_payload_hash != fingerprint do
      {:error, :envelope_changed}
    else
      message
      |> Message.changeset(%{
        to_addresses: Enum.map(email.to, &elem(&1, 1)),
        cc_addresses: Enum.map(email.cc, &elem(&1, 1))
      })
      |> Ecto.Changeset.change(%{
        delivery_payload_hash: fingerprint
      })
      |> Repo.update()
    end
  end

  @doc """
  Compose a Swoosh.Email struct without delivering.
  Useful for previewing or testing email composition.
  """
  def compose(%Message{} = message, conversation, recipient, from_address) do
    message =
      if conversation.source == :public_intake, do: %{message | cc_addresses: []}, else: message

    new()
    |> to(recipient)
    |> put_cc(
      if(conversation.source == :public_intake, do: %{message | cc_addresses: []}, else: message),
      recipient
    )
    |> put_archive_bcc(conversation)
    |> from(from_address)
    |> put_channel_reply_to(conversation)
    |> subject(compose_subject(conversation))
    |> text_body(message.body)
    |> html_body(wrap_html(message.body))
    |> put_threading_headers(message)
    |> put_message_id_header(message)
    |> put_provider_option(:idempotency_key, idempotency_key(message))
  end

  defp idempotency_key(message) do
    "custyard-" <>
      (:crypto.hash(:sha256, "#{message.id}:#{message.message_id}")
       |> Base.encode16(case: :lower))
  end

  # --- Private ---

  # Reply-all CC (spec-inbound-channels D5): the operator-approved list, never
  # the recipient twice. Prospect conversations carry no CC by construction
  # (Conversations.default_reply_cc/2 returns [] and the composer hides it).
  defp put_cc(email, %Message{cc_addresses: cc}, recipient) when is_list(cc) and cc != [] do
    recipient = String.downcase(recipient)

    case Enum.reject(cc, &(String.downcase(&1) == recipient)) do
      [] -> email
      list -> cc(email, list)
    end
  end

  defp put_cc(email, _message, _recipient), do: email

  defp put_channel_reply_to(email, %{
         inbound_channel:
           %InboundChannel{reply_from: :public_address, sending_domain: domain} = channel
       })
       when is_binary(domain), do: reply_to(email, channel.public_address)

  defp put_channel_reply_to(email, _conversation), do: email

  # Archive copy (spec-inbound-channels D4): BCC the channel's public address
  # so the operator's mailbox keeps the reply. The copy is forwarded straight
  # back and recognised by triage as an own echo, never a new conversation.
  defp put_archive_bcc(email, %{inbound_channel: %InboundChannel{archive_copy: true} = channel}),
    do: bcc(email, channel.public_address)

  defp put_archive_bcc(email, _conversation), do: email

  @doc """
  The address the next reply on `conversation` is sent to: the customer's
  Reply-To when it overrides the contact address (D5), else the contact's
  email, else an opted-in prospect's. The composer shows this so the
  operator sees the address delivery will use.

  The contact channel delivers unconditionally (established-customer path).
  `Conversations.reply_channel/1` already excludes revoked prospects and
  empty emails, so the prospect channel only needs the consent check here.
  """
  def reply_recipient(conversation),
    do: ReplyRecipients.recipient(conversation)

  defp resolve_from_address(message, conversation) do
    # Priority: message sender_email > app config fallback
    if is_binary(message.sender_email) and message.sender_email != "" do
      {:ok, {from_name(conversation), message.sender_email}}
    else
      fallback_from_address(conversation)
    end
  end

  defp fallback_from_address(conversation) do
    with {:ok, channel} <- Custyard.EmailSetup.default_reply_channel(conversation.tenant_id),
         address when is_binary(address) and address != "" <-
           InboundChannels.from_address(channel) do
      {:ok, {from_name(conversation), address}}
    else
      _ -> {:error, :from_not_set}
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
    |> ThreadHeaders.for_conversation(
      exclude_message_id: message.message_id,
      before_id: message.id
    )
    |> Map.get("References", in_reply_to)
  end

  defp from_name(conversation) do
    name = channel_display_name(conversation) || tenant_name(conversation.tenant_id)
    header_safe_name(name)
  end

  defp channel_display_name(%{inbound_channel: %InboundChannel{} = channel}),
    do: InboundChannels.from_name(channel)

  defp channel_display_name(_conversation), do: nil

  defp tenant_name(tenant_id), do: Repo.get!(Tenant, tenant_id).name

  defp header_safe_name(name), do: name |> sanitize_header_text() |> quote_display_name()

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

  @doc false
  # Nudge subscribed LiveViews (ConversationLive) to refresh the delivery
  # indicator once the async delivery lands on :sent or :failed.
  def broadcast_delivery_update(%Message{} = message) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{message.conversation_id}",
      {:message_updated, message.conversation_id}
    )

    message
  end
end
