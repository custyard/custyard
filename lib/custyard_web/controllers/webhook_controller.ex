defmodule CustyardWeb.WebhookController do
  use CustyardWeb, :controller

  alias Custyard.{InboundRoute, Repo}
  alias Custyard.Email.Processor
  alias Custyard.Webhooks.{Dispatcher, Normalizer, Registry, Signature}

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
      case Dispatcher.dispatch(route, normalized) do
        {:ok, conversation} ->
          json(conn, %{status: "ok", conversation_id: conversation.id})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{status: "error", reason: reason})
      end
    else
      {:error, reason} ->
        conn |> put_status(401) |> json(%{status: "error", reason: reason})
    end
  end

  def routed(conn, %{"callback_token" => callback_token} = params) do
    # Default to lettermint when no source specified
    with {:ok, route} <- find_route(callback_token),
         {:ok, normalized} <- Normalizer.normalize_legacy(params) do
      case Dispatcher.dispatch(route, normalized) do
        {:ok, conversation} ->
          json(conn, %{status: "ok", conversation_id: conversation.id})

        {:error, reason} ->
          conn |> put_status(422) |> json(%{status: "error", reason: reason})
      end
    else
      {:error, reason} ->
        conn |> put_status(401) |> json(%{status: "error", reason: reason})
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

  defp verify_webhook(adapter, conn, params) do
    # Get webhook secret from application config
    source = adapter.source_name()
    secret = get_webhook_secret(source)

    if secret do
      signature = get_signature_header(conn, source)
      raw_body = conn.assigns[:raw_body] || Jason.encode!(params)
      Signature.verify(source, raw_body, signature, secret)
    else
      # No secret configured — skip verification (development mode)
      :ok
    end
  end

  defp get_signature_header(conn, :lettermint) do
    get_req_header(conn, "x-lettermint-signature") |> List.first()
  end

  defp get_signature_header(conn, :zendesk) do
    get_req_header(conn, "x-zendesk-webhook-signature") |> List.first()
  end

  defp get_signature_header(conn, :intercom) do
    get_req_header(conn, "x-hub-signature") |> List.first()
  end

  defp get_signature_header(conn, :slack) do
    get_req_header(conn, "x-slack-signature") |> List.first()
  end

  defp get_signature_header(_conn, _source), do: nil

  defp get_webhook_secret(source) do
    Application.get_env(:custyard, :webhook_secrets, %{})
    |> Map.get(source)
  end
end
