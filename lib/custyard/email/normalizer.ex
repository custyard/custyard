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

  @doc "Maximum allowed subject length (500 characters)."
  def max_subject_length, do: @max_subject_length

  @doc "Maximum allowed body length (100,000 characters)."
  def max_body_length, do: @max_body_length

  @doc """
  Look up a header value by name, case-insensitive.

  Tries an exact key match first, then falls back to a case-insensitive scan.
  """
  @spec get_header(map(), String.t()) :: String.t() | nil
  def get_header(headers, name) do
    headers[name] || find_header_case_insensitive(headers, name)
  end

  @doc """
  Strip HTML tags from a string, collapsing whitespace.

  Returns `nil` when given `nil`.
  """
  @spec strip_html(String.t() | nil) :: String.t() | nil
  def strip_html(nil), do: nil

  def strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc """
  Truncate text to `max_length`, appending \"...\" when truncated.

  Returns `""` when given `nil`.
  """
  @spec truncate(String.t() | nil, non_neg_integer()) :: String.t()
  def truncate(nil, _max_length), do: ""
  def truncate(text, max_length) when byte_size(text) <= max_length, do: text

  def truncate(text, max_length) do
    String.slice(text, 0, max_length - 3) <> "..."
  end

  # -- private ----------------------------------------------------------------

  defp find_header_case_insensitive(headers, name) do
    lowercase_name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == lowercase_name, do: v
    end)
  end
end
