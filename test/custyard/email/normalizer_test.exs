defmodule Custyard.Email.NormalizerTest do
  use ExUnit.Case, async: true

  alias Custyard.Email.Normalizer

  describe "get_header/2" do
    test "returns value for exact key match" do
      headers = %{"message-id" => "<abc@example.com>"}
      assert Normalizer.get_header(headers, "message-id") == "<abc@example.com>"
    end

    test "returns value via case-insensitive match" do
      headers = %{"Message-ID" => "<abc@example.com>"}
      assert Normalizer.get_header(headers, "message-id") == "<abc@example.com>"
    end

    test "handles all-uppercase header name" do
      headers = %{"IN-REPLY-TO" => "<ref@example.com>"}
      assert Normalizer.get_header(headers, "in-reply-to") == "<ref@example.com>"
    end

    test "prefers exact match over case-insensitive match" do
      headers = %{
        "message-id" => "<exact@example.com>",
        "Message-Id" => "<casefolded@example.com>"
      }

      assert Normalizer.get_header(headers, "message-id") == "<exact@example.com>"
    end

    test "returns nil for missing header" do
      assert Normalizer.get_header(%{}, "message-id") == nil
    end

    test "returns nil when headers map has keys but not the requested one" do
      headers = %{"subject" => "Hello", "from" => "alice@example.com"}
      assert Normalizer.get_header(headers, "message-id") == nil
    end
  end

  describe "strip_html/1" do
    test "removes HTML tags" do
      assert Normalizer.strip_html("<p>Hello <b>world</b></p>") == "Hello world"
    end

    test "removes nested tags" do
      html = "<div><p>Outer <span>inner</span> text</p></div>"
      assert Normalizer.strip_html(html) == "Outer inner text"
    end

    test "collapses whitespace" do
      assert Normalizer.strip_html("<p>Hello</p>\n\n<p>world</p>") == "Hello world"
    end

    test "trims leading and trailing whitespace" do
      assert Normalizer.strip_html("  <p>Hello</p>  ") == "Hello"
    end

    test "handles self-closing tags" do
      assert Normalizer.strip_html("Hello<br/>world") == "Hello world"
    end

    test "returns nil for nil input" do
      assert Normalizer.strip_html(nil) == nil
    end

    test "returns empty string for empty HTML" do
      assert Normalizer.strip_html("") == ""
    end
  end

  describe "truncate/2" do
    test "returns text unchanged when under limit" do
      assert Normalizer.truncate("short", 100) == "short"
    end

    test "returns text unchanged when exactly at limit" do
      text = String.duplicate("a", 50)
      assert Normalizer.truncate(text, 50) == text
    end

    test "truncates with ellipsis when over limit" do
      text = String.duplicate("a", 20)
      result = Normalizer.truncate(text, 10)

      assert byte_size(result) <= 10
      assert String.ends_with?(result, "...")
    end

    test "truncated result preserves prefix of original" do
      result = Normalizer.truncate("Hello, world! This is a long string.", 15)

      # The result should start with the beginning of the original text
      prefix = String.slice(result, 0, String.length(result) - 3)
      assert String.starts_with?("Hello, world! This is a long string.", prefix)
      assert String.ends_with?(result, "...")
    end

    test "returns empty string for nil input" do
      assert Normalizer.truncate(nil, 100) == ""
    end

    test "handles max_length less than 4" do
      # For max_length < 4, returns slice without ellipsis
      assert Normalizer.truncate("hello", 3) == "hel"
      assert Normalizer.truncate("hello", 2) == "he"
      assert Normalizer.truncate("hello", 1) == "h"
      assert Normalizer.truncate("hello", 0) == ""
    end

    test "handles multi-byte UTF-8 characters correctly" do
      # "café" has 4 graphemes but 5 bytes (é is 2 bytes)
      assert Normalizer.truncate("café", 10) == "café"

      # Emoji handling - the emoji is truncated but result length respects limit
      result = Normalizer.truncate("café🎉test", 6)
      assert String.length(result) <= 6
    end
  end
end
