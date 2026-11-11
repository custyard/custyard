defmodule Custyard.Threads.QueueNav do
  @moduledoc """
  Previous and next conversation in the attention queue's order, for stepping
  through the queue from inside a conversation.

  Looking at a conversation changes its place in the queue. Opening a new
  thread makes it active and resets its idle time, so its score drops and it
  sinks; replying takes it out of "needs reply"; resolving takes it out of
  everything. Its own current place is therefore the wrong anchor. The place
  it had when it was opened travels with the link as a position hint, and the
  neighbours are read from the queue *without* this conversation: what
  followed it now sits at that position, what preceded it sits just before.
  """

  @type neighbor :: %{id: integer(), pos: non_neg_integer()}
  @type t :: %{
          prev: neighbor() | nil,
          next: neighbor() | nil,
          position: pos_integer() | nil,
          total: non_neg_integer()
        }

  @doc """
  Neighbors of `current_id` in `ids`, the queue's thread ids in listed order.

  `pos_hint` is the zero-based position the conversation had when it was
  opened; without one, its current position is used, and a conversation that
  is not listed has no neighbors. Each neighbor carries its own current
  position, to pass on as the hint of the link that leads to it.

  `:position` is the one-based place in the queue being stepped through and
  `:total` the number of conversations listed now.
  """
  @spec neighbors([integer()], integer(), non_neg_integer() | nil) :: t()
  def neighbors(ids, current_id, pos_hint \\ nil) when is_list(ids) do
    others = List.delete(ids, current_id)
    total = length(ids)

    case pos_hint || Enum.find_index(ids, &(&1 == current_id)) do
      nil ->
        %{prev: nil, next: nil, position: nil, total: total}

      slot ->
        slot = min(slot, length(others))

        %{
          prev: neighbor(ids, slot > 0 && Enum.at(others, slot - 1)),
          next: neighbor(ids, Enum.at(others, slot)),
          position: if(total > 0, do: min(slot + 1, total)),
          total: total
        }
    end
  end

  defp neighbor(_ids, id) when id in [nil, false], do: nil
  defp neighbor(ids, id), do: %{id: id, pos: Enum.find_index(ids, &(&1 == id))}
end
