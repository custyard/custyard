defmodule Custyard.Webhooks.Adapters.Email do
  @moduledoc """
  Webhook adapter for direct email paths (LMTP, IMAP).

  Normalizes Parser.parse() output into the unified adapter format so that
  LMTP and IMAP messages can flow through Webhooks.Dispatcher just like
  HTTP webhook payloads. This gives email-originated messages the same
  route context (org, project, purpose dispatch) as webhook-originated ones.

  Signature verification is a no-op because these payloads never arrive
  over HTTP — they come from trusted internal paths (the LMTP server or
  IMAP poller).
  """
  @behaviour Custyard.Webhooks.Adapter

  alias Custyard.Email.Normalizer

  @impl true
  def source_name, do: :email

  @impl true
  def verify_signature(_payload, _signature, _secret), do: :ok

  @doc """
  Normalize Parser.parse() output into the unified adapter payload format.

  Parser emits separate `text` and `html` keys; this collapses them into a
  single `body` field (preferring text, falling back to stripped HTML) and
  adds the `source` and `metadata` fields the Dispatcher expects.

  The input map uses both atom and string keys (see Parser moduledoc).
  We read atom keys since they're always present.
  """
  @impl true
  def normalize(parsed) when is_map(parsed) do
    headers = field(parsed, :headers) || %{}
    subject = field(parsed, :subject) || "(no subject)"

    # Collapse text/html into single body — same logic as Processor.parse_payload
    body = field(parsed, :text) || Normalizer.strip_html(field(parsed, :html)) || ""

    {:ok,
     %{
       from: field(parsed, :from),
       to: field(parsed, :to),
       subject: Normalizer.truncate(subject, Normalizer.max_subject_length()),
       body: Normalizer.truncate(body, Normalizer.max_body_length()),
       message_id: parsed[:message_id] || Normalizer.get_header(headers, "message-id"),
       in_reply_to: parsed[:in_reply_to] || Normalizer.get_header(headers, "in-reply-to"),
       references: parsed[:references] || Normalizer.get_header(headers, "references"),
       headers: headers,
       source: :email,
       metadata: %{}
     }}
  end

  # Parser output mixes atom and string keys (see Parser moduledoc)
  defp field(parsed, key), do: parsed[key] || parsed[Atom.to_string(key)]
end
