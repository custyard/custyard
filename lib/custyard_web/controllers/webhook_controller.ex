defmodule CustyardWeb.WebhookController do
  use CustyardWeb, :controller

  alias Custyard.{InboundRoute, Repo}
  alias Custyard.Email.Processor
  alias Custyard.Webhooks.{Dispatcher, Normalizer, Registry, Signature}
  alias Custyard.Webhooks.Adapters.Slack, as: SlackAdapter

  @signature_headers %{
    lettermint: "x-lettermint-signature",
    zendesk: "x-zendesk-webhook-signature",
    intercom: "x-hub-signature",
    slack: "x-slack-signature"
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
        conn
        |> put_status(422)
        |> json(%{status: "error", reason: reason})
    end
  end

  @doc """
  Routed webhook endpoint — dispatched via callback_token.

  Looks up the InboundRoute by token, verifies the source adapter signature,
  normalizes the payload, and dispatches through the multi-webhook pipeline.
  """
  def routed(conn, %{"callback_token" => callback_token, "source" => source} = params) do
    with {:ok, route} <- find_route(callback_token),
         {:ok, adapter} <- resolve_adapter(source),
         :ok <- verify_webhook(adapter, conn, params),
         {:ok, normalized} <- adapter.normalize(params) do
      dispatch_normalized(conn, route, normalized)
    else
      # Slack URL verification bypass
      {:bypass, %{type: "url_verification", challenge: challenge}} ->
        json(conn, %{challenge: challenge})

      {:error, reason} ->
        conn |> put_status(401) |> json(%{status: "error", reason: reason})
    end
  end

  def routed(conn, %{"callback_token" => callback_token} = params) do
    # Default to lettermint when no source specified
    with {:ok, route} <- find_route(callback_token),
         {:ok, normalized} <- Normalizer.normalize_legacy(params) do
      dispatch_normalized(conn, route, normalized)
    else
      {:error, reason} ->
        conn |> put_status(401) |> json(%{status: "error", reason: reason})
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
      nil -> {:error, "unknown route"}
      route -> {:ok, route}
    end
  end

  defp resolve_adapter(source) do
    case Registry.get_adapter(source) do
      nil -> {:error, "unknown source: #{source}"}
      adapter -> {:ok, adapter}
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
    # No secret configured — skip in dev/test, fail closed in prod
    if Application.get_env(:custyard, :env, :prod) in [:dev, :test] do
      :ok
    else
      {:error, "webhook secret not configured for source: #{source}"}
    end
  end

  defp verify_with_secret(conn, :slack, secret) do
    case conn.private[:raw_body] do
      nil ->
        {:error, "missing raw request body for signature verification"}

      raw_body ->
        signature = get_signature_header(conn, :slack)
        timestamp = get_req_header(conn, "x-slack-request-timestamp") |> List.first()
        SlackAdapter.verify_request(raw_body, timestamp, signature, secret)
    end
  end

  defp verify_with_secret(conn, source, secret) do
    case conn.private[:raw_body] do
      nil ->
        {:error, "missing raw request body for signature verification"}

      raw_body ->
        signature = get_signature_header(conn, source)
        Signature.verify(source, raw_body, signature, secret)
    end
  end

  defp get_signature_header(conn, source) do
    case Map.get(@signature_headers, source) do
      nil -> nil
      header_name -> get_req_header(conn, header_name) |> List.first()
    end
  end

  defp get_webhook_secret(source) do
    Application.get_env(:custyard, :webhook_secrets, %{})
    |> Map.get(source)
  end
end
