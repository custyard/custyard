defmodule Custyard.Email.DeliveryStatus do
  @moduledoc """
  Applies Lettermint delivery lifecycle events to an outbound message
  (spec-conversation-loop, "Delivery Tracking").

  Lettermint sends one event per recipient and names it in `data.recipient`.
  Each recipient keeps its own latest status in `message_recipient_statuses`,
  and the message's `delivery_status` follows its primary recipient only: the
  `to` address the reply was sent to. An event for a CC or other secondary
  recipient (the archive copy) records that recipient's status and never
  moves the message, so a hard bounce on a CC address leaves a reply the
  customer received marked delivered, and the thread shows the CC failure
  separately. An event that names no recipient, or one for a message that
  recorded no recipient lists, applies to the message as a whole.

  Statuses are rank-ordered: pending < sending < sent < delivered. Bounced,
  suppressed and failed are terminal. A status replaces the current one only
  when its rank is higher or it is a terminal status different from the
  current one, so retried, duplicated and out-of-order webhooks are harmless
  no-ops. The same rule applies to each recipient, ordered by the event's own
  timestamp, so a late event cannot undo a newer status. `:withheld` (consent
  withheld, never handed to the provider) is never changed by a provider
  event, and inbound messages (`delivery_status` nil) are never touched even
  if they carry a `lettermint_message_id`.

  Writes are conditional on the state that was read. When two webhooks for
  one message overlap and a write loses, the event is re-evaluated against
  the stored state rather than acknowledged: a bounce that lost to a
  concurrent `delivered` still applies and is retried.

  Every applied change writes an append-only `:delivery_status_updated` audit
  event carrying the message's status before and after, the recipient's role
  and its status before and after. The payload deliberately omits recipient
  addresses, subjects, metadata, spam symbols and raw SMTP response text.

  A recipient whose status becomes bounced or suppressed sends the operator a
  notice, once per recipient, naming it and its role. A bounced or suppressed
  recipient that is a contact of the conversation's organization is also
  flagged (`contacts.email_status`), and a later delivery to it clears the
  flag (spec-conversation-loop, "Bounce and Suppression Handling"). The flag
  follows the recipient, not the message, and applies even when nothing else
  changes, because an earlier recipient's event may already have set it.
  """

  import Ecto.Query

  require Custyard.Log, as: Log

  alias Custyard.{AuditEvent, Contact, Conversation, Message, MessageRecipientStatus, Repo}
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
  Which list of `message` the address was sent on: `:to`, `:cc` or `:other`.

  A message that recorded no recipients predates the lists; every address on
  it counts as primary, so its indicator behaves as it always did.
  """
  def recipient_role(%Message{to_addresses: to, cc_addresses: cc}, address) do
    address = normalize_address(address)

    cond do
      to in [nil, []] -> :to
      Enum.any?(to, &(normalize_address(&1) == address)) -> :to
      Enum.any?(cc || [], &(normalize_address(&1) == address)) -> :cc
      true -> :other
    end
  end

  @doc """
  Apply a decoded Lettermint webhook envelope to the outbound message it
  refers to.

  Returns `{:ok, :updated, message}` when the message's status, a recipient's
  status or both changed, `{:ok, :ignored, reason}` for events that are not
  status changes, unknown messages, or non-advancing transitions, or
  `{:error, term}` when the write failed (including
  `{:error, :concurrent_update}` when an advancing event kept losing to
  overlapping writes; the caller answers non-2xx so the provider retries).
  """
  def apply_event(envelope, opts \\ [])

  def apply_event(%{"event" => event} = envelope, opts) when is_binary(event) do
    data = map_or_empty(envelope["data"])

    result =
      with {:ok, status} <- resolve_status(event),
           {:ok, provider_id} <- provider_message_id(data),
           {:ok, message} <- find_message(provider_id, opts) do
        incoming = %{
          status: status,
          event: event,
          delivery_id: envelope["id"],
          at: event_time(envelope["timestamp"]),
          recipient: normalize_address(data["recipient"]),
          data: data
        }

        record_contact_status(message, incoming)
        apply_status(message, incoming, @max_attempts)
      else
        {:ignored, reason} -> {:ok, :ignored, reason}
      end

    emit_telemetry(event, result)
    result
  end

  def apply_event(_envelope, _opts), do: {:error, :invalid_payload}

  # A conditional write that touched 0 rows means another webhook moved the
  # state between our read and our write. The event may still apply (a hard
  # bounce that lost to a concurrent `delivered` must still win), so re-read
  # and decide again instead of acknowledging it as ignored.
  defp apply_status(_message, _incoming, 0), do: {:error, :concurrent_update}

  defp apply_status(%Message{} = message, incoming, attempts) do
    with {:ok, plan} <- plan(message, incoming),
         {:ok, updated} <- transition(message, plan, incoming) do
      {:ok, :updated, updated}
    else
      {:ignored, :concurrent_update} -> reapply(message, incoming, attempts - 1)
      {:ignored, reason} -> {:ok, :ignored, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reapply(%Message{} = message, incoming, attempts) do
    case Repo.reload(message) do
      nil -> {:ok, :ignored, :unknown_message}
      fresh -> apply_status(fresh, incoming, attempts)
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
  defp find_message(provider_id, opts) do
    query =
      from(m in Message,
        where: m.lettermint_message_id == ^provider_id and not is_nil(m.delivery_status),
        limit: 1
      )

    query =
      case Keyword.get(opts, :tenant_id) do
        nil ->
          query

        tenant_id ->
          from(m in query,
            join: c in assoc(m, :conversation),
            where: c.tenant_id == ^tenant_id
          )
      end

    case Repo.one(query) do
      nil -> {:ignored, :unknown_message}
      message -> {:ok, message}
    end
  end

  # --- Deciding what the event changes ---

  # The named recipient's row, the message's own status, both or neither.
  defp plan(%Message{} = message, incoming) do
    recipient = recipient_change(message, incoming)
    message_change = message_change(message, incoming, recipient)

    if recipient == :none and message_change == :none,
      do: {:ignored, :not_advanced},
      else: {:ok, %{recipient: recipient, message: message_change}}
  end

  # No recipient named: the event is about the message as a whole.
  defp recipient_change(_message, %{recipient: nil}), do: :none

  defp recipient_change(%Message{} = message, %{recipient: address} = incoming) do
    case Repo.get_by(MessageRecipientStatus, message_id: message.id, address: address) do
      nil ->
        {:insert, recipient_role(message, address), nil}

      %MessageRecipientStatus{} = row ->
        if advance?(row.status, incoming.status) and not stale?(row, incoming.at),
          do: {:update, row.role, row},
          else: :none
    end
  end

  # An event older than the recipient's recorded status cannot undo it.
  defp stale?(%MessageRecipientStatus{status_at: at}, incoming_at),
    do: DateTime.compare(at, incoming_at) == :gt

  # The message indicator follows its primary recipient. An event that names
  # a secondary recipient never moves it; one that names no recipient moves
  # it as before. A primary recipient's event moves it only when it moved
  # the recipient, so the two cannot disagree.
  defp message_change(
         %Message{delivery_status: current},
         %{status: status, recipient: nil},
         :none
       ),
       do: if(advance?(current, status), do: :advance, else: :none)

  defp message_change(%Message{delivery_status: current}, %{status: status}, {_op, :to, _row}),
    do: if(advance?(current, status), do: :advance, else: :none)

  defp message_change(_message, _incoming, _recipient_change), do: :none

  # --- Writing it ---

  # The recipient row, the message status and the audit event are written in
  # one transaction, so a change is never recorded without its history entry.
  # Each write is conditional on the state we read; a loser sees 0 rows and
  # `apply_status/3` re-evaluates the event. The LiveView nudge and the
  # operator notice go out only after commit.
  defp transition(%Message{} = message, plan, incoming) do
    message
    |> transition_transaction(plan, incoming)
    |> case do
      {:ok, {updated, recipient}} -> {:ok, after_commit(updated, recipient, incoming)}
      {:error, {:ignored, reason}} -> {:ignored, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition_transaction(%Message{} = message, plan, incoming) do
    Repo.transaction(fn ->
      with {:ok, recipient} <- write_recipient(message, plan.recipient, incoming),
           {:ok, updated} <- write_message(message, plan.message, incoming),
           :ok <- record_audit(updated, message.delivery_status, recipient, incoming) do
        {updated, recipient}
      else
        {:ignored, reason} -> Repo.rollback({:ignored, reason})
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp write_recipient(_message, :none, _incoming), do: {:ok, nil}

  defp write_recipient(%Message{id: message_id}, {:insert, role, nil}, incoming) do
    %MessageRecipientStatus{}
    |> MessageRecipientStatus.changeset(%{
      message_id: message_id,
      address: incoming.recipient,
      role: role,
      status: incoming.status,
      status_at: incoming.at
    })
    |> Repo.insert()
    |> case do
      {:ok, _row} ->
        {:ok, %{role: role, from: nil, to: incoming.status}}

      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_violation?(changeset),
          do: {:ignored, :concurrent_update},
          else: {:error, changeset}
    end
  end

  defp write_recipient(_message, {:update, role, row}, incoming) do
    query =
      from(r in MessageRecipientStatus,
        where: r.id == ^row.id and r.status == ^row.status and r.status_at == ^row.status_at
      )

    case Repo.update_all(query,
           set: [status: incoming.status, status_at: incoming.at, updated_at: now()]
         ) do
      {1, _} -> {:ok, %{role: role, from: row.status, to: incoming.status}}
      {0, _} -> {:ignored, :concurrent_update}
    end
  end

  defp unique_violation?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn {_field, {_message, opts}} -> opts[:constraint] == :unique end)
  end

  defp write_message(%Message{} = message, :none, _incoming), do: {:ok, message}

  defp write_message(%Message{id: id, delivery_status: from}, :advance, %{status: to}) do
    query =
      from(m in Message,
        where: m.id == ^id and m.delivery_status == ^from,
        select: m
      )

    case Repo.update_all(query, set: [delivery_status: to, updated_at: now()]) do
      {1, [updated]} -> {:ok, updated}
      {0, _} -> {:ignored, :concurrent_update}
    end
  end

  defp record_audit(%Message{} = message, from_status, recipient, incoming) do
    %Message{conversation: conversation} = Repo.preload(message, :conversation)
    data = incoming.data
    response = map_or_empty(data["response"])
    recipient = recipient || %{role: nil, from: nil, to: nil}

    attrs = %{
      event_type: :delivery_status_updated,
      source: @source,
      message_id: message.message_id,
      conversation_id: message.conversation_id,
      organization_id: conversation && conversation.organization_id,
      payload: %{
        "event" => incoming.event,
        "delivery_id" => scalar(incoming.delivery_id),
        "from" => Atom.to_string(from_status),
        "to" => Atom.to_string(message.delivery_status),
        "recipient_role" => atom_string(recipient.role),
        "recipient_from" => atom_string(recipient.from),
        "recipient_to" => atom_string(recipient.to),
        "reason_code" => scalar(data["reason_code"]),
        "status_code" => scalar(response["status_code"]),
        "enhanced_status_code" => scalar(response["enhanced_status_code"])
      }
    }

    case AuditEvent.create(attrs) do
      {:ok, _audit_event} ->
        :ok

      {:error, changeset} ->
        Log.error(
          :delivery_status_audit_record_failed,
          [message_id: message.id, status: message.delivery_status] ++ Log.failure(changeset)
        )

        {:error, changeset}
    end
  end

  # --- The recipient's contact ---

  # The contact update is one conditional write, so a retried or reordered
  # event is a no-op: it changes nothing when the status already matches or
  # a newer event set it.
  defp record_contact_status(%Message{} = message, incoming) do
    with contact_status when not is_nil(contact_status) <-
           Map.get(@contact_statuses, incoming.status),
         recipient when is_binary(recipient) <- incoming.recipient,
         organization_id when not is_nil(organization_id) <- message_organization(message) do
      at = incoming.at

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

  defp message_organization(%Message{conversation_id: conversation_id}) do
    from(c in Conversation, where: c.id == ^conversation_id, select: c.organization_id)
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

  # --- After commit ---

  defp after_commit(%Message{} = message, recipient, incoming) do
    notify_operator(message, recipient, incoming)
    Outbound.broadcast_delivery_update(message)
  end

  # One notice per recipient that fails: on the named recipient's change to
  # bounced or suppressed, or, when the event names no recipient, on the
  # message's own. A notice failure never fails the webhook: the change is
  # committed, and a retried event would not advance. The notifier logs an
  # error result; a raise is logged here by type only, since its message may
  # name the recipient.
  defp notify_operator(%Message{} = message, %{to: status, role: role}, incoming)
       when status in @notified_statuses do
    send_notice(message, status, incoming.recipient, role)
  end

  defp notify_operator(%Message{delivery_status: status} = message, nil, %{recipient: nil})
       when status in @notified_statuses do
    send_notice(message, status, nil, :to)
  end

  defp notify_operator(_message, _recipient, _incoming), do: :ok

  defp send_notice(%Message{} = message, status, recipient, role) do
    %Message{conversation: conversation} =
      Repo.preload(message, conversation: [:organization, :contact])

    NotificationEmail.deliver_delivery_failure(conversation, status, recipient, role)
  rescue
    exception ->
      Log.error(
        :delivery_failure_notice_failed,
        [message_id: message.id] ++ Log.failure(exception)
      )

      :error
  end

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

  defp atom_string(nil), do: nil
  defp atom_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  # Only scalars reach the audit payload; nested provider structures are dropped.
  defp scalar(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp scalar(_value), do: nil
end
