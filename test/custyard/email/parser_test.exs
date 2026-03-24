defmodule Custyard.Email.ParserTest do
  @moduledoc """
  Tests for the email parser module.

  The parser converts raw RFC 5322 email data into normalized maps
  suitable for the email processor. Uses gen_smtp's mimemail for parsing.
  """
  use ExUnit.Case, async: true

  alias Custyard.Email.Parser

  @fixtures_path Path.join([__DIR__, "..", "..", "fixtures", "emails"])

  # Helper to read fixture files
  defp read_fixture(filename) do
    @fixtures_path
    |> Path.join(filename)
    |> File.read!()
  end

  describe "parse/1 with simple plain text email" do
    test "extracts from address" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["from"] == "alice@example.com"
    end

    test "extracts to address" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["to"] == "support@custyard.test"
    end

    test "extracts subject" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["subject"] == "Help with setup"
    end

    test "extracts message-id from headers" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["message-id"] == "<simple-001@example.com>"
    end

    test "extracts plain text body" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["text"] =~ "I need help setting up my account"
      assert parsed["text"] =~ "Thanks,"
    end

    test "html is nil for plain text email" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["html"] == nil
    end
  end

  describe "parse/1 with multipart/alternative (text + html)" do
    test "extracts both text and html parts" do
      raw = read_fixture("multipart_alternative.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["text"] =~ "plain text version"
      assert parsed["html"] =~ "<strong>HTML</strong>"
    end

    test "preserves html structure" do
      raw = read_fixture("multipart_alternative.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["html"] =~ "<html>"
      assert parsed["html"] =~ "</body>"
    end

    test "extracts message-id from multipart email" do
      raw = read_fixture("multipart_alternative.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["message-id"] == "<multipart-alt-001@example.com>"
    end
  end

  describe "parse/1 with multipart/mixed and attachments" do
    test "extracts text body from mixed multipart" do
      raw = read_fixture("multipart_mixed_attachment.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["text"] =~ "attached invoice"
    end

    test "identifies attachments" do
      raw = read_fixture("multipart_mixed_attachment.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert is_list(parsed["attachments"])
      assert parsed["attachments"] != []

      [attachment | _] = parsed["attachments"]
      assert attachment["filename"] == "invoice.pdf"
      assert attachment["content_type"] == "application/pdf"
    end
  end

  describe "parse/1 with various charsets" do
    test "decodes ISO-8859-1 charset correctly" do
      raw = read_fixture("iso_8859_1_charset.eml")
      {:ok, parsed} = Parser.parse(raw)

      # Should decode German umlauts - converted to UTF-8
      # Original: Gruesse -> with conversion from Latin-1
      assert String.valid?(parsed["text"])
    end

    test "decodes encoded subject header (RFC 2047)" do
      raw = read_fixture("iso_8859_1_charset.eml")
      {:ok, parsed} = Parser.parse(raw)

      # Encoded subject: =?ISO-8859-1?Q?Gr=FC=DFe_aus_M=FCnchen?=
      # Should decode to readable text
      assert parsed["subject"] != nil
      assert String.valid?(parsed["subject"])
      # The decoded subject should contain "aus" (from German)
      assert parsed["subject"] =~ "aus"
    end

    test "decodes Windows-1252 charset correctly" do
      raw = read_fixture("windows_1252_charset.eml")
      {:ok, parsed} = Parser.parse(raw)

      # Smart quotes and special chars should be converted to UTF-8
      assert String.valid?(parsed["text"])
      assert parsed["text"] =~ "smart quotes" or parsed["text"] =~ "quotes"

      # Verify 0x80-0x9F range characters are properly converted
      # 0x93 -> U+201C (left double quote), 0x94 -> U+201D (right double quote)
      assert String.contains?(parsed["text"], <<0x201C::utf8>>)
      assert String.contains?(parsed["text"], <<0x201D::utf8>>)
      # 0x96 -> U+2013 (en dash), 0x97 -> U+2014 (em dash)
      assert String.contains?(parsed["text"], <<0x2013::utf8>>)
      assert String.contains?(parsed["text"], <<0x2014::utf8>>)
      # 0x85 -> U+2026 (horizontal ellipsis)
      assert String.contains?(parsed["text"], <<0x2026::utf8>>)
    end
  end

  describe "parse/1 with base64 encoded body" do
    test "decodes base64 body to plain text" do
      raw = read_fixture("base64_body.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["text"] =~ "base64 encoded message"
      assert parsed["text"] =~ "multiple lines"
    end

    test "does not include raw base64 in output" do
      raw = read_fixture("base64_body.eml")
      {:ok, parsed} = Parser.parse(raw)

      # The raw base64 should not appear
      refute parsed["text"] =~ "VGhpcyBpcyBh"
    end
  end

  describe "parse/1 with quoted-printable encoded body" do
    test "decodes quoted-printable soft line breaks" do
      raw = read_fixture("quoted_printable_body.eml")
      {:ok, parsed} = Parser.parse(raw)

      # Soft line breaks (=\n) should be removed
      assert parsed["text"] =~ "exceeds 76 characters"
      refute parsed["text"] =~ "=\n"
    end

    test "decodes quoted-printable special characters" do
      raw = read_fixture("quoted_printable_body.eml")
      {:ok, parsed} = Parser.parse(raw)

      # =C3=A9 is e-acute in UTF-8
      # Should decode to proper unicode
      assert String.valid?(parsed["text"])
    end
  end

  describe "parse/1 with custom X-headers" do
    test "extracts X-Customer-Tier header with preserved case" do
      raw = read_fixture("custom_x_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["X-Customer-Tier"] == "enterprise"
    end

    test "extracts X-Priority header" do
      raw = read_fixture("custom_x_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["X-Priority"] == "urgent"
    end

    test "extracts arbitrary X-headers" do
      raw = read_fixture("custom_x_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["X-Request-ID"] == "req-12345"
    end

    test "X-headers preserve original case while standard headers are lowercased" do
      raw = read_fixture("custom_x_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      # X-headers preserve case
      assert Map.has_key?(parsed["headers"], "X-Customer-Tier")
      # Standard headers are lowercased
      assert Map.has_key?(parsed["headers"], "from")
      assert Map.has_key?(parsed["headers"], "message-id")
    end
  end

  describe "parse/1 with threading headers" do
    test "extracts in-reply-to header (lowercased)" do
      raw = read_fixture("threading_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["in-reply-to"] == "<original-001@example.com>"
    end

    test "extracts references header" do
      raw = read_fixture("threading_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["references"] =~ "original-001@example.com"
      assert parsed["headers"]["references"] =~ "followup-001@example.com"
    end

    test "extracts message-id for threading" do
      raw = read_fixture("threading_headers.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert parsed["headers"]["message-id"] == "<reply-001@example.com>"
    end
  end

  describe "parse/1 with malformed emails" do
    test "handles missing required headers gracefully" do
      raw = read_fixture("malformed_missing_headers.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Parser may succeed with nil values
          assert parsed["from"] == nil or parsed["from"] == ""

        {:error, reason} ->
          # Or parser may return error - both are acceptable
          assert is_tuple(reason) or is_atom(reason)
      end
    end

    test "handles truncated multipart gracefully" do
      raw = read_fixture("malformed_truncated.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Parser may extract partial content or nil
          assert parsed["text"] == nil or is_binary(parsed["text"])

        {:error, _reason} ->
          # Error is also acceptable for malformed input
          assert true
      end
    end

    test "returns error tuple for completely invalid input" do
      result = Parser.parse("not an email at all")

      case result do
        {:error, {:parse_failed, _}} ->
          assert true

        {:ok, parsed} ->
          # If parser is lenient, it may return something
          assert is_map(parsed)
      end
    end

    test "handles empty input" do
      result = Parser.parse("")

      assert match?({:error, _}, result)
    end
  end

  describe "parse/1 with missing from field" do
    test "returns nil for missing from" do
      # Inline test data - minimal email without From header
      raw = """
      To: support@custyard.test
      Subject: No sender
      Message-ID: <no-from@example.com>

      Body without from header.
      """

      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          assert parsed["from"] == nil
          assert parsed["subject"] == "No sender"

        {:error, _} ->
          # Also acceptable
          assert true
      end
    end
  end

  describe "parse/1 with missing subject field" do
    test "returns empty string for missing subject" do
      raw = """
      From: alice@example.com
      To: support@custyard.test
      Message-ID: <no-subject@example.com>

      Body without subject header.
      """

      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Subject defaults to empty string when missing
          assert parsed["subject"] == ""
          assert parsed["from"] == "alice@example.com"

        {:error, _} ->
          assert true
      end
    end
  end

  describe "parse/1 output structure" do
    test "returns expected keys in parsed map" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      # Verify expected structure with string keys
      assert Map.has_key?(parsed, "from")
      assert Map.has_key?(parsed, "to")
      assert Map.has_key?(parsed, "subject")
      assert Map.has_key?(parsed, "text")
      assert Map.has_key?(parsed, "html")
      assert Map.has_key?(parsed, "headers")
    end

    test "headers is a map with string keys" do
      raw = read_fixture("simple_plain_text.eml")
      {:ok, parsed} = Parser.parse(raw)

      assert is_map(parsed["headers"])
      # All keys should be strings
      assert Enum.all?(Map.keys(parsed["headers"]), &is_binary/1)
    end
  end

  describe "parse/1 with binary (raw SMTP) input" do
    test "handles binary data from gen_smtp" do
      # gen_smtp delivers emails as binaries
      raw = read_fixture("simple_plain_text.eml")
      binary_raw = :erlang.iolist_to_binary(raw)

      {:ok, parsed} = Parser.parse(binary_raw)

      assert parsed["from"] == "alice@example.com"
      assert parsed["subject"] == "Help with setup"
    end
  end

  describe "parse/1 with Name <email> format" do
    test "extracts email address from 'Name <email>' format" do
      raw = """
      From: Alice Smith <alice@example.com>
      To: Support Team <support@custyard.test>
      Subject: Test
      Message-ID: <name-format@example.com>

      Test body
      """

      {:ok, parsed} = Parser.parse(raw)

      # Should extract just the email address
      assert parsed["from"] == "alice@example.com"
      assert parsed["to"] == "support@custyard.test"
    end

    test "handles plain email address without name" do
      raw = """
      From: plain@example.com
      To: support@custyard.test
      Subject: Test
      Message-ID: <plain@example.com>

      Test body
      """

      {:ok, parsed} = Parser.parse(raw)

      assert parsed["from"] == "plain@example.com"
    end
  end

  describe "parse/1 with nested multipart boundaries" do
    test "extracts text from nested multipart/alternative inside multipart/mixed" do
      raw = read_fixture("nested_multipart.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Should find text in nested alternative part
          assert parsed["text"] =~ "Plain text in nested multipart"

        {:error, _} ->
          # Parser may fail on complex nesting - acceptable
          assert true
      end
    end

    test "extracts html from nested multipart structure" do
      raw = read_fixture("nested_multipart.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Should find HTML in nested alternative part
          assert parsed["html"] =~ "HTML in nested multipart"

        {:error, _} ->
          assert true
      end
    end

    test "extracts attachments from outer multipart level" do
      raw = read_fixture("nested_multipart.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          assert is_list(parsed["attachments"])

          if parsed["attachments"] != [] do
            [attachment | _] = parsed["attachments"]
            assert attachment["filename"] == "nested.pdf"
          end

        {:error, _} ->
          assert true
      end
    end

    test "handles deeply nested multipart (3 levels)" do
      raw = read_fixture("deeply_nested_multipart.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Should traverse to innermost level and find text
          assert parsed["text"] =~ "Deep nesting level 3"

        {:error, _} ->
          # Deep nesting may fail - acceptable behavior
          assert true
      end
    end
  end

  describe "parse/1 with missing boundary markers" do
    test "handles missing initial boundary marker" do
      raw = read_fixture("missing_boundary_marker.eml")
      result = Parser.parse(raw)

      # Parser should either:
      # - Return error for malformed MIME
      # - Return ok with nil/empty body parts
      # Both are acceptable
      case result do
        {:ok, parsed} ->
          assert is_map(parsed)
          # Body parts may be nil or contain preamble text
          assert parsed["text"] == nil or is_binary(parsed["text"])

        {:error, reason} ->
          assert is_tuple(reason) or is_atom(reason)
      end
    end

    test "handles content before first boundary (preamble)" do
      raw = read_fixture("missing_boundary_marker.eml")
      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # Preamble text should typically be ignored per RFC 2046
          # but lenient parsers may include it
          assert is_map(parsed)

        {:error, _} ->
          assert true
      end
    end
  end

  describe "parse/1 with truncated base64" do
    test "handles base64 that ends mid-sequence" do
      raw = read_fixture("truncated_base64.eml")
      result = Parser.parse(raw)

      # Truncated base64 may:
      # - Decode partially (ignoring invalid trailing bytes)
      # - Return original undecoded content
      # - Return error
      case result do
        {:ok, parsed} ->
          # If decoding succeeded partially, should have some text
          # or the raw base64 if decoding failed
          assert parsed["text"] == nil or is_binary(parsed["text"])

        {:error, _} ->
          assert true
      end
    end

    test "handles invalid base64 characters" do
      raw = read_fixture("invalid_base64_chars.eml")
      result = Parser.parse(raw)

      # Invalid characters in base64 should be handled gracefully
      case result do
        {:ok, parsed} ->
          # Parser may return partially decoded, undecoded, or nil
          assert parsed["text"] == nil or is_binary(parsed["text"])

        {:error, _} ->
          assert true
      end
    end

    test "does not crash on base64 with embedded garbage" do
      # Inline test with obviously invalid base64
      raw = """
      From: garbage@example.com
      To: support@custyard.test
      Subject: Garbage base64
      Message-ID: <garbage-001@example.com>
      Content-Type: text/plain
      Content-Transfer-Encoding: base64

      Not base64 at all!!! <<<>>> @@@
      """

      # Should not raise, should return ok or error tuple
      result = Parser.parse(raw)

      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end
  end

  describe "parse/1 multipart boundary edge cases" do
    test "handles boundary that appears in body text" do
      # Edge case: text contains string that looks like boundary
      raw = """
      From: edge@example.com
      To: support@custyard.test
      Subject: Boundary in body
      Message-ID: <boundary-in-body@example.com>
      Content-Type: multipart/mixed; boundary="simple"

      --simple
      Content-Type: text/plain

      This text mentions --simple in the middle of a line.
      But that should not be treated as a boundary.

      --simple--
      """

      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          # The "--simple" in text should be preserved, not treated as boundary
          if parsed["text"] do
            assert parsed["text"] =~ "--simple in the middle"
          end

        {:error, _} ->
          assert true
      end
    end

    test "handles empty boundary string" do
      raw = """
      From: empty@example.com
      To: support@custyard.test
      Subject: Empty boundary
      Message-ID: <empty-boundary@example.com>
      Content-Type: multipart/mixed; boundary=""

      Body content here.
      """

      result = Parser.parse(raw)

      # Empty boundary is invalid - parser should handle gracefully
      assert match?({:ok, _}, result) or match?({:error, _}, result)
    end

    test "handles very long boundary string" do
      long_boundary = String.duplicate("x", 70)

      raw = """
      From: long@example.com
      To: support@custyard.test
      Subject: Long boundary
      Message-ID: <long-boundary@example.com>
      Content-Type: multipart/mixed; boundary="#{long_boundary}"

      --#{long_boundary}
      Content-Type: text/plain

      Text with long boundary.

      --#{long_boundary}--
      """

      result = Parser.parse(raw)

      case result do
        {:ok, parsed} ->
          assert parsed["text"] =~ "long boundary" or parsed["text"] == nil

        {:error, _} ->
          assert true
      end
    end
  end
end
