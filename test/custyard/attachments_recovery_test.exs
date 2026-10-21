defmodule Custyard.Attachments.RecoveryTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Attachments, Conversations, MessageAttachment, Repo}
  alias Custyard.Attachments.{Recovery, StubClient}

  defmodule Provider do
    def get_webhook_delivery("webhook", delivery_id) do
      Process.get({:delivery, delivery_id}, {:error, :not_found})
    end
  end

  setup do
    org = insert_organization()
    channel = insert_inbound_channel(organization_id: org.id)

    insert_inbound_route_webhook(
      inbound_route_id: channel.inbound_route_id,
      lettermint_webhook_id: "webhook"
    )

    conversation =
      insert_conversation(organization_id: org.id, inbound_channel_id: channel.id, suspect: true)

    message =
      insert_message(
        conversation_id: conversation.id,
        provider_delivery_id: "delivery",
        lettermint_message_id: "provider-message"
      )

    url = StubClient.unique_url()
    descriptor = %{filename: "note.txt", content_type: "text/plain", size: 5, url: url}
    {:ok, [_]} = Attachments.fetch_for_message(message, [descriptor], skip: "suspect")
    StubClient.put(url, "hello")

    payload = %{
      "id" => "delivery",
      "event" => "message.inbound",
      "data" => %{
        "message_id" => "provider-message",
        "from" => %{"email" => "sender@example.com"},
        "attachments" => [
          %{"filename" => "note.txt", "content_type" => "text/plain", "size" => 5, "url" => url}
        ]
      }
    }

    Process.put({:delivery, "delivery"}, {:ok, %{"payload" => payload}})
    %{conversation: conversation, payload: payload}
  end

  test "trust permits recovery from retained delivery without saving URLs", %{conversation: conv} do
    assert {:error, :conversation_unavailable} = Recovery.recover(conv.id, client: Provider)
    assert {:ok, _} = Conversations.set_suspect(conv, false)
    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert [%{state: :fetched, filename: "note.txt"}] = Repo.all(MessageAttachment)
    refute inspect(Repo.all(MessageAttachment)) =~ "https://"
    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert length(Repo.all(MessageAttachment)) == 1
  end

  test "deleted messages are not recovered", %{conversation: conv} do
    Conversations.set_suspect(conv, false)
    [row] = Repo.all(MessageAttachment)

    Repo.get!(Custyard.Message, row.message_id)
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end

  test "missing retained payload stays visible and can be retried", %{conversation: conv} do
    Conversations.set_suspect(conv, false)
    Process.put({:delivery, "delivery"}, {:error, :expired})
    assert {:error, :recovery_incomplete} = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end

  test "a different delivery cannot replace attachment content", %{
    conversation: conv,
    payload: payload
  } do
    Conversations.set_suspect(conv, false)
    Process.put({:delivery, "delivery"}, {:ok, %{"payload" => Map.put(payload, "id", "other")}})
    assert {:error, :recovery_incomplete} = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end
end
