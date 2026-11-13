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
  prefix), the original body and the original's To and Cc recipients.
  Anything the staff typed above the block is dropped: the original's
  words are what becomes the message.

  The same block carries a reply the staff sent from their own mailbox and
  forwarded in afterwards (D6, "forwarded sent reply"). Its recipients say
  whose thread it belongs to.
  """

  alias Custyard.Email.SenderMatcher
  alias Custyard.EmailAddress

  @marker ~r/^[ \t>]*(?:-{3,}\s*(?:forwarded message|original message|forwarded)\s*-{3,}|begin forwarded message:)[ \t]*$/im
  # `Bcc:` shows up when the forwarded message came from a Sent folder. It is
  # read so it does not end up as the first line of the body.
  @header ~r/^(from|date|sent|subject|to|cc|bcc|reply-to)\s*:\s*(.*)$/i
  @recipient_headers ~w(to cc bcc)
  @address ~r"[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9.-]+"i
  # A quoted display name directly before `<address>`.
  @quoted_name ~r/"[^"]*"\s*(?=<)/
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
             date: String.t() | nil,
             to: [String.t()],
             cc: [String.t()]
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
         date: headers["date"] || headers["sent"],
         to: addresses(headers["to"]),
         cc: addresses(headers["cc"])
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
  # header may wrap onto the next line (see continuation/3). The block ends
  # at the first blank line after at least one header, or after 12 header
  # lines.
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
        {value, rest} = continuation(name, value, rest)
        take_headers(rest, Map.put_new(headers, name, String.trim(value)), count + 1)

      map_size(headers) == 0 ->
        # Text before the first header (a name line, a stray marker) is skipped.
        take_headers(rest, headers, count + 1)

      true ->
        {headers, [line | rest]}
    end
  end

  # Most clients indent the rest of a wrapped header. Gmail wraps a long
  # recipient list without indenting, often right after a `<`. So a line
  # also continues a recipient header when the list is visibly unfinished or
  # the line carries an address.
  defp continuation(name, value, [next | rest] = lines) do
    cond do
      String.trim(next) == "" or Regex.match?(@header, String.trim_leading(next)) ->
        {value, lines}

      indented?(next) or (name in @recipient_headers and recipient_line?(value, next)) ->
        continuation(name, value <> " " <> String.trim(next), rest)

      true ->
        {value, lines}
    end
  end

  defp continuation(_name, value, []), do: {value, []}

  defp indented?(<<ws, _rest::binary>>) when ws in [?\s, ?\t], do: true
  defp indented?(_line), do: false

  defp recipient_line?(value, next) do
    String.ends_with?(String.trim_trailing(value), [",", ";", "<"]) or
      String.contains?(next, "@")
  end

  # The addresses on a To: or Cc: line, bare and lowercased, in the order
  # written. Clients separate recipients with commas (Gmail, Apple Mail,
  # Thunderbird, Proton) or semicolons (Outlook) and write each one as
  # `Name <address>`, `"Name" <address>`, `Name [mailto:address]`,
  # `'address'` or the bare address. The line is scanned for addresses
  # because a display name can hold a comma. Proton repeats the address as a
  # quoted display name, which is skipped. A recipient shown by name only
  # has no address to return.
  defp addresses(nil), do: []

  defp addresses(value) do
    @address
    |> Regex.scan(Regex.replace(@quoted_name, value, " "))
    |> Enum.map(fn [address] -> address |> String.trim("'") |> String.trim_trailing(".") end)
    |> Enum.map(&String.downcase/1)
    |> Enum.filter(&EmailAddress.valid?/1)
    |> Enum.uniq()
  end

  defp subject(nil, outer) when is_binary(outer), do: presence(strip_forward_prefix(outer))
  defp subject(nil, _outer), do: nil
  defp subject(inner, _outer), do: presence(strip_forward_prefix(inner))

  defp presence(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp presence(_value), do: nil
end
