defmodule CustyardWeb.Plugs.WebhookAuth do
  @moduledoc """
  Plug that authenticates webhook requests using a bearer token.

  The expected token is configured via the :webhook_token application env.
  Requests must include an `Authorization: Bearer <token>` header.

  Returns 401 if no token is configured (webhooks disabled by default)
  or if the provided token doesn't match.
  """
  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    configured_token = Application.get_env(:custyard, :webhook_token)

    if is_nil(configured_token) or configured_token == "" do
      reject(conn, "Webhook authentication not configured")
    else
      verify_token(conn, configured_token)
    end
  end

  defp verify_token(conn, configured_token) do
    case get_bearer_token(conn) do
      nil ->
        reject(conn, "Missing authorization token")

      token ->
        if Plug.Crypto.secure_compare(token, configured_token) do
          conn
        else
          reject(conn, "Invalid authorization token")
        end
    end
  end

  defp reject(conn, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: message}))
    |> halt()
  end

  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> String.trim(token)
      _ -> nil
    end
  end
end
