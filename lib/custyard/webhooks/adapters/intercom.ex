defmodule Custyard.Webhooks.Adapters.Intercom do
  @moduledoc """
  Webhook adapter for Intercom conversation events.

  Intercom sends webhook notifications when conversations are created or
  replied to. Uses HMAC-SHA1 signature verification via the
  `X-Hub-Signature` header.

  ## Security Note: HMAC-SHA1

  This adapter uses HMAC-SHA1 for signature verification because Intercom's
  webhook signature scheme uses SHA-1. While SHA-1 has known collision
  vulnerabilities (SHAttered attack, 2017), HMAC-SHA1 remains secure for
  message authentication because:

  1. HMAC construction prevents length-extension attacks
  2. Collision attacks don't translate to HMAC forgery
  3. Finding a valid HMAC for an arbitrary message still requires the secret

  However, SHA-1 is considered deprecated for new implementations. If Intercom
  introduces a newer signature scheme (e.g., SHA-256), this adapter should be
  updated. Monitor Intercom's webhook documentation for updates:
  https://developers.intercom.com/docs/webhooks
  """
  @behaviour Custyard.Webhooks.Adapter

  @impl true
  def source_name, do: :intercom

  @impl true
  def verify_signature(_payload, _signature, nil), do: {:error, "no secret configured"}

  def verify_signature(payload, signature, secret) when is_binary(signature) do
    body = if is_binary(payload), do: payload, else: Jason.encode!(payload)

    hmac =
      :crypto.mac(:hmac, :sha, secret, body)
      |> Base.encode16(case: :lower)

    expected = "sha1=" <> hmac

    if Plug.Crypto.secure_compare(expected, String.downcase(signature)) do
      :ok
    else
      {:error, "invalid signature"}
    end
  end

  def verify_signature(_payload, nil, _secret), do: {:error, "missing signature header"}

  @impl true
  def normalize(params) do
    {item, latest_part} = extract_item_and_part(params)
    source = item["source"] || %{}
    author = resolve_author(source, latest_part)

    {:ok,
     %{
       from: format_sender(author),
       to: nil,
       subject: source["subject"] || item["title"] || "(no subject)",
       body: extract_body(source, latest_part),
       message_id: build_message_id(item, latest_part),
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

  defp extract_item_and_part(params) do
    data = params["data"] || %{}
    item = data["item"] || %{}
    conversation_parts = item["conversation_parts"] || %{}
    parts = conversation_parts["conversation_parts"] || []
    {item, List.last(parts)}
  end

  defp resolve_author(source, latest_part) do
    source["author"] || latest_part_author(latest_part) || %{}
  end

  defp format_sender(author) do
    email = author["email"] || ""
    name = author["name"]
    if name, do: "#{name} <#{email}>", else: email
  end

  defp latest_part_author(nil), do: nil
  defp latest_part_author(part), do: part["author"] || %{}

  defp extract_body(source, nil), do: source["body"] || ""

  defp extract_body(source, latest_part) do
    latest_part["body"] || source["body"] || ""
  end

  # Build a unique message ID. If there's a latest conversation part, use its
  # ID to distinguish it from the parent conversation.
  defp build_message_id(item, nil) do
    case item["id"] do
      nil -> nil
      id -> "intercom-#{id}@intercom.webhook"
    end
  end

  defp build_message_id(item, latest_part) do
    part_id = latest_part["id"]
    conv_id = item["id"]

    cond do
      part_id -> "intercom-#{conv_id}-part-#{part_id}@intercom.webhook"
      conv_id -> "intercom-#{conv_id}@intercom.webhook"
      true -> nil
    end
  end

  # Reference the parent conversation ID for threading.
  # Format must match build_message_id for ThreadMatcher to find the parent.
  defp build_in_reply_to(item) do
    case item["id"] do
      nil -> nil
      id -> "intercom-#{id}@intercom.webhook"
    end
  end
end
