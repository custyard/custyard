defmodule CustyardWeb.Operator.ChannelSetupComponent do
  @moduledoc """
  Guided setup for one inbound channel (spec-inbound-channels, "Operator
  onboarding"). Four steps, each resumable from the channel state:

  1. create: public address, route, how mail arrives, provider
  2. connect, by ingress kind (D8):
     - forward: ingress address plus provider instructions; waits for the
       provider confirmation captured by triage and shows the code or link
     - mx: the MX record to publish for the custom domain and a check that
       asks Lettermint whether it is in place
     - imap: connection status, the last error, and the mailbox settings;
       creating the channel already tries to connect
  3. test: send a test email; completes when the first delivery arrives
  4. reply identity: sending-domain check and, for forwarding channels, the
     ingress-address fallback and the archive copy

  The parent LiveView owns the data. It passes the current `channel` (nil
  for a new one) and reloads it on `{:channel_updated, id}`; this component
  tells the parent about a newly created channel with
  `{:channel_setup_created, id}` and about closing with
  `:channel_setup_closed`. Admin-only: the parent renders it only for
  operators who can manage the organization.
  """
  use CustyardWeb, :live_component

  alias Custyard.{InboundChannel, InboundChannels, InboundRoute}

  @ingress_kinds [
    {"forward", "Forward from an existing mailbox"},
    {"mx", "Direct MX on a dedicated subdomain"},
    {"imap", "Read a mailbox over IMAP"}
  ]

  @imap_fields ~w(imap_host imap_port imap_username imap_password imap_folder)

  @providers [
    {"google", "Gmail / Google Workspace (per-user forwarding)"},
    {"google_workspace", "Google Workspace (admin routing)"},
    {"proton", "Proton Mail"},
    {"other", "Other provider"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:step, 1)
     |> assign(:revealed_for, nil)
     |> assign(:previous_state, nil)
     |> assign(:form, to_form(InboundChannels.change_channel(%InboundChannel{}), as: :channel))
     |> assign(:local_flash, nil)}
  end

  @impl true
  def update(assigns, socket) do
    socket = assign(socket, assigns)
    channel = socket.assigns.channel

    socket =
      if is_nil(channel),
        do: assign(socket, step: 1, previous_state: nil),
        else: sync_step(socket, channel)

    {:ok, maybe_record_reveal(socket)}
  end

  # Follow the state machine when the channel moves, except that the first
  # delivery while the operator watches step 3 shows the success panel there
  # instead of jumping ahead; reopening an active channel lands on step 4.
  defp sync_step(socket, channel) do
    if channel.state == socket.assigns.previous_state do
      socket
    else
      step =
        if socket.assigns.step == 3 and channel.state == :active,
          do: 3,
          else: step_for_state(channel.state)

      socket
      |> assign(:step, step)
      |> assign(:previous_state, channel.state)
    end
  end

  # The full ingress address is shown on step 2 of a forwarding channel; D7
  # asks for an audit event each time it is revealed. Once per channel per
  # wizard session.
  defp maybe_record_reveal(socket) do
    %{channel: channel, step: step, revealed_for: revealed_for} = socket.assigns

    if (step == 2 and channel) && InboundChannel.forwarding?(channel) &&
         channel.id != revealed_for do
      InboundChannels.record_reveal(channel, operator: socket.assigns.current_operator)
      assign(socket, :revealed_for, channel.id)
    else
      socket
    end
  end

  defp step_for_state(:pending_verification), do: 2
  defp step_for_state(:awaiting_first_message), do: 3
  defp step_for_state(:active), do: 4
  defp step_for_state(:paused), do: 4
  defp step_for_state(:revoked), do: 4
  defp step_for_state(_state), do: 1

  # --- Events ---

  @impl true
  def handle_event("validate", %{"channel" => params}, socket) do
    changeset = InboundChannels.change_channel(%InboundChannel{}, params)
    {:noreply, assign(socket, :form, to_form(changeset, as: :channel, action: :validate))}
  end

  def handle_event("create", %{"channel" => params}, socket) do
    attrs =
      Map.take(params, ~w(public_address display_name ingress_kind provider) ++ @imap_fields)

    kind = Map.get(params, "ingress_kind", "forward")

    case selectable_route(socket.assigns.routes, Map.get(params, "inbound_route_id"), kind) do
      nil ->
        {:noreply,
         socket
         |> assign(
           :form,
           to_form(InboundChannels.change_channel(%InboundChannel{}, attrs), as: :channel)
         )
         |> put_flash_local(:error, "Choose a route that can carry this channel")}

      route ->
        case InboundChannels.create_channel(route, attrs,
               operator: socket.assigns.current_operator
             ) do
          {:ok, channel} ->
            send(self(), {:channel_setup_created, channel.id})

            socket =
              socket
              |> assign(:channel, channel)
              |> assign(:previous_state, channel.state)
              |> assign(:step, 2)
              |> assign(:local_flash, nil)
              |> maybe_record_reveal()

            if channel.ingress_kind == :imap,
              do: handle_event("connect_imap", %{}, socket),
              else: {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, :form, to_form(changeset, as: :channel, action: :insert))}
        end
    end
  end

  def handle_event("confirm_forwarding", _params, socket) do
    with_channel(socket, fn channel ->
      InboundChannels.confirm_verification(channel, operator: socket.assigns.current_operator)
    end)
  end

  def handle_event("check_mx", _params, socket) do
    with_channel(socket, fn channel ->
      case InboundChannels.check_mx(channel, operator: socket.assigns.current_operator) do
        {:ok, %InboundChannel{state: :pending_verification}, result} ->
          {:error, mx_failure_message(result)}

        {:ok, channel, _result} ->
          {:ok, channel}

        {:error, %Ecto.Changeset{}} = error ->
          error

        {:error, reason} ->
          {:error, "MX check failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle_event("connect_imap", _params, socket) do
    with_channel(socket, fn channel ->
      case InboundChannels.connect_imap(channel, operator: socket.assigns.current_operator) do
        {:ok, _channel} = ok -> ok
        {:error, code} when is_binary(code) -> {:error, imap_error_text(code)}
        {:error, %Ecto.Changeset{}} = error -> error
      end
    end)
  end

  def handle_event("save_imap", %{"channel" => params}, socket) do
    attrs =
      params
      |> Map.take(@imap_fields)
      |> Map.reject(fn {key, value} -> key == "imap_password" and value == "" end)

    case InboundChannels.update_channel(socket.assigns.channel, attrs,
           operator: socket.assigns.current_operator
         ) do
      {:ok, channel} ->
        handle_event("connect_imap", %{}, assign(socket, :channel, channel))

      {:error, changeset} ->
        {:noreply, put_flash_local(socket, :error, changeset_message(changeset))}
    end
  end

  def handle_event("check_domain", _params, socket) do
    with_channel(socket, fn channel ->
      case InboundChannels.check_sending_domain(channel,
             operator: socket.assigns.current_operator
           ) do
        {:ok, _} = ok -> ok
        {:error, reason} -> {:error, "Domain check failed: #{inspect(reason)}"}
      end
    end)
  end

  def handle_event("set_reply_from", %{"reply_from" => value}, socket)
      when value in ~w(public_address ingress_address) do
    with_channel(socket, fn channel ->
      InboundChannels.update_channel(channel, %{reply_from: value},
        operator: socket.assigns.current_operator
      )
    end)
  end

  def handle_event("set_archive_copy", params, socket) do
    enabled? = Map.get(params, "archive_copy") in ["true", "on"]

    with_channel(socket, fn channel ->
      InboundChannels.update_channel(channel, %{archive_copy: enabled?},
        operator: socket.assigns.current_operator
      )
    end)
  end

  def handle_event("set_attachment_limit", %{"attachment_limit_mb" => value}, socket) do
    with_channel(socket, fn channel ->
      InboundChannels.update_channel(channel, %{attachment_limit_mb: value},
        operator: socket.assigns.current_operator
      )
    end)
  end

  def handle_event("goto_step", %{"step" => step}, socket) do
    case {Integer.parse(step), socket.assigns.channel} do
      {{n, ""}, %InboundChannel{}} when n in 2..4 ->
        {:noreply, socket |> assign(:step, n) |> maybe_record_reveal()}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("close", _params, socket) do
    send(self(), :channel_setup_closed)
    {:noreply, socket}
  end

  defp mx_failure_message(result) do
    found =
      case result["found_mx_records"] do
        [_ | _] = records -> "Lettermint found #{Enum.join(records, ", ")}."
        _ -> "Lettermint found no MX record."
      end

    "Not verified yet. #{found} DNS changes can take a while to propagate; check again later."
  end

  defp with_channel(%{assigns: %{channel: nil}} = socket, _fun), do: {:noreply, socket}

  defp with_channel(socket, fun) do
    case fun.(socket.assigns.channel) do
      {:ok, %InboundChannel{} = channel} ->
        channel = Custyard.Repo.preload(channel, [:inbound_route, :project])

        socket =
          socket
          |> assign(:channel, channel)
          |> assign(:local_flash, nil)
          |> sync_step(channel)

        {:noreply, socket}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash_local(socket, :error, changeset_message(changeset))}

      {:error, message} when is_binary(message) ->
        {:noreply, put_flash_local(socket, :error, message)}
    end
  end

  # Flash inside the component: the parent's flash would survive closing the
  # wizard, and these messages belong to the step they came from.
  defp put_flash_local(socket, kind, message), do: assign(socket, :local_flash, {kind, message})

  defp changeset_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
    |> Enum.map_join(", ", fn {field, msgs} -> "#{field} #{Enum.join(msgs, ", ")}" end)
  end

  defp selectable_route(routes, route_id, kind) when is_binary(route_id) do
    case Integer.parse(route_id) do
      {id, ""} -> Enum.find(routes, &(&1.id == id and route_selectable?(&1, kind)))
      _ -> nil
    end
  end

  defp selectable_route(_routes, _route_id, _kind), do: nil

  # IMAP mail never passes through Lettermint, so any mail route scopes it;
  # forwarding and direct MX need a Lettermint route with its domain synced.
  defp route_selectable?(route, "imap"), do: route.source in [:lettermint, :email]

  defp route_selectable?(route, _kind),
    do: route.source == :lettermint and not is_nil(InboundRoute.ingress_domain(route))

  # --- Render ---

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:steps, steps(assigns.channel))
      |> assign(:providers, @providers)
      |> assign(:ingress_kinds, @ingress_kinds)

    ~H"""
    <div
      class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-indigo-300 dark:border-indigo-600 space-y-4"
      data-testid="channel-setup"
    >
      <div class="flex items-start justify-between gap-4">
        <div>
          <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100">
            {if @channel, do: "Channel setup: #{@channel.public_address}", else: "New channel"}
          </h3>
          <p class="text-xs text-gray-500 dark:text-zinc-400 mt-0.5">
            Connect a support address to Custyard. Each step picks up where the channel left off.
          </p>
        </div>
        <button
          type="button"
          phx-click="close"
          phx-target={@myself}
          class="text-xs text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-100"
          data-testid="channel-setup-close"
        >
          Close
        </button>
      </div>

      <.progress steps={@steps} step={@step} channel={@channel} myself={@myself} />

      <p
        :if={@local_flash}
        class={[
          "text-xs rounded px-2 py-1.5",
          elem(@local_flash, 0) == :error &&
            "text-red-700 dark:text-red-300 bg-red-50 dark:bg-red-950",
          elem(@local_flash, 0) != :error &&
            "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"
        ]}
        role="alert"
        data-testid="channel-setup-flash"
      >
        {elem(@local_flash, 1)}
      </p>

      <%= case @step do %>
        <% 1 -> %>
          <.create_step
            form={@form}
            routes={@routes}
            providers={@providers}
            ingress_kinds={@ingress_kinds}
            myself={@myself}
          />
        <% 2 -> %>
          <%= case @channel.ingress_kind do %>
            <% :mx -> %>
              <.dns_step channel={@channel} myself={@myself} />
            <% :imap -> %>
              <.imap_step channel={@channel} myself={@myself} />
            <% _forward -> %>
              <.forward_step channel={@channel} myself={@myself} />
          <% end %>
        <% 3 -> %>
          <.test_step channel={@channel} />
        <% 4 -> %>
          <.reply_step channel={@channel} myself={@myself} />
      <% end %>
    </div>
    """
  end

  attr :steps, :list, required: true
  attr :step, :integer, required: true
  attr :channel, :any, required: true
  attr :myself, :any, required: true

  defp progress(assigns) do
    ~H"""
    <ol class="flex flex-wrap items-center gap-2 text-xs" data-testid="channel-setup-progress">
      <li :for={{number, _key, label} <- @steps} class="flex items-center gap-2">
        <button
          type="button"
          phx-click="goto_step"
          phx-value-step={number}
          phx-target={@myself}
          disabled={is_nil(@channel) or number == 1}
          aria-current={if number == @step, do: "step", else: nil}
          class={[
            "inline-flex items-center gap-1.5 px-2 py-1 rounded border",
            number == @step &&
              "border-indigo-500 text-indigo-700 dark:text-indigo-300 bg-indigo-50 dark:bg-indigo-950",
            (number != @step and step_done?(@channel, number)) &&
              "border-green-200 dark:border-green-800 text-green-700 dark:text-green-300",
            (number != @step and not step_done?(@channel, number)) &&
              "border-gray-200 dark:border-zinc-700 text-gray-500 dark:text-zinc-400",
            (is_nil(@channel) or number == 1) && "cursor-default"
          ]}
          data-testid={"channel-setup-step-#{number}"}
        >
          <span class="font-semibold">{number}</span>
          <span>{label}</span>
        </button>
        <span :if={number < 4} class="text-gray-300 dark:text-zinc-600" aria-hidden="true">
          &rarr;
        </span>
      </li>
      <li :if={@channel} class="ml-auto">
        <.channel_state_badge state={@channel.state} id={@channel.id} />
      </li>
    </ol>
    """
  end

  defp steps(%InboundChannel{ingress_kind: :mx}),
    do: [{1, :create, "Address"}, {2, :dns, "DNS"}, {3, :test, "Test"}, {4, :reply, "Replies"}]

  defp steps(%InboundChannel{ingress_kind: :imap}),
    do: [
      {1, :create, "Address"},
      {2, :connect, "Connect"},
      {3, :test, "Test"},
      {4, :reply, "Replies"}
    ]

  defp steps(_channel),
    do: [
      {1, :create, "Address"},
      {2, :forward, "Forward"},
      {3, :test, "Test"},
      {4, :reply, "Replies"}
    ]

  defp step_done?(nil, _number), do: false
  defp step_done?(_channel, 1), do: true

  defp step_done?(%{state: state}, 2),
    do: state in [:awaiting_first_message, :active]

  defp step_done?(%{state: :active}, 3), do: true
  defp step_done?(%{sending_domain_status: "verified"}, 4), do: true
  defp step_done?(%{reply_from: :ingress_address}, 4), do: true
  defp step_done?(_channel, _number), do: false

  # --- Step 1: create ---

  attr :form, :any, required: true
  attr :routes, :list, required: true
  attr :providers, :list, required: true
  attr :ingress_kinds, :list, required: true
  attr :myself, :any, required: true

  defp create_step(assigns) do
    assigns = assign(assigns, :kind, to_string(assigns.form[:ingress_kind].value || "forward"))

    ~H"""
    <.form
      for={@form}
      id="channel-create-form"
      phx-change="validate"
      phx-submit="create"
      phx-target={@myself}
      class="space-y-3"
      data-testid="channel-create-form"
    >
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div>
          <label
            for={@form[:public_address].id}
            class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Public address
          </label>
          <input
            type="email"
            id={@form[:public_address].id}
            name={@form[:public_address].name}
            value={@form[:public_address].value}
            placeholder="support@companyname.com"
            required
            class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-public-address"
          />
          <.field_errors field={@form[:public_address]} />
        </div>
        <div>
          <label
            for={@form[:display_name].id}
            class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Display name (optional)
          </label>
          <input
            type="text"
            id={@form[:display_name].id}
            name={@form[:display_name].name}
            value={@form[:display_name].value}
            placeholder="Acme Support"
            maxlength="100"
            class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-display-name"
          />
          <.field_errors field={@form[:display_name]} />
        </div>
        <div>
          <label
            for="channel-route-select"
            class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Route
          </label>
          <select
            id="channel-route-select"
            name="channel[inbound_route_id]"
            required
            class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-route-select"
          >
            <option
              :for={route <- @routes}
              value={route.id}
              disabled={not route_selectable?(route, @kind)}
              data-testid={"channel-route-option-#{route.id}"}
            >
              {route_label(route, @kind)}
            </option>
          </select>
          <p class="mt-1 text-xs text-gray-500 dark:text-zinc-400">
            Organization-wide channels use the general route; project channels use that project's route.
          </p>
        </div>
        <div>
          <label
            for={@form[:ingress_kind].id}
            class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            How mail arrives
          </label>
          <select
            id={@form[:ingress_kind].id}
            name={@form[:ingress_kind].name}
            class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-ingress-kind-select"
          >
            <option :for={{value, label} <- @ingress_kinds} value={value} selected={@kind == value}>
              {label}
            </option>
          </select>
          <p
            :if={@kind == "mx"}
            class="mt-1 text-xs text-gray-500 dark:text-zinc-400"
            data-testid="channel-mx-hint"
          >
            Customers write straight to an address on a subdomain whose MX record points at
            Lettermint, such as support@help.companyname.com. Use a subdomain no mailbox uses.
          </p>
          <.field_errors field={@form[:ingress_kind]} />
        </div>
        <div :if={@kind == "forward"}>
          <label
            for={@form[:provider].id}
            class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Mail provider
          </label>
          <select
            id={@form[:provider].id}
            name={@form[:provider].name}
            class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-provider-select"
          >
            <option
              :for={{value, label} <- @providers}
              value={value}
              selected={to_string(@form[:provider].value) == value}
            >
              {label}
            </option>
          </select>
          <.field_errors field={@form[:provider]} />
        </div>
      </div>
      <.imap_fields :if={@kind == "imap"} form={@form} />
      <div class="flex justify-end">
        <button
          type="submit"
          class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
          data-testid="channel-create-submit"
        >
          Create channel
        </button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :heading, :boolean, default: true

  defp imap_fields(assigns) do
    ~H"""
    <fieldset class="space-y-2" data-testid="channel-imap-fields">
      <p :if={@heading} class="text-xs text-gray-500 dark:text-zinc-400">
        Custyard reads one folder read-only over TLS: it never marks, moves or deletes mail, and
        starts with mail that arrives after it connects. Use an app password. Microsoft 365 and
        Outlook.com only allow OAuth and Proton only offers IMAP through the local Bridge; use
        forwarding for those.
      </p>
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <.imap_input
          form={@form}
          field={:imap_host}
          label="IMAP server"
          placeholder="imap.fastmail.com"
        />
        <.imap_input
          form={@form}
          field={:imap_port}
          label="Port (TLS)"
          type="number"
          placeholder="993"
        />
        <.imap_input
          form={@form}
          field={:imap_username}
          label="Username"
          placeholder="support@companyname.com"
        />
        <.imap_input
          form={@form}
          field={:imap_password}
          label="App password"
          type="password"
          placeholder={if @heading, do: "", else: "unchanged"}
        />
        <.imap_input form={@form} field={:imap_folder} label="Folder" placeholder="INBOX" />
      </div>
    </fieldset>
    """
  end

  attr :form, :any, required: true
  attr :field, :atom, required: true
  attr :label, :string, required: true
  attr :type, :string, default: "text"
  attr :placeholder, :string, default: nil

  defp imap_input(assigns) do
    assigns = assign(assigns, :f, assigns.form[assigns.field])

    ~H"""
    <div>
      <label for={@f.id} class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
        {@label}
      </label>
      <input
        type={@type}
        id={@f.id}
        name={@f.name}
        value={if @type == "password", do: "", else: @f.value}
        placeholder={@placeholder}
        autocomplete={if @type == "password", do: "new-password", else: "off"}
        class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
        data-testid={"channel-#{String.replace(to_string(@field), "_", "-")}"}
      />
      <.field_errors field={@f} />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp field_errors(assigns) do
    errors =
      if Phoenix.Component.used_input?(assigns.field),
        do: assigns.field.errors,
        else: []

    assigns = assign(assigns, :errors, errors)

    ~H"""
    <p
      :for={{msg, _opts} <- @errors}
      class="mt-1 text-xs text-red-600 dark:text-red-400"
      data-testid={"channel-error-#{@field.field}"}
    >
      {msg}
    </p>
    """
  end

  defp route_label(route, kind) do
    scope =
      case route do
        %{route_type: :general} -> "Organization-wide"
        %{project: %{title: title}} -> title
        %{route_type: type} -> to_string(type)
      end

    cond do
      not route_selectable?(route, kind) -> "#{scope} (domain not synced)"
      kind == "imap" -> scope
      true -> "#{scope} (@#{InboundRoute.ingress_domain(route)})"
    end
  end

  # --- Step 2: forward ---

  attr :channel, :any, required: true
  attr :myself, :any, required: true

  defp forward_step(assigns) do
    channel = assigns.channel
    now = DateTime.utc_now()

    assigns =
      assigns
      |> assign(:ingress_address, InboundChannels.ingress_address(channel))
      |> assign(:verification_live, InboundChannel.verification_valid?(channel, now))

    ~H"""
    <div class="space-y-4" data-testid="channel-forward-step">
      <section>
        <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
          1. Forward {@channel.public_address} to this address
        </h4>
        <div class="flex items-center gap-2">
          <code
            class="flex-1 text-sm bg-gray-50 dark:bg-zinc-900 text-gray-800 dark:text-zinc-200 px-2 py-1.5 rounded border border-gray-200 dark:border-zinc-700 break-all"
            data-testid="channel-setup-ingress-address"
          >
            {@ingress_address || "Ingress domain not synced yet"}
          </code>
          <button
            :if={@ingress_address}
            type="button"
            id={"copy-setup-ingress-#{@channel.id}"}
            phx-hook="CopyToClipboard"
            data-clipboard-text={@ingress_address}
            class="text-xs px-2 py-1.5 text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors whitespace-nowrap"
            data-testid="channel-setup-copy-ingress"
          >
            Copy
          </button>
        </div>
      </section>

      <.provider_instructions provider={@channel.provider} />

      <section
        :if={@channel.provider == :google_workspace}
        class="rounded border border-gray-200 dark:border-zinc-700 p-3 text-sm text-gray-600 dark:text-zinc-400"
        data-testid="channel-verification-none"
      >
        Admin routing sends no confirmation email. Confirm below once the rule is saved; the first
        message to {@channel.public_address} also completes this step.
      </section>

      <section
        :if={@channel.provider != :google_workspace}
        class="rounded border border-gray-200 dark:border-zinc-700 p-3"
        data-testid="channel-verification-panel"
      >
        <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
          2. Confirmation from your provider
        </h4>
        <%= if @verification_live do %>
          <p class="text-sm text-gray-800 dark:text-zinc-200">
            Confirmation received. Finish the step in your mail provider:
          </p>
          <dl class="mt-2 space-y-1 text-sm">
            <div :if={@channel.verification_code} class="flex items-center gap-2">
              <dt class="text-gray-500 dark:text-zinc-400">Code</dt>
              <dd>
                <code
                  class="font-mono text-base text-gray-900 dark:text-zinc-100 bg-gray-50 dark:bg-zinc-900 px-2 py-0.5 rounded"
                  data-testid="channel-verification-code"
                >
                  {@channel.verification_code}
                </code>
              </dd>
            </div>
            <div :if={@channel.verification_link} class="flex items-center gap-2">
              <dt class="text-gray-500 dark:text-zinc-400">Link</dt>
              <dd>
                <a
                  href={@channel.verification_link}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="text-indigo-600 dark:text-indigo-400 underline break-all"
                  data-testid="channel-verification-link"
                >
                  Open the confirmation link
                </a>
              </dd>
            </div>
          </dl>
          <p class="mt-2 text-xs text-gray-500 dark:text-zinc-400">
            The code expires 24 hours after it was received.
          </p>
        <% else %>
          <p
            class="text-sm text-gray-600 dark:text-zinc-400"
            data-testid="channel-verification-waiting"
          >
            Waiting for the confirmation email. It is delivered to the ingress address and appears here
            as soon as it arrives; nothing to do until then.
          </p>
        <% end %>
      </section>

      <div class="flex justify-end">
        <button
          type="button"
          phx-click="confirm_forwarding"
          phx-target={@myself}
          class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
          data-testid="channel-confirm-forwarding"
        >
          I've confirmed forwarding
        </button>
      </div>
    </div>
    """
  end

  # --- Step 2 (IMAP): connect ---

  attr :channel, :any, required: true
  attr :myself, :any, required: true

  defp imap_step(assigns) do
    channel = assigns.channel

    assigns =
      assigns
      |> assign(:connected, not is_nil(channel.imap_uid_validity))
      |> assign(:form, to_form(InboundChannels.change_channel(channel), as: :channel))

    ~H"""
    <div class="space-y-4" data-testid="channel-imap-step">
      <section
        class="rounded border border-gray-200 dark:border-zinc-700 p-3 space-y-1 text-sm"
        data-testid="channel-imap-status"
      >
        <p :if={@connected} class="text-gray-800 dark:text-zinc-200">
          Connected to {@channel.imap_host} as {@channel.imap_username}, reading {@channel.imap_folder}. Mail that arrives from now on is imported every minute.
        </p>
        <p :if={not @connected} class="text-gray-600 dark:text-zinc-400">
          Not connected yet.
        </p>
        <p
          :if={@channel.imap_last_error}
          class="text-red-700 dark:text-red-300"
          data-testid="channel-imap-error"
        >
          {imap_error_text(@channel.imap_last_error)}
        </p>
        <p
          :if={@channel.imap_auth_failed_at}
          class="text-red-700 dark:text-red-300"
          data-testid="channel-imap-suspended"
        >
          Polling stopped after repeated login failures. Enter the password again to resume.
        </p>
      </section>

      <.form
        for={@form}
        id={"channel-imap-form-#{@channel.id}"}
        phx-submit="save_imap"
        phx-target={@myself}
        class="space-y-3"
      >
        <.imap_fields form={@form} heading={false} />
        <p class="text-xs text-gray-500 dark:text-zinc-400">
          Leave the password empty to keep the stored one. Changing the server, username or folder
          starts again from the newest message.
        </p>
        <div class="flex justify-end gap-2">
          <button
            type="button"
            phx-click="connect_imap"
            phx-target={@myself}
            class="px-3 py-1.5 text-sm text-indigo-600 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700 rounded-md hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors"
            data-testid="channel-imap-test"
          >
            Test connection
          </button>
          <button
            type="submit"
            class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
            data-testid="channel-imap-save"
          >
            Save and connect
          </button>
        </div>
      </.form>
    </div>
    """
  end

  @doc "Operator-facing text for an IMAP error code (`Custyard.Email.ImapPoll.error_code/1`)."
  def imap_error_text("auth_failed"), do: "The server rejected the username or password."

  def imap_error_text("folder_unavailable"),
    do: "The folder does not exist or cannot be opened."

  def imap_error_text("disallowed_host"),
    do: "The server name points at a private or reserved address."

  def imap_error_text("unresolvable"), do: "The server name does not resolve."

  def imap_error_text("credentials_unreadable"),
    do: "The stored password cannot be decrypted with the current key. Enter it again."

  def imap_error_text("timeout"), do: "The server did not answer in time."
  def imap_error_text("tls_failed"), do: "The TLS connection failed (certificate or protocol)."

  def imap_error_text("fetch_failed"),
    do: "Reading a message failed. The next poll tries again."

  def imap_error_text(_code), do: "Could not connect to the server."

  # --- Step 2 (direct MX): DNS ---

  attr :channel, :any, required: true
  attr :myself, :any, required: true

  defp dns_step(assigns) do
    assigns = assign(assigns, :domain, InboundChannel.public_domain(assigns.channel))

    ~H"""
    <div class="space-y-4" data-testid="channel-dns-step">
      <section class="space-y-2">
        <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
          1. Publish this record at your DNS provider
        </h4>
        <div class="overflow-x-auto">
          <table class="text-sm" data-testid="channel-mx-record">
            <thead>
              <tr class="text-left text-xs text-gray-500 dark:text-zinc-400">
                <th class="pr-4 font-medium">Type</th>
                <th class="pr-4 font-medium">Host</th>
                <th class="pr-4 font-medium">Priority</th>
                <th class="font-medium">Value</th>
              </tr>
            </thead>
            <tbody class="font-mono text-gray-900 dark:text-zinc-100">
              <tr>
                <td class="pr-4">MX</td>
                <td class="pr-4 break-all">{@domain}</td>
                <td class="pr-4">10</td>
                <td>lettermint.mx</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p class="text-xs text-gray-500 dark:text-zinc-400">
          Some DNS providers want only the host part. Add no other MX records for {@domain}: every
          message to that domain then arrives in Custyard, so it must not be a domain a mailbox uses.
        </p>
      </section>

      <section class="rounded border border-gray-200 dark:border-zinc-700 p-3 space-y-2">
        <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">2. Check the record</h4>
        <p class="text-sm text-gray-600 dark:text-zinc-400">
          Lettermint looks the record up when you check. The first message to {@channel.public_address} also completes this step on its own.
        </p>
        <div class="flex justify-end">
          <button
            type="button"
            phx-click="check_mx"
            phx-target={@myself}
            class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
            data-testid="channel-check-mx"
          >
            Check MX record
          </button>
        </div>
      </section>
    </div>
    """
  end

  attr :provider, :atom, required: true

  defp provider_instructions(%{provider: :google} = assigns) do
    ~H"""
    <section
      class="text-sm text-gray-700 dark:text-zinc-300 space-y-1"
      data-testid="channel-provider-help"
    >
      <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
        In Gmail / Google Workspace
      </h4>
      <ol class="list-decimal list-inside space-y-0.5">
        <li>Settings &rsaquo; See all settings &rsaquo; Forwarding and POP/IMAP.</li>
        <li>Add a forwarding address and paste the ingress address above.</li>
        <li>
          Google emails a confirmation code to that address. It lands in Custyard and appears below;
          enter the code back in Gmail, then choose "Forward a copy" and keep the original in your inbox.
        </li>
      </ol>
      <p class="text-xs text-gray-500 dark:text-zinc-400">
        Workspace admins can block per-user forwarding. If the forwarding option is missing, create the
        channel with "Google Workspace (admin routing)" instead.
      </p>
    </section>
    """
  end

  defp provider_instructions(%{provider: :google_workspace} = assigns) do
    ~H"""
    <section
      class="text-sm text-gray-700 dark:text-zinc-300 space-y-2"
      data-testid="channel-provider-help"
    >
      <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
        In the Google Admin console (Gmail settings administrator)
      </h4>
      <ol class="list-decimal list-inside space-y-0.5">
        <li>
          Apps &rsaquo; Google Workspace &rsaquo; Gmail &rsaquo; Default routing &rsaquo; Configure.
        </li>
        <li>
          Under "Specify envelope recipients to match", choose Single recipient and enter the public
          address.
        </li>
        <li>
          Choose Modify message, then Add more recipients &rsaquo; Add, and enter the full ingress
          address above, including the part after the +. Do not use Change envelope recipient: that
          takes the message out of the mailbox.
        </li>
        <li>
          Choose "Perform this action on non-recognized and recognized addresses" and save. Google says
          changes can take up to 24 hours.
        </li>
      </ol>
      <p class="text-xs text-gray-500 dark:text-zinc-400">
        The mailbox keeps its copy and Custyard receives a second one. If a test message does not
        arrive, check the organization's rejection log: a copy delivered without the + part of the
        ingress address is logged there as "no matching channel".
      </p>
    </section>
    """
  end

  defp provider_instructions(%{provider: :proton} = assigns) do
    ~H"""
    <section
      class="text-sm text-gray-700 dark:text-zinc-300 space-y-2"
      data-testid="channel-provider-help"
    >
      <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
        In Proton Mail (paid plan required)
      </h4>
      <ol class="list-decimal list-inside space-y-0.5">
        <li>Settings &rsaquo; Auto forward &rsaquo; Add forwarding rule.</li>
        <li>Enter the ingress address above and save.</li>
        <li>
          Proton sends an "Accept forwarding" email to that address. It lands in Custyard and appears
          below; open the link to accept.
        </li>
      </ol>
      <p
        class="rounded border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200 px-3 py-2 text-sm"
        role="note"
        data-testid="channel-proton-e2ee-notice"
      >
        Forwarding to an address outside Proton disables end-to-end encryption for all mail to and
        from this Proton address. Mail is still encrypted in transit, but Proton can no longer
        store it zero-access.
      </p>
    </section>
    """
  end

  defp provider_instructions(assigns) do
    ~H"""
    <section
      class="text-sm text-gray-700 dark:text-zinc-300 space-y-1"
      data-testid="channel-provider-help"
    >
      <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">In your mail provider</h4>
      <p>
        Create a forwarding rule from the public address to the ingress address above, keeping the
        original in the mailbox. If the provider sends a confirmation email to the destination, it
        appears below.
      </p>
    </section>
    """
  end

  # --- Step 3: test ---

  attr :channel, :any, required: true

  defp test_step(assigns) do
    ~H"""
    <div class="space-y-3" data-testid="channel-test-step">
      <%= if @channel.state == :active do %>
        <div
          class="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950 px-3 py-2 text-sm text-green-800 dark:text-green-200"
          data-testid="channel-setup-complete"
        >
          First message received. {arrival_text(@channel)} and the channel is active.
        </div>
      <% else %>
        <p class="text-sm text-gray-700 dark:text-zinc-300" data-testid="channel-test-prompt">
          Send a test email to
          <code class="text-gray-900 dark:text-zinc-100">{@channel.public_address}</code>
          from any other mailbox. This panel updates when it arrives.
        </p>
        <p class="text-xs text-gray-500 dark:text-zinc-400">
          A pass on the authentication badge does not make a request safe to act on; account changes
          still need out-of-band verification.
        </p>
      <% end %>
    </div>
    """
  end

  defp arrival_text(%InboundChannel{ingress_kind: :mx}), do: "The MX record works"
  defp arrival_text(%InboundChannel{ingress_kind: :imap}), do: "Reading the mailbox works"
  defp arrival_text(_channel), do: "Forwarding works"

  # --- Step 4: reply identity ---

  attr :channel, :any, required: true
  attr :myself, :any, required: true

  defp reply_step(assigns) do
    channel = assigns.channel

    assigns =
      assigns
      |> assign(:summary, InboundChannels.sending_domain_summary(channel))
      |> assign(:domain, InboundChannel.public_domain(channel))
      |> assign(:ingress_address, InboundChannels.ingress_address(channel))
      |> assign(:data_path, data_path_text(channel))

    ~H"""
    <div class="space-y-4" data-testid="channel-reply-step">
      <section class="rounded border border-gray-200 dark:border-zinc-700 p-3 space-y-2">
        <div class="flex items-center justify-between gap-2">
          <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
            Sending domain: {@domain}
          </h4>
          <div class="flex items-center gap-2">
            <.sending_domain_pill summary={@summary} id={@channel.id} />
            <button
              type="button"
              phx-click="check_domain"
              phx-target={@myself}
              class="text-xs px-2 py-1 text-indigo-600 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors"
              data-testid="channel-setup-check-domain"
            >
              Check domain
            </button>
          </div>
        </div>
        <p class="text-sm text-gray-700 dark:text-zinc-300" data-testid="channel-domain-explanation">
          <%= case @summary do %>
            <% :verified -> %>
              Replies go out as {@channel.public_address}. Customers answer the address they wrote to.
            <% :unchecked -> %>
              Not checked yet. Replies are sent as {@channel.public_address} once the domain is verified in Lettermint.
            <% _ -> %>
              <%= if InboundChannel.forwarding?(@channel) do %>
                {@domain} is not a verified sending domain in Lettermint. Add the DKIM CNAME records and the
                SPF include for the root domain in Lettermint, then check again. Until then, replies from
                the public address will fail authentication; the fallback below replies from the ingress
                address instead.
              <% else %>
                {@domain} is not a verified sending domain in Lettermint. Add it in Lettermint with its
                DKIM CNAME records and SPF include, then check again. Until then, replies from {@channel.public_address} will fail authentication.
              <% end %>
          <% end %>
        </p>
        <label
          :if={InboundChannel.forwarding?(@channel)}
          class="flex items-start gap-2 text-sm text-gray-700 dark:text-zinc-300"
        >
          <input
            type="checkbox"
            name="reply_from"
            phx-click="set_reply_from"
            phx-target={@myself}
            phx-value-reply_from={
              if @channel.reply_from == :ingress_address,
                do: "public_address",
                else: "ingress_address"
            }
            checked={@channel.reply_from == :ingress_address}
            class="mt-0.5 rounded border-gray-300 dark:border-zinc-600 dark:bg-zinc-700"
            data-testid="channel-reply-from-toggle"
          />
          <span>
            Reply from the ingress address instead.
            <span class="text-xs text-gray-500 dark:text-zinc-400">
              Customers will then see {@ingress_address || "the ingress address"} as the sender and their
              replies go straight to Custyard, bypassing your mailbox.
            </span>
          </span>
        </label>
      </section>

      <section class="rounded border border-gray-200 dark:border-zinc-700 p-3 space-y-3">
        <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">Mailbox and attachments</h4>
        <%!-- D4: archive copy, admin-only, audited through update_channel. A
             direct-MX channel has no mailbox to keep the copy in. --%>
        <label
          :if={@channel.ingress_kind != :mx}
          class="flex items-start gap-2 text-sm text-gray-700 dark:text-zinc-300"
        >
          <input
            type="checkbox"
            name="archive_copy"
            phx-click="set_archive_copy"
            phx-target={@myself}
            phx-value-archive_copy={if @channel.archive_copy, do: "false", else: "true"}
            checked={@channel.archive_copy}
            class="mt-0.5 rounded border-gray-300 dark:border-zinc-600 dark:bg-zinc-700"
            data-testid="channel-archive-copy-toggle"
          />
          <span>
            Keep a copy of replies in {@channel.public_address}.
            <span class="text-xs text-gray-500 dark:text-zinc-400">
              Each reply is BCC'd to the public address so your mailbox holds both sides. The copy
              comes back here and is recognised as your own message.
            </span>
          </span>
        </label>
        <%!-- D9: per-message attachment cap. --%>
        <form
          id={"attachment-limit-form-#{@channel.id}"}
          phx-change="set_attachment_limit"
          phx-target={@myself}
          class="flex items-center gap-2 text-sm text-gray-700 dark:text-zinc-300"
        >
          <label for={"attachment-limit-#{@channel.id}"}>Fetch attachments up to</label>
          <input
            id={"attachment-limit-#{@channel.id}"}
            type="number"
            name="attachment_limit_mb"
            min="0"
            max="100"
            value={@channel.attachment_limit_mb}
            phx-debounce="400"
            class="w-20 border border-gray-300 dark:border-zinc-600 rounded px-2 py-1 text-sm dark:bg-zinc-700 dark:text-zinc-100"
            data-testid="channel-attachment-limit"
          />
          <span>MB per message</span>
          <span class="text-xs text-gray-500 dark:text-zinc-400">(0 lists attachments without fetching)</span>
        </form>
      </section>

      <section class="rounded border border-gray-200 dark:border-zinc-700 p-3 space-y-2">
        <div class="flex items-center justify-between gap-2">
          <h4 class="text-xs font-medium text-gray-500 dark:text-zinc-400">
            Data path (for your records of processing)
          </h4>
          <button
            type="button"
            id={"copy-data-path-#{@channel.id}"}
            phx-hook="CopyToClipboard"
            data-clipboard-text={@data_path}
            class="text-xs px-2 py-1 text-indigo-600 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors"
            data-testid="channel-copy-data-path"
          >
            Copy
          </button>
        </div>
        <pre
          class="whitespace-pre-wrap break-words font-sans text-xs text-gray-700 dark:text-zinc-300"
          data-testid="channel-data-path"
        >{@data_path}</pre>
      </section>
    </div>
    """
  end

  @doc false
  def data_path_text(%InboundChannel{ingress_kind: :mx} = channel) do
    domain = InboundChannel.public_domain(channel)

    """
    Inbound mail for #{channel.public_address}
    1. Customer -> Lettermint B.V., Zwolle, Netherlands (EU; GDPR Art. 28 processor, public DPA): the MX record for #{domain} delivers the message directly. Lettermint keeps the raw message for 28 days.
    2. Lettermint -> this Custyard instance: #{stored_text(channel)}
    Replies: this Custyard instance -> Lettermint -> customer. No other mailbox holds a copy.
    """
  end

  def data_path_text(%InboundChannel{ingress_kind: :imap} = channel) do
    domain = InboundChannel.public_domain(channel)

    """
    Inbound mail for #{channel.public_address}
    1. Customer -> #{domain} (operator's mail provider): the public mailbox receives the message.
    2. #{channel.imap_host} -> this Custyard instance: Custyard reads the #{channel.imap_folder} folder over IMAP with TLS, using credentials stored encrypted, and changes nothing in the mailbox. Stored: #{stored_text(channel)}
    Replies: this Custyard instance -> Lettermint B.V., Zwolle, Netherlands (EU; GDPR Art. 28 processor, public DPA) -> customer.#{archive_copy_line(channel)}
    """
  end

  def data_path_text(channel) do
    provider = provider_name(channel.provider)
    domain = InboundChannel.public_domain(channel)

    """
    Inbound mail for #{channel.public_address}
    1. Customer -> #{domain} (#{provider}): the public mailbox receives the message.
    2. #{provider} -> Lettermint B.V., Zwolle, Netherlands (EU; GDPR Art. 28 processor, public DPA): the forwarding rule delivers a copy to the ingress address. Lettermint keeps the raw message for 28 days.
    3. Lettermint -> this Custyard instance: #{stored_text(channel)}
    Replies: this Custyard instance -> Lettermint -> customer.#{archive_copy_line(channel)}
    """
  end

  defp stored_text(channel) do
    "parsed text body, sanitised HTML, attachments up to #{channel.attachment_limit_mb} MB per " <>
      "message, addresses needed to reply, authentication summary and spam score are stored. " <>
      "Raw messages, signed URLs and full headers are not."
  end

  defp archive_copy_line(%{archive_copy: true, ingress_kind: :imap, public_address: address}),
    do: " A copy of each reply is BCC'd to #{address} and read back here."

  defp archive_copy_line(%{archive_copy: true, public_address: address}),
    do: " A copy of each reply is BCC'd to #{address} and forwarded back here."

  defp archive_copy_line(_channel), do: ""

  defp provider_name(:google), do: "Google Workspace / Gmail"
  defp provider_name(:google_workspace), do: "Google Workspace"
  defp provider_name(:proton), do: "Proton Mail"
  defp provider_name(_other), do: "operator's mail provider"

  # --- Shared badges (also used by the channels tab) ---

  @doc "State badge, one colour per channel state."
  attr :state, :atom, required: true
  attr :id, :any, required: true

  def channel_state_badge(assigns) do
    colors =
      case assigns.state do
        :draft ->
          "bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300"

        :pending_verification ->
          "bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"

        :awaiting_first_message ->
          "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-300"

        :active ->
          "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"

        :paused ->
          "bg-zinc-200 dark:bg-zinc-700 text-zinc-700 dark:text-zinc-300"

        :revoked ->
          "bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded whitespace-nowrap #{@colors}"}
      data-testid={"channel-state-#{@id}"}
      data-state={@state}
    >
      {@state |> to_string() |> String.replace("_", " ")}
    </span>
    """
  end

  @doc "Sending-domain summary pill."
  attr :summary, :atom, required: true
  attr :id, :any, required: true

  def sending_domain_pill(assigns) do
    {colors, label} =
      case assigns.summary do
        :verified ->
          {"bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300", "domain verified"}

        :pending ->
          {"bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300", "domain pending"}

        :failed ->
          {"bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300", "domain failed"}

        :not_found ->
          {"bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300",
           "domain not in Lettermint"}

        _ ->
          {"bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300", "domain unchecked"}
      end

    assigns = assigns |> assign(:colors, colors) |> assign(:label, label)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded whitespace-nowrap #{@colors}"}
      data-testid={"channel-domain-#{@id}"}
      data-summary={@summary}
    >
      {@label}
    </span>
    """
  end
end
