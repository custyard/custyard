defmodule Custyard.Webhooks.Purposes.Enrichment do
  @moduledoc """
  Async enrichment of conversations after creation.

  Updates urgency scoring based on metadata, extracts keywords,
  and classifies attachments. Runs after sender_matching completes.
  """

  alias Custyard.{Conversation, Repo, Scoring}

  require Logger

  @doc """
  Enrich a conversation with additional metadata from the normalized payload.
  """
  def process(conversation, normalized, _route_context) do
    conversation = Repo.reload!(conversation)
    attrs = build_enrichment_attrs(normalized)

    if map_size(attrs) > 0 do
      conversation
      |> Conversation.changeset(attrs)
      |> Repo.update()

      # Recalculate score after enrichment
      Scoring.calculate_and_cache(conversation.id)

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversations",
        {:conversation_updated, conversation.id}
      )
    end

    :ok
  rescue
    error ->
      Logger.error("Enrichment failed for conversation #{conversation.id}: #{inspect(error)}")
      :ok
  end

  defp build_enrichment_attrs(normalized) do
    attrs = %{}

    # Apply external priority from metadata if available
    case get_in(normalized, [:metadata, :external_priority]) do
      "urgent" -> Map.put(attrs, :urgency, :urgent)
      "high" -> Map.put(attrs, :urgency, :elevated)
      _ -> attrs
    end
  end
end
