defmodule Custyard.Webhooks.Adapters.Zendesk do
  @moduledoc """
  Webhook adapter for Zendesk ticket events.

  Zendesk sends webhook payloads when tickets are created or updated.
  Uses HMAC-SHA256 signature verification via the `X-Zendesk-Webhook-Signature` header.

  Zendesk signs `timestamp <> raw_body` and sends the timestamp in
  `X-Zendesk-Webhook-Signature-Timestamp`.
  """
  @behaviour Custyard.Webhooks.Adapter

  # Maximum allowed time skew for timestamp validation (5 minutes)
  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :zendesk

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(_payload, _signature, _secret),
    do: {:error, "Zendesk requires verify_request/4 with a timestamp"}

  @doc """
  Verify Zendesk's timestamp-prefixed body signature and reject stale requests.
  """
  @impl true
  def verify_request(_raw_body, _timestamp, _signature, nil), do: {:error, "no secret configured"}

  def verify_request(raw_body, timestamp, signature, secret) do
    with :ok <- validate_timestamp(timestamp),
         true <- is_binary(signature) do
      expected = :crypto.mac(:hmac, :sha256, secret, timestamp <> raw_body) |> Base.encode64()

      if Plug.Crypto.secure_compare(expected, signature),
        do: :ok,
        else: {:error, "invalid signature"}
    else
      false -> {:error, "missing signature header"}
      error -> error
    end
  end

  defp validate_timestamp(nil), do: {:error, "missing timestamp"}

  defp validate_timestamp(timestamp_str) when is_binary(timestamp_str) do
    case DateTime.from_iso8601(timestamp_str) do
      {:ok, timestamp, _offset} ->
        validate_timestamp_seconds(DateTime.to_unix(timestamp))

      _ ->
        case Integer.parse(timestamp_str) do
          {timestamp, ""} -> validate_timestamp_seconds(timestamp)
          _ -> {:error, "invalid timestamp format"}
        end
    end
  end

  defp validate_timestamp_seconds(timestamp) do
    if abs(System.system_time(:second) - timestamp) <= @max_timestamp_skew,
      do: :ok,
      else: {:error, "stale timestamp - request may be a replay attack"}
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
    comment = ticket["comment"] || ticket["latest_comment"] || params["comment"]
    body = extract_body(ticket, comment)

    with {:ok, message_id} <- build_message_id(ticket, params, comment) do
      {:ok,
       %{
         from: from,
         to: nil,
         subject: truncate(subject, @max_subject_length),
         body: truncate(body, @max_body_length),
         message_id: message_id,
         in_reply_to: ticket_thread_id(ticket),
         references: nil,
         headers: %{},
         source: :zendesk,
         metadata: build_metadata(ticket)
       }}
    end
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

  defp extract_body(ticket, comment) when is_map(comment),
    do: comment["body"] || ticket["description"] || ""

  defp extract_body(_ticket, comment) when is_binary(comment), do: comment
  defp extract_body(ticket, _comment), do: ticket["description"] || ""

  defp ticket_thread_id(%{"id" => id}) when not is_nil(id),
    do: "zendesk-ticket-#{id}@zendesk.webhook"

  defp ticket_thread_id(_), do: nil

  defp build_message_id(%{"id" => ticket_id}, params, comment) when not is_nil(ticket_id) do
    comment_id = (is_map(comment) && comment["id"]) || params["comment_id"] || params["event_id"]

    case comment_id do
      nil ->
        if is_nil(comment) do
          # Ticket-only event, with no comment to discard on a later update.
          {:ok, "zendesk-#{ticket_id}@zendesk.webhook"}
        else
          {:error, "Zendesk comment ID is required for idempotent delivery"}
        end

      comment_id ->
        {:ok, "zendesk-ticket-#{ticket_id}-comment-#{comment_id}@zendesk.webhook"}
    end
  end

  defp build_message_id(_, _, _), do: {:ok, nil}

  defp truncate(nil, _max_length), do: ""
  defp truncate(text, max_length) when byte_size(text) <= max_length, do: text

  defp truncate(text, max_length) do
    String.slice(text, 0, max_length - 3) <> "..."
  end
end
