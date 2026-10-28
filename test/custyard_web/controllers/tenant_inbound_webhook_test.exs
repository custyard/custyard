defmodule CustyardWeb.TenantInboundWebhookTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  alias Custyard.{EmailSetup, InboundRoute, Repo, Tenant}

  setup do
    old_env = Application.get_env(:custyard, :env)
    old_secrets = Application.get_env(:custyard, :webhook_secrets)
    Application.put_env(:custyard, :env, :test)
    Application.put_env(:custyard, :webhook_secrets, %{lettermint: "legacy-global-secret"})

    on_exit(fn ->
      for {key, value} <- [env: old_env, webhook_secrets: old_secrets] do
        if value,
          do: Application.put_env(:custyard, key, value),
          else: Application.delete_env(:custyard, key)
      end
    end)

    tenant =
      Repo.insert!(
        Tenant.changeset(%Tenant{}, %{
          name: "Inbound tenant",
          slug: "inbound-#{System.unique_integer([:positive])}"
        })
      )

    admin = insert_staff_account(role: "admin", tenant_id: tenant.id)
    {:ok, _} = EmailSetup.ensure_connection(admin, tenant.id)

    route =
      Repo.insert!(
        InboundRoute.changeset(%InboundRoute{}, %{
          tenant_id: tenant.id,
          source: :lettermint,
          lettermint_route_id: "real-route",
          lettermint_route_domain: "inbound.lettermint.app"
        })
      )

    {:ok, secret} =
      Custyard.Credentials.encrypt(
        "route-secret",
        "inbound_route:#{tenant.id}:#{route.id}:webhook_secret"
      )

    route =
      Repo.update!(
        Ecto.Changeset.change(route,
          webhook_secret_ciphertext: secret,
          lettermint_webhook_id: "real-webhook"
        )
      )

    {:ok, channel} =
      Custyard.InboundChannels.create_channel(route, %{public_address: "support@service.example"})

    %{route: route, tenant: tenant, channel: channel, admin: admin}
  end

  test "a stored route binding never bypasses signatures and records genuine receiving separately",
       c do
    path = "/api/webhook/route/#{c.route.callback_token}"

    params = inbound_payload(c, "initial")

    assert c.conn |> post(path, params) |> json_response(401)
    assert signed_post(path, params, "legacy-global-secret") |> json_response(401)
    refute EmailSetup.summary(c.tenant.id).receiving?
    response = signed_post(path, params, "route-secret") |> json_response(200)
    thread = Repo.get!(Custyard.Thread, response["thread_id"])
    assert thread.tenant_id == c.tenant.id
    assert EmailSetup.summary(c.tenant.id).receiving?
    refute EmailSetup.summary(c.tenant.id).sending?
    refute EmailSetup.summary(c.tenant.id).complete?
    assert EmailSetup.connection(c.tenant.id).latest_received_thread_id == thread.id
  end

  test "completion requires a new customer reply referencing a preceding sent staff message",
       c do
    path = "/api/webhook/route/#{c.route.callback_token}"

    response =
      signed_post(path, inbound_payload(c, "initial"), "route-secret") |> json_response(200)

    thread_id = response["thread_id"]

    outgoing =
      insert_message(
        thread_id: thread_id,
        source: :staff,
        message_id: "<staff-reply@service.example>",
        delivery_status: :sent,
        lettermint_message_id: "outbound-provider"
      )

    EmailSetup.record_reply_accepted(outgoing)

    outgoing = Repo.update!(Ecto.Changeset.change(outgoing, delivery_status: :delivered))

    EmailSetup.record_status_event(
      EmailSetup.connection(c.tenant.id),
      %{"event" => "message.delivered", "sandbox" => false},
      outgoing
    )

    refute EmailSetup.summary(c.tenant.id).complete?

    returned =
      inbound_payload(c, "returning", %{
        "in-reply-to" => outgoing.message_id,
        "references" => "<initial@acme.example> #{outgoing.message_id}"
      })

    response = signed_post(path, returned, "route-secret") |> json_response(200)
    assert response["thread_id"] == thread_id
    assert EmailSetup.summary(c.tenant.id).returning?
    assert EmailSetup.summary(c.tenant.id).complete?

    EmailSetup.invalidate_receiving(c.tenant.id)
    refute EmailSetup.summary(c.tenant.id).receiving?
    refute EmailSetup.summary(c.tenant.id).returning?
    signed_post(path, returned, "route-secret") |> json_response(200)
    refute EmailSetup.summary(c.tenant.id).receiving?
    refute EmailSetup.summary(c.tenant.id).complete?
  end

  test "sandbox samples, suspect mail and automatic responses never prove setup", c do
    path = "/api/webhook/route/#{c.route.callback_token}"
    sandbox = inbound_payload(c, "sandbox") |> Map.put("sandbox", true)
    signed_post(path, sandbox, "route-secret") |> json_response(200)
    refute EmailSetup.summary(c.tenant.id).receiving?
    suspect = inbound_payload(c, "suspect") |> put_in(["data", "is_spam"], true)
    signed_post(path, suspect, "route-secret") |> json_response(200)
    refute EmailSetup.summary(c.tenant.id).receiving?
    auto = inbound_payload(c, "auto", %{"auto-submitted" => "auto-replied"})
    signed_post(path, auto, "route-secret") |> json_response(200)
    refute EmailSetup.summary(c.tenant.id).receiving?
    assert is_nil(EmailSetup.connection(c.tenant.id).latest_received_thread_id)
  end

  test "a changed sender requires a new send and ignores delayed evidence for the old identity",
       c do
    path = "/api/webhook/route/#{c.route.callback_token}"

    response =
      signed_post(path, inbound_payload(c, "initial"), "route-secret") |> json_response(200)

    thread_id = response["thread_id"]

    old_reply =
      insert_message(
        thread_id: thread_id,
        source: :staff,
        message_id: "<old-identity@service.example>",
        delivery_status: :delivered,
        lettermint_message_id: "old-provider-reply"
      )

    EmailSetup.record_reply_accepted(old_reply)
    old_connection = EmailSetup.connection(c.tenant.id)
    delivered_event = %{"event" => "message.delivered", "sandbox" => false}
    EmailSetup.record_status_event(old_connection, delivered_event, old_reply)

    signed_post(
      path,
      inbound_payload(c, "old-return", %{"in-reply-to" => old_reply.message_id}),
      "route-secret"
    )
    |> json_response(200)

    assert EmailSetup.summary(c.tenant.id).complete?

    assert {:ok, _} =
             c.channel
             |> Repo.reload!()
             |> Custyard.InboundChannels.update_channel(%{reply_from: :ingress_address},
               staff: c.admin
             )

    refute EmailSetup.summary(c.tenant.id).sending?
    refute EmailSetup.summary(c.tenant.id).delivered?
    refute EmailSetup.summary(c.tenant.id).returning?

    EmailSetup.record_reply_accepted(old_reply)
    EmailSetup.record_status_event(old_connection, delivered_event, old_reply)

    signed_post(
      path,
      inbound_payload(c, "late-old-return", %{"in-reply-to" => old_reply.message_id}),
      "route-secret"
    )
    |> json_response(200)

    assert EmailSetup.summary(c.tenant.id).receiving?
    refute EmailSetup.summary(c.tenant.id).sending?
    refute EmailSetup.summary(c.tenant.id).delivered?
    refute EmailSetup.summary(c.tenant.id).returning?

    new_reply =
      insert_message(
        thread_id: thread_id,
        source: :staff,
        message_id: "<new-identity@service.example>",
        delivery_status: :delivered,
        lettermint_message_id: "new-provider-reply"
      )

    EmailSetup.record_reply_accepted(new_reply)
    EmailSetup.record_status_event(EmailSetup.connection(c.tenant.id), delivered_event, new_reply)

    signed_post(
      path,
      inbound_payload(c, "new-return", %{"in-reply-to" => new_reply.message_id}),
      "route-secret"
    )
    |> json_response(200)

    assert EmailSetup.summary(c.tenant.id).complete?
  end

  test "an unthreaded fresh message cannot prove the returning reply", c do
    path = "/api/webhook/route/#{c.route.callback_token}"
    signed_post(path, inbound_payload(c, "new"), "route-secret") |> json_response(200)
    assert EmailSetup.summary(c.tenant.id).receiving?
    refute EmailSetup.summary(c.tenant.id).returning?
  end

  test "referencing an unsent staff draft does not prove a successful roundtrip", c do
    path = "/api/webhook/route/#{c.route.callback_token}"

    response =
      signed_post(path, inbound_payload(c, "initial"), "route-secret") |> json_response(200)

    outgoing =
      insert_message(
        thread_id: response["thread_id"],
        source: :staff,
        message_id: "<draft@service.example>",
        delivery_status: :pending
      )

    returned = inbound_payload(c, "returning", %{"in-reply-to" => outgoing.message_id})
    signed_post(path, returned, "route-secret") |> json_response(200)
    refute EmailSetup.summary(c.tenant.id).returning?
  end

  test "credential rotation clears receiving evidence and its thread link", c do
    path = "/api/webhook/route/#{c.route.callback_token}"
    signed_post(path, inbound_payload(c, "initial"), "route-secret") |> json_response(200)
    assert EmailSetup.summary(c.tenant.id).receiving?

    assert {:ok, connection} =
             EmailSetup.save_credentials(c.admin, c.tenant.id, %{
               "team_token" => "replacement-team-token"
             })

    assert is_nil(connection.latest_received_thread_id)
    refute EmailSetup.summary(c.tenant.id).receiving?
    assert is_nil(Repo.reload!(c.route).webhook_verified_at)
  end

  test "a corrupted stored secret fails closed even in test mode", c do
    Repo.update!(Ecto.Changeset.change(c.route, webhook_secret_ciphertext: "invalid"))
    path = "/api/webhook/route/#{c.route.callback_token}"
    assert signed_post(path, %{}, "legacy-global-secret") |> json_response(401)
  end

  defp signed_post(path, params, secret) do
    raw = Jason.encode!(params)
    timestamp = to_string(System.system_time(:second))

    signature =
      :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw) |> Base.encode16(case: :lower)

    build_conn()
    |> put_private(:raw_body, raw)
    |> put_req_header("x-lettermint-signature", "t=#{timestamp},v1=#{signature}")
    |> put_req_header("content-type", "application/json")
    |> post(path, params)
  end

  defp inbound_payload(c, id, headers \\ %{}) do
    %{
      "id" => "provider-#{id}",
      "event" => "message.inbound",
      "sandbox" => false,
      "data" => %{
        "message_id" => "provider-message-#{id}",
        "from" => %{"email" => "alice@acme.example"},
        "recipient" => Custyard.InboundChannels.ingress_address(c.channel),
        "subject" => "Customer question",
        "body" => %{"text" => "Please help"},
        "authentication_results" => %{
          "dkim" => %{"result" => "pass", "domain" => "acme.example"},
          "dmarc" => %{"result" => "pass"}
        },
        "headers" => Map.merge(%{"message-id" => "<#{id}@acme.example>"}, headers)
      }
    }
  end
end
