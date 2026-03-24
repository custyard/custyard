defmodule Custyard.Email.Parser do
  @moduledoc """
  Parse RFC 5322 raw email into normalized map for Processor.

  Handles:
  - MIME multipart (text/plain + text/html)
  - Charset encoding (UTF-8, ISO-8859-1, etc.)
  - Transfer encoding (base64, quoted-printable)
  - Custom X-headers for Sieve integration

  ## Output Format

  Returns a map with BOTH atom keys and string keys for compatibility with
  multiple consumers:

  - **Atom keys** (e.g., `:from`, `:subject`): For direct pattern matching and
    struct-like access in Elixir code (LMTP/IMAP flow).

  - **String keys** (e.g., `"from"`, `"subject"`): For JSON webhook payloads
    and external API compatibility (Processor.process/1 expects these).

  Threading headers (`message_id`, `in_reply_to`, `references`) appear at the
  top level for convenience and are also accessible in the `headers` map with
  their original casing (e.g., `"message-id"`). The Processor re-extracts these
  from headers for normalization.
  """

  # Windows-1252 to Unicode mapping for bytes 0x80-0x9F
  # These bytes differ from Latin-1 (which has control chars in this range)
  @cp1252_map %{
    # Euro sign
    0x80 => 0x20AC,
    # Undefined (keep as-is)
    0x81 => 0x0081,
    # Single low-9 quotation mark
    0x82 => 0x201A,
    # Latin small letter f with hook
    0x83 => 0x0192,
    # Double low-9 quotation mark
    0x84 => 0x201E,
    # Horizontal ellipsis
    0x85 => 0x2026,
    # Dagger
    0x86 => 0x2020,
    # Double dagger
    0x87 => 0x2021,
    # Modifier letter circumflex accent
    0x88 => 0x02C6,
    # Per mille sign
    0x89 => 0x2030,
    # Latin capital letter S with caron
    0x8A => 0x0160,
    # Single left-pointing angle quotation mark
    0x8B => 0x2039,
    # Latin capital ligature OE
    0x8C => 0x0152,
    # Undefined (keep as-is)
    0x8D => 0x008D,
    # Latin capital letter Z with caron
    0x8E => 0x017D,
    # Undefined (keep as-is)
    0x8F => 0x008F,
    # Undefined (keep as-is)
    0x90 => 0x0090,
    # Left single quotation mark
    0x91 => 0x2018,
    # Right single quotation mark
    0x92 => 0x2019,
    # Left double quotation mark
    0x93 => 0x201C,
    # Right double quotation mark
    0x94 => 0x201D,
    # Bullet
    0x95 => 0x2022,
    # En dash
    0x96 => 0x2013,
    # Em dash
    0x97 => 0x2014,
    # Small tilde
    0x98 => 0x02DC,
    # Trade mark sign
    0x99 => 0x2122,
    # Latin small letter s with caron
    0x9A => 0x0161,
    # Single right-pointing angle quotation mark
    0x9B => 0x203A,
    # Latin small ligature oe
    0x9C => 0x0153,
    # Undefined (keep as-is)
    0x9D => 0x009D,
    # Latin small letter z with caron
    0x9E => 0x017E,
    # Latin capital letter Y with diaeresis
    0x9F => 0x0178
  }

  @doc """
  Parse raw RFC 5322 email binary into normalized map.

  Returns map compatible with Processor.process/1. Fields have BOTH atom and
  string keys for compatibility (see moduledoc for rationale).

  ## Example Output

      %{
        # Atom keys (for pattern matching)
        from: "sender@example.com",
        to: "support@platform.test",
        subject: "Subject line",
        text: "Plain text body",
        html: "<html>...",
        message_id: "<id@domain>",
        in_reply_to: "<ref@domain>",
        references: "<ref1> <ref2>",
        headers: %{"message-id" => "<id@domain>", "X-Priority" => "1"},
        attachments: [%{filename: "doc.pdf", content_type: "application/pdf", content: <<...>>}],

        # String keys (same values, for JSON/webhook compat)
        "from" => "sender@example.com",
        "to" => "support@platform.test",
        "subject" => "Subject line",
        "text" => "Plain text body",
        "html" => "<html>...",
        "headers" => %{...},
        "attachments" => [%{...}]
      }

  Note: `message_id`, `in_reply_to`, `references` exist only as atom keys at
  top level. The Processor extracts these from `headers` map anyway.
  """
  @spec parse(binary()) :: {:ok, map()} | {:error, term()}
  def parse(nil), do: {:error, :nil_input}
  def parse(""), do: {:error, :empty_input}

  def parse(raw_email) when is_binary(raw_email) do
    # Normalize line endings to CRLF (RFC 5322 requirement)
    normalized = normalize_line_endings(raw_email)

    # Decode with encoding: :none to handle charset conversion ourselves
    opts = [{:allow_missing_version, true}, {:encoding, :none}]

    case :mimemail.decode(normalized, opts) do
      {_type, _subtype, headers, _properties, _body} = mime_tuple ->
        {:ok, build_normalized_map(mime_tuple, headers)}

      {:error, reason} ->
        {:error, {:parse_failed, reason}}
    end
  rescue
    e -> {:error, {:parse_failed, e}}
  end

  # Normalize LF to CRLF for RFC 5322 compliance
  defp normalize_line_endings(text) do
    # Replace lone LF (not preceded by CR) with CRLF
    String.replace(text, ~r/(?<!\r)\n/, "\r\n")
  end

  defp build_normalized_map(mime_tuple, headers) do
    %{
      from: extract_email_address(get_header(headers, "From")),
      to: extract_email_address(get_header(headers, "To")),
      subject: decode_header_value(get_header(headers, "Subject") || ""),
      text: extract_text_body(mime_tuple),
      html: extract_html_body(mime_tuple),
      message_id: get_header(headers, "Message-ID"),
      in_reply_to: get_header(headers, "In-Reply-To"),
      references: get_header(headers, "References"),
      headers: build_headers_map(headers),
      attachments: extract_attachments(mime_tuple)
    }
    |> add_string_keys()
  end

  # Add string key versions for JSON webhook compatibility
  defp add_string_keys(map) do
    # Convert attachment maps to also have string keys
    attachments_with_string_keys =
      Enum.map(map.attachments, fn att ->
        att
        |> Map.put("filename", att.filename)
        |> Map.put("content_type", att.content_type)
        |> Map.put("content", att.content)
      end)

    map
    |> Map.put("from", map.from)
    |> Map.put("to", map.to)
    |> Map.put("subject", map.subject)
    |> Map.put("text", map.text)
    |> Map.put("html", map.html)
    |> Map.put("headers", map.headers)
    |> Map.put("attachments", attachments_with_string_keys)
  end

  # Extract email address from header value like "Name <email@domain>" or "email@domain"
  defp extract_email_address(nil), do: nil

  defp extract_email_address(value) when is_binary(value) do
    value = decode_header_value(value)

    # Format: "Name <email@domain>" or just "email@domain"
    if String.contains?(value, "<") do
      case Regex.run(~r/<([^>]+)>/, value) do
        [_, email] -> String.trim(email)
        _ -> String.trim(value)
      end
    else
      String.trim(value)
    end
  end

  # Get header value (case-insensitive key lookup)
  defp get_header(headers, name) when is_list(headers) do
    name_lower = String.downcase(name)

    Enum.find_value(headers, fn {key, value} ->
      if String.downcase(to_string(key)) == name_lower, do: value
    end)
  end

  defp get_header(_headers, _name), do: nil

  # Decode RFC 2047 encoded header values (=?charset?encoding?text?=)
  defp decode_header_value(nil), do: nil

  defp decode_header_value(value) when is_binary(value) do
    # Handle RFC 2047 encoded words
    Regex.replace(~r/=\?([^?]+)\?([BQ])\?([^?]*)\?=/i, value, fn _, charset, encoding, text ->
      decode_encoded_word(charset, encoding, text)
    end)
    |> String.trim()
  end

  defp decode_header_value(value), do: to_string(value)

  defp decode_encoded_word(charset, encoding, text) do
    decoded =
      case String.upcase(encoding) do
        "B" -> Base.decode64!(text)
        "Q" -> decode_quoted_printable_header(text)
      end

    convert_charset(decoded, charset)
  rescue
    _ -> text
  end

  # Quoted-printable in headers uses _ for space
  defp decode_quoted_printable_header(text) do
    text
    |> String.replace("_", " ")
    |> decode_quoted_printable()
  end

  # Extract plain text body from MIME structure
  defp extract_text_body({_type, _subtype, _headers, _props, body})
       when is_list(body) do
    # Multipart - find text/plain part
    find_part_by_type(body, "text", "plain")
  end

  defp extract_text_body({"text", "plain", headers, props, body}) do
    decode_body(body, headers, props)
  end

  defp extract_text_body({"text", "html", _headers, _props, _body}) do
    # Only HTML, no plain text
    nil
  end

  defp extract_text_body({_type, _subtype, _headers, _props, body})
       when is_binary(body) do
    # Non-text type with binary body - likely single part that isn't text
    nil
  end

  defp extract_text_body(_), do: nil

  # Extract HTML body from MIME structure
  defp extract_html_body({_type, _subtype, _headers, _props, body})
       when is_list(body) do
    # Multipart - find text/html part
    find_part_by_type(body, "text", "html")
  end

  defp extract_html_body({"text", "html", headers, props, body}) do
    decode_body(body, headers, props)
  end

  defp extract_html_body({"text", "plain", _headers, _props, _body}) do
    # Only plain text, no HTML
    nil
  end

  defp extract_html_body({_type, _subtype, _headers, _props, _body}) do
    nil
  end

  defp extract_html_body(_), do: nil

  # Find a specific content type in multipart body
  defp find_part_by_type(parts, type, subtype) when is_list(parts) do
    Enum.find_value(parts, fn
      {^type, ^subtype, headers, props, body} ->
        decode_body(body, headers, props)

      {"multipart", _sub, _headers, _props, nested_parts} when is_list(nested_parts) ->
        find_part_by_type(nested_parts, type, subtype)

      _ ->
        nil
    end)
  end

  # Extract attachments from MIME structure
  defp extract_attachments({_type, _subtype, _headers, _props, body}) when is_list(body) do
    body
    |> Enum.flat_map(&extract_attachment_from_part/1)
  end

  defp extract_attachments(_), do: []

  # Handle nested multipart first (more specific pattern)
  defp extract_attachment_from_part({"multipart", _sub, _headers, _props, nested})
       when is_list(nested) do
    Enum.flat_map(nested, &extract_attachment_from_part/1)
  end

  # Handle regular MIME parts
  defp extract_attachment_from_part({type, subtype, headers, props, body}) do
    is_non_text = type != "text"
    is_text_attachment = type == "text" and attachment?(props)

    if is_non_text or is_text_attachment do
      filename = get_filename(headers, props)
      content_type = "#{type}/#{subtype}"

      if filename do
        decoded_content = decode_attachment_body(body, headers, props)

        [
          %{
            filename: filename,
            content_type: content_type,
            content: decoded_content
          }
        ]
      else
        []
      end
    else
      []
    end
  end

  defp extract_attachment_from_part(_), do: []

  defp attachment?(props) do
    disposition = Map.get(props, :disposition, "inline")
    disposition == "attachment"
  end

  defp get_filename(headers, props) do
    # Check Content-Disposition filename parameter first
    disposition_params = Map.get(props, :disposition_params, [])

    filename =
      case List.keyfind(disposition_params, "filename", 0) do
        {"filename", name} -> name
        _ -> nil
      end

    # Fall back to Content-Type name parameter
    filename ||
      case Map.get(props, :content_type_params, []) do
        params when is_list(params) ->
          case List.keyfind(params, "name", 0) do
            {"name", name} -> name
            _ -> nil
          end

        _ ->
          nil
      end ||
      get_header(headers, "Content-Disposition")
      |> extract_filename_from_header()
  end

  defp extract_filename_from_header(nil), do: nil

  defp extract_filename_from_header(header) do
    case Regex.run(~r/filename="?([^";\s]+)"?/i, header) do
      [_, filename] -> filename
      _ -> nil
    end
  end

  defp decode_attachment_body(body, headers, props) when is_binary(body) do
    encoding = get_transfer_encoding(headers, props)
    decode_transfer_encoding(body, encoding)
  end

  defp decode_attachment_body(body, _headers, _props), do: body

  # Decode body based on content-transfer-encoding and charset
  defp decode_body(body, headers, props) when is_binary(body) do
    encoding = get_transfer_encoding(headers, props)
    charset = get_charset(props)

    body
    |> decode_transfer_encoding(encoding)
    |> convert_charset(charset)
    |> normalize_crlf_to_lf()
  end

  defp decode_body(body, _headers, _props), do: to_string(body)

  # Convert CRLF back to LF for internal processing
  defp normalize_crlf_to_lf(text) when is_binary(text) do
    String.replace(text, "\r\n", "\n")
  end

  defp normalize_crlf_to_lf(text), do: text

  defp get_transfer_encoding(headers, props) do
    # Check props first (gen_smtp parses this into map)
    case Map.get(props, :transfer_encoding) do
      nil -> get_header(headers, "Content-Transfer-Encoding") || "7bit"
      enc -> to_string(enc)
    end
    |> String.downcase()
  end

  defp get_charset(props) do
    # gen_smtp puts charset in props under content_type_params (as list of tuples)
    case Map.get(props, :content_type_params, []) do
      params when is_list(params) ->
        case List.keyfind(params, "charset", 0) do
          {"charset", charset} -> charset
          _ -> "utf-8"
        end

      _ ->
        "utf-8"
    end
  end

  defp decode_transfer_encoding(body, "base64") do
    case Base.decode64(String.replace(body, ~r/\s/, "")) do
      {:ok, decoded} -> decoded
      :error -> body
    end
  end

  defp decode_transfer_encoding(body, "quoted-printable") do
    decode_quoted_printable(body)
  end

  defp decode_transfer_encoding(body, _), do: body

  # Decode quoted-printable encoding
  defp decode_quoted_printable(text) do
    text
    # Handle soft line breaks (=\r\n or =\n)
    |> String.replace(~r/=\r?\n/, "")
    # Decode hex sequences
    |> decode_qp_hex()
  end

  defp decode_qp_hex(text) do
    Regex.replace(~r/=([0-9A-Fa-f]{2})/, text, fn _, hex ->
      <<String.to_integer(hex, 16)>>
    end)
  end

  # Convert charset to UTF-8
  defp convert_charset(text, charset) when is_binary(text) do
    charset_lower = String.downcase(charset)

    case charset_lower do
      c when c in ["utf-8", "utf8", "us-ascii", "ascii"] ->
        text

      "iso-8859-1" ->
        # Latin-1 to UTF-8
        :unicode.characters_to_binary(text, :latin1, :utf8)
        |> normalize_unicode_result()

      "iso-8859-15" ->
        # Latin-9 (ISO-8859-15) differs from Latin-1 at 8 code points.
        # Remap those bytes before converting the rest as Latin-1.
        text
        |> remap_iso8859_15_bytes()
        |> List.to_string()

      "windows-1252" ->
        # CP1252 has special characters in 0x80-0x9F range that differ from Latin-1
        convert_cp1252_to_utf8(text)

      _ ->
        # Best effort - try as-is
        text
    end
  end

  defp convert_charset(text, _charset), do: to_string(text)

  defp normalize_unicode_result(result) when is_binary(result), do: result
  defp normalize_unicode_result({:error, _, _}), do: ""
  defp normalize_unicode_result({:incomplete, partial, _}), do: partial

  # Convert Windows-1252 (CP1252) to UTF-8
  # Bytes 0x00-0x7F and 0xA0-0xFF are same as Latin-1
  # Bytes 0x80-0x9F need special mapping
  defp convert_cp1252_to_utf8(text) when is_binary(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.map(&cp1252_byte_to_codepoint/1)
    |> List.to_string()
  end

  defp cp1252_byte_to_codepoint(byte) when byte in 0x80..0x9F do
    Map.get(@cp1252_map, byte, byte)
  end

  defp cp1252_byte_to_codepoint(byte), do: byte

  # ISO-8859-15 (Latin-9) byte-to-codepoint mapping for the 8 positions
  # that differ from ISO-8859-1 (Latin-1):
  #   0xA4 -> U+20AC (Euro sign, replaces currency sign)
  #   0xA6 -> U+0160 (S with caron)
  #   0xA8 -> U+0161 (s with caron)
  #   0xB4 -> U+017D (Z with caron)
  #   0xB8 -> U+017E (z with caron)
  #   0xBC -> U+0152 (OE ligature)
  #   0xBD -> U+0153 (oe ligature)
  #   0xBE -> U+0178 (Y with diaeresis)
  @iso8859_15_map %{
    0xA4 => 0x20AC,
    0xA6 => 0x0160,
    0xA8 => 0x0161,
    0xB4 => 0x017D,
    0xB8 => 0x017E,
    0xBC => 0x0152,
    0xBD => 0x0153,
    0xBE => 0x0178
  }

  defp remap_iso8859_15_bytes(text) when is_binary(text) do
    text
    |> :binary.bin_to_list()
    |> Enum.map(&iso8859_15_byte_to_codepoint/1)
  end

  defp iso8859_15_byte_to_codepoint(byte) when is_map_key(@iso8859_15_map, byte) do
    Map.fetch!(@iso8859_15_map, byte)
  end

  defp iso8859_15_byte_to_codepoint(byte), do: byte

  # Build headers map with normalized keys
  defp build_headers_map(headers) when is_list(headers) do
    headers
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      key_str = to_string(key)
      # Preserve original case for X-headers, lowercase standard headers
      normalized_key =
        if String.starts_with?(String.upcase(key_str), "X-") do
          key_str
        else
          String.downcase(key_str)
        end

      decoded_value = decode_header_value(value)
      Map.put(acc, normalized_key, decoded_value)
    end)
  end

  defp build_headers_map(_), do: %{}
end
