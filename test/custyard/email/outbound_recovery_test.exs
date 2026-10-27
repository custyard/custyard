defmodule Custyard.Email.OutboundRecoveryTest.Adapter do
  use Swoosh.Adapter

  def deliver(email, _config) do
    send(Application.fetch_env!(:custyard, :recovery_test_owner), {:attempted_email, email})
    Application.fetch_env!(:custyard, :recovery_test_result)
  end
end

defmodule Custyard.Email.OutboundRecoveryTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.{Conversations, Message, Repo}
  alias Custyard.Email.{Outbound, OutboundQueue}

  setup do
    previous = Application.get_env(:custyard, Custyard.Mailer)
    Application.put_env(:custyard, Custyard.Mailer, adapter: __MODULE__.Adapter)
    Application.put_env(:custyard, :recovery_test_owner, self())

    Application.put_env(
      :custyard,
      :recovery_test_result,
      {:error, {422, %{body: "private-message-body"}}}
    )

    on_exit(fn ->
      Application.put_env(:custyard, Custyard.Mailer, previous)
      Application.delete_env(:custyard, :recovery_test_owner)
      Application.delete_env(:custyard, :recovery_test_result)
    end)

    org = insert_organization()
    contact = insert_contact(organization_id: org.id)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)
    operator = insert_operator_account(role: "super_admin")

    insert_message(
      conversation_id: conversation.id,
      source: :email,
      sender_email: contact.email,
      message_id: "<original@customer.example>"
    )

    {:ok, message} = Conversations.send_reply(conversation, "Please try this fix.")
    %{message: message, operator: operator, contact: contact, conversation: conversation}
  end

  test "confirmed rejection retries with the same idempotency key and no raw error logging",
       context do
    log =
      capture_log(fn ->
        assert {:error, {422, _}, failed} = Outbound.deliver(context.message)
        assert failed.delivery_failure_kind == :rejected
        assert failed.delivery_error_code == "http_422"
        assert Outbound.retryable?(failed)
      end)

    refute log =~ "private-message-body"
    assert_receive {:attempted_email, original_email}
    failed = Repo.get!(Message, context.message.id)

    insert_message(
      conversation_id: context.conversation.id,
      source: :email,
      sender_email: context.contact.email,
      message_id: "<later@customer.example>"
    )

    assert {:ok, retried} = Outbound.retry(failed, context.operator)
    Application.put_env(:custyard, :recovery_test_result, {:ok, %{id: "provider-result"}})
    assert {:ok, sent} = Outbound.deliver(retried)
    assert sent.delivery_status == :sent
    assert_receive {:attempted_email, retry_email}

    assert retry_email.provider_options.idempotency_key ==
             original_email.provider_options.idempotency_key

    assert retry_email.to == original_email.to
    assert retry_email.headers == original_email.headers
  end

  test "timeouts and interrupted sends are acceptance-unknown and cannot retry blindly",
       context do
    Application.put_env(:custyard, :recovery_test_result, {:error, :timeout})
    assert {:error, :timeout, failed} = Outbound.deliver(context.message)
    assert failed.delivery_failure_kind == :unknown
    refute Outbound.retryable?(failed)
    assert {:error, :reconciliation_required} = Outbound.retry(failed, context.operator)

    old = DateTime.utc_now() |> DateTime.add(-1200) |> DateTime.truncate(:second)

    context.message
    |> Ecto.Changeset.change(delivery_status: :sending, updated_at: old)
    |> Repo.update!()

    assert OutboundQueue.fail_stale_sending() == 1
    recovered = Repo.get!(Message, context.message.id)
    assert recovered.delivery_failure_kind == :unknown
    assert recovered.delivery_error_code == "interrupted"
  end

  test "a changed payload cannot reuse a previously attempted idempotency key", context do
    assert {:error, _, failed} = Outbound.deliver(context.message)
    assert_receive {:attempted_email, _email}
    failed |> Ecto.Changeset.change(body: "A different reply") |> Repo.update!()
    assert {:ok, retried} = Outbound.retry(failed, context.operator)
    assert {:error, :envelope_changed, blocked} = Outbound.deliver(retried)
    refute Outbound.retryable?(blocked)
    refute_receive {:attempted_email, _email}
  end

  test "expired failures require reconciliation rather than a fresh provider send", context do
    assert {:error, _, failed} = Outbound.deliver(context.message)
    old = DateTime.utc_now() |> DateTime.add(-86_401) |> DateTime.truncate(:second)
    failed = failed |> Ecto.Changeset.change(delivery_attempted_at: old) |> Repo.update!()
    refute Outbound.retryable?(failed)
    assert {:error, :reconciliation_required} = Outbound.retry(failed, context.operator)
  end

  test "a later participant cannot redirect an already queued reply", context do
    insert_message(
      conversation_id: context.conversation.id,
      source: :email,
      sender_email: "bob@customer.example",
      triage_class: :customer
    )

    Application.put_env(:custyard, :recovery_test_result, {:ok, %{id: "accepted"}})
    assert {:ok, sent} = Outbound.deliver(context.message)
    assert sent.to_addresses == [context.contact.email]
    assert_receive {:attempted_email, email}
    assert email.to == [{"", context.contact.email}]
  end

  test "recipient erasure cannot be undone by queued delivery", context do
    assert {:ok, _} =
             Custyard.DataSubjects.erase_participation(
               context.contact.email,
               context.conversation.organization_id
             )

    assert {:error, :no_recipient_email, failed} = Outbound.deliver(context.message)
    assert failed.to_addresses == []
    refute_receive {:attempted_email, _email}
  end

  test "a stale composer must review a changed recipient before insertion", context do
    insert_message(
      conversation_id: context.conversation.id,
      source: :email,
      sender_email: "bob@customer.example",
      triage_class: :customer
    )

    count = Repo.aggregate(Message, :count)

    assert {:error, :recipient_changed} =
             Conversations.send_reply(context.conversation, "Reply to old preview",
               expected_recipient: context.contact.email
             )

    assert Repo.aggregate(Message, :count) == count
  end
end
