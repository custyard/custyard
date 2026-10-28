defmodule CustyardWeb.EmailStatusController do
  @moduledoc """
  Delivery-status webhook for outbound replies, separate from the inbound
  message pipeline (`WebhookController`).

  Each Lettermint webhook has its own signing secret. Tenant callback URLs
  use the encrypted secret saved by Email setup, separately from the inbound
  route secret. Until binding succeeds, these URLs deliberately return 401;
  turning off provider Basic Auth does not bypass signature verification.

  The legacy URL uses `:webhook_secrets[:lettermint_status]`. Missing legacy
  configuration is allowed with a warning in dev/test and fails closed in
  production.

  Responses never echo payload fields other than the event name's outcome.
  """

  use CustyardWeb, :controller

  require Logger

  alias Custyard.Email.DeliveryStatus
  alias Custyard.Webhooks.Adapters.Lettermint

  def lettermint(conn, %{"callback_token" => callback_token} = params) do
    with %Custyard.EmailConnection{} = connection <-
           Custyard.EmailSetup.status_connection(callback_token),
         {:ok, secret} <- Custyard.EmailSetup.status_secret(connection),
         :ok <- verify_with_secret(conn, secret) do
      if Custyard.EmailSetup.status_message_belongs?(connection, params) do
        conn |> assign(:email_connection, connection) |> handle_event(params)
      else
        json(conn, %{status: "ignored", reason: "unknown_message"})
      end
    else
      _ -> conn |> put_status(401) |> json(%{status: "error", reason: "unauthorized"})
    end
  end

  def lettermint(conn, params) do
    case verify(conn) do
      :ok ->
        if Custyard.EmailSetup.legacy_status_allowed?(params),
          do: handle_event(conn, params),
          else: json(conn, %{status: "ignored", reason: "unknown_message"})

      {:error, reason} ->
        Logger.warning(
          "Lettermint status webhook rejected (delivery #{delivery_id(params)}): #{reason}"
        )

        conn |> put_status(401) |> json(%{status: "error", reason: "unauthorized"})
    end
  end

  defp handle_event(conn, %{"sandbox" => true}),
    do: json(conn, %{status: "ignored", reason: "sandbox"})

  defp handle_event(conn, %{"event" => event} = params) when is_binary(event) do
    tenant_id =
      case conn.assigns[:email_connection] do
        %{tenant_id: tenant_id} -> tenant_id
        nil -> Custyard.Tenants.default_tenant().id
      end

    case DeliveryStatus.apply_event(params, tenant_id: tenant_id) do
      {:ok, :updated, message} ->
        if connection = conn.assigns[:email_connection],
          do: Custyard.EmailSetup.record_status_event(connection, params, message)

        json(conn, %{status: "ok"})

      {:ok, :ignored, reason} ->
        json(conn, %{status: "ignored", reason: to_string(reason)})

      {:error, reason} ->
        Logger.warning(
          "Lettermint status webhook failed (delivery #{delivery_id(params)}, " <>
            "event #{event}): #{inspect(reason)}"
        )

        conn |> put_status(422) |> json(%{status: "error", reason: "processing failed"})
    end
  end

  defp handle_event(conn, _params) do
    conn |> put_status(422) |> json(%{status: "error", reason: "invalid payload"})
  end

  defp verify(conn) do
    case status_secret() do
      nil -> verify_without_secret()
      secret -> verify_with_secret(conn, secret)
    end
  end

  defp verify_without_secret do
    if Application.get_env(:custyard, :env, :prod) in [:dev, :test] do
      Logger.warning(
        "Lettermint status webhook signature verification SKIPPED (no secret configured). " <>
          "Set :webhook_secrets[:lettermint_status] to enable verification."
      )

      :ok
    else
      Logger.error("Webhook secret not configured for lettermint_status")
      {:error, "unauthorized"}
    end
  end

  defp verify_with_secret(conn, secret) do
    signature = conn |> get_req_header("x-lettermint-signature") |> List.first()

    case conn.private[:raw_body] do
      nil -> {:error, "missing raw body"}
      raw_body -> Lettermint.verify_request(raw_body, nil, signature, secret)
    end
  end

  defp status_secret do
    case Application.get_env(:custyard, :webhook_secrets, %{}) do
      %{lettermint_status: secret} when is_binary(secret) and secret != "" -> secret
      _ -> nil
    end
  end

  # Only the provider's delivery id is logged; never recipient or subject.
  defp delivery_id(%{"id" => id}) when is_binary(id), do: String.slice(id, 0, 64)
  defp delivery_id(_params), do: "unknown"
end
