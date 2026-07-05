defmodule Custyard.Email.Processor do
  @moduledoc """
  Legacy module -- use Webhooks.Dispatcher for all new integrations.
  LMTP and IMAP paths now route through Dispatcher directly.

  Retained for backward compatibility with existing tests and the legacy
  Lettermint webhook endpoint. No new callers should be added.
  """

  alias Custyard.Email.Normalizer
  alias Custyard.Webhooks.Purposes.SenderMatching

  @doc """
  Process raw email payload from legacy webhook path.

  Parses the payload into normalized format and delegates to SenderMatching
  with an empty route context (no org/project scoping).

  Deprecated: Use `Webhooks.Adapters.Email.normalize/1` followed by
  `Webhooks.Dispatcher.dispatch/2` instead.
  """
  @deprecated "Use Webhooks.Dispatcher with Adapters.Email instead"
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
