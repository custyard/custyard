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

  alias Custyard.{Threads, InboundChannels, Message, Repo}
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
    configure_tenant_email(org.tenant_id)
    contact = insert_contact(organization_id: org.id)
    thread = insert_thread(organization_id: org.id, contact_id: contact.id)
    staff = insert_staff_account(role: "admin")

    insert_message(
      thread_id: thread.id,
      source: :email,
      sender_email: contact.email,
      message_id: "<original@customer.example>"
    )

    {:ok, message} = Threads.send_reply(thread, "Please try this fix.")
    %{message: message, staff: staff, contact: contact, thread: thread}
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

    # An absent Reply-To uses the canonical envelope representation.
    canonical_hash =
      {original_email.from, original_email.to, original_email.cc, original_email.bcc,
       original_email.subject, original_email.text_body, original_email.html_body,
       original_email.headers}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert is_nil(original_email.reply_to)
    assert failed.delivery_payload_hash == canonical_hash

    insert_message(
      thread_id: context.thread.id,
      source: :email,
      sender_email: context.contact.email,
      message_id: "<later@customer.example>"
    )

    assert {:ok, retried} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )

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

    assert {:error, :reconciliation_required} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )

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

    assert {:ok, retried} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )

    assert {:error, :envelope_changed, blocked} = Outbound.deliver(retried)
    refute Outbound.retryable?(blocked)
    refute_receive {:attempted_email, _email}
  end

  test "expired failures require reconciliation rather than a fresh provider send", context do
    assert {:error, _, failed} = Outbound.deliver(context.message)
    old = DateTime.utc_now() |> DateTime.add(-86_401) |> DateTime.truncate(:second)
    failed = failed |> Ecto.Changeset.change(delivery_attempted_at: old) |> Repo.update!()
    refute Outbound.retryable?(failed)

    assert {:error, :reconciliation_required} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )
  end

  test "a retry cannot drop Reply-To after clearing the domain or selecting ingress", context do
    for attrs <- [%{sending_domain: ""}, %{reply_from: :ingress_address}] do
      {channel, message} = custom_domain_reply(context)
      assert {:error, {422, _}, failed} = Outbound.deliver(message)
      assert_receive {:attempted_email, original_email}
      assert original_email.reply_to == {"", channel.public_address}

      assert {:ok, _} = InboundChannels.update_channel(channel, attrs, staff: context.staff)
      Application.put_env(:custyard, :recovery_test_result, {:ok, %{id: "retry-must-not-send"}})

      assert {:ok, retried} =
               Outbound.retry(
                 Custyard.Scope.for_staff(
                   context.staff,
                   Custyard.Tenants.get_tenant!(context.staff.tenant_id)
                 ),
                 failed
               )

      assert retried.sender_email == message.sender_email
      assert {:error, :envelope_changed, blocked} = Outbound.deliver(retried)
      refute Outbound.retryable?(blocked)
      refute_receive {:attempted_email, _}

      Application.put_env(:custyard, :recovery_test_result, {:error, {422, %{body: "rejected"}}})
    end
  end

  test "an unattempted configuration retry cannot drop the saved return path", context do
    {channel, message} = custom_domain_reply(context)

    connection = Custyard.EmailSetup.connection(message.tenant_id)
    connection |> Ecto.Changeset.change(project_token_ciphertext: nil) |> Repo.update!()

    assert {:error, :not_configured, failed} = Outbound.deliver(message)
    assert is_nil(failed.delivery_attempted_at)
    refute_receive {:attempted_email, _}

    assert {:ok, _} =
             InboundChannels.update_channel(channel, %{sending_domain: ""}, staff: context.staff)

    Application.put_env(:custyard, Custyard.Mailer, adapter: __MODULE__.Adapter)
    Application.put_env(:custyard, :recovery_test_result, {:ok, %{id: "retry-must-not-send"}})

    assert {:ok, retried} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )

    assert {:error, :envelope_changed, blocked} = Outbound.deliver(retried)
    assert is_nil(blocked.delivery_attempted_at)
    refute_receive {:attempted_email, _}
  end

  defp custom_domain_reply(context) do
    channel =
      insert_inbound_channel(
        organization_id: context.thread.organization_id,
        tenant_id: context.thread.tenant_id,
        public_address: "support@acme.example",
        sending_domain: "mail.acme.example",
        state: :active
      )

    thread =
      insert_thread(
        organization_id: context.thread.organization_id,
        contact_id: context.contact.id,
        inbound_channel_id: channel.id
      )

    {:ok, message} = Threads.send_reply(thread, "A reply using the custom sender")
    assert message.sender_email == "support@mail.acme.example"
    {channel, message}
  end

  test "configuration failures before provider invocation remain retryable after a day",
       context do
    connection = Custyard.EmailSetup.connection(context.message.tenant_id)
    encrypted = connection.project_token_ciphertext
    Repo.update!(Ecto.Changeset.change(connection, project_token_ciphertext: nil))

    assert {:error, :not_configured, failed} = Outbound.deliver(context.message)
    assert failed.delivery_failure_kind == :configuration
    assert is_nil(failed.delivery_attempted_at)
    assert is_binary(failed.delivery_payload_hash)
    refute_receive {:attempted_email, _email}

    old = DateTime.utc_now() |> DateTime.add(-172_800) |> DateTime.truncate(:second)
    failed = failed |> Ecto.Changeset.change(inserted_at: old, updated_at: old) |> Repo.update!()
    assert Outbound.retryable?(failed)

    Repo.update!(
      Ecto.Changeset.change(Repo.reload!(connection), project_token_ciphertext: encrypted)
    )

    Application.put_env(:custyard, :recovery_test_result, {:ok, %{id: "configured-later"}})

    assert {:ok, retried} =
             Outbound.retry(
               Custyard.Scope.for_staff(
                 context.staff,
                 Custyard.Tenants.get_tenant!(context.staff.tenant_id)
               ),
               failed
             )

    assert {:ok, sent} = Outbound.deliver(retried)
    assert sent.delivery_status == :sent
    assert %DateTime{} = sent.delivery_attempted_at
    assert_receive {:attempted_email, email}
    assert email.headers["X-LM-Preserve-Message-ID"] == "true"
  end

  test "missing tenant credentials still lock the return path before a retry" do
    tenant =
      %Custyard.Tenant{}
      |> Custyard.Tenant.changeset(%{
        name: "Unconfigured tenant",
        slug: "unconfigured-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    staff = insert_staff_account(tenant_id: tenant.id, role: "admin")
    org = insert_organization(tenant_id: tenant.id)
    contact = insert_contact(organization_id: org.id)
    thread = insert_thread(organization_id: org.id, contact_id: contact.id)
    {channel, message} = custom_domain_reply(%{thread: thread, contact: contact})

    assert {:error, :not_configured, failed} = Outbound.deliver(message)
    assert is_binary(failed.delivery_payload_hash)
    assert is_nil(failed.delivery_attempted_at)
    refute_receive {:attempted_email, _}

    assert {:ok, _} =
             InboundChannels.update_channel(channel, %{sending_domain: ""}, staff: staff)

    assert {:ok, retried} = Outbound.retry(Custyard.Scope.for_staff(staff, tenant), failed)
    assert {:error, :envelope_changed, _} = Outbound.deliver(retried)
    refute_receive {:attempted_email, _}
  end

  test "a missing tenant From fails before recording a provider attempt", context do
    Repo.update_all(
      from(c in Custyard.InboundChannel, where: c.tenant_id == ^context.message.tenant_id),
      set: [state: :paused]
    )

    message =
      context.message
      |> Ecto.Changeset.change(sender_email: nil, inbound_channel_id: nil)
      |> Repo.update!()

    assert {:error, :from_not_set, failed} = Outbound.deliver(message)
    assert is_nil(failed.delivery_attempted_at)
    assert Outbound.retryable?(failed)
    refute_receive {:attempted_email, _email}
  end

  test "a later participant cannot redirect an already queued reply", context do
    insert_message(
      thread_id: context.thread.id,
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
               staff_scope(context.message.tenant_id),
               context.contact.email,
               context.thread.organization_id
             )

    assert {:error, :no_recipient_email, failed} = Outbound.deliver(context.message)
    assert failed.to_addresses == []
    assert is_nil(failed.delivery_attempted_at)
    refute_receive {:attempted_email, _email}
  end

  test "a stale composer must review a changed recipient before insertion", context do
    insert_message(
      thread_id: context.thread.id,
      source: :email,
      sender_email: "bob@customer.example",
      triage_class: :customer
    )

    count = Repo.aggregate(Message, :count)

    assert {:error, :recipient_changed} =
             Threads.send_reply(context.thread, "Reply to old preview",
               expected_recipient: context.contact.email
             )

    assert Repo.aggregate(Message, :count) == count
  end
end
