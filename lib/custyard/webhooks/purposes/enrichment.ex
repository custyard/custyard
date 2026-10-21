defmodule Custyard.Webhooks.Purposes.Enrichment do
  @moduledoc """
  Async enrichment of conversations after creation.

  Applies the external priority carried in metadata and detects the
  conversation's language from the first customer message
  (spec-inbound-channels Phase 2). Runs after sender_matching completes.
  """

  alias Custyard.{Conversation, Repo, Scoring}
  alias Custyard.Email.LanguageDetector

  require Logger

  @doc """
  Enrich a conversation with additional metadata from the normalized payload.
  """
  def process(conversation, normalized, _route_context) do
    conversation = Repo.reload!(conversation)
    attrs = normalized |> build_enrichment_attrs() |> put_language(conversation, normalized)

    if map_size(attrs) > 0 do
      changeset = Conversation.changeset(conversation, attrs)

      case Repo.update(changeset) do
        {:ok, updated} ->
          Scoring.calculate_and_cache(updated.id)

          Phoenix.PubSub.broadcast(
            Custyard.PubSub,
            "conversations",
            {:conversation_updated, updated.id}
          )

        {:error, changeset} ->
          Logger.error(
            "Failed to enrich conversation #{conversation.id}: #{inspect(changeset.errors)}"
          )
      end
    end

    :ok
  rescue
    error ->
      Logger.error("Enrichment failed for conversation #{conversation.id}: #{inspect(error)}")
      :ok
  end

  # The first detectable message decides; a later message in another language
  # does not flip the badge back and forth.
  defp put_language(attrs, %Conversation{language: nil}, normalized) do
    case LanguageDetector.detect(normalized[:body]) do
      nil -> attrs
      code -> Map.put(attrs, :language, code)
    end
  end

  defp put_language(attrs, _conversation, _normalized), do: attrs

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
