defmodule Custyard.Email.Processor do
  @moduledoc """
  Process inbound emails from legacy Lettermint webhook and direct LMTP/IMAP paths.

  Handles email parsing then delegates to SenderMatching for the actual processing.
  This module exists to maintain backward compatibility with the legacy webhook
  endpoint and direct email paths (LMTP, IMAP).

  For new integrations, use Webhooks.Dispatcher which routes through adapters
  and provides richer context (project assignment, multi-source support).
  """

  alias Custyard.Webhooks.Purposes.SenderMatching

  # Conversation.changeset validates subject max 500 chars
  @max_subject_length 500
  # Message.changeset validates body max 100,000 chars
  @max_body_length 100_000

  @doc """
  Process raw email payload from LMTP, IMAP, or legacy webhook.

  Parses the payload into normalized format and delegates to SenderMatching.
  """
  def process(params) do
    with {:ok, normalized} <- parse_payload(params) do
      # Delegate to SenderMatching with empty route context (no project routing)
      SenderMatching.process(normalized, %{})
    end
  end

  defp parse_payload(params) do
    # Lettermint sends: from, to, subject, text, html, headers, attachments
    headers = params["headers"] || %{}
    subject = params["subject"] || "(no subject)"
    body = params["text"] || strip_html(params["html"]) || ""

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: truncate(subject, @max_subject_length),
       body: truncate(body, @max_body_length),
       message_id: get_header(headers, "message-id"),
       in_reply_to: get_header(headers, "in-reply-to"),
       references: get_header(headers, "references"),
       # Preserve all headers for Sieve metadata extraction
       headers: headers,
       # Explicit email source for direct paths
       source: :email
     }}
  end

  # Get header value, case-insensitive for header name
  defp get_header(headers, name) do
    # Try exact match first, fall back to case-insensitive lookup
    headers[name] || find_header_case_insensitive(headers, name)
  end

  defp find_header_case_insensitive(headers, name) do
    lowercase_name = String.downcase(name)

    Enum.find_value(headers, fn {k, v} ->
      if String.downcase(to_string(k)) == lowercase_name, do: v
    end)
  end

  defp strip_html(nil), do: nil

  defp strip_html(html) do
    html
    |> String.replace(~r/<[^>]+>/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp truncate(nil, _max_length), do: ""
  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length - 3) <> "..."
  end
end
