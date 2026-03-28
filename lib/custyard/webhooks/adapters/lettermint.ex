defmodule Custyard.Webhooks.Adapters.Lettermint do
  @moduledoc """
  Webhook adapter for Lettermint email service.

  Lettermint provides per-project inbound/outbound routes with HMAC-SHA256
  signature verification. Includes optional timestamp-based replay protection
  when the X-Lettermint-Timestamp header is present.
  """
  @behaviour Custyard.Webhooks.Adapter

  # Maximum allowed time skew for timestamp validation (5 minutes)
  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :lettermint

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(signature) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    expected = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    # Strip "sha256=" prefix if present
    signature = String.replace_prefix(signature, "sha256=", "")

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @doc """
  Verify request with replay protection.

  If a timestamp is provided, validates it's within the allowed skew window
  to prevent replay attacks. Falls back to signature-only verification if
  no timestamp is provided (for backward compatibility).
  """
  @impl true
  def verify_request(_raw_body, _timestamp, _signature, nil), do: {:error, "no secret configured"}

  def verify_request(raw_body, timestamp, signature, secret) do
    # First verify the signature
    case verify_signature(raw_body, signature, secret) do
      :ok ->
        # Then validate timestamp if provided
        validate_timestamp(timestamp)

      error ->
        error
    end
  end

  defp validate_timestamp(nil) do
    # No timestamp provided - accept for backward compatibility
    # Replay protection relies on message_id deduplication in this case
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

  alias Custyard.Email.Normalizer

  @impl true
  def normalize(params) do
    headers = params["headers"] || %{}
    body = params["text"] || Normalizer.strip_html(params["html"]) || ""

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject:
         Normalizer.truncate(params["subject"] || "(no subject)", Normalizer.max_subject_length()),
       body: Normalizer.truncate(body, Normalizer.max_body_length()),
       message_id: Normalizer.get_header(headers, "message-id"),
       in_reply_to: Normalizer.get_header(headers, "in-reply-to"),
       references: Normalizer.get_header(headers, "references"),
       headers: headers,
       source: :lettermint,
       metadata: %{}
     }}
  end
end
