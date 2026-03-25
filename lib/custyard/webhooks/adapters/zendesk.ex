defmodule Custyard.Webhooks.Adapters.Zendesk do
  @moduledoc """
  Webhook adapter for Zendesk ticket events.

  Zendesk sends webhook payloads when tickets are created or updated.
  Uses HMAC-SHA256 signature verification via the `X-Zendesk-Webhook-Signature` header.
  """
  @behaviour Custyard.Webhooks.Adapter

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

  @impl true
  def normalize(params) do
    ticket = params["ticket"] || params

    requester = ticket["requester"] || %{}
    from_email = requester["email"] || params["current_user_email"] || ""
    from_name = requester["name"] || params["current_user_name"]
    from = if from_name, do: "#{from_name} <#{from_email}>", else: from_email

    subject = ticket["subject"] || ticket["title"] || "(no subject)"
    body = extract_body(ticket)

    {:ok,
     %{
       from: from,
       to: nil,
       subject: subject,
       body: body,
       message_id: build_message_id(ticket),
       in_reply_to: nil,
       references: nil,
       headers: %{},
       source: :zendesk,
       metadata: %{
         external_id: to_string(ticket["id"]),
         external_status: ticket["status"],
         external_priority: ticket["priority"],
         tags: ticket["tags"] || []
       }
     }}
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
end
