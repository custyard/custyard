defmodule CustyardWeb.EmailStatusControllerTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  alias Custyard.Auth.Token
  alias Custyard.{Credentials, EmailConnection, Message, Repo}

  @secret "whsec_status_test_secret"
  @provider_id "lm-msg-ctrl-001"
  @recipient "alice@customer.com"

  setup do
    org = insert_organization()
    contact = insert_contact(organization_id: org.id, email: @recipient)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)

    outbound =
      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        delivery_status: :sent,
        lettermint_message_id: @provider_id
      )

    {:ok, ciphertext} =
      Credentials.encrypt(@secret, "email_connection:#{org.tenant_id}:status_secret")

    connection =
      %EmailConnection{}
      |> EmailConnection.changeset(%{tenant_id: org.tenant_id})
      |> Ecto.Changeset.change(
        status_secret_ciphertext: ciphertext,
        status_callback_token: Token.generate() |> elem(0)
      )
      |> Repo.insert!()

    %{outbound: outbound, connection: connection}
  end

  test "signed tenant status advances the message", c do
    assert json_response(send_event(c, envelope("message.delivered")), 200) == %{"status" => "ok"}
    assert Repo.get!(Message, c.outbound.id).delivery_status == :delivered
  end

  test "unknown status events are ignored", c do
    assert json_response(send_event(c, envelope("message.opened")), 200) == %{
             "status" => "ignored",
             "reason" => "unknown_event"
           }
  end

  test "unknown message is ignored", c do
    event = put_in(envelope("message.delivered"), ["data", "message_id"], "unknown")

    assert json_response(send_event(c, event), 200) == %{
             "status" => "ignored",
             "reason" => "unknown_message"
           }
  end

  test "invalid payload is contained", c do
    event = Map.delete(envelope("message.delivered"), "event")
    assert json_response(send_event(c, event), 422)["reason"] == "invalid payload"
  end

  test "bad signature fails closed", c do
    assert json_response(send_event(c, envelope("message.delivered"), "wrong"), 401)["reason"] ==
             "unauthorized"

    assert Repo.get!(Message, c.outbound.id).delivery_status == :sent
  end

  test "missing signature fails closed", c do
    assert json_response(send_event(c, envelope("message.delivered"), nil), 401)["reason"] ==
             "unauthorized"
  end

  test "callback credentials cannot authorize a different tenant's message", c do
    other = insert_tenant()
    {:ok, encrypted} = Credentials.encrypt(@secret, "email_connection:#{other.id}:status_secret")

    connection =
      %EmailConnection{}
      |> EmailConnection.changeset(%{tenant_id: other.id})
      |> Ecto.Changeset.change(
        status_secret_ciphertext: encrypted,
        status_callback_token: Token.generate() |> elem(0)
      )
      |> Repo.insert!()

    assert json_response(
             send_event(%{c | connection: connection}, envelope("message.delivered")),
             200
           )["reason"] == "unknown_message"

    assert Repo.get!(Message, c.outbound.id).delivery_status == :sent
  end

  test "delivery callbacks continue during suspension", c do
    Custyard.Tenants.get_tenant!(c.connection.tenant_id)
    |> Ecto.Changeset.change(status: "suspended")
    |> Repo.update!()

    assert json_response(send_event(c, envelope("message.delivered")), 200)["status"] == "ok"
  end

  test "responses do not expose recipient or subject", c do
    response = send_event(c, envelope("message.delivered"))
    refute response.resp_body =~ @recipient
    refute response.resp_body =~ "Private subject"
  end

  test "removed global status endpoint is unavailable", c do
    assert post(c.conn, "/api/webhook/email-status/lettermint", envelope("message.delivered")).status ==
             404
  end

  defp send_event(c, event, secret \\ @secret) do
    raw = Jason.encode!(event)
    conn = c.conn |> put_req_header("content-type", "application/json")

    conn =
      if secret, do: put_req_header(conn, "x-lettermint-signature", sign(raw, secret)), else: conn

    post(conn, "/api/webhook/email-status/lettermint/#{c.connection.status_callback_token}", raw)
  end

  defp sign(raw, secret) do
    timestamp = to_string(System.system_time(:second))

    digest =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw) |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{digest}"
  end

  defp envelope(event),
    do: %{
      "id" => "evt-#{System.unique_integer([:positive])}",
      "event" => event,
      "timestamp" => "2026-10-20T12:00:00Z",
      "sandbox" => false,
      "data" => %{
        "message_id" => @provider_id,
        "recipient" => @recipient,
        "subject" => "Private subject"
      }
    }
end
