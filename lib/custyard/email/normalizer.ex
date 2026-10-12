defmodule Custyard.Email.Normalizer do
  @moduledoc """
  Shared email normalization utilities.

  Extracted from duplicated implementations across `Email.Processor`,
  `Webhooks.Adapters.Lettermint`, and `Email.SieveHeaderMapper`.
  Provides case-insensitive header lookup, HTML stripping, and text truncation.
  """

  # Conversation.changeset validates subject max 500 chars
  @max_subject_length 500
  # Message.changeset validates body max 100,000 chars
  @max_body_length 100_000

  # Pre-compiled regexes for strip_html/1
  @html_tag_regex ~r/<[^>]+>/
  @whitespace_regex ~r/\s+/

  @doc "Maximum allowed subject length (500 characters)."
  def max_subject_length, do: @max_subject_length

  @doc "Maximum allowed body length (100,000 characters)."
  def max_body_length, do: @max_body_length

  @doc """
  Look up a header value by name, case-insensitive.

  Tries an exact key match first, then falls back to a case-insensitive scan.
  """
  @spec get_header(term(), String.t()) :: String.t() | nil
  def get_header(headers, name) when is_map(headers) do
    headers[name] || find_header_case_insensitive(headers, name)
  end

  def get_header(_headers, _name), do: nil

  @doc """
  Returns `text` when it is a non-blank string, otherwise `nil`.

  Provider payloads carry `""` for absent fields as often as they omit them,
  and `""` is truthy, so `params["text"] || fallback` never falls back.
  """
  @spec presence(term()) :: String.t() | nil
  def presence(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  def presence(_text), do: nil

  @doc """
  Strip HTML tags from a string, collapsing whitespace.

  Returns `nil` when given `nil`.
  """
  @spec strip_html(term()) :: String.t() | nil
  def strip_html(html) when not is_binary(html), do: nil

  def strip_html(html) do
    html
    |> String.replace(@html_tag_regex, " ")
    |> String.replace(@whitespace_regex, " ")
    |> String.trim()
  end

  @doc """
  Truncate text to `max_length`, appending \"...\" when truncated.

  Returns `""` when given `nil`.
  """
  @spec truncate(term(), non_neg_integer()) :: String.t()
  def truncate(text, _max_length) when not is_binary(text), do: ""
  def truncate(_text, max_length) when max_length == 0, do: ""
  def truncate(text, max_length) when max_length < 4, do: String.slice(text, 0, max_length)

  def truncate(text, max_length) when is_binary(text) do
    if String.length(text) <= max_length do
      text
    else
      String.slice(text, 0, max_length - 3) <> "..."
    end
  end

  # -- private ----------------------------------------------------------------

  defp find_header_case_insensitive(headers, name) do
    lowercase_name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == lowercase_name, do: v
    end)
  end
end
