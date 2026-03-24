defmodule Custyard.Email.Parser do
  @moduledoc """
  Parse RFC 5322 raw email into normalized map for Processor.

  Handles:
  - MIME multipart (text/plain + text/html)
  - Charset encoding (UTF-8, ISO-8859-1, etc.)
  - Transfer encoding (base64, quoted-printable)
  - Custom X-headers for Sieve integration
  """

  @doc """
  Parse raw RFC 5322 email binary into normalized map.

  Returns map compatible with Processor.process/1 (with atom keys for direct
  struct access AND string keys for JSON webhook compatibility):

      %{
        from: "sender@example.com",
        to: "support@platform.test",
        subject: "Subject line",
        text: "Plain text body",
        html: "<html>...",
        message_id: "<id@domain>",
        in_reply_to: "<ref@domain>",
        references: "<ref1> <ref2>",
        headers: %{
          "message-id" => "<id@domain>",
          "X-Customer-Tier" => "enterprise"
        },
        attachments: [
          %{filename: "file.pdf", content_type: "application/pdf", content: <<...>>}
        ]
      }
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
    map
    |> Map.put("from", map.from)
    |> Map.put("to", map.to)
    |> Map.put("subject", map.subject)
    |> Map.put("text", map.text)
    |> Map.put("html", map.html)
    |> Map.put("headers", map.headers)
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
        # Latin-9, similar to Latin-1 with Euro sign
        :unicode.characters_to_binary(text, :latin1, :utf8)
        |> normalize_unicode_result()

      "windows-1252" ->
        # CP1252 is superset of Latin-1
        :unicode.characters_to_binary(text, :latin1, :utf8)
        |> normalize_unicode_result()

      _ ->
        # Best effort - try as-is
        text
    end
  end

  defp convert_charset(text, _charset), do: to_string(text)

  defp normalize_unicode_result(result) when is_binary(result), do: result
  defp normalize_unicode_result({:error, _, _}), do: ""
  defp normalize_unicode_result({:incomplete, partial, _}), do: partial

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
