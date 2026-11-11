defmodule Custyard.Threads.QueuePreview do
  @moduledoc """
  Latest-message facts for attention-queue rows: a plain-text snippet and who
  spoke last, loaded for a whole page of threads in one query.

  Reached through `Custyard.Threads.queue_previews/2`, which checks the staff
  scope first. Every query here is still bounded by the tenant id, so a thread
  id from another tenant yields nothing.

  This module also owns the rule for whose turn it is, in the two forms the
  queue needs: `turn/2` for a loaded row and `message_facts/1` for filtering
  and counting in SQL. Both rest on the same two definitions, `exchanged/1`
  and `staff_voice/1`.
  """
  import Ecto.Query

  alias Custyard.{Message, Repo}

  @doc """
  Query expression: the message is part of the conversation with the customer.
  Internal notes and automatic replies are not.
  """
  defmacro exchanged(message) do
    quote do
      not unquote(message).is_internal_note and
        (is_nil(unquote(message).triage_class) or
           unquote(message).triage_class != :auto_response)
    end
  end

  @doc """
  Query expression: the message is the staff speaking. A reply sent from the
  staff's own mailbox is captured as an email with the `:staff_sent` triage
  class; it is still the staff's voice.
  """
  defmacro staff_voice(message) do
    quote do
      unquote(message).source == :staff or unquote(message).triage_class == :staff_sent
    end
  end

  @doc """
  Per-thread message facts as a query, for joining into queue queries:

    * `:count` – every message on the thread
    * `:exchanged` – messages exchanged with the customer
    * `:recent` – messages since `since` (24 hours ago by default) that are
      not automatic replies: the count `Custyard.Scoring` uses for velocity
    * `:last_id` – id of the newest exchanged message
    * `:last_staff_id` – id of the newest exchanged message from staff

  Staff spoke last exactly when `last_staff_id == last_id`. Pass the tenant id
  to keep the scan to that tenant's messages.
  """
  def message_facts(tenant_id, since \\ DateTime.add(DateTime.utc_now(), -24, :hour)) do
    query =
      from(m in Message,
        group_by: m.thread_id,
        select: %{
          thread_id: m.thread_id,
          count: count(m.id),
          exchanged: count(fragment("CASE WHEN ? THEN 1 END", exchanged(m))),
          recent:
            count(
              fragment(
                "CASE WHEN ? THEN 1 END",
                m.inserted_at >= ^since and
                  (is_nil(m.triage_class) or m.triage_class != :auto_response)
              )
            ),
          last_id: max(fragment("CASE WHEN ? THEN ? END", exchanged(m), m.id)),
          last_staff_id:
            max(fragment("CASE WHEN ? THEN ? END", exchanged(m) and staff_voice(m), m.id))
        }
      )

    if is_integer(tenant_id), do: where(query, [m], m.tenant_id == ^tenant_id), else: query
  end

  @doc """
  Who has to act next on a thread, given its preview (or `nil` when it has no
  messages): `:ours`, `:theirs`, or `:none` for a resolved thread.

  An explicit waiting state wins over the message history. Otherwise the last
  speaker decides, and a thread nobody has answered yet is ours.
  """
  @spec turn(%{state: atom()}, preview() | nil) :: :ours | :theirs | :none
  def turn(%{state: :resolved}, _preview), do: :none
  def turn(%{state: :waiting}, _preview), do: :theirs
  def turn(_thread, %{last_speaker: :staff}), do: :theirs
  def turn(_thread, _preview), do: :ours

  # Characters of the stored text body read per message. A row shows one line,
  # so the full body (up to 100,000 characters) never leaves the database.
  @body_chars 600
  @snippet_chars 180

  @quoted_reply_start ~r/\A(On .+ wrote:|-{2,} ?Original Message ?-{2,}|-{2,} ?Forwarded message ?-{2,})\z/i
  @whitespace ~r/\s+/u

  @type preview :: %{
          snippet: String.t() | nil,
          snippet_from: :customer | :staff | :note | :auto_reply | :deleted,
          author_staff_id: integer() | nil,
          last_speaker: :customer | :staff | nil,
          last_spoke_at: DateTime.t() | nil
        }

  @doc """
  Previews keyed by thread id. Threads without messages are absent.

    * `:snippet` is the newest message of any kind as one line of plain text,
      or `nil` when that message was deleted or has no text.
    * `:snippet_from` says what kind of message the snippet came from.
    * `:author_staff_id` is the staff account that wrote it, when one did.
    * `:last_speaker` is who sent the newest message that is part of the
      conversation with the customer. Internal notes and automatic replies
      never count, so a note written after a customer message leaves the
      customer as the last speaker.
    * `:last_spoke_at` is when that message arrived.
  """
  @spec for_threads(integer(), [integer()]) :: %{integer() => preview()}
  def for_threads(_tenant_id, []), do: %{}

  def for_threads(tenant_id, thread_ids) when is_integer(tenant_id) and is_list(thread_ids) do
    newest =
      from(m in Message,
        where: m.tenant_id == ^tenant_id and m.thread_id in ^thread_ids,
        group_by: m.thread_id,
        select: %{
          any_id: max(m.id),
          exchange_id: max(fragment("CASE WHEN ? THEN ? END", exchanged(m), m.id))
        }
      )

    from(m in Message,
      join: n in subquery(newest),
      on: m.id == n.any_id or m.id == n.exchange_id,
      select: %{
        id: m.id,
        thread_id: m.thread_id,
        any_id: n.any_id,
        exchange_id: n.exchange_id,
        source: m.source,
        triage_class: m.triage_class,
        is_internal_note: m.is_internal_note,
        author_staff_id: m.author_staff_id,
        deleted_at: m.deleted_at,
        inserted_at: m.inserted_at,
        body: fragment("substr(?, 1, ?)", m.body, ^@body_chars)
      }
    )
    |> Repo.all()
    |> Enum.group_by(& &1.thread_id)
    |> Map.new(fn {thread_id, rows} -> {thread_id, build(rows)} end)
  end

  defp build(rows) do
    newest = Enum.find(rows, &(&1.id == &1.any_id))
    exchange = Enum.find(rows, &(&1.id == &1.exchange_id))
    from = snippet_from(newest)

    %{
      snippet: if(from == :deleted, do: nil, else: snippet(newest.body)),
      snippet_from: from,
      author_staff_id: newest.author_staff_id,
      last_speaker: exchange && speaker(exchange),
      last_spoke_at: exchange && exchange.inserted_at
    }
  end

  defp snippet_from(%{deleted_at: %DateTime{}}), do: :deleted
  defp snippet_from(%{is_internal_note: true}), do: :note
  defp snippet_from(%{triage_class: :auto_response}), do: :auto_reply
  defp snippet_from(message), do: speaker(message)

  # The loaded-row form of staff_voice/1.
  defp speaker(%{source: :staff}), do: :staff
  defp speaker(%{triage_class: :staff_sent}), do: :staff
  defp speaker(_message), do: :customer

  @doc """
  One line of plain text from a stored message body.

  Drops quoted reply text so a short answer above a long quote previews as the
  answer, collapses whitespace and cuts to #{@snippet_chars} characters. The
  result is plain text and must still be escaped when rendered.
  """
  @spec snippet(term()) :: String.t() | nil
  def snippet(body) when is_binary(body) do
    lines = body |> String.split(~r/\R/) |> Enum.map(&String.trim/1)

    own_words =
      lines
      |> Enum.take_while(&(not Regex.match?(@quoted_reply_start, &1)))
      |> Enum.reject(&String.starts_with?(&1, ">"))
      |> one_line()

    case own_words || one_line(lines) do
      nil -> nil
      text -> String.slice(text, 0, @snippet_chars)
    end
  end

  def snippet(_body), do: nil

  defp one_line(lines) do
    text = lines |> Enum.join(" ") |> String.replace(@whitespace, " ") |> String.trim()
    if text == "", do: nil, else: text
  end
end
