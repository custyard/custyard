defmodule Custyard.Email.Processor do
  @moduledoc """
  Process inbound emails from legacy Lettermint webhook and direct LMTP/IMAP paths.

  Handles email parsing then delegates to SenderMatching for the actual processing.
  This module exists to maintain backward compatibility with the legacy webhook
  endpoint and direct email paths (LMTP, IMAP).

  For new integrations, use Webhooks.Dispatcher which routes through adapters
  and provides richer context (project assignment, multi-source support).
  """

  alias Custyard.Email.Normalizer
  alias Custyard.Webhooks.Purposes.SenderMatching

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
    body = params["text"] || Normalizer.strip_html(params["html"]) || ""

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: Normalizer.truncate(subject, Normalizer.max_subject_length()),
       body: Normalizer.truncate(body, Normalizer.max_body_length()),
       message_id: Normalizer.get_header(headers, "message-id"),
       in_reply_to: Normalizer.get_header(headers, "in-reply-to"),
       references: Normalizer.get_header(headers, "references"),
       # Preserve all headers for Sieve metadata extraction
       headers: headers,
       # Explicit email source for direct paths
       source: :email
     }}
  end
end
