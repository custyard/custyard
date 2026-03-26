defmodule Custyard.Webhooks.Adapters.Slack do
  @moduledoc """
  Webhook adapter for Slack events.

  Handles Slack Events API payloads (message events, app mentions) and
  verifies requests using Slack's signing secret with HMAC-SHA256.

  Slack signs requests as `v0:{timestamp}:{raw_body}` and includes:
  - `X-Slack-Signature` header with `v0={hexdigest}`
  - `X-Slack-Request-Timestamp` header for replay protection
  """
  @behaviour Custyard.Webhooks.Adapter

  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :slack

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret)
      when is_binary(signature) and is_binary(secret) do
    # Simplified verification without timestamp — used only for basic
    # signature checks. The controller uses verify_request/4 instead,
    # which includes proper timestamp validation and replay protection.
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    hmac =
      :crypto.mac(:hmac, :sha256, secret, body)
      |> Base.encode16(case: :lower)

    expected = "v0=" <> hmac

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @doc """
  Verify a Slack request using the full signing protocol with timestamp.

  This is the preferred verification method that validates both the
  signature and the timestamp for replay protection.
  """
  def verify_request(raw_body, timestamp_str, signature, secret) do
    with {:ok, timestamp} <- parse_timestamp(timestamp_str),
         :ok <- validate_timestamp(timestamp) do
      base_string = "v0:" <> timestamp_str <> ":" <> raw_body

      hmac =
        :crypto.mac(:hmac, :sha256, secret, base_string)
        |> Base.encode16(case: :lower)

      expected = "v0=" <> hmac

      if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
        :ok
      else
        {:error, "invalid signature"}
      end
    end
  end

  defp parse_timestamp(ts) when is_binary(ts) do
    case Integer.parse(ts) do
      {int, ""} -> {:ok, int}
      _ -> {:error, "invalid timestamp"}
    end
  end

  defp parse_timestamp(_), do: {:error, "missing timestamp"}

  defp validate_timestamp(timestamp) when is_integer(timestamp) do
    now = System.system_time(:second)

    if abs(now - timestamp) <= @max_timestamp_skew do
      :ok
    else
      {:error, "stale timestamp"}
    end
  end

  @impl true
  def normalize(%{"type" => "url_verification", "challenge" => challenge}) do
    # Slack URL verification handshake — return a bypass result so the
    # controller can respond directly with the challenge without dispatching.
    {:bypass, %{type: "url_verification", challenge: challenge, source: :slack}}
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

  defp build_in_reply_to(channel, thread_ts),
    do: "slack-#{channel}-#{thread_ts}@slack.webhook"
end
