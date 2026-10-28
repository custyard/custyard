defmodule Custyard.Attachments.Recovery do
  @moduledoc """
  Recover withheld attachments from the provider's retained delivery after trust
  is granted. Only provider identifiers are stored locally; the delivery payload
  and signed URLs remain in memory. Retention expiry or missing content permission
  leaves the rows visible for an operator retry, never silently successful.
  """
  import Ecto.Query

  alias Custyard.{
    Attachments,
    Conversation,
    InboundChannel,
    InboundRouteWebhook,
    Message,
    MessageAttachment,
    InboundRoute,
    Repo
  }

  alias Custyard.Lettermint.Client
  alias Custyard.Webhooks.Adapters.Lettermint

  def recover(conversation_id, opts \\ []) do
    case Repo.get(Conversation, conversation_id) do
      %Conversation{suspect: false} = conversation ->
        messages =
          Repo.all(
            from m in Message,
              join: a in MessageAttachment,
              on: a.message_id == m.id,
              where:
                m.conversation_id == ^conversation.id and is_nil(m.deleted_at) and
                  (a.skip_reason == "suspect" or a.state in [:failed, :pending]),
              distinct: true
          )

        results = Enum.map(messages, &recover_message(&1, conversation, opts))
        if Enum.all?(results, &(&1 == :ok)), do: :ok, else: {:error, :recovery_incomplete}

      _ ->
        {:error, :conversation_unavailable}
    end
  rescue
    _error -> {:error, :recovery_incomplete}
  end

  defp recover_message(message, conversation, opts) do
    client = Keyword.get_lazy(opts, :client, &Client.client/0)

    with %InboundChannel{} = channel <- Repo.get(InboundChannel, message.inbound_channel_id),
         true <- channel.tenant_id == conversation.tenant_id,
         true <- is_binary(message.provider_delivery_id),
         true <-
           Code.ensure_loaded?(client) and function_exported?(client, :get_webhook_delivery, 2) do
      webhooks =
        Repo.all(
          from w in InboundRouteWebhook,
            where:
              w.inbound_route_id == ^channel.inbound_route_id and
                not is_nil(w.lettermint_webhook_id)
        )

      route = Repo.get(InboundRoute, channel.inbound_route_id)

      webhooks =
        if route && route.lettermint_webhook_id,
          do: [%{lettermint_webhook_id: route.lettermint_webhook_id} | webhooks],
          else: webhooks

      Enum.reduce_while(webhooks, {:error, :delivery_unavailable}, fn webhook, _acc ->
        case recover_delivery(client, webhook, message, channel) do
          :ok -> {:halt, :ok}
          error -> {:cont, error}
        end
      end)
    else
      _ -> {:error, :delivery_unavailable}
    end
  end

  defp recover_delivery(client, webhook, message, channel) do
    with {:ok, %{"payload" => payload}} <-
           get_delivery(
             client,
             channel,
             webhook.lettermint_webhook_id,
             message.provider_delivery_id
           ),
         %{"event" => "message.inbound", "id" => id} <- payload,
         true <- id == message.provider_delivery_id,
         {:ok, normalized} <- Lettermint.normalize(payload),
         true <- normalized.metadata.lettermint_message_id == message.lettermint_message_id,
         descriptors when descriptors != [] <- normalized.metadata.attachments,
         # Trust may have been revoked while the provider request was running.
         %Conversation{suspect: false} <- Repo.get(Conversation, message.conversation_id),
         %Message{deleted_at: nil} <- Repo.get(Message, message.id),
         {:ok, rows} <-
           Attachments.fetch_for_message(message, descriptors,
             limit_bytes: Attachments.limit_bytes(channel)
           ),
         true <-
           Enum.all?(rows, &(&1.state not in [:failed, :pending] and &1.skip_reason != "suspect")) do
      :ok
    else
      _ -> {:error, :delivery_unavailable}
    end
  end

  defp get_delivery(Custyard.Lettermint.HttpClient, channel, webhook_id, delivery_id),
    do: Client.call(:get_webhook_delivery, [webhook_id, delivery_id], channel.tenant_id)

  defp get_delivery(Custyard.Lettermint.DisabledClient, channel, webhook_id, delivery_id),
    do: Client.call(:get_webhook_delivery, [webhook_id, delivery_id], channel.tenant_id)

  defp get_delivery(client, _channel, webhook_id, delivery_id),
    do: client.get_webhook_delivery(webhook_id, delivery_id)
end
