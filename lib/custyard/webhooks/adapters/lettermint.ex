defmodule Custyard.Webhooks.Adapters.Lettermint do
  @moduledoc """
  Webhook adapter for Lettermint email service.

  Lettermint signs `timestamp.raw_body` with HMAC-SHA256 and sends the timestamp
  and hex digest together in `X-Lettermint-Signature: t=...,v1=...`.
  """
  @behaviour Custyard.Webhooks.Adapter

  # Maximum allowed time skew for timestamp validation (5 minutes)
  @max_timestamp_skew 60 * 5

  @impl true
  def source_name, do: :lettermint

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(payload),
    do: verify_request(payload, nil, signature, secret)

  def verify_signature(_payload, _signature, _secret),
    do: {:error, "missing signature header"}

  @doc """
  Verify the signed timestamp and exact raw body with replay protection.
  """
  @impl true
  def verify_request(_raw_body, _timestamp, _signature, nil), do: {:error, "no secret configured"}

  def verify_request(raw_body, _timestamp, signature, secret) when is_binary(raw_body) do
    with {:ok, timestamp, provided} <- parse_signature(signature),
         :ok <- validate_timestamp(timestamp) do
      expected =
        :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw_body)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(expected, String.downcase(provided)),
        do: :ok,
        else: {:error, "invalid signature"}
    end
  end

  defp parse_signature(nil), do: {:error, "missing signature header"}

  defp parse_signature(signature) when is_binary(signature) do
    parts =
      signature
      |> String.split(",")
      |> Enum.map(&String.split(&1, "=", parts: 2))

    with [timestamp] <- for(["t", value] <- parts, do: value),
         [digest] <- for(["v1", value] <- parts, do: value),
         true <- byte_size(digest) == 64 and String.match?(digest, ~r/\A[0-9a-fA-F]{64}\z/) do
      {:ok, timestamp, digest}
    else
      _ -> {:error, "invalid signature format"}
    end
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
