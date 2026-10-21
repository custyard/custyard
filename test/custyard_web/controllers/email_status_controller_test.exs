defmodule CustyardWeb.EmailStatusControllerTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.{Message, Repo}

  @provider_id "lm-msg-ctrl-001"
  @recipient "alice@customer.com"

  setup do
    original_env = Application.get_env(:custyard, :env)
    original_secrets = Application.get_env(:custyard, :webhook_secrets)

    # Skip signature verification unless a test configures a secret.
    Application.put_env(:custyard, :env, :test)
    Application.delete_env(:custyard, :webhook_secrets)

    on_exit(fn ->
      restore_env(:env, original_env)
      restore_env(:webhook_secrets, original_secrets)
    end)

    org = insert_organization()
    contact = insert_contact(organization_id: org.id, email: @recipient)
    conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)

    outbound =
      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        sender_email: "support@acme.com",
        message_id: "<reply-ctrl@custyard.local>",
        body: "We can help with that.",
        delivery_status: :sent,
        lettermint_message_id: @provider_id
      )

    {:ok, outbound: outbound}
  end

  describe "POST /api/webhook/email-status/lettermint without a secret (dev/test)" do
    test "returns 200 ok on a valid delivered event and advances the message", %{
      conn: conn,
      outbound: outbound
    } do
      response =
        conn
        |> post(~p"/api/webhook/email-status/lettermint", delivered_envelope())
        |> json_response(200)

      assert response == %{"status" => "ok"}
      assert Repo.get!(Message, outbound.id).delivery_status == :delivered
    end

    test "returns 200 ignored for a non-status event", %{conn: conn} do
      response =
        conn
        |> post(
          ~p"/api/webhook/email-status/lettermint",
          envelope("message.opened", %{"message_id" => @provider_id, "recipient" => @recipient})
        )
        |> json_response(200)

      assert response == %{"status" => "ignored", "reason" => "unknown_event"}
    end

    test "returns 200 ignored for an unknown message id", %{conn: conn} do
      response =
        conn
        |> post(
          ~p"/api/webhook/email-status/lettermint",
          envelope("message.delivered", %{"message_id" => "lm-unknown", "recipient" => @recipient})
        )
        |> json_response(200)

      assert response == %{"status" => "ignored", "reason" => "unknown_message"}
    end

    test "returns 422 invalid payload when event is missing", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/webhook/email-status/lettermint", %{"id" => "evt-1", "data" => %{}})
        |> json_response(422)

      assert response == %{"status" => "error", "reason" => "invalid payload"}
    end

    test "returns 422 invalid payload for a non-object JSON body", %{conn: conn} do
      response =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/email-status/lettermint", Jason.encode!(["message.delivered"]))
        |> json_response(422)

      assert response == %{"status" => "error", "reason" => "invalid payload"}
    end

    test "never echoes the recipient address", %{conn: conn} do
      envelopes = [
        delivered_envelope(),
        envelope("message.opened", %{"message_id" => @provider_id, "recipient" => @recipient}),
        envelope("message.delivered", %{"message_id" => "lm-x", "recipient" => @recipient}),
        %{"id" => "evt-1", "data" => %{"recipient" => @recipient}}
      ]

      for envelope <- envelopes do
        body =
          conn
          |> post(~p"/api/webhook/email-status/lettermint", envelope)
          |> Map.fetch!(:resp_body)

        refute body =~ @recipient
        refute body =~ "Help with billing"
      end
    end
  end

  describe "POST /api/webhook/email-status/lettermint with a configured secret" do
    @secret "whsec_status_test_secret"

    setup do
      Application.put_env(:custyard, :webhook_secrets, %{lettermint_status: @secret})
      :ok
    end

    test "a correctly signed request succeeds", %{conn: conn, outbound: outbound} do
      params = delivered_envelope()
      raw_body = Jason.encode!(params)

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", sign(raw_body, @secret))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/email-status/lettermint", params)
        |> json_response(200)

      assert response == %{"status" => "ok"}
      assert Repo.get!(Message, outbound.id).delivery_status == :delivered
    end

    test "a bad signature returns 401 and does not change the message", %{
      conn: conn,
      outbound: outbound
    } do
      params = delivered_envelope()
      raw_body = Jason.encode!(params)

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", sign(raw_body, "wrong-secret"))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/email-status/lettermint", params)
        |> json_response(401)

      assert response == %{"status" => "error", "reason" => "unauthorized"}
      assert Repo.get!(Message, outbound.id).delivery_status == :sent
    end

    test "a missing signature returns 401", %{conn: conn} do
      params = delivered_envelope()

      response =
        conn
        |> put_private(:raw_body, Jason.encode!(params))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/email-status/lettermint", params)
        |> json_response(401)

      assert response == %{"status" => "error", "reason" => "unauthorized"}
    end

    test "the inbound route secret does not authorize the status webhook", %{conn: conn} do
      Application.put_env(:custyard, :webhook_secrets, %{lettermint: @secret})
      Application.put_env(:custyard, :env, :prod)

      params = delivered_envelope()
      raw_body = Jason.encode!(params)

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", sign(raw_body, @secret))
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/email-status/lettermint", params)
        |> json_response(401)

      assert response == %{"status" => "error", "reason" => "unauthorized"}
    end
  end

  defp sign(raw_body, secret) do
    timestamp = to_string(System.system_time(:second))

    digest =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw_body)
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{digest}"
  end

  defp delivered_envelope do
    envelope("message.delivered", %{
      "message_id" => @provider_id,
      "subject" => "Help with billing",
      "recipient" => @recipient,
      "response" => %{
        "status_code" => 250,
        "enhanced_status_code" => "2.0.0",
        "content" => "250 2.0.0 OK"
      }
    })
  end

  defp envelope(event, data) do
    %{
      "id" => "evt-#{System.unique_integer([:positive])}",
      "event" => event,
      "timestamp" => "2026-10-20T12:00:00Z",
      "sandbox" => false,
      "sandbox_result" => nil,
      "context" => %{"scope" => "route", "team_id" => "t", "project_id" => "p", "route_id" => "r"},
      "data" => data
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:custyard, key)
  defp restore_env(key, value), do: Application.put_env(:custyard, key, value)
end
