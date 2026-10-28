defmodule CustyardWeb.Live.ProspectAuth do
  @moduledoc """
  LiveView on_mount hook for access-token authentication.

  The token comes from the URL params on EVERY mount — never from the
  session, whose 24-hour max-age and shared staff/portal keys disqualify
  it for a months-lived credential. The presented token is hashed via
  `Custyard.Auth.Token` and looked up through
  `Custyard.Intake.get_conversation_by_access_token/2`; invalid, revoked,
  and purged tokens all halt to the ONE uniform "conversation unavailable"
  page — the same redirect for every failure class, no validity oracle.

  Mounts are rate-limited per client IP (`:conversation_mount`): the plug-level
  limits never see websocket mounts, so the check lives here where it covers
  both the HTTP and the socket mount. A missing client IP (connect info not
  captured) falls back to a shared `"unknown"` key — still bounded, never a
  crash.

  Assigns on success:

    * `:conversation` — preloaded with prospect and public messages
    * `:branding` — tenant branding for the `:intake` layout
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
  import Ecto.Query

  alias Custyard.Auth.Token
  alias Custyard.{Conversation, Intake, Prospect, RateLimit, Repo, Settings, Tenants}
  alias CustyardWeb.ClientIP

  @unavailable_path "/threads/unavailable"

  def on_mount(:default, params, _session, socket) do
    socket = CustyardWeb.HostScope.capture(socket)
    tenant = Tenants.resolve_host(socket.assigns.verified_host)

    socket =
      socket
      |> assign(
        :branding,
        if(tenant,
          do: Settings.get_branding(tenant.id),
          else: %{name: "Custyard", logo_url: nil, primary_color: nil}
        )
      )
      |> assign(:host_tenant_id, tenant && tenant.id)

    client_ip = ClientIP.from_socket(socket)

    result =
      with {:allow, _} <- RateLimit.check_rate(:public_instance_ip, client_ip || "unknown") do
        RateLimit.check_rate(:conversation_mount, {tenant && tenant.id, client_ip || "unknown"})
      end

    case result do
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
    case Intake.get_conversation_by_access_token(token, socket.assigns.host_tenant_id) do
      {:ok, conversation} ->
        tenant_allowed? =
          socket.assigns.host_tenant_id == conversation.tenant_id and
            Tenants.active?(conversation.tenant_id)

        if tenant_allowed? do
          {:cont,
           socket
           |> assign(:conversation, conversation)
           |> assign(
             :branding,
             Tenants.branding(Tenants.get_tenant!(conversation.tenant_id))
           )
           |> assign(:access_token_hash, Token.hash(token))
           |> assign(:client_ip, {conversation.tenant_id, client_ip || "unknown"})
           |> attach_hook(:prospect_tenant_event, :handle_event, fn _, _, socket ->
             check_tenant(socket)
           end)
           |> attach_hook(:prospect_tenant_info, :handle_info, fn _, socket ->
             check_tenant(socket)
           end)
           |> attach_hook(:prospect_tenant_params, :handle_params, fn _, _, socket ->
             check_tenant(socket)
           end)
           |> attach_hook(:prospect_tenant_async, :handle_async, fn _, _, socket ->
             check_tenant(socket)
           end)}
        else
          {:halt, redirect(socket, to: @unavailable_path)}
        end

      {:error, :not_found} ->
        {:halt, redirect(socket, to: @unavailable_path)}
    end
  end

  defp authenticate(_token, _client_ip, socket) do
    {:halt, redirect(socket, to: @unavailable_path)}
  end

  defp check_tenant(socket) do
    tenant = Tenants.resolve_host(socket.assigns.verified_host)

    if tenant && tenant.id == socket.assigns.host_tenant_id && tenant.status == "active" &&
         current_credential?(socket, tenant.id),
       do: {:cont, socket},
       else: {:halt, redirect(socket, to: @unavailable_path)}
  end

  defp current_credential?(socket, tenant_id) do
    conversation_id = socket.assigns.conversation.id
    token_hash = socket.assigns.access_token_hash

    Repo.exists?(
      from p in Prospect,
        join: c in Conversation,
        on: c.id == p.conversation_id and c.tenant_id == p.tenant_id,
        where: p.tenant_id == ^tenant_id and c.id == ^conversation_id,
        where: p.access_token_hash == ^token_hash and is_nil(p.revoked_at)
    )
  end
end
