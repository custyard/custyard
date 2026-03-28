defmodule Custyard.Webhooks.Adapters.Zendesk do
  @moduledoc """
  Webhook adapter for Zendesk ticket events.

  Zendesk sends webhook payloads when tickets are created or updated.
  Uses HMAC-SHA256 signature verification via the `X-Zendesk-Webhook-Signature` header.

  ## Replay Protection

  Zendesk webhooks do not include timestamps by default. Replay protection relies on:
  1. Message ID deduplication (tickets have unique IDs)
  2. Optional timestamp validation if `X-Zendesk-Webhook-Timestamp` header is provided

  If your Zendesk setup supports custom headers, configure it to send timestamps.
  """
  @behaviour Custyard.Webhooks.Adapter

  # Maximum allowed time skew for timestamp validation (5 minutes)
  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :zendesk

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(signature) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode64()

    if Plug.Crypto.secure_compare(expected, signature) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @doc """
  Verify request with optional replay protection.

  If a timestamp is provided (via custom header), validates it's within the
  allowed skew window. Falls back to signature-only verification if no
  timestamp is provided (standard Zendesk behavior).
  """
  @impl true
  def verify_request(_raw_body, _timestamp, _signature, nil), do: {:error, "no secret configured"}

  def verify_request(raw_body, timestamp, signature, secret) do
    case verify_signature(raw_body, signature, secret) do
      :ok -> validate_timestamp(timestamp)
      error -> error
    end
  end

  defp validate_timestamp(nil) do
    # No timestamp provided - accept but rely on message_id deduplication
    :ok
  end

  defp validate_timestamp(timestamp_str) when is_binary(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {timestamp, ""} ->
        now = System.system_time(:second)

        if abs(now - timestamp) <= @max_timestamp_skew do
          :ok
        else
          {:error, "stale timestamp - request may be a replay attack"}
        end

      _ ->
        {:error, "invalid timestamp format"}
    end
  end

  # Conversation.changeset validates subject max 500 chars
  @max_subject_length 500
  # Message.changeset validates body max 100,000 chars
  @max_body_length 100_000

  @impl true
  def normalize(params) do
    ticket = params["ticket"] || params
    from = extract_sender(ticket, params)
    subject = ticket["subject"] || ticket["title"] || "(no subject)"
    body = extract_body(ticket)

    {:ok,
     %{
       from: from,
       to: nil,
       subject: truncate(subject, @max_subject_length),
       body: truncate(body, @max_body_length),
       message_id: build_message_id(ticket),
       in_reply_to: nil,
       references: nil,
       headers: %{},
       source: :zendesk,
       metadata: build_metadata(ticket)
     }}
  end

  defp extract_sender(ticket, params) do
    requester = ticket["requester"] || %{}
    email = requester["email"] || params["current_user_email"] || ""
    name = requester["name"] || params["current_user_name"]
    if name, do: "#{name} <#{email}>", else: email
  end

  defp build_metadata(ticket) do
    %{
      external_id: to_string(ticket["id"]),
      external_status: ticket["status"],
      external_priority: ticket["priority"],
      tags: ticket["tags"] || []
    }
  end

  defp extract_body(ticket) do
    comment = ticket["comment"] || ticket["latest_comment"] || %{}
    comment["body"] || ticket["description"] || ""
  end

  defp build_message_id(ticket) do
    case ticket["id"] do
      nil -> nil
      id -> "zendesk-#{id}@zendesk.webhook"
    end
  end

  defp truncate(nil, _max_length), do: ""
  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length - 3) <> "..."
  end
end
