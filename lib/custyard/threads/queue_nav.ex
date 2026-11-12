defmodule Custyard.Threads.QueueNav do
  @moduledoc """
  Previous and next conversation in the attention queue's order, for stepping
  through the queue from inside a conversation.

  Looking at a conversation changes its place in the queue. Opening a new
  thread makes it active and resets its idle time, so its score drops and it
  sinks; replying takes it out of "needs reply"; resolving takes it out of
  everything. Its own current place is therefore not where the reader is in
  the queue. The place it had when it was opened travels with the link as a
  position hint, and the neighbours are read from the queue *without* this
  conversation: what followed it now sits at that position, what preceded it
  sits just before.

  The queue also changes while staff are reading: a colleague resolves a
  conversation further up, a new one arrives on top. A position counted when
  the link was rendered is then off by those rows. So a place also names
  witnesses: conversations that were listed before it and after it. Each one
  that is still listed says which side of it the place is on.

  Witnesses move as well: a colleague opens the next conversation and it
  sinks, a customer writes again and theirs rises. The place taken is the
  one that keeps the most witnesses on their side. Among several such places
  it is the one nearest the position hint, then the one that keeps the
  nearer witnesses, then the earlier one. With no witness listed that is the
  position hint itself. A place names up to three witnesses on each side,
  in a link and in what a page remembers for its own reloads (`:place` in
  the result), so that one that moved is outvoted by the others.

  A conversation that arrived next to the place is offered as the next one,
  so stepping can show a conversation twice but does not pass one by.
  """

  @type place :: %{pos: non_neg_integer(), after: [integer()], before: [integer()]}
  @type neighbor :: %{
          id: integer(),
          pos: non_neg_integer(),
          after: [integer()],
          before: [integer()]
        }
  @type t :: %{
          prev: neighbor() | nil,
          next: neighbor() | nil,
          position: pos_integer() | nil,
          total: non_neg_integer(),
          place: place() | nil
        }

  # Witnesses named on each side of a place.
  @witnesses 3

  @doc "How many witnesses a place names on each side at most."
  @spec witnesses() :: pos_integer()
  def witnesses, do: @witnesses

  @doc """
  The place of the conversation at `pos` in `ids`, to carry with a link to
  it: its position and the ids listed just before and just after it, nearest
  first.
  """
  @spec place([integer()], non_neg_integer()) :: place()
  def place(ids, pos) do
    %{
      pos: pos,
      after: ids |> Enum.take(pos) |> Enum.reverse() |> Enum.take(@witnesses),
      before: ids |> Enum.drop(pos + 1) |> Enum.take(@witnesses)
    }
  end

  @doc """
  Neighbors of `current_id` in `ids`, the queue's thread ids in listed order.

  `pos_hint` is the zero-based position the conversation had when its place
  was recorded. `anchors` are the witnesses: under `:after` an id, or a list
  of ids, that were listed before it then (the place comes after them), and
  under `:before` those that were listed after it. An id that is not listed
  now counts for nothing. Without a hint or a listed witness the
  conversation's current position is used, and a conversation that is not
  listed then has no neighbors.

  Each neighbor carries its own place (`place/2`), to pass on with the link
  that leads to it. `:place` is the place found for the conversation itself,
  with up to #{@witnesses} witnesses on each side, nearest first, for the
  caller to pass back on its next call.

  `:position` is the one-based place in the queue being stepped through and
  `:total` the number of conversations listed now.
  """
  @spec neighbors([integer()], integer(), non_neg_integer() | nil, keyword()) :: t()
  def neighbors(ids, current_id, pos_hint \\ nil, anchors \\ []) when is_list(ids) do
    others = List.delete(ids, current_id)
    total = length(ids)
    before_place = listed(others, anchors[:after])
    after_place = listed(others, anchors[:before])

    case placed(others, pos_hint, before_place, after_place) || index_of(ids, current_id) do
      nil ->
        %{prev: nil, next: nil, position: nil, total: total, place: nil}

      slot ->
        %{
          prev: neighbor(ids, slot > 0 && Enum.at(others, slot - 1)),
          next: neighbor(ids, Enum.at(others, slot)),
          position: if(total > 0, do: min(slot + 1, total)),
          total: total,
          place: %{
            pos: slot,
            after: others |> Enum.take(slot) |> Enum.reverse() |> Enum.take(@witnesses),
            before: others |> Enum.drop(slot) |> Enum.take(@witnesses)
          }
        }
    end
  end

  # Where the witnesses that are still listed sit among `others`, each with
  # its rank: 0 for the one that was nearest the place.
  defp listed(others, ids) do
    ids
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.flat_map(fn {id, rank} ->
      case index_of(others, id) do
        nil -> []
        index -> [{index, rank}]
      end
    end)
  end

  # A slot is a gap between the other ids: slot 2 has two of them before it.
  # Enum.max_by keeps the first of equals, which is the earlier slot.
  defp placed(_others, nil, [], []), do: nil

  defp placed(others, pos_hint, before_place, after_place) do
    Enum.max_by(0..length(others), fn slot ->
      kept =
        Enum.filter(before_place, fn {index, _rank} -> index < slot end) ++
          Enum.filter(after_place, fn {index, _rank} -> index >= slot end)

      ranks = kept |> Enum.map(fn {_index, rank} -> rank end) |> Enum.sum()
      {length(kept), -abs(slot - (pos_hint || slot)), -ranks}
    end)
  end

  defp index_of(_ids, nil), do: nil
  defp index_of(ids, id), do: Enum.find_index(ids, &(&1 == id))

  defp neighbor(_ids, id) when id in [nil, false], do: nil
  defp neighbor(ids, id), do: ids |> place(index_of(ids, id)) |> Map.put(:id, id)
end
