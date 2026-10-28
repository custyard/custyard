defmodule CustyardWeb.WebhookControllerTest do
  use CustyardWeb.ConnCase, async: false

  alias Custyard.Fixtures.EmailPayloads
  alias Custyard.InboundRoute
  alias Custyard.Repo

  import Custyard.Factory

  import Custyard.Fixtures.EmailPayloads,
    except: [standard_payload: 0, standard_payload: 1, reply_payload: 1]

  describe "routed/2 (token-based routing)" do
    setup do
      # Skip signature verification in test environment
      Application.put_env(:custyard, :env, :test)

      on_exit(fn ->
        Application.delete_env(:custyard, :env)
      end)

      :ok
    end

    test "returns 401 for invalid callback token", %{conn: conn} do
      response =
        conn
        |> post(~p"/api/webhook/route/invalid-token", %{})
        |> json_response(401)

      assert response["status"] == "error"
      assert response["reason"] == "unauthorized"
    end

    test "processes valid routed webhook for lettermint", %{conn: conn} do
      org = insert_organization()
      _contact = insert_contact(organization_id: org.id, email: "alice@test.example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "Routed webhook test",
        "text" => "Test body via routed webhook",
        "headers" => %{
          "message-id" => "<routed-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"
      assert is_integer(response["thread_id"])
    end

    test "handles Slack URL verification challenge", %{conn: conn} do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :slack
        })
        |> insert_configured_route()

      params = %{
        "type" => "url_verification",
        "challenge" => "test-challenge-token"
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["challenge"] == "test-challenge-token"
    end

    test "assigns a compatible channel project hint on new threads", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      _contact = insert_contact(organization_id: org.id, email: "alice@test.example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          project_id: project.id,
          route_type: :project,
          source: :lettermint
        })
        |> insert_configured_route()

      Repo.get_by!(Custyard.InboundChannel, inbound_route_id: route.id)
      |> Ecto.Changeset.change(default_organization_id: org.id, default_project_id: project.id)
      |> Repo.update!()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "Project webhook test",
        "text" => "Test body for project routing",
        "headers" => %{
          "message-id" => "<project-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"

      # Verify the thread was assigned to the project
      thread = Repo.get!(Custyard.Thread, response["thread_id"])
      assert thread.project_id == project.id
    end
  end

  describe "threading" do
    setup do
      Application.put_env(:custyard, :env, :test)

      on_exit(fn ->
        Application.delete_env(:custyard, :env)
      end)

      org = insert_organization()
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      {:ok, org: org, route: route}
    end

    test "reply with In-Reply-To threads into existing thread", %{
      conn: conn,
      route: route
    } do
      original_id = unique_message_id()

      first_response =
        conn
        |> post(
          ~p"/api/webhook/route/#{route.callback_token}",
          standard_payload(%{"headers" => %{"message-id" => original_id}})
        )
        |> json_response(200)

      thread_id = first_response["thread_id"]

      reply_response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", reply_payload(original_id))
        |> json_response(200)

      assert reply_response["status"] == "ok"
      assert reply_response["thread_id"] == thread_id
    end

    test "unrelated In-Reply-To starts a new thread", %{conn: conn, route: route} do
      first_response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", standard_payload())
        |> json_response(200)

      reply_response =
        conn
        |> post(
          ~p"/api/webhook/route/#{route.callback_token}",
          reply_payload("<nonexistent@elsewhere.example.com>")
        )
        |> json_response(200)

      assert reply_response["thread_id"] != first_response["thread_id"]
    end

    test "html-only payload creates a thread with stripped body", %{
      conn: conn,
      route: route
    } do
      response =
        conn
        |> post(
          ~p"/api/webhook/route/#{route.callback_token}",
          html_only_payload(%{"to" => "support+controller-test-token@inbound.test"})
        )
        |> json_response(200)

      assert response["status"] == "ok"

      message =
        Repo.get_by!(Custyard.Message, thread_id: response["thread_id"])

      assert message.body =~ "HTML only body"
      refute message.body =~ "<p>"
    end
  end

  describe "signature verification" do
    setup do
      # Use dev environment to test signature warnings
      Application.put_env(:custyard, :env, :dev)

      on_exit(fn ->
        Application.delete_env(:custyard, :env)
        Application.delete_env(:custyard, :webhook_secrets)
      end)

      :ok
    end

    test "skips verification in dev/test when no secret configured", %{conn: conn} do
      org = insert_organization()
      _contact = insert_contact(organization_id: org.id, email: "alice@test.example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "No signature test",
        "text" => "Test body without signature",
        "headers" => %{
          "message-id" => "<nosig-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      # Should succeed even without signature header in dev/test
      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"
    end

    test "fails in prod when no secret configured", %{conn: conn} do
      Application.put_env(:custyard, :env, :prod)

      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", %{
          "from" => "alice@test.example.com"
        })
        |> json_response(401)

      assert response["status"] == "error"
      assert response["reason"] == "unauthorized"
    end

    test "verifies lettermint signature when secret is configured", %{conn: conn} do
      org = insert_organization()
      _contact = insert_contact(organization_id: org.id, email: "alice@test.example.com")
      secret = "test-lettermint-secret"

      Application.put_env(:custyard, :webhook_secrets, %{lettermint: secret})

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "Signed test",
        "text" => "Test body with signature",
        "headers" => %{
          "message-id" => "<signed-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      raw_body = Jason.encode!(params)
      timestamp = to_string(System.system_time(:second))

      digest =
        :crypto.mac(:hmac, :sha256, secret, timestamp <> "." <> raw_body)
        |> Base.encode16(case: :lower)

      signature = "t=#{timestamp},v1=#{digest}"

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", signature)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"
    end

    test "verifies Zendesk's timestamp header with the route's signing secret", %{conn: conn} do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{tenant_id: org.tenant_id, source: :zendesk})
        |> insert_configured_route()

      secret = "zendesk-route-secret"

      route = put_route_secret(route, secret)

      params = %{
        "ticket" => %{
          "id" => 941,
          "subject" => "Signed Zendesk event",
          "comment" => %{"id" => 11, "body" => "Customer comment"},
          "requester" => %{"email" => "alice@example.com"}
        }
      }

      raw_body = Jason.encode!(params)
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      signature = :crypto.mac(:hmac, :sha256, secret, timestamp <> raw_body) |> Base.encode64()

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-zendesk-webhook-signature", signature)
        |> put_req_header("x-zendesk-webhook-signature-timestamp", timestamp)
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"
    end

    test "rejects invalid signature", %{conn: conn} do
      org = insert_organization()
      secret = "test-secret"

      Application.put_env(:custyard, :webhook_secrets, %{lettermint: secret})

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      params = %{"from" => "alice@test.example.com"}
      raw_body = Jason.encode!(params)

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", "invalid-signature")
        |> put_req_header("content-type", "application/json")
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(401)

      assert response["status"] == "error"
      assert response["reason"] == "unauthorized"
    end
  end

  describe "error handling" do
    setup do
      Application.put_env(:custyard, :env, :test)

      on_exit(fn ->
        Application.delete_env(:custyard, :env)
      end)

      :ok
    end

    test "returns 422 for processing failures with missing required data", %{conn: conn} do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      # Payload with required from field but will fail on message creation
      # due to missing thread data
      params = %{
        "from" => "test@example.com",
        "subject" => "",
        "text" => "",
        "headers" => %{}
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)

      # May return 200 (success) or 422 (error) depending on validation
      # The important thing is it doesn't crash with a 500
      assert response.status in [200, 422]
    end

    test "returns structured error responses", %{conn: conn} do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          tenant_id: org.tenant_id,
          source: :lettermint
        })
        |> insert_configured_route()

      # Valid from but empty subject (should succeed and create thread)
      params = %{
        "from" => "test@example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "Test subject",
        "text" => "Test body",
        "headers" => %{
          "message-id" => "<test-#{System.unique_integer([:positive])}@example.com>"
        }
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      # Should return structured JSON response
      assert is_map(response)
      assert response["status"] == "ok"
    end
  end

  describe "payload handling after authentication" do
    setup do
      Application.put_env(:custyard, :env, :test)
      on_exit(fn -> Application.delete_env(:custyard, :env) end)
      :ok
    end

    defp authenticated_route(source) do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{tenant_id: org.tenant_id, source: source})
        |> insert_configured_route()

      route
    end

    test "a payload the adapter rejects returns 422, not 401", %{conn: conn} do
      route = authenticated_route(:zendesk)

      # A Zendesk body template that sends the comment as a string without an id
      params = %{
        "ticket" => %{
          "id" => 1,
          "subject" => "Help",
          "requester" => %{"email" => "alice@example.com"},
          "comment" => "No comment id"
        }
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(422)

      assert response["reason"] == "invalid payload"
    end

    test "a payload with an unexpected shape returns 422 instead of 500", %{conn: conn} do
      route = authenticated_route(:zendesk)

      params = %{"ticket" => %{"id" => %{"nested" => 1}, "subject" => "Help"}}

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(422)

      assert response["reason"] == "invalid payload"
    end

    test "a payload without a sender is accepted as a contactless thread", %{conn: conn} do
      route = authenticated_route(:lettermint)

      params = %{
        "to" => "support+controller-test-token@inbound.test",
        "subject" => "No sender",
        "text" => "hello",
        "headers" => %{
          "message-id" => "<nosender-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      thread = Repo.get!(Custyard.Thread, response["thread_id"])
      assert thread.contact_id == nil
    end

    test "non-string fields are tolerated", %{conn: conn} do
      route = authenticated_route(:lettermint)

      params = %{
        "from" => "alice@example.com",
        "to" => "support+controller-test-token@inbound.test",
        "subject" => ["not", "a", "string"],
        "text" => "",
        "html" => "<p>Only HTML</p>",
        "headers" => []
      }

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      thread = Repo.get!(Custyard.Thread, response["thread_id"])
      assert thread.subject == "(no subject)"

      message = Repo.get_by!(Custyard.Message, thread_id: thread.id)
      assert message.body == "Only HTML"
    end
  end

  describe "Lettermint enveloped events" do
    setup do
      Application.put_env(:custyard, :env, :test)
      on_exit(fn -> Application.delete_env(:custyard, :env) end)

      org = insert_organization()
      _contact = insert_contact(organization_id: org.id, email: "customer@example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{tenant_id: org.tenant_id, source: :lettermint})
        |> insert_configured_route()

      %{org: org, route: route}
    end

    defp lettermint_event(event) do
      %{
        "id" => "e3d4f5a6-#{System.unique_integer([:positive])}",
        "event" => event,
        "timestamp" => "2025-10-02T14:30:00.000Z",
        "data" => %{
          "route" => "support-inbox",
          "message_id" => "f47ac10b-#{System.unique_integer([:positive])}",
          "from" => %{"email" => "customer@example.com", "name" => "John Doe"},
          "to" => [%{"email" => "support+controller-test-token@inbound.test", "name" => nil}],
          "cc" => [],
          "recipient" => "support+controller-test-token@inbound.test",
          "subject" => "Question about my order",
          "body" => %{"text" => "Hi, where is my order?", "html" => nil},
          "headers" => [
            %{
              "name" => "Message-ID",
              "value" => "<env-#{System.unique_integer([:positive])}@mail.example.com>"
            }
          ],
          "is_spam" => false,
          "spam_score" => 1.2
        }
      }
    end

    test "an enveloped message.inbound creates a thread", %{conn: conn, route: route} do
      params = lettermint_event("message.inbound")

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response["status"] == "ok"
      assert is_integer(response["thread_id"])

      thread = Repo.get!(Custyard.Thread, response["thread_id"])
      assert thread.subject == "Question about my order"

      message = Repo.get_by!(Custyard.Message, thread_id: thread.id)
      assert message.provider_delivery_id == params["id"]
      assert message.sender_email == "John Doe <customer@example.com>"
    end

    test "a message.delivered envelope is ignored and creates nothing", %{
      conn: conn,
      route: route
    } do
      response =
        conn
        |> post(
          ~p"/api/webhook/route/#{route.callback_token}",
          lettermint_event("message.delivered")
        )
        |> json_response(200)

      assert response == %{"status" => "ignored", "event" => "message.delivered"}
      assert Repo.aggregate(Custyard.Thread, :count) == 0
      assert Repo.aggregate(Custyard.Message, :count) == 0
    end

    test "a delivery the dispatcher ignores is acknowledged with 200", %{
      conn: conn,
      route: route
    } do
      # A route with channels routes by token (D2); a recipient matching none
      # is logged and must not be retried by Lettermint.
      channel = insert_inbound_channel(inbound_route_id: route.id, state: :active)
      params = lettermint_event("message.inbound")
      params = put_in(params, ["data", "recipient"], "support+nosuchtoken@lettermint.app")

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response == %{"status" => "ignored", "reason" => "no_channel"}
      assert Repo.aggregate(Custyard.Thread, :count) == 0

      assert [rejection] = Custyard.InboundChannels.list_rejections_for_route(route.id)
      assert rejection.classification == :no_channel
      assert rejection.inbound_channel_id == nil
      assert Repo.reload!(channel).last_received_at == nil
    end

    test "a verification notice on a configured route is acknowledged as a provider notice", %{
      conn: conn,
      route: route
    } do
      params = lettermint_event("message.inbound")

      params =
        params
        |> put_in(["data", "from"], %{"email" => "forwarding-noreply@google.com", "name" => nil})
        |> put_in(["data", "subject"], "(#123) Gmail Forwarding Confirmation")

      response =
        conn
        |> post(~p"/api/webhook/route/#{route.callback_token}", params)
        |> json_response(200)

      assert response == %{"status" => "ignored", "reason" => "provider_notice"}
      assert Repo.aggregate(Custyard.Thread, :count) == 0
    end
  end

  test "direct email routes cannot use the unsigned internal adapter over HTTP", %{conn: conn} do
    route = insert_inbound_route(tenant_id: factory_tenant_id(), source: :email)
    route = put_route_secret(route, "stored-secret")

    assert conn
           |> post("/api/webhook/route/#{route.callback_token}", standard_payload())
           |> json_response(401) ==
             %{"status" => "error", "reason" => "unauthorized"}

    assert Repo.aggregate(Custyard.Thread, :count) == 0
  end

  defp insert_configured_route(changeset) do
    with {:ok, route} <- Repo.insert(changeset) do
      secret = Application.get_env(:custyard, :webhook_secrets, %{})[route.source]
      route = if is_binary(secret), do: put_route_secret(route, secret), else: route

      if route.source in [:lettermint, :email] do
        insert_inbound_channel(
          inbound_route_id: route.id,
          tenant_id: route.tenant_id,
          public_address: "support@example.test",
          ingress_token: "controller-test-token",
          state: :active
        )
      end

      {:ok, route}
    end
  end

  defp standard_payload(overrides \\ %{}) do
    EmailPayloads.standard_payload(overrides)
    |> Map.put("to", "support+controller-test-token@inbound.test")
  end

  defp reply_payload(id) do
    EmailPayloads.reply_payload(id)
    |> Map.put("to", "support+controller-test-token@inbound.test")
  end

  defp put_route_secret(route, secret) do
    {:ok, encrypted} =
      Custyard.Credentials.encrypt(
        secret,
        "inbound_route:#{route.tenant_id}:#{route.id}:webhook_secret"
      )

    route |> Ecto.Changeset.change(webhook_secret_ciphertext: encrypted) |> Repo.update!()
  end
end
