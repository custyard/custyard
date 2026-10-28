defmodule Custyard.Webhooks.Purposes.Attachments do
  @moduledoc """
  Recoverable fetch of a delivery's attachments after its message is stored
  (spec-inbound-channels D9).

  Finds the message the delivery produced (by provider delivery id, else by
  Message-ID inside the thread), resumes durable attachment slots on
  replay, applies the channel's per-message cap and
  records every attachment as fetched or skipped. Suspect mail is listed but
  never fetched: the staff sees the filenames and can clear the flag
  before anything is downloaded.
  """

  import Ecto.Query

  alias Custyard.{Attachments, InboundChannel, Message, Repo}

  require Logger

  def process(thread, normalized, route_context) do
    descriptors = descriptors(normalized)

    case find_message(thread.id, normalized) do
      %Message{} = message ->
        opts = [limit_bytes: limit(route_context), skip: skip_reason(thread, route_context)]
        {:ok, rows} = Attachments.fetch_for_message(message, descriptors, opts)
        broadcast(thread.id)

        if Enum.any?(rows, &(&1.state in [:failed, :pending])),
          do: {:error, :attachment_fetch_failed},
          else: :ok

      _no_work ->
        :ok
    end
  rescue
    _error ->
      Logger.error("Attachment processing failed for thread #{thread.id}")
      {:error, :attachment_processing_failed}
  end

  @doc false
  def descriptors(normalized) do
    case get_in(normalized, [:metadata, :attachments]) do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp find_message(thread_id, normalized) do
    delivery_id = get_in(normalized, [:metadata, :provider_delivery_id])
    message_id = normalized[:message_id]

    query =
      from m in Message,
        where: m.thread_id == ^thread_id,
        order_by: [desc: m.id],
        limit: 1

    query =
      cond do
        is_binary(delivery_id) -> where(query, [m], m.provider_delivery_id == ^delivery_id)
        is_binary(message_id) -> where(query, [m], m.message_id == ^message_id)
        true -> where(query, [m], false)
      end

    Repo.one(query)
  end

  defp limit(%{channel_id: id}) when is_integer(id) do
    Attachments.limit_bytes(Repo.get(InboundChannel, id))
  end

  defp limit(_route_context), do: Attachments.default_limit_bytes()

  defp skip_reason(%{suspect: true}, _context), do: "suspect"
  defp skip_reason(_thread, %{triage_class: :suspect}), do: "suspect"
  defp skip_reason(_thread, _route_context), do: nil

  defp broadcast(thread_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread_id}",
      {:message_added, thread_id}
    )
  end
end
