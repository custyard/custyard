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

  The queue also changes while staff are reading: a colleague resolves a
  conversation further up, a new one arrives on top. A position counted when
  the link was rendered is then off by those rows. So the link also names the
  conversations that were listed just before and just after its target, and
  the place is read from where those sit now. The position is the fallback
  for when both have left the queue.

  Those two can move as well: a colleague opens one, its customer writes
  again. They then point at different places. If the conversation itself
  still lies between them, its own place is right. Otherwise the one that
  moved is taken to be the one further from the position in the link.
  """

  @type neighbor :: %{
          id: integer(),
          pos: non_neg_integer(),
          after: integer() | nil,
          before: integer() | nil
        }
  @type t :: %{
          prev: neighbor() | nil,
          next: neighbor() | nil,
          position: pos_integer() | nil,
          total: non_neg_integer()
        }

  @doc """
  Neighbors of `current_id` in `ids`, the queue's thread ids in listed order.

  `pos_hint` is the zero-based position the conversation had when the link to
  it was rendered, and `anchors` the ids listed just before it (`:after`) and
  just after it (`:before`) at that time. The conversation is placed right
  after the first anchor and right before the second; an anchor that is not
  listed counts as absent. When the two disagree, the conversation's own
  position decides if it lies between them, and otherwise the anchor nearer
  the position hint, the earlier place on a tie: that can offer a
  conversation twice but never skips one. With neither anchor listed the
  position hint is used. Without any of them its current position is used,
  and a conversation that is not listed has no neighbors. Each neighbor
  carries its own current position and anchors, to pass on with the link
  that leads to it.

  `:position` is the one-based place in the queue being stepped through and
  `:total` the number of conversations listed now.
  """
  @spec neighbors([integer()], integer(), non_neg_integer() | nil, keyword()) :: t()
  def neighbors(ids, current_id, pos_hint \\ nil, anchors \\ []) when is_list(ids) do
    others = List.delete(ids, current_id)
    total = length(ids)
    # As many other ids precede it, so this is also its slot among `others`.
    own = index_of(ids, current_id)

    case anchored_slot(others, own, pos_hint, anchors) || pos_hint || own do
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

  defp anchored_slot(others, own, pos_hint, anchors) do
    after_slot =
      with index when is_integer(index) <- index_of(others, anchors[:after]), do: index + 1

    before_slot = index_of(others, anchors[:before])

    cond do
      is_nil(after_slot) -> before_slot
      is_nil(before_slot) or after_slot == before_slot -> after_slot
      is_integer(own) and own >= after_slot and own <= before_slot -> own
      true -> nearer(after_slot, before_slot, pos_hint)
    end
  end

  defp nearer(slot, other, nil), do: min(slot, other)

  defp nearer(slot, other, pos_hint),
    do: Enum.min_by([min(slot, other), max(slot, other)], &abs(&1 - pos_hint))

  defp index_of(_ids, nil), do: nil
  defp index_of(ids, id), do: Enum.find_index(ids, &(&1 == id))

  defp neighbor(_ids, id) when id in [nil, false], do: nil

  defp neighbor(ids, id) do
    pos = index_of(ids, id)

    %{
      id: id,
      pos: pos,
      after: if(pos > 0, do: Enum.at(ids, pos - 1)),
      before: Enum.at(ids, pos + 1)
    }
  end
end
