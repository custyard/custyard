defmodule Custyard.Webhooks.Adapters.Intercom do
  @moduledoc """
  Webhook adapter for Intercom conversation events.

  Intercom sends webhook notifications when conversations are created or
  replied to. Uses HMAC-SHA1 signature verification via the
  `X-Hub-Signature` header.
  """
  @behaviour Custyard.Webhooks.Adapter

  @impl true
  def source_name, do: :intercom

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(signature) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)
    expected = "sha1=" <> (:crypto.mac(:hmac, :sha, secret, body) |> Base.encode16(case: :lower))

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @impl true
  def normalize(params) do
    data = params["data"] || %{}
    item = data["item"] || %{}

    # Intercom wraps conversation data differently for different event types
    conversation_parts = item["conversation_parts"] || %{}
    parts = conversation_parts["conversation_parts"] || []
    latest_part = List.last(parts)

    source = item["source"] || %{}
    author = source["author"] || latest_part_author(latest_part) || %{}

    from_email = author["email"] || ""
    from_name = author["name"]
    from = if from_name, do: "#{from_name} <#{from_email}>", else: from_email

    subject = source["subject"] || item["title"] || "(no subject)"
    body = extract_body(source, latest_part)

    {:ok,
     %{
       from: from,
       to: nil,
       subject: subject,
       body: body,
       message_id: build_message_id(item),
       in_reply_to: build_in_reply_to(item),
       references: nil,
       headers: %{},
       source: :intercom,
       metadata: %{
         external_id: item["id"],
         topic: params["topic"],
         author_type: author["type"]
       }
     }}
  end

  defp latest_part_author(nil), do: nil
  defp latest_part_author(part), do: part["author"] || %{}

  defp extract_body(source, nil), do: source["body"] || ""

  defp extract_body(source, latest_part) do
    latest_part["body"] || source["body"] || ""
  end

  defp build_message_id(item) do
    case item["id"] do
      nil -> nil
      id -> "intercom-#{id}@intercom.webhook"
    end
  end

  defp build_in_reply_to(item) do
    # If this is a reply, reference the parent conversation
    case item["id"] do
      nil -> nil
      id -> "intercom-#{id}@intercom.webhook"
    end
  end
end
