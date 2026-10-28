defmodule Custyard.Attachments.RecoveryTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Attachments, Threads, MessageAttachment, Repo}
  alias Custyard.Attachments.{Recovery, StubClient}

  defmodule Provider do
    def get_webhook_delivery(webhook_id, delivery_id) do
      send(self(), {:requested_delivery, webhook_id, delivery_id})
      Process.get({:delivery, webhook_id, delivery_id}, {:error, :not_found})
    end
  end

  setup do
    org = insert_organization()
    channel = insert_inbound_channel(organization_id: org.id)

    insert_inbound_route_webhook(
      inbound_route_id: channel.inbound_route_id,
      lettermint_webhook_id: "webhook"
    )

    thread =
      insert_thread(organization_id: org.id, inbound_channel_id: channel.id, suspect: true)

    message =
      insert_message(
        thread_id: thread.id,
        inbound_channel_id: channel.id,
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

    Process.put({:delivery, "webhook", "delivery"}, {:ok, %{"payload" => payload}})
    %{thread: thread, channel: channel, message: message, payload: payload}
  end

  test "trust permits recovery from retained delivery without saving URLs", %{thread: conv} do
    assert {:error, :thread_unavailable} = Recovery.recover(conv.id, client: Provider)
    assert {:ok, _} = Threads.set_suspect(conv, false)
    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert [%{state: :fetched, filename: "note.txt"}] = Repo.all(MessageAttachment)
    refute inspect(Repo.all(MessageAttachment)) =~ "https://"
    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert length(Repo.all(MessageAttachment)) == 1
  end

  test "threaded messages recover through their own route and attachment cap", %{
    thread: conv,
    channel: original_channel,
    message: message,
    payload: payload
  } do
    reply_channel =
      insert_inbound_channel(organization_id: conv.organization_id, attachment_limit_mb: 0)

    insert_inbound_route_webhook(
      inbound_route_id: reply_channel.inbound_route_id,
      lettermint_webhook_id: "reply-webhook"
    )

    message
    |> Ecto.Changeset.change(inbound_channel_id: reply_channel.id)
    |> Repo.update!()

    Process.put({:delivery, "reply-webhook", "delivery"}, {:ok, %{"payload" => payload}})
    assert original_channel.inbound_route_id != reply_channel.inbound_route_id
    Threads.set_suspect(conv, false)

    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert_received {:requested_delivery, "reply-webhook", "delivery"}
    refute_received {:requested_delivery, "webhook", "delivery"}
    assert [%{state: :skipped, skip_reason: "disabled"}] = Repo.all(MessageAttachment)
  end

  test "a message channel from another tenant cannot supply recovery credentials", %{
    thread: conv,
    message: message
  } do
    tenant =
      %Custyard.Tenant{}
      |> Custyard.Tenant.changeset(%{
        name: "Other",
        slug: "recovery-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    foreign_channel = insert_inbound_channel(tenant_id: tenant.id)

    assert_raise Ecto.ConstraintError, fn ->
      message |> Ecto.Changeset.change(inbound_channel_id: foreign_channel.id) |> Repo.update!()
    end

    assert Repo.get!(Custyard.Message, message.id).inbound_channel_id != foreign_channel.id
    assert Repo.get!(Custyard.Thread, conv.id).tenant_id != tenant.id
  end

  test "shared tenant inbox recovers using the real route webhook binding", %{
    thread: conv,
    channel: channel,
    payload: payload
  } do
    route = Repo.get!(Custyard.InboundRoute, channel.inbound_route_id)

    Repo.update!(
      Ecto.Changeset.change(route,
        lettermint_webhook_id: "bound-provider-webhook"
      )
    )

    Process.put({:delivery, "bound-provider-webhook", "delivery"}, {:ok, %{"payload" => payload}})
    Threads.set_suspect(conv, false)
    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert_received {:requested_delivery, "bound-provider-webhook", "delivery"}
    refute_received {:requested_delivery, "webhook", "delivery"}
    assert [%{state: :fetched}] = Repo.all(MessageAttachment)
  end

  test "missing message channel does not fall back to the thread route", %{
    thread: conv,
    message: message
  } do
    message |> Ecto.Changeset.change(inbound_channel_id: nil) |> Repo.update!()
    Threads.set_suspect(conv, false)
    assert {:error, :recovery_incomplete} = Recovery.recover(conv.id, client: Provider)
    refute_received {:requested_delivery, _, _}
  end

  test "deleted messages are not recovered", %{thread: conv} do
    Threads.set_suspect(conv, false)
    [row] = Repo.all(MessageAttachment)

    Repo.get!(Custyard.Message, row.message_id)
    |> Ecto.Changeset.change(deleted_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()

    assert :ok = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end

  test "missing retained payload stays visible and can be retried", %{thread: conv} do
    Threads.set_suspect(conv, false)
    Process.put({:delivery, "webhook", "delivery"}, {:error, :expired})
    assert {:error, :recovery_incomplete} = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end

  test "a different delivery cannot replace attachment content", %{
    thread: conv,
    payload: payload
  } do
    Threads.set_suspect(conv, false)

    Process.put(
      {:delivery, "webhook", "delivery"},
      {:ok, %{"payload" => Map.put(payload, "id", "other")}}
    )

    assert {:error, :recovery_incomplete} = Recovery.recover(conv.id, client: Provider)
    assert [%{skip_reason: "suspect"}] = Repo.all(MessageAttachment)
  end
end
