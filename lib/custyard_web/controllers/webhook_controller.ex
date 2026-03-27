defmodule CustyardWeb.WebhookController do
  use CustyardWeb, :controller

  alias Custyard.Email.Processor
  alias Custyard.InboundRoute
  alias Custyard.Repo
  alias Custyard.Webhooks.Adapters.Slack, as: SlackAdapter
  alias Custyard.Webhooks.Dispatcher
  alias Custyard.Webhooks.Registry
  alias Custyard.Webhooks.Signature

  @signature_headers %{
    lettermint: "x-lettermint-signature",
    zendesk: "x-zendesk-webhook-signature",
    intercom: "x-hub-signature",
    slack: "x-slack-signature"
  }

  # Timestamp headers for replay protection (when supported by the source)
  @timestamp_headers %{
    lettermint: "x-lettermint-timestamp",
    slack: "x-slack-request-timestamp"
  }

  # Bearer token auth for legacy inbound endpoint
  plug CustyardWeb.Plugs.WebhookAuth when action in [:inbound]

  @doc """
  Legacy inbound webhook endpoint.

  Maintains backward compatibility with the existing Lettermint integration.
  Delegates to the email Processor directly.
  """
  def inbound(conn, params) do
    case Processor.process(params) do
      {:ok, conversation} ->
        json(conn, %{status: "ok", conversation_id: conversation.id})

      {:error, reason} ->
        # Log detailed error internally but return generic message
        require Logger
        Logger.warning("Legacy webhook processing failed: #{inspect(reason)}")

        conn
        |> put_status(422)
        |> json(%{status: "error", reason: "processing failed"})
    end
  end

  @doc """
  Routed webhook endpoint — dispatched via callback_token.

  Looks up the InboundRoute by token, verifies the source adapter signature,
  normalizes the payload, and dispatches through the multi-webhook pipeline.

  ## Security Notes

  - The adapter is determined by the `source` field on the InboundRoute, NOT
    from the request body. This prevents attackers from selecting adapters
    with weaker or no signature verification.

  - Each adapter has its own signature verification. Always configure
    `:webhook_secrets` in production to enable verification.

  - The callback_token provides route-level authentication (256 bits entropy).
    If a token is leaked, rotate it in the InboundRoute record.
  """
  def routed(conn, %{"callback_token" => callback_token} = params) do
    with {:ok, route} <- find_route(callback_token),
         # Use source from route, not from request body (security fix)
         {:ok, adapter} <- resolve_adapter(route.source),
         :ok <- verify_webhook(adapter, conn, params),
         {:ok, normalized} <- adapter.normalize(params) do
      dispatch_normalized(conn, route, normalized)
    else
      # Slack URL verification bypass
      {:bypass, %{type: "url_verification", challenge: challenge}} ->
        json(conn, %{challenge: challenge})

      {:error, reason} ->
        # Return generic error to prevent information leakage.
        # Log specific error server-side for debugging.
        require Logger
        Logger.warning("Webhook auth failed for token #{String.slice(callback_token, 0, 8)}...: #{reason}")
        conn |> put_status(401) |> json(%{status: "error", reason: "unauthorized"})
    end
  end

  defp dispatch_normalized(conn, route, normalized) do
    case Dispatcher.dispatch(route, normalized) do
      {:ok, conversation} ->
        json(conn, %{status: "ok", conversation_id: conversation.id})

      {:error, reason} ->
        conn |> put_status(422) |> json(%{status: "error", reason: reason})
    end
  end

  defp find_route(callback_token) do
    case Repo.get_by(InboundRoute, callback_token: callback_token) do
      nil ->
        # Add a small random delay to prevent timing attacks
        # This makes it harder to distinguish "not found" from "found but failed"
        :timer.sleep(:rand.uniform(50) + 10)
        {:error, "unauthorized"}

      route ->
        {:ok, route}
    end
  end

  defp resolve_adapter(source) do
    case Registry.get_adapter(source) do
      nil ->
        # Log specific error but return generic message
        require Logger
        Logger.error("Unknown webhook source configured on route: #{source}")
        {:error, "internal configuration error"}

      adapter ->
        {:ok, adapter}
    end
  end

  defp verify_webhook(adapter, conn, _params) do
    source = adapter.source_name()

    case get_webhook_secret(source) do
      nil -> verify_without_secret(source)
      secret -> verify_with_secret(conn, source, secret)
    end
  end

  defp verify_without_secret(source) do
    # No secret configured — skip in dev/test with warning, fail closed in prod
    if Application.get_env(:custyard, :env, :prod) in [:dev, :test] do
      require Logger

      Logger.warning(
        "Webhook signature verification SKIPPED for source #{source} (no secret configured). " <>
          "Set :webhook_secrets in config to enable verification."
      )

      :ok
    else
      require Logger
      Logger.error("Webhook secret not configured for source: #{source}")
      {:error, "unauthorized"}
    end
  end

  defp verify_with_secret(conn, :slack, secret) do
    case conn.private[:raw_body] do
      nil ->
        {:error, "unauthorized"}

      raw_body ->
        signature = get_signature_header(conn, :slack)
        timestamp = get_req_header(conn, "x-slack-request-timestamp") |> List.first()
        SlackAdapter.verify_request(raw_body, timestamp, signature, secret)
    end
  end

  defp verify_with_secret(conn, source, secret) do
    case conn.private[:raw_body] do
      nil ->
        {:error, "unauthorized"}

      raw_body ->
        signature = get_signature_header(conn, source)
        timestamp = get_timestamp_header(conn, source)

        # Try verify_request first (with replay protection), fall back to signature-only
        case try_verify_request(source, raw_body, timestamp, signature, secret) do
          :not_implemented ->
            Signature.verify(source, raw_body, signature, secret)

          result ->
            result
        end
    end
  end

  # Attempt to use verify_request/4 if the adapter implements it
  defp try_verify_request(source, raw_body, timestamp, signature, secret) do
    case Registry.get_adapter(source) do
      nil ->
        :not_implemented

      adapter ->
        if function_exported?(adapter, :verify_request, 4) do
          adapter.verify_request(raw_body, timestamp, signature, secret)
        else
          :not_implemented
        end
    end
  end

  defp get_signature_header(conn, source) do
    case Map.get(@signature_headers, source) do
      nil -> nil
      header_name -> get_req_header(conn, header_name) |> List.first()
    end
  end

  defp get_timestamp_header(conn, source) do
    case Map.get(@timestamp_headers, source) do
      nil -> nil
      header_name -> get_req_header(conn, header_name) |> List.first()
    end
  end

  defp get_webhook_secret(source) do
    Application.get_env(:custyard, :webhook_secrets, %{})
    |> Map.get(source)
  end
end
