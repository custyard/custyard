defmodule Custyard.Webhooks.Purposes.Enrichment do
  @moduledoc """
  Async enrichment of conversations after creation.

  Applies the external priority carried in metadata and detects the
  conversation's language from the first customer message
  (spec-inbound-channels Phase 2). Runs after sender_matching completes.
  """

  import Ecto.Query

  alias Custyard.{Conversation, Message, Repo, Scoring}
  alias Custyard.Email.LanguageDetector

  require Logger

  @doc """
  Enrich a conversation with additional metadata from the normalized payload.
  """
  def process(conversation, normalized, _route_context) do
    conversation = Repo.reload!(conversation)
    attrs = build_enrichment_attrs(normalized)
    language_changed? = is_nil(conversation.language) and set_first_language(conversation.id)

    if map_size(attrs) > 0 or language_changed? do
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

  # Read persisted customer messages in arrival order, rather than whichever
  # enrichment task happens to run first. A conditional write prevents stale
  # tasks from overwriting a language another task already established.
  defp set_first_language(conversation_id) do
    language =
      from(m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.source != :operator and m.is_internal_note == false,
        where: is_nil(m.triage_class) or m.triage_class in [:customer, :operator_forward],
        order_by: [asc: m.inserted_at, asc: m.id],
        select: m.body
      )
      |> Repo.all()
      |> Enum.find_value(&LanguageDetector.detect/1)

    if language do
      {changed, _} =
        from(c in Conversation, where: c.id == ^conversation_id and is_nil(c.language))
        |> Repo.update_all(set: [language: language])

      changed == 1
    else
      false
    end
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
