defmodule Custyard.Scoring.Recalculator do
  @moduledoc """
  Background recalculation of all active thread scores.

  Uses pagination instead of streaming to avoid holding a long-running
  transaction lock (important for SQLite which only allows one writer).
  """

  import Ecto.Query
  alias Custyard.{Thread, Repo, Scoring}

  @batch_size 100

  @doc """
  Recalculate scores for all active threads.
  Uses pagination to process in batches without holding a transaction lock.
  Returns the total number of threads recalculated.
  """
  def recalculate_all do
    recalculate_batch(scored_threads(), 0, 0)
  end

  @doc """
  Recalculate the active threads of one inbound channel, after its
  attention bonus changed, so the queue does not wait for the next sweep.
  Returns the number recalculated.
  """
  def recalculate_channel(channel_id) do
    scored_threads()
    |> where([c], c.inbound_channel_id == ^channel_id)
    |> recalculate_batch(0, 0)
  end

  defp scored_threads do
    from(c in Thread,
      where: c.state in [:new, :active, :waiting, :dormant],
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^DateTime.utc_now()
    )
  end

  defp recalculate_batch(query, offset, total_count) do
    # Fetch a batch of thread IDs (short read transaction)
    ids =
      from(c in query,
        select: c.id,
        order_by: [asc: c.id],
        offset: ^offset,
        limit: @batch_size
      )
      |> Repo.all()

    case ids do
      [] ->
        # No more threads
        total_count

      batch ->
        # Process entire batch efficiently (batch-preloads orgs and message counts)
        Scoring.calculate_and_cache_batch(batch)

        # Continue with next batch
        recalculate_batch(query, offset + @batch_size, total_count + length(batch))
    end
  end
end
