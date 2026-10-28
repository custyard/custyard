defmodule CustyardWeb.EmailStatusController do
  @moduledoc """
  Delivery-status webhook for outbound replies, separate from the inbound
  message pipeline (`WebhookController`).

  Each callback uses the encrypted secret stored on its tenant email connection.
  Until binding succeeds, callbacks return 401. Provider Basic Auth does not
  replace webhook signatures. Previous sends can receive status updates while
  a tenant is suspended; new inbound and outbound work is blocked.

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

  defp handle_event(conn, %{"sandbox" => true}),
    do: json(conn, %{status: "ignored", reason: "sandbox"})

  defp handle_event(conn, %{"event" => event} = params) when is_binary(event) do
    tenant_id = conn.assigns.email_connection.tenant_id

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

  defp verify_with_secret(conn, secret) do
    signature = conn |> get_req_header("x-lettermint-signature") |> List.first()

    case conn.private[:raw_body] do
      nil -> {:error, "missing raw body"}
      raw_body -> Lettermint.verify_request(raw_body, nil, signature, secret)
    end
  end

  # Only the provider's delivery id is logged; never recipient or subject.
  defp delivery_id(%{"id" => id}) when is_binary(id), do: String.slice(id, 0, 64)
  defp delivery_id(_params), do: "unknown"
end
