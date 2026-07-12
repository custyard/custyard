defmodule Custyard.Email.HeadersTest do
  use ExUnit.Case, async: true

  alias Custyard.Email.Headers

  describe "sanitize_header_text/1" do
    test "strips CR/LF and control characters (CWE-93 header injection)" do
      assert Headers.sanitize_header_text("Hello\r\nBcc: attacker@evil.com") ==
               "Hello Bcc: attacker@evil.com"

      assert Headers.sanitize_header_text("null\x00byte\x7Ftab\there") == "null byte tab here"
    end

    test "collapses runs of control characters into one space and trims" do
      assert Headers.sanitize_header_text("  \r\n\t padded \r\n ") == "padded"
      assert Headers.sanitize_header_text("a\r\n\r\n\r\nb") == "a b"
    end

    test "passes clean text through unchanged" do
      assert Headers.sanitize_header_text("Acme Support") == "Acme Support"
    end
  end

  describe "quote_display_name/1" do
    test "plain atext-and-space names pass through unquoted" do
      assert Headers.quote_display_name("Acme Support") == "Acme Support"
      assert Headers.quote_display_name("O'Brien and Co.") == "O'Brien and Co."
    end

    test "names with RFC 5322 specials are quoted" do
      assert Headers.quote_display_name("Acme, Inc.") == ~s{"Acme, Inc."}
      assert Headers.quote_display_name("Acme (EU)") == ~s{"Acme (EU)"}
      assert Headers.quote_display_name("Acme <sales>") == ~s{"Acme <sales>"}
    end

    test "embedded quotes and backslashes are escaped inside the quoted string" do
      assert Headers.quote_display_name(~s(Acme "The Best", Inc.)) ==
               ~s("Acme \\"The Best\\", Inc.")

      assert Headers.quote_display_name(~s(Back\\slash, Co)) == ~s("Back\\\\slash, Co")
    end
  end
end
