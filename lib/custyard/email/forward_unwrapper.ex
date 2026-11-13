defmodule Custyard.Email.ForwardUnwrapper do
  @moduledoc """
  Extracts the original message from a manually forwarded email
  (spec-inbound-channels D6, "staff manual forward").

  Mail clients wrap a forwarded message in a recognisable block: Gmail's
  `---------- Forwarded message ---------`, Apple Mail's
  `Begin forwarded message:`, Outlook's `-----Original Message-----`,
  Thunderbird's and Proton's `-------- Forwarded Message --------`. The
  block is followed by header lines (`From:`, `Date:` or `Sent:`,
  `Subject:`, `To:`, `Cc:`), a blank line and the original body. Some
  clients quote the whole block with `> `; one level of quoting is removed.

  `unwrap/2` returns the original sender (the only required field), the
  original subject (falling back to the outer subject without its `Fwd:`
  prefix) and the original body. Anything the staff typed above the
  block is dropped: the customer's words are what becomes the message.
  """

  alias Custyard.Email.SenderMatcher

  @marker ~r/^[ \t>]*(?:-{3,}\s*(?:forwarded message|original message|forwarded)\s*-{3,}|begin forwarded message:)[ \t]*$/im
  @header ~r/^(from|date|sent|subject|to|cc|reply-to)\s*:\s*(.*)$/i
  @forward_prefix ~r/^\s*(?:(?:fwd?|fw|wg|tr|vs|doorst)\s*:\s*)+/i

  @doc "True when the subject carries a forward prefix (Fwd:, FW:, WG:, TR:)."
  def forward_subject?(subject) when is_binary(subject),
    do: Regex.match?(@forward_prefix, subject)

  def forward_subject?(_subject), do: false

  @doc "True when the body carries a forwarded-message block."
  def forwarded_block?(body) when is_binary(body), do: Regex.match?(@marker, body)
  def forwarded_block?(_body), do: false

  @doc "The subject without any forward prefixes."
  def strip_forward_prefix(subject) when is_binary(subject),
    do: Regex.replace(@forward_prefix, subject, "") |> String.trim()

  def strip_forward_prefix(subject), do: subject

  @doc """
  Unwrap `body`. `outer_subject` is the forward's own subject, used when the
  block carries none. Returns `{:ok, original}` or `:error` when no block
  with a parsable original sender is found.
  """
  @spec unwrap(term(), term()) ::
          {:ok,
           %{
             from: String.t(),
             email: String.t(),
             subject: String.t() | nil,
             body: String.t(),
             date: String.t() | nil
           }}
          | :error
  def unwrap(body, outer_subject \\ nil)

  def unwrap(body, outer_subject) when is_binary(body) do
    case Regex.split(@marker, body, parts: 2) do
      [_above, below] -> parse_block(below, outer_subject)
      _no_marker -> :error
    end
  end

  def unwrap(_body, _outer_subject), do: :error

  defp parse_block(block, outer_subject) do
    lines = block |> unquote_block() |> String.split(~r/\r?\n/)
    {headers, rest} = take_headers(lines, %{}, 0)

    with from when is_binary(from) <- headers["from"],
         email when is_binary(email) <- SenderMatcher.extract_email(from) do
      {:ok,
       %{
         from: from,
         email: String.downcase(email),
         subject: subject(headers["subject"], outer_subject),
         body: rest |> Enum.join("\n") |> String.trim(),
         date: headers["date"] || headers["sent"]
       }}
    else
      _missing -> :error
    end
  end

  # When most lines are quoted, the client quoted the block: strip one level.
  defp unquote_block(block) do
    lines = String.split(block, ~r/\r?\n/)
    non_blank = Enum.reject(lines, &(String.trim(&1) == ""))
    quoted = Enum.count(non_blank, &String.starts_with?(&1, ">"))

    if non_blank != [] and quoted * 2 > length(non_blank) do
      Enum.map_join(lines, "\n", &Regex.replace(~r/^>\s?/, &1, ""))
    else
      block
    end
  end

  # Header lines may be preceded by blank lines (Apple Mail) and a long
  # header may wrap onto an indented continuation line. The block ends at the
  # first blank line after at least one header, or after 12 header lines.
  defp take_headers([], headers, _count), do: {headers, []}
  defp take_headers(rest, headers, count) when count >= 12, do: {headers, rest}

  defp take_headers([line | rest], headers, count) do
    cond do
      String.trim(line) == "" and map_size(headers) == 0 ->
        take_headers(rest, headers, count)

      String.trim(line) == "" ->
        {headers, rest}

      match = Regex.run(@header, String.trim_leading(line)) ->
        [_all, name, value] = match
        name = String.downcase(name)
        {value, rest} = continuation(value, rest)
        take_headers(rest, Map.put_new(headers, name, String.trim(value)), count + 1)

      map_size(headers) == 0 ->
        # Text before the first header (a name line, a stray marker) is skipped.
        take_headers(rest, headers, count + 1)

      true ->
        {headers, [line | rest]}
    end
  end

  defp continuation(value, [<<ws, _::binary>> = next | rest]) when ws in [?\s, ?\t] do
    if String.trim(next) == "" or Regex.match?(@header, String.trim_leading(next)),
      do: {value, [next | rest]},
      else: continuation(value <> " " <> String.trim(next), rest)
  end

  defp continuation(value, rest), do: {value, rest}

  defp subject(nil, outer) when is_binary(outer), do: presence(strip_forward_prefix(outer))
  defp subject(nil, _outer), do: nil
  defp subject(inner, _outer), do: presence(strip_forward_prefix(inner))

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil
end
