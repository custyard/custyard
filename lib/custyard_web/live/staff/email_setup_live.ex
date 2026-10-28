defmodule CustyardWeb.Staff.EmailSetupLive do
  use CustyardWeb, :live_view
  alias Custyard.EmailSetup

  @impl true
  def mount(_params, _session, socket) do
    tenant = socket.assigns.current_tenant

    case EmailSetup.ensure_connection(socket.assigns.current_staff, tenant.id) do
      {:ok, _} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Custyard.PubSub, "email_setup:#{tenant.id}")
          Phoenix.PubSub.subscribe(Custyard.PubSub, "inbound_channels")
        end

        {:ok,
         socket
         |> assign(
           page_title: "Email setup",
           busy: false,
           setup_channel_id: nil,
           show_channel: false,
           revealed_channel_ids: MapSet.new()
         )
         |> reload(), layout: {CustyardWeb.Layouts, :staff}}

      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Only a tenant administrator can configure email.")
         |> redirect(to: ~p"/app")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    selection = params["channel"]
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == selection))

    {:noreply,
     socket
     |> assign(
       show_channel: selection == "new" or not is_nil(channel),
       setup_channel_id: channel && channel.id
     )
     |> reload()}
  end

  @impl true
  def handle_event("save_credentials", %{"connection" => params}, socket) do
    result =
      EmailSetup.save_credentials(
        socket.assigns.current_staff,
        socket.assigns.current_tenant.id,
        params
      )

    # Never put a submitted secret, including invalid input, back into assigns.
    {:noreply, finish(socket, result, "Credentials saved. Check the connection next.")}
  end

  def handle_event("check_connection", _params, socket),
    do: async(socket, fn staff, tenant_id -> EmailSetup.check_connection(staff, tenant_id) end)

  def handle_event("import_route", %{"route" => %{"id" => id}}, socket),
    do: async(socket, fn staff, tenant_id -> EmailSetup.import_route(staff, tenant_id, id) end)

  def handle_event("bind_inbound", %{"webhook" => params}, socket) do
    case Integer.parse(params["route_id"] || "") do
      {id, ""} ->
        async(socket, fn staff, tenant_id ->
          EmailSetup.bind_inbound_webhook(
            staff,
            tenant_id,
            id,
            params["id"] || "",
            params["secret"] || ""
          )
        end)

      _ ->
        {:noreply, put_flash(socket, :error, "Choose a receiving route.")}
    end
  end

  def handle_event("bind_status", %{"status" => params}, socket),
    do:
      async(socket, fn staff, tenant_id ->
        EmailSetup.bind_status_webhook(
          staff,
          tenant_id,
          params["id"] || "",
          params["secret"] || ""
        )
      end)

  def handle_event("channel_action", %{"id" => id, "action" => action}, socket) do
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == id))

    operation =
      %{
        "pause" => :pause,
        "resume" => :resume,
        "revoke" => :revoke,
        "rotate" => :rotate_token,
        "delete" => :delete_channel
      }[action]

    result =
      if channel && operation,
        do:
          apply(Custyard.InboundChannels, operation, [
            channel,
            [staff: socket.assigns.current_staff]
          ]),
        else: {:error, :not_found}

    {:noreply, finish(socket, result, "Support address updated")}
  end

  def handle_event("reveal_channel", %{"id" => id}, socket) do
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == id))

    if channel do
      Custyard.InboundChannels.record_reveal(channel, staff: socket.assigns.current_staff)

      {:noreply,
       assign(
         socket,
         :revealed_channel_ids,
         MapSet.put(socket.assigns.revealed_channel_ids, channel.id)
       )}
    else
      {:noreply, put_flash(socket, :error, "Support address unavailable")}
    end
  end

  def handle_event("routing_defaults", %{"channel" => attrs}, socket) do
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == attrs["id"]))

    result =
      if channel,
        do:
          Custyard.InboundChannels.update_channel(
            channel,
            Map.take(attrs, ~w(default_organization_id default_project_id default_label_id)),
            staff: socket.assigns.current_staff
          ),
        else: {:error, :not_found}

    {:noreply, finish(socket, result, "Address routing defaults saved")}
  end

  def handle_event("new_channel", _, socket),
    do: {:noreply, push_patch(socket, to: ~p"/app/settings/email?#{[channel: "new"]}")}

  def handle_event("set_default_channel", %{"default_channel_id" => id}, socket) do
    result =
      EmailSetup.set_default_channel(
        socket.assigns.current_staff,
        socket.assigns.current_tenant.id,
        id
      )

    {:noreply, finish(socket, result, "Default reply address saved.")}
  end

  def handle_event("resume_channel", %{"id" => id}, socket) do
    channel = Enum.find(socket.assigns.channels, &(to_string(&1.id) == id))

    if channel,
      do: {:noreply, push_patch(socket, to: ~p"/app/settings/email?#{[channel: channel.id]}")},
      else: {:noreply, socket}
  end

  defp async(%{assigns: %{busy: true}} = socket, _fun), do: {:noreply, socket}

  defp async(socket, fun) do
    staff = socket.assigns.current_staff
    tenant_id = socket.assigns.current_tenant.id

    {:noreply,
     socket
     |> assign(:busy, true)
     |> start_async(:provider_check, fn -> fun.(staff, tenant_id) end)}
  end

  @impl true
  def handle_async(:provider_check, {:ok, result}, socket),
    do:
      {:noreply,
       socket |> assign(:busy, false) |> finish(result, "Check saved. Review the status below.")}

  def handle_async(:provider_check, {:exit, _}, socket),
    do:
      {:noreply,
       socket
       |> assign(:busy, false)
       |> put_flash(:error, "The provider check could not finish. Try again.")}

  @impl true
  def handle_info(:email_setup_updated, socket), do: {:noreply, reload(socket)}
  def handle_info({:channel_updated, _}, socket), do: {:noreply, reload(socket)}

  def handle_info({:channel_setup_created, id}, socket),
    do:
      {:noreply,
       socket
       |> reload()
       |> push_patch(to: ~p"/app/settings/email?#{[channel: id]}")}

  def handle_info(:channel_setup_closed, socket),
    do: {:noreply, push_patch(socket, to: ~p"/app/settings/email")}

  defp finish(socket, {:ok, _}, message), do: socket |> reload() |> put_flash(:info, message)

  defp finish(socket, error, _),
    do: socket |> reload() |> put_flash(:error, EmailSetup.error_message(error))

  defp reload(socket) do
    tenant_id = socket.assigns.current_tenant.id
    connection = EmailSetup.connection(tenant_id)
    channels = EmailSetup.channels(tenant_id)

    socket
    |> assign(:connection, connection)
    |> assign(:routes, EmailSetup.routes(tenant_id))
    |> assign(
      :rejections,
      Enum.flat_map(
        EmailSetup.routes(tenant_id),
        &Custyard.InboundChannels.list_rejections_for_route(&1.id, limit: 50)
      )
    )
    |> assign(:channels, channels)
    |> assign(
      :customers,
      Custyard.Organizations.list(socket.assigns.current_scope)
    )
    |> assign(:projects, Custyard.Projects.list(socket.assigns.current_scope, []))
    |> assign(
      :labels,
      Custyard.Labels.list(socket.assigns.current_scope)
    )
    |> assign(
      :project_credential_status,
      EmailSetup.credential_status(tenant_id, "project_token")
    )
    |> assign(:team_credential_status, EmailSetup.credential_status(tenant_id, "team_token"))
    |> assign(:channel, Enum.find(channels, &(&1.id == socket.assigns.setup_channel_id)))
    |> assign(
      :credential_form,
      to_form(
        %{"project_id" => connection.project_id || "", "project_token" => "", "team_token" => ""},
        as: :connection
      )
    )
    |> assign(:status_url, EmailSetup.status_callback_url(connection))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl p-6 space-y-8" id="email-setup">
      <header>
        <h1 class="text-2xl font-semibold">Email setup</h1>
        <p class="mt-2 text-sm text-gray-600 dark:text-zinc-300">
          Connect a support address for {@current_tenant.name}. Keep your existing mailbox and forward a copy here. You can leave and resume these steps.
        </p>
      </header>
      <p :if={@busy} role="status" aria-live="polite">Checking with Lettermint…</p>

      <section class="space-y-3" aria-labelledby="credentials-title">
        <h2 id="credentials-title" class="text-lg font-semibold">1. Connect the email service</h2>
        <p class="text-sm">
          In Lettermint, select the project that will send replies and receive support mail. Inbound mail requires a supported plan (Starter or higher). Add and verify the support address's sending domain there.
        </p>
        <.form
          for={@credential_form}
          id="email-credentials"
          phx-submit="save_credentials"
          class="space-y-3"
        >
          <.input field={@credential_form[:project_id]} label="Lettermint project ID" required />
          <.input
            field={@credential_form[:project_token]}
            label="Project API token (sending)"
            type="password"
            autocomplete="new-password"
            placeholder={credential_placeholder(@project_credential_status)}
            aria-describedby="project-token-state"
          />
          <p id="project-token-state" class="text-xs">
            {credential_help(@project_credential_status)}
          </p>
          <.input
            field={@credential_form[:team_token]}
            label="Team API token (management)"
            type="password"
            autocomplete="new-password"
            placeholder={credential_placeholder(@team_credential_status)}
            aria-describedby="team-token-state"
          />
          <p id="team-token-state" class="text-xs">{credential_help(@team_credential_status)}</p>
          <p class="text-xs">
            Blank token fields keep the saved value. Tokens are encrypted and never shown again. Project tokens send email; Team tokens read projects, routes, domains and webhook configuration. Grant only the required abilities.
          </p>
          <.button disabled={@busy}>Save connection</.button>
        </.form>
        <p class="text-sm">
          Project token: {@project_credential_status}. Team token: {@team_credential_status}.
        </p>
        <button type="button" phx-click="check_connection" disabled={@busy} class="underline text-sm">Check credentials and project</button>
        <dl class="text-sm space-y-1">
          <div>
            <dt class="inline font-medium">Management project:</dt><dd class="inline">
              {@connection.project_check_status} {checked(@connection.project_checked_at)}
            </dd>
          </div>
          <div>
            <dt class="inline font-medium">Sending authentication:</dt><dd class="inline">
              {@connection.sending_check_status} {checked(@connection.sending_checked_at)}
            </dd>
          </div>
        </dl>
        <p class="text-xs">
          Authentication checks do not prove inbox delivery or that the sending token belongs to this project. Verify a real reply in step 4.
        </p>
        <a
          href="https://lettermint.co/docs/platform/teams/api-tokens"
          target="_blank"
          rel="noopener noreferrer"
          class="underline text-sm"
        >Create a Team token and choose its abilities</a>
      </section>

      <section class="space-y-3" aria-labelledby="inbound-title">
        <h2 id="inbound-title" class="text-lg font-semibold">2. Connect inbound delivery</h2>
        <p class="text-sm">
          In Lettermint, open your project → Routes → Create route and choose Inbound. Copy its route ID here. This imports an existing route without creating or changing provider resources.
        </p>
        <form phx-submit="import_route" id="import-email-route" class="flex gap-2 items-end">
          <.input name="route[id]" value="" label="Inbound route ID" required />
          <.button disabled={@busy}>Import route</.button>
        </form>
        <div
          :for={route <- @routes}
          id={"email-route-#{route.id}"}
          class="border rounded-lg p-4 space-y-3"
        >
          <p class="font-medium">{route.lettermint_route_domain}</p>
          <p class="text-sm">
            Imported route ID: <code class="break-all">{route.lettermint_route_id}</code>
          </p>
          <p class="text-sm">
            Open this inbound route's Webhooks screen in Lettermint. Create a route-scoped webhook using this complete URL and subscribe to message.inbound. Enable live deliveries and leave Basic Auth off.
          </p>
          <code class="block break-all text-xs">{Custyard.InboundRoutes.callback_url(route)}</code>
          <form phx-submit="bind_inbound" id={"bind-inbound-#{route.id}"} class="space-y-2">
            <input type="hidden" name="webhook[route_id]" value={route.id} />
            <.input
              id={"inbound-webhook-id-#{route.id}"}
              name="webhook[id]"
              value={route.lettermint_webhook_id || ""}
              label="Provider webhook ID"
              required
            />
            <.input
              id={"inbound-webhook-secret-#{route.id}"}
              name="webhook[secret]"
              value=""
              type="password"
              label="This webhook's signing secret"
              autocomplete="new-password"
              placeholder={
                if route.webhook_secret_ciphertext, do: "Saved securely", else: "Not saved yet"
              }
              aria-describedby={"inbound-secret-state-#{route.id}"}
              required
            />
            <.button disabled={@busy}>Verify binding and save secret</.button>
          </form>
          <p id={"inbound-secret-state-#{route.id}"} class="text-xs">
            {binding_secret_help(route.webhook_secret_ciphertext)}
          </p>
          <p class="text-sm">
            Signed message: {observed(route.webhook_verified_at)}.
          </p>
        </div>
        <p :if={@routes == []} class="text-sm" role="status">
          Import a real receiving route before adding a support address.
        </p>
        <a
          href="https://lettermint.co/docs/platform/inbound-mail/process-inbound-email"
          target="_blank"
          rel="noopener noreferrer"
          class="underline text-sm"
        >Lettermint inbound setup instructions</a>
      </section>

      <section class="space-y-3" aria-labelledby="address-title">
        <h2 id="address-title" class="text-lg font-semibold">3. Connect your support address</h2>
        <p class="text-sm">
          Forward a copy to the complete address shown in the channel wizard, including its +token. Keep the original in your mailbox. Your provider may send a confirmation here.
        </p>
        <button type="button" phx-click="new_channel" disabled={@routes == []} class="underline">Add support address</button>
        <article
          :for={channel <- @channels}
          data-testid={"channel-card-#{channel.id}"}
          class="border rounded p-3 space-y-3 text-sm"
        >
          <div class="flex justify-between">
            <span>{channel.public_address} · {channel.state}</span><button
              type="button"
              phx-click="resume_channel"
              phx-value-id={channel.id}
            >Resume setup</button>
          </div>
          <p>Last received: {channel.last_received_at || "No message yet"}</p>
          <span data-testid={"channel-provider-#{channel.id}"}>{if channel.ingress_kind == :imap,
            do: "IMAP mailbox",
            else:
              if(channel.ingress_kind == :mx,
                do: "Direct MX",
                else: to_string(channel.provider || channel.ingress_kind)
              )}</span>
          <p :if={channel.ingress_kind == :imap} data-testid={"channel-imap-#{channel.id}"}>
            Reads {channel.imap_folder || "INBOX"} of {channel.imap_username}
          </p>
          <p :if={channel.ingress_kind == :mx} data-testid={"channel-mx-#{channel.id}"}>
            Mail reaches this support address through its domain's MX record.
          </p>
          <div :if={channel.ingress_kind == :forward}>
            <code>{if MapSet.member?(@revealed_channel_ids, channel.id),
              do: Custyard.InboundChannels.ingress_address(channel),
              else: Custyard.InboundChannels.masked_ingress_address(channel)}</code>
            <button
              phx-click="reveal_channel"
              phx-value-id={channel.id}
              data-testid={"reveal-channel-#{channel.id}"}
            >Reveal forwarding address</button>
            <button
              phx-click="channel_action"
              phx-value-id={channel.id}
              phx-value-action="rotate"
              data-confirm="Rotate this forwarding token? Update your mailbox forwarding rule afterward."
              data-testid={"rotate-channel-#{channel.id}"}
            >Rotate token</button>
          </div>
          <div class="flex gap-3">
            <button
              :if={channel.state not in [:paused, :revoked]}
              phx-click="channel_action"
              phx-value-id={channel.id}
              phx-value-action="pause"
            >Pause</button>
            <button
              :if={channel.state == :paused}
              phx-click="channel_action"
              phx-value-id={channel.id}
              phx-value-action="resume"
            >Resume receiving</button>
            <button
              :if={channel.state != :revoked}
              phx-click="channel_action"
              phx-value-id={channel.id}
              phx-value-action="revoke"
              data-confirm="Revoke this support address? Inbound delivery will stop."
            >Revoke</button>
            <button
              phx-click="channel_action"
              phx-value-id={channel.id}
              phx-value-action="delete"
              data-confirm="Delete this support address and its configuration?"
            >Delete</button>
          </div>
          <form phx-submit="routing_defaults" class="space-y-2">
            <input type="hidden" name="channel[id]" value={channel.id} />
            <.input
              type="select"
              name="channel[default_organization_id]"
              value={channel.default_organization_id}
              label="Default customer"
              prompt="Resolve from sender"
              options={Enum.map(@customers, &{&1.name, &1.id})}
            />
            <.input
              type="select"
              name="channel[default_project_id]"
              value={channel.default_project_id}
              label="Default project"
              prompt="No project default"
              options={Enum.map(@projects, &{&1.title, &1.id})}
            />
            <.input
              type="select"
              name="channel[default_label_id]"
              value={channel.default_label_id}
              label="Default label"
              prompt="No label default"
              options={Enum.map(@labels, &{&1.name, &1.id})}
            />
            <p>
              Defaults apply only to new threads. Sender identity and existing threads take precedence.
            </p>
            <.button>Save routing defaults</.button>
          </form>
        </article>
        <form
          :if={@channels != []}
          phx-submit="set_default_channel"
          id="default-reply-channel"
          class="space-y-2"
        >
          <.input
            type="select"
            name="default_channel_id"
            value={@connection.default_channel_id}
            label="Default address for portal and form replies"
            prompt="Use the only active support address"
            options={
              for channel <- @channels,
                  channel.state == :active,
                  do: {channel.public_address, channel.id}
            }
          />
          <p class="text-xs">
            Email conversations keep their receiving address. Portal and form requests use this choice; if several addresses are active, choose one explicitly.
          </p>
          <.button>Save default address</.button>
        </form>
        <.live_component
          :if={@show_channel}
          module={CustyardWeb.Staff.ChannelSetupComponent}
          id="tenant-channel-setup"
          channel={@channel}
          routes={@routes}
          current_staff={@current_staff}
        />
      </section>

      <section :if={@rejections != []} class="space-y-3">
        <h2 class="font-semibold">Recent rejected deliveries</h2><p :for={rejection <- @rejections}>
          {rejection.inserted_at} · {rejection.classification} · {rejection.sender_email} · {rejection.subject}
        </p>
      </section>

      <section class="space-y-3" aria-labelledby="reply-title">
        <h2 id="reply-title" class="text-lg font-semibold">4. Verify replies and delivery events</h2>
        <p class="text-sm">
          In Lettermint Dashboard → Webhooks, create or edit a webhook. Set its scope to Projects and select this sending project. A webhook created for an outbound route may use Route scope; change it to Projects here so all sending routes are covered.
        </p>
        <p class="text-sm">
          Enable live deliveries, leave Basic Auth off, use this URL and select: {Enum.join(
            EmailSetup.status_events(),
            ", "
          )}.
        </p>
        <code class="block break-all text-xs">{@status_url}</code>
        <form phx-submit="bind_status" id="bind-status-webhook" class="space-y-2">
          <.input
            name="status[id]"
            value={@connection.status_webhook_id || ""}
            label="Status webhook ID"
            required
          />
          <.input
            name="status[secret]"
            value=""
            type="password"
            label="Status webhook signing secret"
            autocomplete="new-password"
            placeholder={
              if @connection.status_secret_ciphertext, do: "Saved securely", else: "Not saved yet"
            }
            aria-describedby="status-secret-state"
            required
          />
          <.button disabled={@busy}>Verify status binding and save secret</.button>
        </form>
        <p id="status-secret-state" class="text-xs">
          {binding_secret_help(@connection.status_secret_ciphertext)}
        </p>
        <p class="text-xs">
          Deliveries return 401 until the binding and this webhook's signing secret are saved successfully. Changing the scope keeps the same signing secret.
        </p>
        <p class="text-sm">
          Send a new message from an external mailbox to your support address. Open its conversation, send a reply, confirm it arrived, then reply back and confirm the same thread. A provider test event alone does not verify forwarding.
        </p>
        <dl class="text-sm space-y-1" aria-live="polite">
          <div>
            <dt class="inline font-medium">Signed customer email received:</dt><dd class="inline">
              {observed(@connection.last_signed_inbound_at)}
            </dd>
          </div>
          <div>
            <dt class="inline font-medium">Reply accepted by provider:</dt><dd class="inline">
              {observed(@connection.last_reply_accepted_at)}
            </dd>
          </div>
          <div>
            <dt class="inline font-medium">Reply delivery event:</dt><dd class="inline">
              {observed(@connection.last_reply_delivered_at)}
            </dd>
          </div>
          <div>
            <dt class="inline font-medium">Returning reply matched to the same conversation:</dt><dd class="inline">
              {observed(@connection.last_returning_reply_at)}
            </dd>
          </div>
        </dl>
        <.link
          :if={@connection.latest_received_conversation_id}
          navigate={~p"/app/threads/#{@connection.latest_received_conversation_id}"}
          class="underline text-sm"
        >Open the received conversation</.link>
        <p class="text-xs">
          Delivery means the recipient server accepted the message. Confirm inbox receipt and the returning reply yourself. If nothing arrives, inspect Lettermint activity, webhook delivery attempts and quarantine; silence alone is normal for a quiet support mailbox.
        </p>
      </section>
    </main>
    """
  end

  defp credential_placeholder(:missing), do: "Not saved yet"
  defp credential_placeholder(:saved), do: "Saved securely"

  defp credential_help(:missing), do: "No token saved yet."
  defp credential_help(:saved), do: "Saved securely. Leave blank to keep it."

  defp binding_secret_help(nil), do: "No signing secret saved yet."

  defp binding_secret_help(_ciphertext),
    do: "Saved securely. Enter the signing secret again only to recheck or change this binding."

  defp checked(nil), do: "(not checked)"
  defp checked(at), do: "(#{Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")})"
  defp observed(nil), do: "not observed yet"
  defp observed(at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
end
