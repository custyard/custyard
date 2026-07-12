defmodule CustyardWeb.Live.ProspectAuth do
  @moduledoc """
  LiveView on_mount hook for access-token authentication.

  The token comes from the URL params on EVERY mount — never from the
  session, whose 24-hour max-age and shared operator/portal keys disqualify
  it for a months-lived credential. The presented token is hashed via
  `Custyard.Auth.Token` and looked up through
  `Custyard.Intake.get_conversation_by_access_token/1`; invalid, revoked,
  and purged tokens all halt to the ONE uniform "conversation unavailable"
  page — the same redirect for every failure class, no validity oracle.

  Mounts are rate-limited per client IP (`:conversation_mount`): the plug-level
  limits never see websocket mounts, so the check lives here where it covers
  both the HTTP and the socket mount. A missing client IP (connect info not
  captured) falls back to a shared `"unknown"` key — still bounded, never a
  crash.

  Assigns on success:

    * `:conversation` — preloaded with prospect and public messages
    * `:branding` — instance branding for the `:intake` layout
    * `:access_token_hash` — key for the `:conversation_reply` rate bucket; this
      hook deliberately does not assign the plaintext token (auth and rate
      keys are hash-based; `Prospect.ConversationLive` separately keeps the plaintext from
      its mount params solely so the claim-confirmation email can carry the
      conversation URL)
    * `:client_ip` — key for the IP-scoped mutation buckets (connect info is
      only readable during mount, so it is captured here)
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView

  alias Custyard.Auth.Token
  alias Custyard.{Intake, RateLimit, Settings}
  alias CustyardWeb.ClientIP

  @unavailable_path "/c/unavailable"

  def on_mount(:default, params, _session, socket) do
    socket = assign(socket, :branding, Settings.get_branding())
    client_ip = ClientIP.from_socket(socket)

    case RateLimit.check_rate(:conversation_mount, client_ip || "unknown") do
      {:deny, _retry_after_ms} ->
        {:halt,
         socket
         |> put_flash(:error, "Too many requests. Please wait a moment and try again.")
         |> redirect(to: @unavailable_path)}

      {:allow, _count} ->
        authenticate(params["token"], client_ip, socket)
    end
  end

  defp authenticate(token, client_ip, socket) when is_binary(token) do
    case Intake.get_conversation_by_access_token(token) do
      {:ok, conversation} ->
        {:cont,
         socket
         |> assign(:conversation, conversation)
         |> assign(:access_token_hash, Token.hash(token))
         |> assign(:client_ip, client_ip)}

      {:error, :not_found} ->
        {:halt, redirect(socket, to: @unavailable_path)}
    end
  end

  defp authenticate(_token, _client_ip, socket) do
    {:halt, redirect(socket, to: @unavailable_path)}
  end
end
