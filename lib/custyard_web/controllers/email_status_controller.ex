defmodule CustyardWeb.EmailStatusController do
  @moduledoc """
  Delivery-status webhook for outbound replies, separate from the inbound
  message pipeline (`WebhookController`).

  Lettermint signs each webhook with its own `whsec_` secret, so the status
  webhook is verified against `:webhook_secrets[:lettermint_status]` rather
  than the inbound route secret. Without a configured secret, verification is
  skipped with a warning in dev/test and fails closed (401) in production,
  mirroring the inbound controller.

  Responses never echo payload fields other than the event name's outcome.
  """

  use CustyardWeb, :controller

  require Logger

  alias Custyard.Email.DeliveryStatus
  alias Custyard.Webhooks.Adapters.Lettermint

  def lettermint(conn, params) do
    case verify(conn) do
      :ok ->
        handle_event(conn, params)

      {:error, reason} ->
        Logger.warning(
          "Lettermint status webhook rejected (delivery #{delivery_id(params)}): #{reason}"
        )

        conn |> put_status(401) |> json(%{status: "error", reason: "unauthorized"})
    end
  end

  defp handle_event(conn, %{"event" => event} = params) when is_binary(event) do
    case DeliveryStatus.apply_event(params) do
      {:ok, :updated, _message} ->
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
