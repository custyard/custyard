defmodule CustyardWeb.TenantEmailStatusControllerTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  alias Custyard.{EmailSetup, Repo, Tenant}

  setup do
    original_env = Application.get_env(:custyard, :env)
    Application.put_env(:custyard, :env, :test)

    on_exit(fn ->
      if original_env,
        do: Application.put_env(:custyard, :env, original_env),
        else: Application.delete_env(:custyard, :env)
    end)

    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          name: "Status tenant",
          slug: "status-#{System.unique_integer([:positive])}"
        })
      )

    {:ok, connection} =
      EmailSetup.ensure_connection(
        insert_staff_account(role: "admin", tenant_id: tenant.id),
        tenant.id
      )

    {:ok, ciphertext} =
      Custyard.Credentials.encrypt(
        "tenant-status-secret",
        "email_connection:#{tenant.id}:status_secret"
      )

    connection =
      Repo.update!(Ecto.Changeset.change(connection, status_secret_ciphertext: ciphertext))

    org = insert_organization(tenant_id: tenant.id)
    conversation = insert_conversation(tenant_id: tenant.id, organization_id: org.id)

    message =
      insert_message(
        conversation_id: conversation.id,
        source: :staff,
        delivery_status: :sent,
        lettermint_message_id: "tenant-provider-id"
      )

    %{connection: connection, tenant: tenant, message: message}
  end

  test "only a valid signature on the tenant binding records delivery", c do
    payload = payload(c.message.lettermint_message_id)
    path = "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}"

    assert c.conn |> post(path, payload) |> json_response(401) == %{
             "status" => "error",
             "reason" => "unauthorized"
           }

    assert is_nil(EmailSetup.connection(c.tenant.id).last_reply_delivered_at)
    assert signed_post(path, payload, "wrong-secret") |> json_response(401)

    assert signed_post(path, payload, "tenant-status-secret") |> json_response(200) == %{
             "status" => "ok"
           }

    assert Repo.reload!(c.message).delivery_status == :delivered
    assert %DateTime{} = EmailSetup.connection(c.tenant.id).last_reply_delivered_at
  end

  test "signed foreign message IDs and the global legacy endpoint cannot change another tenant",
       c do
    foreign =
      insert_message(
        source: :staff,
        delivery_status: :sent,
        lettermint_message_id: "foreign-provider-id"
      )

    path = "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}"

    assert signed_post(path, payload(foreign.lettermint_message_id), "tenant-status-secret")
           |> json_response(200) == %{"status" => "ignored", "reason" => "unknown_message"}

    assert Repo.reload!(foreign).delivery_status == :sent

    assert c.conn
           |> post(
             "/api/webhook/email-status/lettermint",
             payload(c.message.lettermint_message_id)
           )
           |> response(404)

    assert Repo.reload!(c.message).delivery_status == :sent
  end

  test "a signed sandbox status cannot advance a real message or checklist", c do
    path = "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}"
    sample = payload(c.message.lettermint_message_id) |> Map.put("sandbox", true)

    assert signed_post(path, sample, "tenant-status-secret") |> json_response(200) == %{
             "status" => "ignored",
             "reason" => "sandbox"
           }

    assert Repo.reload!(c.message).delivery_status == :sent
    assert is_nil(EmailSetup.connection(c.tenant.id).last_reply_delivered_at)
  end

  test "a tenant's inbound provider ID cannot authorize a foreign outbound transition", c do
    foreign =
      insert_message(
        source: :staff,
        delivery_status: :sent,
        lettermint_message_id: "foreign-duplicate-provider-id"
      )

    insert_message(
      conversation_id: c.message.conversation_id,
      source: :email,
      delivery_status: nil,
      lettermint_message_id: foreign.lettermint_message_id
    )

    path = "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}"

    assert signed_post(path, payload(foreign.lettermint_message_id), "tenant-status-secret")
           |> json_response(200) == %{"status" => "ignored", "reason" => "unknown_message"}

    assert Repo.reload!(foreign).delivery_status == :sent
    assert is_nil(EmailSetup.connection(c.tenant.id).last_reply_delivered_at)
  end

  test "archive-copy delivery cannot prove that the customer received a reply", c do
    message =
      Repo.update!(
        Ecto.Changeset.change(c.message,
          delivery_status: :bounced,
          to_addresses: ["customer@example.com"],
          cc_addresses: ["support-archive@example.com"]
        )
      )

    event =
      payload(message.lettermint_message_id)
      |> put_in(["data", "recipient"], "support-archive@example.com")

    path = "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}"

    assert signed_post(path, event, "tenant-status-secret") |> json_response(200) == %{
             "status" => "ok"
           }

    assert Repo.reload!(message).delivery_status == :bounced
    assert %DateTime{} = EmailSetup.connection(c.tenant.id).last_status_event_at
    assert is_nil(EmailSetup.connection(c.tenant.id).last_reply_delivered_at)
  end

  defp signed_post(path, payload, secret) do
    raw = Jason.encode!(payload)
    timestamp = to_string(System.system_time(:second))

    signature =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw) |> Base.encode16(case: :lower)

    build_conn()
    |> put_private(:raw_body, raw)
    |> put_req_header("x-lettermint-signature", "t=#{timestamp},v1=#{signature}")
    |> put_req_header("content-type", "application/json")
    |> post(path, payload)
  end

  defp payload(id),
    do: %{
      "id" => "event-#{System.unique_integer([:positive])}",
      "event" => "message.delivered",
      "timestamp" => "2026-10-27T12:00:00Z",
      "sandbox" => false,
      "data" => %{"message_id" => id}
    }
end
