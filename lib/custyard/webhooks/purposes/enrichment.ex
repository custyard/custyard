defmodule Custyard.Webhooks.Purposes.Enrichment do
  @moduledoc """
  Async enrichment of threads after creation.

  Applies the external priority carried in metadata and detects the
  thread's language from the first customer message
  (spec-inbound-channels Phase 2). Runs after sender_matching completes.
  """

  import Ecto.Query

  alias Custyard.{Thread, Message, Repo, Scoring}
  alias Custyard.Email.LanguageDetector

  require Logger

  @doc """
  Enrich a thread with additional metadata from the normalized payload.
  """
  def process(thread, normalized, _route_context) do
    thread = Repo.reload!(thread)
    attrs = build_enrichment_attrs(normalized)
    language_changed? = is_nil(thread.language) and set_first_language(thread.id)

    if map_size(attrs) > 0 or language_changed? do
      changeset = Thread.changeset(thread, attrs)

      case Repo.update(changeset) do
        {:ok, updated} ->
          Scoring.calculate_and_cache(updated.id)

          Phoenix.PubSub.broadcast(
            Custyard.PubSub,
            "threads",
            {:thread_updated, updated.id}
          )

        {:error, changeset} ->
          Logger.error("Failed to enrich thread #{thread.id}: #{inspect(changeset.errors)}")
      end
    end

    :ok
  rescue
    error ->
      Logger.error("Enrichment failed for thread #{thread.id}: #{inspect(error)}")
      :ok
  end

  # Read persisted customer messages in arrival order, rather than whichever
  # enrichment task happens to run first. A conditional write prevents stale
  # tasks from overwriting a language another task already established.
  defp set_first_language(thread_id) do
    language =
      from(m in Message,
        where: m.thread_id == ^thread_id,
        where: m.source != :staff and m.is_internal_note == false,
        where: is_nil(m.triage_class) or m.triage_class in [:customer, :staff_forward],
        order_by: [asc: m.inserted_at, asc: m.id],
        select: m.body
      )
      |> Repo.all()
      |> Enum.find_value(&LanguageDetector.detect/1)

    if language do
      {changed, _} =
        from(c in Thread, where: c.id == ^thread_id and is_nil(c.language))
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
