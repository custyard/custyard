defmodule Custyard.Webhooks.Purposes.Attachments do
  @moduledoc """
  Async fetch of a delivery's attachments after its message is stored
  (spec-inbound-channels D9).

  Finds the message the delivery produced (by provider delivery id, else by
  Message-ID inside the conversation), skips when it already has attachment
  rows (a replayed delivery), applies the channel's per-message cap and
  records every attachment as fetched or skipped. Suspect mail is listed but
  never fetched: the operator sees the filenames and can clear the flag
  before anything is downloaded.
  """

  import Ecto.Query

  alias Custyard.{Attachments, InboundChannel, Message, Repo}

  require Logger

  def process(conversation, normalized, route_context) do
    descriptors = descriptors(normalized)

    with [_ | _] <- descriptors,
         %Message{} = message <- find_message(conversation.id, normalized),
         [] <- Attachments.list_for_message(message.id) do
      opts = [limit_bytes: limit(route_context), skip: skip_reason(route_context)]
      {:ok, _rows} = Attachments.fetch_for_message(message, descriptors, opts)
      broadcast(conversation.id)
      :ok
    else
      _no_work -> :ok
    end
  rescue
    error ->
      Logger.error(
        "Attachment processing failed for conversation #{conversation.id}: #{inspect(error)}"
      )

      :ok
  end

  @doc false
  def descriptors(normalized) do
    case get_in(normalized, [:metadata, :attachments]) do
      list when is_list(list) -> Enum.filter(list, &is_map/1)
      _other -> []
    end
  end

  defp find_message(conversation_id, normalized) do
    delivery_id = get_in(normalized, [:metadata, :provider_delivery_id])
    message_id = normalized[:message_id]

    query =
      from m in Message,
        where: m.conversation_id == ^conversation_id,
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

  defp skip_reason(%{triage_class: :suspect}), do: "suspect"
  defp skip_reason(_route_context), do: nil

  defp broadcast(conversation_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation_id}",
      {:message_added, conversation_id}
    )
  end
end
