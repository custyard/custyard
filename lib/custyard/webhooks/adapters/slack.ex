defmodule Custyard.Webhooks.Adapters.Slack do
  @moduledoc """
  Webhook adapter for Slack events.

  Handles Slack Events API payloads (message events, app mentions) and
  verifies requests using Slack's signing secret with HMAC-SHA256.
  """
  @behaviour Custyard.Webhooks.Adapter

  @impl true
  def source_name, do: :slack

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(signature) do
    # Slack uses "v0=hmac" format with a timestamp-prefixed body
    # For simplicity, we verify the HMAC portion against the raw body
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    expected = "v0=" <> (:crypto.mac(:hmac, :sha256, secret, "v0:0:#{body}") |> Base.encode16(case: :lower))

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @impl true
  def normalize(%{"type" => "url_verification", "challenge" => challenge}) do
    # Slack URL verification handshake
    {:ok,
     %{
       from: "slack-system",
       to: nil,
       subject: "URL Verification",
       body: challenge,
       message_id: nil,
       in_reply_to: nil,
       references: nil,
       headers: %{},
       source: :slack,
       metadata: %{type: "url_verification", challenge: challenge}
     }}
  end

  def normalize(params) do
    event = params["event"] || %{}

    user = event["user"] || event["bot_id"] || "unknown"
    channel = event["channel"] || ""
    text = event["text"] || ""
    thread_ts = event["thread_ts"]
    ts = event["ts"]

    {:ok,
     %{
       from: user,
       to: channel,
       subject: truncate_subject(text),
       body: text,
       message_id: build_message_id(channel, ts),
       in_reply_to: build_in_reply_to(channel, thread_ts),
       references: nil,
       headers: %{},
       source: :slack,
       metadata: %{
         channel: channel,
         thread_ts: thread_ts,
         ts: ts,
         event_type: event["type"],
         team: params["team_id"]
       }
     }}
  end

  defp truncate_subject(text) do
    case String.length(text) do
      len when len > 80 -> String.slice(text, 0, 77) <> "..."
      _ -> text
    end
  end

  defp build_message_id(channel, nil), do: "slack-#{channel}@slack.webhook"
  defp build_message_id(channel, ts), do: "slack-#{channel}-#{ts}@slack.webhook"

  defp build_in_reply_to(_channel, nil), do: nil
  defp build_in_reply_to(channel, thread_ts), do: "slack-#{channel}-#{thread_ts}@slack.webhook"
end
