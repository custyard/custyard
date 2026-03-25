defmodule Custyard.Webhooks.Adapters.Lettermint do
  @moduledoc """
  Webhook adapter for Lettermint email service.

  Lettermint provides per-project inbound/outbound routes with HMAC-SHA256
  signature verification. This is the primary adapter for email ingestion.
  """
  @behaviour Custyard.Webhooks.Adapter

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

  @impl true
  def normalize(params) do
    headers = params["headers"] || %{}

    {:ok,
     %{
       from: params["from"] || params["sender"],
       to: params["to"] || params["recipient"],
       subject: params["subject"] || "(no subject)",
       body: params["text"] || strip_html(params["html"]) || "",
       message_id: get_header(headers, "message-id"),
       in_reply_to: get_header(headers, "in-reply-to"),
       references: get_header(headers, "references"),
       headers: headers,
       source: :lettermint,
       metadata: %{}
     }}
  end

  defp get_header(headers, name) do
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
end
