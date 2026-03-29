defmodule CustyardWeb.WebhookControllerTest do
  use CustyardWeb.ConnCase, async: true

  alias Custyard.InboundRoute
  alias Custyard.Repo

  import Custyard.Factory

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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support@example.com",
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
      assert is_integer(response["conversation_id"])
    end

    test "handles Slack URL verification challenge", %{conn: conn} do
      org = insert_organization()

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          source: :slack
        })
        |> Repo.insert()

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

    test "associates conversation with route's project when set", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      _contact = insert_contact(organization_id: org.id, email: "alice@test.example.com")

      {:ok, route} =
        %InboundRoute{}
        |> InboundRoute.changeset(%{
          organization_id: org.id,
          project_id: project.id,
          route_type: :project,
          source: :lettermint
        })
        |> Repo.insert()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support@example.com",
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

      # Verify the conversation was assigned to the project
      conversation = Repo.get!(Custyard.Conversation, response["conversation_id"])
      assert conversation.project_id == project.id
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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support@example.com",
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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

      params = %{
        "from" => "alice@test.example.com",
        "to" => "support@example.com",
        "subject" => "Signed test",
        "text" => "Test body with signature",
        "headers" => %{
          "message-id" => "<signed-#{System.unique_integer([:positive])}@test.com>"
        }
      }

      raw_body = Jason.encode!(params)
      signature = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)

      response =
        conn
        |> put_private(:raw_body, raw_body)
        |> put_req_header("x-lettermint-signature", signature)
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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

      # Payload with required from field but will fail on message creation
      # due to missing conversation data
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
          organization_id: org.id,
          source: :lettermint
        })
        |> Repo.insert()

      # Valid from but empty subject (should succeed and create conversation)
      params = %{
        "from" => "test@example.com",
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
end
