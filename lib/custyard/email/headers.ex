defmodule Custyard.Email.Headers do
  @moduledoc """
  Shared header-discipline helpers for anything email-bound.

  Extracted from `Custyard.Email.Outbound`'s privates so operator-reply
  mail and prospect-facing mail (slug-claim confirmations) can never
  diverge on header injection handling. `Outbound` delegates here;
  behavior is byte-identical.
  """

  @doc """
  Strip CR/LF and other control characters from header-bound text.

  Header values must never contain control characters (CWE-93 header
  injection); inbound subjects can carry them through the webhook JSON
  path, and Swoosh does not sanitize header values.
  """
  def sanitize_header_text(text) do
    text
    |> String.replace(~r/[\x00-\x1F\x7F]+/, " ")
    |> String.trim()
  end

  @doc """
  Quote an RFC 5322 display name when it contains specials.

  Display names containing specials (comma, parens, quotes, ...) must be
  quoted-string wrapped, or `Acme, Inc. <a@b>` parses as two addresses.
  Plain atext-and-space names pass through unquoted.
  """
  def quote_display_name(name) do
    if name =~ ~r/^[a-zA-Z0-9!#$%&'*+\/=?^_`{|}~. -]*$/ do
      name
    else
      escaped = String.replace(name, ~r/["\\]/, fn char -> "\\" <> char end)
      "\"#{escaped}\""
    end
  end
end
