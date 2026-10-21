defmodule Custyard.Email.DeliveryStatus do
  @moduledoc """
  Advances `messages.delivery_status` from Lettermint delivery lifecycle
  events (spec-conversation-loop, "Delivery Tracking").

  Statuses are rank-ordered: pending < sending < sent < delivered. Bounced,
  suppressed and failed are terminal. An event advances a message only when
  its rank is higher than the current status or it is terminal, so retried,
  duplicated and out-of-order webhooks are harmless no-ops. `:withheld`
  (consent withheld, never handed to the provider) is never changed by a
  provider event, and inbound messages (`delivery_status` nil) are never
  touched even if they carry a `lettermint_message_id`.

  Every applied transition writes an append-only `:delivery_status_updated`
  audit event. The audit payload deliberately omits recipient addresses,
  subjects, metadata, spam symbols and raw SMTP response text.
  """

  import Ecto.Query

  require Logger

  alias Custyard.{AuditEvent, Message, Repo}
  alias Custyard.Email.Outbound

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

  @source "lettermint"

  @doc "Rank of a non-terminal status; nil for terminal statuses and `:withheld`."
  def rank(status), do: Map.get(@ranks, status)

  @doc "Whether the status is a terminal delivery failure."
  def terminal?(status), do: status in @terminal

  @doc "Status an event maps to, or nil when the event is not a status change."
  def event_status(event) when is_binary(event), do: Map.get(@event_statuses, event)
  def event_status(_event), do: nil

  @doc """
  Whether `incoming` should replace `current`.

  False for inbound messages (nil) and `:withheld`; true when `incoming` is
  terminal (even over another terminal status) or outranks `current`.
  """
  def advance?(nil, _incoming), do: false
  def advance?(:withheld, _incoming), do: false

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
  or `{:error, term}` when the write failed.
  """
  def apply_event(%{"event" => event} = envelope) when is_binary(event) do
    data = map_or_empty(envelope["data"])

    result =
      with {:ok, status} <- resolve_status(event),
           {:ok, provider_id} <- provider_message_id(data),
           {:ok, message} <- find_message(provider_id),
           :ok <- check_advance(message, status),
           {:ok, updated} <- transition(message, status, event, envelope["id"], data) do
        {:ok, :updated, updated}
      else
        {:ignored, reason} -> {:ok, :ignored, reason}
        {:error, reason} -> {:error, reason}
      end

    emit_telemetry(event, result)
    result
  end

  def apply_event(_envelope), do: {:error, :invalid_payload}

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
  # is treated as a no-op. The audit event is written in the same transaction
  # so a transition is never recorded without its history entry. The LiveView
  # nudge goes out only after commit.
  defp transition(%Message{} = message, to_status, event, delivery_id, data) do
    changeset = Message.delivery_status_changeset(message, to_status)

    if changeset.valid? do
      message
      |> transition_transaction(to_status, event, delivery_id, data)
      |> case do
        {:ok, updated} -> {:ok, Outbound.broadcast_delivery_update(updated)}
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
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    query =
      from(m in Message,
        where: m.id == ^id and m.delivery_status == ^from_status,
        select: m
      )

    case Repo.update_all(query, set: [delivery_status: to_status, updated_at: now]) do
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
