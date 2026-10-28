defmodule Custyard.Intake.EmailBranding do
  @moduledoc false
  alias Custyard.{Conversation, InboundChannels, Repo, Tenants}
  alias Custyard.Email.Headers

  def tenant_id_for_claim(%{conversation_id: id}) do
    case id && Repo.get(Conversation, id) do
      %Conversation{tenant_id: tenant_id} -> tenant_id
      _ -> raise ArgumentError, "claim requires a tenant-owned conversation"
    end
  end

  def delivery_settings(id) do
    with {:ok, channel} <- Custyard.EmailSetup.default_reply_channel(id),
         {:ok, config} <- Custyard.EmailSetup.sending_config(id),
         address when is_binary(address) and address != "" <-
           InboundChannels.from_address(channel) do
      reply_to =
        if channel.reply_from == :public_address and is_binary(channel.sending_domain),
          do: channel.public_address

      {:ok, %{address: address, config: config, reply_to: reply_to}}
    else
      nil -> {:error, :from_not_set}
      "" -> {:error, :from_not_set}
      error -> error
    end
  end

  def put_sender(email, branding, %{address: address} = delivery) do
    name =
      branding.name
      |> Headers.sanitize_header_text()
      |> Headers.quote_display_name()

    email = Swoosh.Email.from(email, {name, address})

    if reply_to = Map.get(delivery, :reply_to),
      do: Swoosh.Email.reply_to(email, reply_to),
      else: email
  end

  def put_sender(email, branding, tenant_id) do
    case delivery_settings(tenant_id) do
      {:ok, delivery} ->
        put_sender(email, branding, delivery)

      {:error, _} ->
        email
    end
  end

  def for_tenant(id) do
    tenant = Tenants.get_tenant!(id)

    %{
      tenant?: true,
      name: tenant.name,
      color: tenant.primary_color || "#4f46e5",
      logo: tenant.logo_url && Tenants.url(tenant) <> tenant.logo_url
    }
  end

  def for_claim(%{conversation_id: id}) do
    case id && Repo.get(Conversation, id) do
      %Conversation{tenant_id: tenant_id} -> for_tenant(tenant_id)
      _ -> raise ArgumentError, "claim requires a tenant-owned conversation"
    end
  end

  def text_header(%{tenant?: true, name: name}), do: name <> "\n\n"
  def text_header(_), do: ""

  def html_header(%{tenant?: true} = branding) do
    logo =
      if branding.logo,
        do:
          ~s(<img src="#{escape(branding.logo)}" alt="" style="max-height: 64px; max-width: 240px; margin-bottom: 12px;" />),
        else: ""

    logo <> ~s(<h1 style="font-size: 20px; margin: 0 0 20px;">#{escape(branding.name)}</h1>)
  end

  def html_header(_), do: ""

  def escape(value), do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
