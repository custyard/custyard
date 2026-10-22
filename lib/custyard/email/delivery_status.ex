defmodule Custyard.Email.DeliveryStatus do
  @moduledoc """
  Advances `messages.delivery_status` from Lettermint delivery lifecycle
  events (spec-conversation-loop, "Delivery Tracking").

  Statuses are rank-ordered: pending < sending < sent < delivered. Bounced,
  suppressed and failed are terminal. An event advances a message only when
  its rank is higher than the current status or it is a terminal status
  different from the current one, so retried, duplicated and out-of-order
  webhooks are harmless no-ops. `:withheld` (consent withheld, never handed
  to the provider) is never changed by a provider event, and inbound
  messages (`delivery_status` nil) are never touched even if they carry a
  `lettermint_message_id`.

  The status write is conditional on the status that was read. When two
  webhooks for one message overlap and the write loses, the event is
  re-evaluated against the stored status rather than acknowledged: a bounce
  that lost to a concurrent `delivered` still applies and is retried.

  Every applied transition writes an append-only `:delivery_status_updated`
  audit event. The audit payload deliberately omits recipient addresses,
  subjects, metadata, spam symbols and raw SMTP response text. A transition
  to bounced or suppressed also sends the operator a notice.

  Lettermint sends one event per recipient and names it in `data.recipient`.
  A bounced or suppressed recipient that is a contact of the conversation's
  organization is flagged (`contacts.email_status`), and a later delivery to
  it clears the flag (spec-conversation-loop, "Bounce and Suppression
  Handling"). The flag follows the recipient, not the message, so a bounced
  CC address never flags the conversation's contact. It applies even when the
  message status does not advance, because an earlier recipient's event may
  already have set it. Events are ordered by their own timestamp, so a late
  delivery event cannot clear a newer bounce.
  """

  import Ecto.Query

  require Logger

  alias Custyard.{AuditEvent, Contact, Conversation, Message, Repo}
  alias Custyard.Email.Outbound
  alias Custyard.Notifications.Email, as: NotificationEmail

  @ranks %{pending: 0, sending: 1, sent: 2, delivered: 3}
  @terminal [:bounced, :suppressed, :failed]

  # Lettermint lifecycle events that change delivery status. Everything else
  # (created, soft_bounced, spam_complaint, opened, clicked, unsubscribed,
  # auto_replied, inbound, unknown) is recorded as ignored.
  @event_statuses %{
    "message.sent" => :sent,
    "message.delivered" => :delivered,
    "message.hard_bounced" => :bounced,
    "message.failed" => :failed,
    "message.policy_rejected" => :failed,
    "message.suppressed" => :suppressed
  }

  # What each status means for the recipient's address. Sent and failed say
  # nothing about the address itself.
  @contact_statuses %{bounced: :bounced, suppressed: :suppressed, delivered: :valid}

  @notified_statuses [:bounced, :suppressed]

  @source "lettermint"

  # Rounds of read-check-write before a persistently losing event is handed
  # back as an error (422) for the provider to retry later.
  @max_attempts 3

  @doc "Rank of a non-terminal status; nil for terminal statuses and `:withheld`."
  def rank(status), do: Map.get(@ranks, status)

  @doc "Whether the status is a terminal delivery failure."
  def terminal?(status), do: status in @terminal

  @doc "Status an event maps to, or nil when the event is not a status change."
  def event_status(event) when is_binary(event), do: Map.get(@event_statuses, event)
  def event_status(_event), do: nil

  @doc """
  Whether `incoming` should replace `current`.

  False for inbound messages (nil) and `:withheld`, and for a status equal
  to the current one (a retried terminal event changes nothing); true when
  `incoming` is terminal (even over a different terminal status) or outranks
  `current`.
  """
  def advance?(nil, _incoming), do: false
  def advance?(:withheld, _incoming), do: false
  def advance?(current, current), do: false

  def advance?(current, incoming) do
    cond do
      terminal?(incoming) -> true
      is_nil(rank(current)) or is_nil(rank(incoming)) -> false
      true -> rank(incoming) > rank(current)
    end
  end

  @doc """
  Apply a decoded Lettermint webhook envelope to the outbound message it
  refers to.

  Returns `{:ok, :updated, message}`, `{:ok, :ignored, reason}` for events
  that are not status changes, unknown messages, or non-advancing transitions,
  or `{:error, term}` when the write failed (including
  `{:error, :concurrent_update}` when an advancing event kept losing to
  overlapping writes; the caller answers non-2xx so the provider retries).
  """
  def apply_event(%{"event" => event} = envelope) when is_binary(event) do
    data = map_or_empty(envelope["data"])

    result =
      with {:ok, status} <- resolve_status(event),
           {:ok, provider_id} <- provider_message_id(data) do
        record_recipient_status(provider_id, status, envelope["timestamp"], data)
        apply_status(provider_id, status, event, envelope["id"], data, @max_attempts)
      else
        {:ignored, reason} -> {:ok, :ignored, reason}
      end

    emit_telemetry(event, result)
    result
  end

  def apply_event(_envelope), do: {:error, :invalid_payload}

  # A conditional write that touched 0 rows means another webhook moved the
  # status between our read and our write. The event may still apply (a
  # hard bounce that lost to a concurrent `delivered` must still win), so
  # re-read and decide again instead of acknowledging it as ignored.
  defp apply_status(_provider_id, _status, _event, _delivery_id, _data, 0),
    do: {:error, :concurrent_update}

  defp apply_status(provider_id, status, event, delivery_id, data, attempts) do
    with {:ok, message} <- find_message(provider_id),
         :ok <- check_advance(message, status),
         {:ok, updated} <- transition(message, status, event, delivery_id, data) do
      {:ok, :updated, updated}
    else
      {:ignored, :concurrent_update} ->
        apply_status(provider_id, status, event, delivery_id, data, attempts - 1)

      {:ignored, reason} ->
        {:ok, :ignored, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_status(event) do
    case event_status(event) do
      nil -> {:ignored, :unknown_event}
      status -> {:ok, status}
    end
  end

  defp provider_message_id(%{"message_id" => id}) when is_binary(id) and id != "", do: {:ok, id}
  defp provider_message_id(_data), do: {:ignored, :missing_message_id}

  # Outbound only: inbound messages have a nil delivery_status and must never
  # be touched, even when they carry the same provider id.
  defp find_message(provider_id) do
    query =
      from(m in Message,
        where: m.lettermint_message_id == ^provider_id and not is_nil(m.delivery_status),
        limit: 1
      )

    case Repo.one(query) do
      nil -> {:ignored, :unknown_message}
      message -> {:ok, message}
    end
  end

  defp check_advance(%Message{delivery_status: current}, incoming) do
    if advance?(current, incoming), do: :ok, else: {:ignored, :not_advanced}
  end

  # The status write is conditional on the status we read, so two concurrent
  # webhooks for the same message cannot both win; the loser sees 0 rows and
  # `apply_status/6` re-evaluates it. The audit event is written in the same
  # transaction so a transition is never recorded without its history entry.
  # The LiveView nudge goes out only after commit.
  defp transition(%Message{} = message, to_status, event, delivery_id, data) do
    changeset = Message.delivery_status_changeset(message, to_status)

    if changeset.valid? do
      message
      |> transition_transaction(to_status, event, delivery_id, data)
      |> case do
        {:ok, updated} -> {:ok, after_commit(updated, data)}
        {:error, {:ignored, reason}} -> {:ignored, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, changeset}
    end
  end

  defp transition_transaction(%Message{} = message, to_status, event, delivery_id, data) do
    from_status = message.delivery_status

    Repo.transaction(fn ->
      with {:ok, updated} <- conditional_update(message, from_status, to_status),
           :ok <- record_audit(updated, from_status, to_status, event, delivery_id, data) do
        updated
      else
        {:ignored, reason} -> Repo.rollback({:ignored, reason})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp conditional_update(%Message{id: id}, from_status, to_status) do
    query =
      from(m in Message,
        where: m.id == ^id and m.delivery_status == ^from_status,
        select: m
      )

    case Repo.update_all(query, set: [delivery_status: to_status, updated_at: now()]) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:ignored, :concurrent_update}
    end
  end

  defp record_audit(%Message{} = message, from_status, to_status, event, delivery_id, data) do
    %Message{conversation: conversation} = Repo.preload(message, :conversation)
    response = map_or_empty(data["response"])

    attrs = %{
      event_type: :delivery_status_updated,
      source: @source,
      message_id: message.message_id,
      conversation_id: message.conversation_id,
      organization_id: conversation && conversation.organization_id,
      payload: %{
        "event" => event,
        "delivery_id" => scalar(delivery_id),
        "from" => Atom.to_string(from_status),
        "to" => Atom.to_string(to_status),
        "reason" => scalar(data["reason"]),
        "reason_code" => scalar(data["reason_code"]),
        "status_code" => scalar(response["status_code"]),
        "enhanced_status_code" => scalar(response["enhanced_status_code"])
      }
    }

    case AuditEvent.create(attrs) do
      {:ok, _audit_event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Delivery status audit failed for message #{message.id} " <>
            "(#{from_status} -> #{to_status}): #{inspect(changeset.errors)}"
        )

        {:error, changeset}
    end
  end

  # The contact update is one conditional write, so a retried or reordered
  # event is a no-op: it changes nothing when the status already matches or
  # a newer event set it.
  defp record_recipient_status(provider_id, status, timestamp, data) do
    with contact_status when not is_nil(contact_status) <- Map.get(@contact_statuses, status),
         recipient when is_binary(recipient) <- normalize_address(data["recipient"]),
         organization_id when not is_nil(organization_id) <- message_organization(provider_id) do
      at = event_time(timestamp)

      from(c in Contact,
        where:
          c.organization_id == ^organization_id and
            fragment("lower(trim(?))", c.email) == ^recipient and
            c.email_status != ^contact_status and
            (is_nil(c.email_status_at) or c.email_status_at <= ^at)
      )
      |> Repo.update_all(
        set: [email_status: contact_status, email_status_at: at, updated_at: now()]
      )
    end

    :ok
  end

  defp message_organization(provider_id) do
    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: m.lettermint_message_id == ^provider_id and not is_nil(m.delivery_status),
      select: c.organization_id,
      limit: 1
    )
    |> Repo.one()
  end

  defp normalize_address(address) when is_binary(address) do
    case address |> String.trim() |> String.downcase() do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_address(_address), do: nil

  defp event_time(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, at, _offset} -> DateTime.truncate(at, :second)
      {:error, _reason} -> now()
    end
  end

  defp event_time(_timestamp), do: now()

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp after_commit(%Message{} = message, data) do
    notify_operator(message, data)
    Outbound.broadcast_delivery_update(message)
  end

  # A notice failure is logged by the notifier and never fails the webhook:
  # the transition is committed, and a retried event would not advance.
  defp notify_operator(%Message{delivery_status: status} = message, data)
       when status in @notified_statuses do
    %Message{conversation: conversation} =
      Repo.preload(message, conversation: [:organization, :contact])

    NotificationEmail.deliver_delivery_failure(conversation, status, data["recipient"])
  end

  defp notify_operator(_message, _data), do: :ok

  defp emit_telemetry(event, result) do
    outcome =
      case result do
        {:ok, :updated, _} -> :updated
        {:ok, :ignored, _} -> :ignored
        {:error, _} -> :error
      end

    :telemetry.execute(
      [:custyard, :email, :delivery_status, :event],
      %{count: 1},
      %{event: event, result: outcome}
    )
  end

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}

  # Only scalars reach the audit payload; nested provider structures are dropped.
  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(_value), do: nil
end
