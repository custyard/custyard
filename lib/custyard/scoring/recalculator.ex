defmodule Custyard.Scoring.Recalculator do
  @moduledoc """
  Background recalculation of all active conversation scores.

  Uses pagination instead of streaming to avoid holding a long-running
  transaction lock (important for SQLite which only allows one writer).
  """

  import Ecto.Query
  alias Custyard.{Conversation, Repo, Scoring}

  @batch_size 100

  @doc """
  Recalculate scores for all active conversations.
  Uses pagination to process in batches without holding a transaction lock.
  Returns the total number of conversations recalculated.
  """
  def recalculate_all do
    recalculate_batch(0, 0)
  end

  defp recalculate_batch(offset, total_count) do
    # Fetch a batch of conversation IDs (short read transaction)
    ids =
      from(c in Conversation,
        where: c.state in [:new, :active, :waiting, :dormant],
        where: is_nil(c.snoozed_until) or c.snoozed_until < ^DateTime.utc_now(),
        select: c.id,
        order_by: [asc: c.id],
        offset: ^offset,
        limit: @batch_size
      )
      |> Repo.all()

    case ids do
      [] ->
        # No more conversations
        total_count

      batch ->
        # Process entire batch efficiently (batch-preloads orgs and message counts)
        Scoring.calculate_and_cache_batch(batch)

        # Continue with next batch
        recalculate_batch(offset + @batch_size, total_count + length(batch))
    end
  end
end
