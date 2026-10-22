defmodule CustyardWeb.Operator.OrganizationDetailLive do
  @moduledoc """
  Organization detail view showing conversations, contacts, projects,
  channels (with the routes behind them under an "Advanced" disclosure) and
  acknowledgments.

  Channel management follows spec-inbound-channels D7 and "Access": agents
  see the public address, state and health; admins also see the masked
  ingress address, may reveal it (audited), and run the lifecycle actions.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents

  import CustyardWeb.Operator.ChannelSetupComponent,
    only: [channel_state_badge: 1, sending_domain_pill: 1]

  require Logger

  alias Custyard.{
    Conversations,
    Organizations,
    Projects,
    InboundChannels,
    InboundRoutes,
    Authorization,
    Acknowledgments
  }

  alias Custyard.{InboundChannel, InboundRoute, InboundRouteWebhook}
  alias CustyardWeb.Operator.ChannelSetupComponent

  @tabs ~w(conversations contacts projects channels acknowledgments)

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Organizations.get_organization_for_operator(id, socket.assigns.current_operator) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found")
         |> redirect(to: ~p"/operator/organizations")}

      org ->
        if connected?(socket), do: InboundChannels.subscribe_organization(org.id)

        socket =
          socket
          |> assign(:page_title, org.name)
          |> assign(:organization, org)
          |> assign(:tab, "conversations")
          |> assign(:can_manage_routes, false)
          |> assign(:setup_channel_id, nil)
          |> load_tab_data(org, "conversations")

        {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
    end
  end

  # `?tab=routes` stays valid: the routes tab became the channels tab and
  # routes live under its "Advanced" disclosure.
  @impl true
  def handle_params(%{"tab" => "routes"} = params, uri, socket),
    do: handle_params(%{params | "tab" => "channels"}, uri, socket)

  def handle_params(%{"tab" => tab} = params, _uri, socket) when tab in @tabs do
    socket =
      socket
      |> assign(:tab, tab)
      |> assign(:acknowledgment_page, acknowledgment_page(params))
      |> load_tab_data(socket.assigns.organization, tab)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp load_tab_data(socket, org, "conversations") do
    conversations = Conversations.list_for_organization(org.id, include_resolved: true)
    assign(socket, :conversations, conversations)
  end

  defp load_tab_data(socket, org, "contacts") do
    contacts = Organizations.list_contacts(org.id)
    assign(socket, :contacts, contacts)
  end

  defp load_tab_data(socket, org, "projects") do
    projects = Projects.list_for_organization(org.id)
    assign(socket, :projects, projects)
  end

  defp load_tab_data(socket, org, "channels") do
    socket
    |> load_tab_data(org, "routes")
    |> load_channels(org)
    |> assign(:revealed_channel_ids, MapSet.new())
    |> assign(:confirm_channel_action, nil)
  end

  defp load_tab_data(socket, org, "routes") do
    routes = InboundRoutes.list_for_organization(org.id)
    projects = Projects.list_for_organization(org.id)
    can_manage = Authorization.can_manage_organization?(socket.assigns.current_operator, org.id)
    general_route_count = Enum.count(routes, &(&1.route_type == :general))

    socket
    |> assign(:routes, routes)
    |> assign(:available_projects, projects)
    |> assign(:can_manage_routes, can_manage)
    |> assign(:general_route_count, general_route_count)
    |> assign(:show_create_route_form, false)
    |> assign(:confirm_delete_route_id, nil)
  end

  @acknowledgment_page_size 20

  # `org` is always socket.assigns.organization, set in mount after the access
  # check; a patched URL's id never selects whose bindings are shown.
  defp load_tab_data(socket, org, "acknowledgments") do
    page = Map.get(socket.assigns, :acknowledgment_page, 1)

    records =
      Acknowledgments.list_for_organization(org.id,
        limit: @acknowledgment_page_size + 1,
        offset: (page - 1) * @acknowledgment_page_size
      )

    socket
    |> assign(:acknowledgments, Enum.take(records, @acknowledgment_page_size))
    |> assign(:acknowledgment_has_next, length(records) > @acknowledgment_page_size)
    |> assign(:acknowledgment_bindings, Acknowledgments.list_bindings_for_organization(org.id))
  end

  defp acknowledgment_page(params) do
    case Map.get(params, "page", "1") do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {page, ""} when page > 0 and page <= 1_000_000 -> page
          _ -> 1
        end

      _ ->
        1
    end
  end

  defp load_channels(socket, org) do
    channels = InboundChannels.list_for_organization(org.id)

    socket
    |> assign(:channels, channels)
    # Rejection log (spec-inbound-channels D6): "did my customer's mail get
    # lost?" answered from the last 14 days, swept by retention.
    |> assign(:rejections, InboundChannels.list_rejections_for_organization(org.id, limit: 50))
  end

  # --- Channel PubSub and wizard messages ---

  @impl true
  def handle_info({:channel_updated, _id}, socket), do: {:noreply, refresh_channels(socket)}
  def handle_info({:channel_quiet, _id}, socket), do: {:noreply, refresh_channels(socket)}

  def handle_info({:channel_setup_created, id}, socket) do
    {:noreply, socket |> assign(:setup_channel_id, id) |> refresh_channels()}
  end

  def handle_info(:channel_setup_closed, socket) do
    {:noreply, assign(socket, :setup_channel_id, nil)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # --- Channel Event Handlers ---

  @impl true
  def handle_event("open_channel_setup", params, socket) do
    if socket.assigns.can_manage_routes do
      target =
        case params do
          %{"id" => id} ->
            case parse_id(id) do
              {:ok, parsed} -> parsed
              :error -> nil
            end

          _ ->
            :new
        end

      if target,
        do: {:noreply, assign(socket, :setup_channel_id, target)},
        else: {:noreply, socket}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels")}
    end
  end

  def handle_event("close_channel_setup", _, socket) do
    {:noreply, assign(socket, :setup_channel_id, nil)}
  end

  def handle_event("reveal_channel", %{"id" => id}, socket) do
    with_managed_channel(socket, id, fn channel ->
      InboundChannels.record_reveal(channel, operator: socket.assigns.current_operator)
      revealed = MapSet.put(socket.assigns.revealed_channel_ids, channel.id)
      {:noreply, assign(socket, :revealed_channel_ids, revealed)}
    end)
  end

  def handle_event("hide_channel", %{"id" => id}, socket) do
    case parse_id(id) do
      {:ok, parsed} ->
        revealed = MapSet.delete(socket.assigns.revealed_channel_ids, parsed)
        {:noreply, assign(socket, :revealed_channel_ids, revealed)}

      :error ->
        {:noreply, socket}
    end
  end

  def handle_event("check_channel_domain", %{"id" => id}, socket) do
    with_managed_channel(socket, id, fn channel ->
      case InboundChannels.check_sending_domain(channel,
             operator: socket.assigns.current_operator
           ) do
        {:ok, _channel} ->
          {:noreply, refresh_channels(socket)}

        {:error, reason} ->
          Logger.error(
            "Sending-domain check failed for channel #{channel.id}: #{inspect(reason)}"
          )

          {:noreply, put_flash(socket, :error, "Could not check the sending domain")}
      end
    end)
  end

  def handle_event("pause_channel", %{"id" => id}, socket) do
    channel_transition(socket, id, &InboundChannels.pause/2, "Channel paused")
  end

  def handle_event("resume_channel", %{"id" => id}, socket) do
    channel_transition(socket, id, &InboundChannels.resume/2, "Channel resumed")
  end

  def handle_event("confirm_channel_action", %{"id" => id, "action" => action}, socket)
      when action in ~w(rotate revoke) do
    case parse_id(id) do
      {:ok, parsed} -> {:noreply, assign(socket, :confirm_channel_action, {action, parsed})}
      :error -> {:noreply, put_flash(socket, :error, "Invalid channel ID")}
    end
  end

  def handle_event("cancel_channel_action", _, socket) do
    {:noreply, assign(socket, :confirm_channel_action, nil)}
  end

  def handle_event("rotate_channel_token", %{"id" => id}, socket) do
    channel_transition(
      socket,
      id,
      &InboundChannels.rotate_token/2,
      "Token rotated. The previous address keeps working for 7 days; update the forwarding rule."
    )
  end

  def handle_event("revoke_channel", %{"id" => id}, socket) do
    channel_transition(socket, id, &InboundChannels.revoke/2, "Channel revoked")
  end

  # --- Route Event Handlers ---

  def handle_event("show_create_route_form", _, socket) do
    if socket.assigns.can_manage_routes do
      {:noreply, assign(socket, :show_create_route_form, true)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to create routes")}
    end
  end

  def handle_event("hide_create_route_form", _, socket) do
    if socket.assigns.can_manage_routes do
      {:noreply, assign(socket, :show_create_route_form, false)}
    else
      {:noreply, socket}
    end
  end

  @valid_route_types Enum.map(InboundRoute.route_types(), &to_string/1)
  @valid_sources Enum.map(InboundRoute.sources(), &to_string/1)
  @valid_purposes Enum.map(InboundRouteWebhook.purposes(), &to_string/1)

  def handle_event(
        "create_route",
        %{"route_type" => route_type, "source" => source} = params,
        socket
      ) do
    if socket.assigns.can_manage_routes do
      with :ok <- validate_param(route_type, @valid_route_types, "route_type"),
           :ok <- validate_param(source, @valid_sources, "source") do
        org = socket.assigns.organization

        attrs = %{
          organization_id: org.id,
          route_type: String.to_existing_atom(route_type),
          source: String.to_existing_atom(source)
        }

        attrs =
          case params do
            %{"project_id" => project_id} when project_id != "" ->
              case parse_id(project_id) do
                {:ok, id} -> Map.put(attrs, :project_id, id)
                :error -> attrs
              end

            _ ->
              attrs
          end

        case InboundRoutes.create_route(attrs) do
          {:ok, _route} ->
            socket =
              socket
              |> put_flash(:info, "Route created successfully")
              |> load_tab_data(org, "routes")

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            message =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
              |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

            {:noreply, put_flash(socket, :error, "Failed to create route: #{message}")}

          {:error, reason} ->
            Logger.error("Failed to create route: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to create route")}
        end
      else
        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to create routes")}
    end
  end

  def handle_event(
        "toggle_webhook",
        %{"route-id" => route_id, "purpose" => purpose, "enabled" => enabled},
        socket
      ) do
    if socket.assigns.can_manage_routes do
      with :ok <- validate_param(purpose, @valid_purposes, "purpose"),
           {:ok, id} <- parse_id(route_id) do
        purpose_atom = String.to_existing_atom(purpose)

        with_org_route(socket, id, "webhook toggle", fn route ->
          toggle_route_webhook(socket, route, purpose_atom, enabled)
        end)
      else
        {:error, message} when is_binary(message) ->
          {:noreply, put_flash(socket, :error, message)}

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid route ID")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage webhooks")}
    end
  end

  def handle_event("confirm_delete_route", %{"id" => route_id}, socket) do
    case parse_id(route_id) do
      {:ok, id} -> {:noreply, assign(socket, :confirm_delete_route_id, id)}
      :error -> {:noreply, put_flash(socket, :error, "Invalid route ID")}
    end
  end

  def handle_event("cancel_delete_route", _, socket) do
    {:noreply, assign(socket, :confirm_delete_route_id, nil)}
  end

  def handle_event("delete_route", %{"id" => route_id}, socket) do
    if socket.assigns.can_manage_routes do
      case parse_id(route_id) do
        {:ok, id} ->
          with_org_route(socket, id, "delete", &delete_org_route(socket, &1))

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid route ID")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to delete routes")}
    end
  end

  defp refresh_channels(%{assigns: %{tab: "channels"}} = socket),
    do: load_channels(socket, socket.assigns.organization)

  defp refresh_channels(socket), do: socket

  defp channel_transition(socket, id, fun, success_message) do
    with_managed_channel(socket, id, fn channel ->
      case fun.(channel, operator: socket.assigns.current_operator) do
        {:ok, _channel} ->
          {:noreply,
           socket
           |> put_flash(:info, success_message)
           |> assign(:confirm_channel_action, nil)
           |> refresh_channels()}

        {:error, %Ecto.Changeset{} = changeset} ->
          message =
            changeset
            |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
            |> Enum.flat_map(fn {_field, msgs} -> msgs end)
            |> Enum.join(", ")

          {:noreply, socket |> assign(:confirm_channel_action, nil) |> put_flash(:error, message)}
      end
    end)
  end

  # Admin-only channel actions. The channel is re-read scoped to this
  # organization so a stale or foreign id is answered here.
  defp with_managed_channel(socket, id, fun) do
    if socket.assigns.can_manage_routes do
      case parse_id(id) do
        {:ok, parsed} ->
          org = socket.assigns.organization

          case InboundChannels.get_channel_for_organization(parsed, org.id) do
            nil ->
              {:noreply,
               socket
               |> put_flash(:error, "That channel no longer exists")
               |> assign(:confirm_channel_action, nil)
               |> refresh_channels()}

            channel ->
              fun.(channel)
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid channel ID")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage channels")}
    end
  end

  # Runs `fun` on the route the page referred to, once it is known to still
  # exist and to belong to this organization; the stale and foreign cases
  # are answered here.
  defp with_org_route(socket, id, action, fun) do
    org = socket.assigns.organization

    case InboundRoutes.get_route(id) do
      nil ->
        {:noreply, stale_route(socket, org)}

      %{organization_id: org_id} = route when org_id == org.id ->
        fun.(route)

      route ->
        Logger.warning("Unauthorized #{action} on route #{route.id} by operator in org #{org.id}")
        {:noreply, put_flash(socket, :error, "You do not have permission to manage this route")}
    end
  end

  defp toggle_route_webhook(socket, route, purpose, enabled) do
    result =
      case enabled do
        "true" -> InboundRoutes.enable_webhook(route, purpose)
        "false" -> InboundRoutes.disable_webhook(route, purpose)
        _ -> {:error, :invalid_enabled_value}
      end

    case result do
      {:ok, _webhook} ->
        {:noreply, load_tab_data(socket, socket.assigns.organization, "routes")}

      {:error, reason} ->
        Logger.error("Failed to toggle webhook: #{inspect(reason)}")
        {:noreply, put_flash(socket, :error, "Failed to toggle webhook")}
    end
  end

  defp delete_org_route(socket, route) do
    if InboundRoutes.is_last_general_route?(route) do
      {:noreply,
       put_flash(socket, :error, "Cannot delete the last general route for this organization")}
    else
      case InboundRoutes.delete_route(route) do
        {:ok, _} ->
          socket =
            socket
            |> put_flash(:info, "Route deleted")
            |> assign(:confirm_delete_route_id, nil)
            |> load_tab_data(socket.assigns.organization, "routes")

          {:noreply, socket}

        {:error, reason} ->
          Logger.error("Failed to delete route: #{inspect(reason)}")
          {:noreply, put_flash(socket, :error, "Failed to delete route")}
      end
    end
  end

  # A route deleted from another session is still on this operator's screen
  # until the tab reloads; a raising lookup turned that click into a LiveView
  # crash.
  defp stale_route(socket, org) do
    socket
    |> put_flash(:error, "That route no longer exists")
    |> assign(:confirm_delete_route_id, nil)
    |> load_tab_data(org, "routes")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col" data-testid="operator-org-detail">
      <%!-- Header --%>
      <div class="bg-white dark:bg-zinc-800 border-b border-gray-200 dark:border-zinc-700 px-4 py-4">
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/operator/organizations"}
            class="text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
            data-testid="org-detail-back"
          >
            <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
          </.link>
          <div class="flex-1">
            <div class="flex items-center gap-3">
              <%= if @organization.logo_url do %>
                <img
                  src={@organization.logo_url}
                  alt={"#{@organization.name} logo"}
                  class="h-8 w-8 rounded object-cover"
                />
              <% end %>
              <h1
                class="text-xl font-semibold text-gray-900 dark:text-zinc-100"
                data-testid="org-detail-name"
              >
                {@organization.name}
              </h1>
              <.tier_badge tier={@organization.tier} />
            </div>
            <div class="mt-1 text-sm text-gray-600 dark:text-zinc-400 flex items-center gap-4">
              <%= if @organization.domain do %>
                <span data-testid="org-detail-domain">{@organization.domain}</span>
              <% end %>
              <%= if @organization.custom_domain do %>
                <span
                  class="text-indigo-600 dark:text-indigo-400"
                  data-testid="org-detail-custom-domain"
                >
                  {@organization.custom_domain}
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="mt-4 flex gap-4 border-b border-gray-200 dark:border-zinc-700 -mb-px">
          <.tab_link
            tab="conversations"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=conversations"}
          >
            Conversations
          </.tab_link>
          <.tab_link
            tab="contacts"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=contacts"}
          >
            Contacts
          </.tab_link>
          <.tab_link
            tab="projects"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=projects"}
          >
            Projects
          </.tab_link>
          <.tab_link
            tab="channels"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=channels"}
          >
            Channels
          </.tab_link>
          <.tab_link
            tab="acknowledgments"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=acknowledgments"}
          >
            Acknowledgments
          </.tab_link>
        </div>
      </div>

      <%!-- Content --%>
      <div class="flex-1 overflow-auto p-4">
        <%= case @tab do %>
          <% "conversations" -> %>
            <.conversations_tab conversations={@conversations} />
          <% "contacts" -> %>
            <.contacts_tab contacts={@contacts} />
          <% "projects" -> %>
            <.projects_tab projects={@projects} />
          <% "acknowledgments" -> %>
            <.acknowledgment_bindings bindings={@acknowledgment_bindings} />
            <.acknowledgments_tab
              records={@acknowledgments}
              organization={@organization}
              page={@acknowledgment_page}
              has_next={@acknowledgment_has_next}
            />
          <% "channels" -> %>
            <.channels_tab
              channels={@channels}
              rejections={@rejections}
              routes={@routes}
              can_manage={@can_manage_routes}
              setup_channel_id={@setup_channel_id}
              revealed_channel_ids={@revealed_channel_ids}
              confirm_channel_action={@confirm_channel_action}
              organization={@organization}
              current_operator={@current_operator}
            />
            <details
              class="mt-6 rounded-lg border border-gray-200 dark:border-zinc-700 bg-gray-50 dark:bg-zinc-900 p-3"
              data-testid="org-routes-advanced"
            >
              <summary class="cursor-pointer text-sm font-medium text-gray-700 dark:text-zinc-300">
                Advanced: routes
              </summary>
              <p class="mt-1 mb-3 text-xs text-gray-500 dark:text-zinc-400">
                Routes are the Lettermint ingress behind channels: callback URLs, webhook purposes and
                ingress domains. Most setups never need to touch them.
              </p>
              <.routes_tab
                routes={@routes}
                available_projects={@available_projects}
                can_manage={@can_manage_routes}
                show_create_form={@show_create_route_form}
                confirm_delete_route_id={@confirm_delete_route_id}
                organization={@organization}
                general_route_count={@general_route_count}
              />
            </details>
        <% end %>
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
        if(@tab == @current,
          do: "border-indigo-600 text-indigo-600 dark:border-indigo-400 dark:text-indigo-400",
          else:
            "border-transparent text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-200 hover:border-gray-300 dark:hover:border-zinc-600"
        )
      ]}
      data-testid={"org-tab-#{@tab}"}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :bindings, :list, required: true

  # Read-only: bindings are made by super admins on the Acknowledgments page.
  defp acknowledgment_bindings(assigns) do
    ~H"""
    <section class="mb-6" data-testid="org-acknowledgment-bindings">
      <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Source bindings</h2>
      <p
        :if={@bindings == []}
        class="mt-2 text-sm text-gray-600 dark:text-zinc-400"
        data-testid="org-acknowledgment-bindings-empty"
      >
        No source is bound to this organization. Evidence for this organization arrives only
        after a super admin binds it.
      </p>
      <ul :if={@bindings != []} class="mt-2 space-y-1 text-sm text-gray-600 dark:text-zinc-400">
        <li :for={binding <- @bindings} data-testid={"org-acknowledgment-binding-#{binding.id}"}>
          <span class="break-all">{binding.source}</span>
          · <span class="break-all">{binding.source_organization_id}</span>
        </li>
      </ul>
    </section>
    """
  end

  attr :records, :list, required: true
  attr :organization, :any, required: true
  attr :page, :integer, required: true
  attr :has_next, :boolean, required: true

  defp acknowledgments_tab(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="org-acknowledgments-list">
      <p :if={@records == []} class="py-12 text-center text-sm text-gray-600 dark:text-zinc-400">
        No acknowledgments on this page.
      </p>
      <article
        :for={record <- @records}
        class="rounded-lg border border-gray-200 bg-white p-4 dark:border-zinc-700 dark:bg-zinc-800"
        data-testid={"org-acknowledgment-#{record.id}"}
      >
        <h2 class="font-medium text-gray-900 dark:text-zinc-100">
          {record.statement_key} · {record.statement_version}
        </h2>
        <dl class="mt-3 grid gap-2 text-sm text-gray-600 dark:text-zinc-400 sm:grid-cols-2">
          <div>
            <dt class="font-medium">Source</dt><dd class="break-all">{record.source}</dd>
          </div>
          <div>
            <dt class="font-medium">Source organization</dt><dd class="break-all">
              {record.source_organization_id}
            </dd>
          </div>
          <div>
            <dt class="font-medium">Submission ID</dt><dd class="break-all">
              {record.submission_id}
            </dd>
          </div>
          <div>
            <dt class="font-medium">Actor</dt><dd class="break-all">{record.actor_id}</dd>
          </div>
          <div>
            <dt class="font-medium">Actor role</dt><dd>{record.actor_role}</dd>
          </div>
          <div>
            <dt class="font-medium">Actor type</dt><dd>{record.actor_type}</dd>
          </div>
          <div>
            <dt class="font-medium">Acknowledged at (UTC)</dt><dd>
              {record.acknowledged_at}
            </dd>
          </div>
          <div>
            <dt class="font-medium">Received at (UTC)</dt><dd>
              {DateTime.to_iso8601(record.received_at)}
            </dd>
          </div>
          <div class="sm:col-span-2">
            <dt class="font-medium">Statement SHA-256</dt><dd class="break-all">
              {record.statement_hash}
            </dd>
          </div>
        </dl>
        <h3 class="mt-4 text-sm font-medium text-gray-900 dark:text-zinc-100">
          Exact historical wording
        </h3>
        <pre
          class="mt-2 whitespace-pre-wrap break-words font-sans text-sm text-gray-900 dark:text-zinc-100"
          data-testid="acknowledgment-statement"
        >{record.statement_text}</pre>
      </article>
      <nav aria-label="Acknowledgment pages" class="flex items-center gap-4 text-sm">
        <.link
          :if={@page > 1}
          patch={
            ~p"/operator/organizations/#{@organization.id}?tab=acknowledgments&page=#{@page - 1}"
          }
          data-testid="acknowledgments-previous"
        >Previous</.link>
        <span>Page {@page}</span>
        <.link
          :if={@has_next}
          patch={
            ~p"/operator/organizations/#{@organization.id}?tab=acknowledgments&page=#{@page + 1}"
          }
          data-testid="acknowledgments-next"
        >Next</.link>
      </nav>
    </div>
    """
  end

  attr :conversations, :list, required: true

  defp conversations_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-conversations-list">
      <div
        :if={@conversations == []}
        class="text-center py-12"
        data-testid="org-conversations-empty"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M8.625 12a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H8.25m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H12m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0h-.375M21 12c0 4.556-4.03 8.25-9 8.25a9.764 9.764 0 01-2.555-.337A5.972 5.972 0 015.41 20.97a5.969 5.969 0 01-.474-.065 4.48 4.48 0 00.978-2.025c.09-.457-.133-.901-.467-1.226C3.93 16.178 3 14.189 3 12c0-4.556 4.03-8.25 9-8.25s9 3.694 9 8.25z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No conversations yet.</p>
      </div>

      <.link
        :for={conv <- @conversations}
        navigate={~p"/operator/conversation/#{conv.id}"}
        class="block p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700 hover:border-indigo-300 dark:hover:border-indigo-600 transition-colors"
        data-testid={"org-conversation-#{conv.id}"}
      >
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <div class="font-medium text-gray-900 dark:text-zinc-100 truncate">
              {conv.subject || "No subject"}
            </div>
            <div class="text-sm text-gray-600 dark:text-zinc-400 mt-1">
              {if conv.contact, do: conv.contact.name || conv.contact.email, else: "Unknown contact"}
            </div>
          </div>
          <div class="ml-4 flex flex-col items-end gap-1">
            <.state_badge state={conv.state} />
            <span class="text-xs text-gray-500 dark:text-zinc-500">
              {Calendar.strftime(conv.updated_at, "%b %d, %Y")}
            </span>
          </div>
        </div>
      </.link>
    </div>
    """
  end

  attr :contacts, :list, required: true

  defp contacts_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-contacts-list">
      <div
        :if={@contacts == []}
        class="text-center py-12"
        data-testid="org-contacts-empty"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No contacts yet.</p>
      </div>

      <div
        :for={contact <- @contacts}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700"
        data-testid={"org-contact-#{contact.id}"}
      >
        <div class="flex items-center justify-between">
          <div>
            <div class="font-medium text-gray-900 dark:text-zinc-100">
              {contact.name || "Unnamed contact"}
            </div>
            <div class="text-sm text-gray-600 dark:text-zinc-400">
              {contact.email}
            </div>
          </div>
          <div class="text-xs text-gray-500 dark:text-zinc-500">
            Added {Calendar.strftime(contact.inserted_at, "%b %d, %Y")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :projects, :list, required: true

  defp projects_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-projects-list">
      <div
        :if={@projects == []}
        class="text-center py-12"
        data-testid="org-projects-empty"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M9 12h3.75M9 15h3.75M9 18h3.75m3 .75H18a2.25 2.25 0 002.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 00-1.123-.08m-5.801 0c-.065.21-.1.433-.1.664 0 .414.336.75.75.75h4.5a.75.75 0 00.75-.75 2.25 2.25 0 00-.1-.664m-5.8 0A2.251 2.251 0 0113.5 2.25H15c1.012 0 1.867.668 2.15 1.586m-5.8 0c-.376.023-.75.05-1.124.08C9.095 4.01 8.25 4.973 8.25 6.108V8.25m0 0H4.875c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V9.375c0-.621-.504-1.125-1.125-1.125H8.25zM6.75 12h.008v.008H6.75V12zm0 3h.008v.008H6.75V15zm0 3h.008v.008H6.75V18z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No projects yet.</p>
      </div>

      <.link
        :for={project <- @projects}
        navigate={~p"/operator/projects"}
        class="block p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700 hover:border-indigo-300 dark:hover:border-indigo-600 transition-colors"
        data-testid={"org-project-#{project.id}"}
      >
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <div class="font-medium text-gray-900 dark:text-zinc-100">
              {project.title}
            </div>
            <%= if project.description do %>
              <div class="text-sm text-gray-600 dark:text-zinc-400 mt-1 line-clamp-2">
                {project.description}
              </div>
            <% end %>
          </div>
          <div class="ml-4 text-xs text-gray-500 dark:text-zinc-500">
            {length(project.tasks)} tasks
          </div>
        </div>
      </.link>
    </div>
    """
  end

  # --- Channels Tab ---

  attr :channels, :list, required: true
  attr :rejections, :list, required: true
  attr :routes, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :setup_channel_id, :any, required: true
  attr :revealed_channel_ids, :any, required: true
  attr :confirm_channel_action, :any, required: true
  attr :organization, :map, required: true
  attr :current_operator, :any, required: true

  defp channels_tab(assigns) do
    setup_channel =
      case assigns.setup_channel_id do
        id when is_integer(id) -> Enum.find(assigns.channels, &(&1.id == id))
        _ -> nil
      end

    assigns = assign(assigns, :setup_channel, setup_channel)

    ~H"""
    <div class="space-y-4" data-testid="org-channels-list">
      <div :if={@can_manage and is_nil(@setup_channel_id)} class="flex justify-end">
        <button
          phx-click="open_channel_setup"
          class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
          data-testid="new-channel-btn"
        >
          New channel
        </button>
      </div>

      <.live_component
        :if={@can_manage and not is_nil(@setup_channel_id)}
        module={ChannelSetupComponent}
        id="channel-setup"
        organization={@organization}
        current_operator={@current_operator}
        routes={@routes}
        channel={@setup_channel}
      />

      <div :if={@channels == []} class="text-center py-12" data-testid="org-channels-empty">
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M21.75 6.75v10.5a2.25 2.25 0 01-2.25 2.25h-15a2.25 2.25 0 01-2.25-2.25V6.75m19.5 0A2.25 2.25 0 0019.5 4.5h-15a2.25 2.25 0 00-2.25 2.25m19.5 0v.243a2.25 2.25 0 01-1.07 1.916l-7.5 4.615a2.25 2.25 0 01-2.36 0L3.32 8.91a2.25 2.25 0 01-1.07-1.916V6.75"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">
          No channels yet. A channel forwards a support mailbox such as support@yourdomain into Custyard.
        </p>
      </div>

      <.channel_card
        :for={channel <- @channels}
        channel={channel}
        can_manage={@can_manage}
        revealed={MapSet.member?(@revealed_channel_ids, channel.id)}
        confirm_action={@confirm_channel_action}
      />

      <.rejection_log rejections={@rejections} channels={@channels} />
    </div>
    """
  end

  # Deliveries that reached a route but became no customer message
  # (spec-inbound-channels D6): sender, masked recipient, subject and the
  # reason, kept 14 days. Bodies are never stored, so none are shown.
  attr :rejections, :list, required: true
  attr :channels, :list, required: true

  defp rejection_log(assigns) do
    channel_addresses = Map.new(assigns.channels, &{&1.id, &1.public_address})
    assigns = assign(assigns, :channel_addresses, channel_addresses)

    ~H"""
    <details
      class="rounded-lg border border-gray-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 p-3"
      data-testid="org-rejection-log"
    >
      <summary class="cursor-pointer text-sm font-medium text-gray-700 dark:text-zinc-300">
        Rejected deliveries, last 14 days
        <span class="text-gray-400 dark:text-zinc-500" data-testid="org-rejection-count">
          ({length(@rejections)})
        </span>
      </summary>
      <p class="mt-1 mb-3 text-xs text-gray-500 dark:text-zinc-400">
        Mail that reached a route but did not become a conversation: auto-replies with no thread,
        provider notices, copies of your own replies, and deliveries to a paused, revoked or
        unknown address. Bodies are not kept.
      </p>
      <p
        :if={@rejections == []}
        class="text-sm text-gray-500 dark:text-zinc-400"
        data-testid="org-rejection-empty"
      >
        Nothing rejected in the last 14 days.
      </p>
      <div :if={@rejections != []} class="overflow-x-auto">
        <table class="min-w-full text-xs text-left" data-testid="org-rejection-table">
          <thead class="text-gray-500 dark:text-zinc-400">
            <tr>
              <th class="pr-3 py-1 font-medium">When</th>
              <th class="pr-3 py-1 font-medium">From</th>
              <th class="pr-3 py-1 font-medium">Subject</th>
              <th class="pr-3 py-1 font-medium">Reason</th>
              <th class="pr-3 py-1 font-medium">Channel</th>
            </tr>
          </thead>
          <tbody class="text-gray-700 dark:text-zinc-300 align-top">
            <tr
              :for={rejection <- @rejections}
              class="border-t border-gray-100 dark:border-zinc-700"
              data-testid={"rejection-#{rejection.id}"}
            >
              <td class="pr-3 py-1 whitespace-nowrap">
                {Calendar.strftime(rejection.inserted_at, "%b %d %H:%M")}
              </td>
              <td class="pr-3 py-1 break-all">{rejection.sender_email || "unknown sender"}</td>
              <td class="pr-3 py-1 break-words max-w-xs">{rejection.subject || "(no subject)"}</td>
              <td class="pr-3 py-1 whitespace-nowrap" data-testid={"rejection-reason-#{rejection.id}"}>
                {rejection_label(rejection.classification)}
              </td>
              <td class="pr-3 py-1 break-all">
                {Map.get(@channel_addresses, rejection.inbound_channel_id) ||
                  mask_recipient(rejection.recipient)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </details>
    """
  end

  defp rejection_label(:no_channel), do: "no matching channel"
  defp rejection_label(:channel_paused), do: "channel paused"
  defp rejection_label(:channel_revoked), do: "channel revoked"
  defp rejection_label(:auto_response), do: "auto-reply, no thread"
  defp rejection_label(:provider_notice), do: "provider notice"
  defp rejection_label(:own_echo), do: "copy of your own reply"
  defp rejection_label(other), do: to_string(other)

  # The recipient of a rejection is a route address, possibly carrying a
  # channel token; the token stays masked here as it does on channel cards.
  defp mask_recipient(recipient) when is_binary(recipient) do
    case String.split(recipient, "@", parts: 2) do
      [local, domain] ->
        case String.split(local, "+", parts: 2) do
          [base, _tag] -> "#{base}+…@#{domain}"
          _plain -> "#{local}@#{domain}"
        end

      _other ->
        recipient
    end
  end

  defp mask_recipient(_recipient), do: "unknown address"

  attr :channel, InboundChannel, required: true
  attr :can_manage, :boolean, required: true
  attr :revealed, :boolean, required: true
  attr :confirm_action, :any, required: true

  defp channel_card(assigns) do
    channel = assigns.channel

    assigns =
      assigns
      |> assign(:quiet, channel_quiet?(channel))
      |> assign(:summary, InboundChannels.sending_domain_summary(channel))
      |> assign(:confirming, confirming(assigns.confirm_action, channel.id))
      # The wizard is the only place reply identity and the sending-domain
      # check live, so it stays reachable after the channel goes active;
      # the label says which job it is doing.
      |> assign(:setup_available, channel.state != :revoked)
      |> assign(
        :setup_label,
        if(channel.state in [:pending_verification, :awaiting_first_message],
          do: "Setup",
          else: "Settings"
        )
      )

    ~H"""
    <div
      class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700 space-y-3"
      data-testid={"channel-card-#{@channel.id}"}
    >
      <div class="flex flex-wrap items-start justify-between gap-2">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span
              class="font-medium text-gray-900 dark:text-zinc-100 break-all"
              data-testid={"channel-public-address-#{@channel.id}"}
            >
              {@channel.public_address}
            </span>
            <.channel_state_badge state={@channel.state} id={@channel.id} />
          </div>
          <div class="mt-1 text-xs text-gray-500 dark:text-zinc-400 flex flex-wrap items-center gap-x-2">
            <span :if={@channel.display_name} data-testid={"channel-display-name-#{@channel.id}"}>
              {@channel.display_name}
            </span>
            <span data-testid={"channel-provider-#{@channel.id}"}>{source_label(@channel)}</span>
            <span aria-hidden="true">·</span>
            <span data-testid={"channel-scope-#{@channel.id}"}>
              {if @channel.project, do: @channel.project.title, else: "Organization-wide"}
            </span>
          </div>
        </div>

        <div :if={@can_manage} class="flex flex-wrap items-center gap-2">
          <%= case @confirming do %>
            <% "rotate" -> %>
              <span class="text-xs text-amber-700 dark:text-amber-300">
                Rotate the token? The old address keeps working for 7 days.
              </span>
              <button
                phx-click="rotate_channel_token"
                phx-value-id={@channel.id}
                class="text-xs px-2 py-1 text-white bg-amber-600 hover:bg-amber-700 rounded transition-colors"
                data-testid={"confirm-rotate-channel-#{@channel.id}"}
              >
                Yes, rotate
              </button>
              <button
                phx-click="cancel_channel_action"
                class="text-xs px-2 py-1 text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-100"
                data-testid={"cancel-channel-action-#{@channel.id}"}
              >
                Cancel
              </button>
            <% "revoke" -> %>
              <span class="text-xs text-red-600 dark:text-red-400">
                Revoke this channel? All tokens stop matching immediately.
              </span>
              <button
                phx-click="revoke_channel"
                phx-value-id={@channel.id}
                class="text-xs px-2 py-1 text-white bg-red-600 hover:bg-red-700 rounded transition-colors"
                data-testid={"confirm-revoke-channel-#{@channel.id}"}
              >
                Yes, revoke
              </button>
              <button
                phx-click="cancel_channel_action"
                class="text-xs px-2 py-1 text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-100"
                data-testid={"cancel-channel-action-#{@channel.id}"}
              >
                Cancel
              </button>
            <% _ -> %>
              <button
                :if={@setup_available}
                phx-click="open_channel_setup"
                phx-value-id={@channel.id}
                class="text-xs px-2 py-1 text-indigo-600 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors"
                data-testid={"setup-channel-#{@channel.id}"}
              >
                {@setup_label}
              </button>
              <button
                :if={@channel.state == :paused}
                phx-click="resume_channel"
                phx-value-id={@channel.id}
                class="text-xs px-2 py-1 text-gray-700 dark:text-zinc-300 border border-gray-200 dark:border-zinc-600 rounded hover:bg-gray-50 dark:hover:bg-zinc-700 transition-colors"
                data-testid={"resume-channel-#{@channel.id}"}
              >
                Resume
              </button>
              <button
                :if={@channel.state in [:pending_verification, :awaiting_first_message, :active]}
                phx-click="pause_channel"
                phx-value-id={@channel.id}
                class="text-xs px-2 py-1 text-gray-700 dark:text-zinc-300 border border-gray-200 dark:border-zinc-600 rounded hover:bg-gray-50 dark:hover:bg-zinc-700 transition-colors"
                data-testid={"pause-channel-#{@channel.id}"}
              >
                Pause
              </button>
              <button
                :if={@channel.state != :revoked and InboundChannel.forwarding?(@channel)}
                phx-click="confirm_channel_action"
                phx-value-id={@channel.id}
                phx-value-action="rotate"
                class="text-xs px-2 py-1 text-gray-700 dark:text-zinc-300 border border-gray-200 dark:border-zinc-600 rounded hover:bg-gray-50 dark:hover:bg-zinc-700 transition-colors"
                data-testid={"rotate-channel-#{@channel.id}"}
              >
                Rotate token
              </button>
              <button
                :if={@channel.state != :revoked}
                phx-click="confirm_channel_action"
                phx-value-id={@channel.id}
                phx-value-action="revoke"
                class="text-xs px-2 py-1 text-red-600 dark:text-red-400 hover:text-red-800 dark:hover:text-red-300 rounded hover:bg-red-50 dark:hover:bg-red-950 transition-colors"
                data-testid={"revoke-channel-#{@channel.id}"}
              >
                Revoke
              </button>
          <% end %>
        </div>
      </div>

      <%!-- Direct MX: where the domain's mail goes; nothing secret to reveal --%>
      <div
        :if={@channel.ingress_kind == :mx}
        class="text-xs text-gray-500 dark:text-zinc-400"
        data-testid={"channel-mx-#{@channel.id}"}
      >
        Receives mail directly: MX 10 lettermint.mx for {InboundChannel.public_domain(@channel)}
      </div>

      <%!-- Ingress address: masked unless explicitly revealed; admins only --%>
      <div
        :if={@can_manage and InboundChannel.forwarding?(@channel)}
        class="flex flex-wrap items-center gap-2"
      >
        <span class="text-xs text-gray-500 dark:text-zinc-400">Forwarding to</span>
        <%= if @revealed do %>
          <code
            class="text-xs bg-gray-50 dark:bg-zinc-900 text-gray-800 dark:text-zinc-200 px-2 py-1 rounded border border-gray-200 dark:border-zinc-700 break-all"
            data-testid={"channel-ingress-#{@channel.id}"}
          >
            {InboundChannels.ingress_address(@channel) || "domain not synced"}
          </code>
          <button
            :if={InboundChannels.ingress_address(@channel)}
            id={"copy-ingress-#{@channel.id}"}
            phx-hook="CopyToClipboard"
            data-clipboard-text={InboundChannels.ingress_address(@channel)}
            class="text-xs px-2 py-1 text-indigo-600 dark:text-indigo-400 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors"
            data-testid={"copy-ingress-#{@channel.id}"}
          >
            Copy
          </button>
          <button
            phx-click="hide_channel"
            phx-value-id={@channel.id}
            class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-800 dark:hover:text-zinc-200"
            data-testid={"hide-channel-#{@channel.id}"}
          >
            Hide
          </button>
        <% else %>
          <code
            class="text-xs bg-gray-50 dark:bg-zinc-900 text-gray-600 dark:text-zinc-400 px-2 py-1 rounded border border-gray-200 dark:border-zinc-700 break-all"
            data-testid={"channel-ingress-masked-#{@channel.id}"}
          >
            {InboundChannels.masked_ingress_address(@channel) || "domain not synced"}
          </code>
          <button
            phx-click="reveal_channel"
            phx-value-id={@channel.id}
            class="text-xs text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300"
            data-testid={"reveal-channel-#{@channel.id}"}
          >
            Reveal
          </button>
        <% end %>
      </div>

      <%!-- Health --%>
      <div class="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-zinc-400">
        <span data-testid={"channel-last-received-#{@channel.id}"}>
          <%= if @channel.last_received_at do %>
            last received {relative_time(@channel.last_received_at)}
          <% else %>
            no mail yet
          <% end %>
        </span>
        <span
          :if={@quiet}
          class="px-1.5 py-0.5 rounded bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
          data-testid={"channel-quiet-#{@channel.id}"}
        >
          quiet for over {@channel.quiet_after_hours}h: {quiet_hint(@channel)}
        </span>
        <span class="ml-auto flex items-center gap-2">
          <.sending_domain_pill summary={@summary} id={@channel.id} />
          <button
            :if={@can_manage and @channel.state != :revoked}
            phx-click="check_channel_domain"
            phx-value-id={@channel.id}
            class="text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300"
            data-testid={"check-domain-#{@channel.id}"}
          >
            Check domain
          </button>
        </span>
      </div>
    </div>
    """
  end

  defp confirming({action, id}, id), do: action
  defp confirming(_confirm_action, _id), do: nil

  defp source_label(%InboundChannel{ingress_kind: :mx}), do: "Direct MX"
  defp source_label(%InboundChannel{provider: provider}), do: provider_label(provider)

  defp quiet_hint(%InboundChannel{ingress_kind: :mx}), do: "check the MX record"
  defp quiet_hint(_channel), do: "check the forwarding rule"

  defp provider_label(:google), do: "Gmail forwarding"
  defp provider_label(:google_workspace), do: "Google Workspace admin routing"
  defp provider_label(:proton), do: "Proton Mail"
  defp provider_label(:other), do: "Other provider"
  defp provider_label(_provider), do: "Provider not set"

  # D7: an active channel that was receiving mail and has gone quiet for its
  # window is the only signal that a forwarding rule was disabled upstream.
  defp channel_quiet?(%InboundChannel{state: :active, last_received_at: %DateTime{} = at} = ch) do
    DateTime.diff(DateTime.utc_now(), at, :hour) >= ch.quiet_after_hours
  end

  defp channel_quiet?(_channel), do: false

  defp relative_time(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at, :second)

    cond do
      seconds < 60 -> "just now"
      seconds < 3600 -> "#{div(seconds, 60)} min ago"
      seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  # --- Routes Tab ---

  attr :routes, :list, required: true
  attr :available_projects, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :show_create_form, :boolean, required: true
  attr :confirm_delete_route_id, :any, required: true
  attr :organization, :map, required: true
  attr :general_route_count, :integer, required: true

  defp routes_tab(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="org-routes-list">
      <%!-- Header with create button --%>
      <div :if={@can_manage} class="flex justify-end">
        <button
          :if={not @show_create_form}
          phx-click="show_create_route_form"
          class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
          data-testid="create-route-btn"
        >
          New Route
        </button>
      </div>

      <%!-- Create route form --%>
      <div
        :if={@show_create_form and @can_manage}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-indigo-300 dark:border-indigo-600"
        data-testid="create-route-form"
      >
        <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100 mb-3">Create New Route</h3>
        <form phx-submit="create_route" class="space-y-3">
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Route Type
              </label>
              <select
                name="route_type"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-type-select"
              >
                <option value="general">General</option>
                <option value="project">Project</option>
                <option value="disambiguation">Disambiguation</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Source
              </label>
              <select
                name="source"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-source-select"
              >
                <%= for source <- Custyard.InboundRoute.sources() do %>
                  <option value={source}>{to_string(source)}</option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Project (optional)
              </label>
              <select
                name="project_id"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-project-select"
              >
                <option value="">None</option>
                <%= for project <- @available_projects do %>
                  <option value={project.id}>{project.title}</option>
                <% end %>
              </select>
            </div>
          </div>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="hide_create_route_form"
              class="px-3 py-1.5 text-sm text-gray-700 dark:text-zinc-300 hover:text-gray-900 dark:hover:text-zinc-100"
              data-testid="cancel-create-route-btn"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
              data-testid="submit-create-route-btn"
            >
              Create
            </button>
          </div>
        </form>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@routes == []}
        class="text-center py-12"
        data-testid="org-routes-empty"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.07-9.07l4.5-4.5a4.5 4.5 0 016.364 6.364l-1.757 1.757"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No routes configured.</p>
      </div>

      <%!-- Route cards --%>
      <div
        :for={route <- @routes}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700"
        data-testid={"route-card-#{route.id}"}
      >
        <%!-- Route header: badges + delete --%>
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <.route_type_badge type={route.route_type} />
            <.source_badge source={route.source} />
            <span
              :if={route.project}
              class="text-xs text-gray-500 dark:text-zinc-400"
            >
              / {route.project.title}
            </span>
          </div>
          <div :if={@can_manage} class="flex items-center gap-2">
            <%= if @confirm_delete_route_id == route.id do %>
              <span class="text-xs text-red-600 dark:text-red-400 mr-1">Delete this route?</span>
              <button
                phx-click="delete_route"
                phx-value-id={route.id}
                class="text-xs px-2 py-1 text-white bg-red-600 hover:bg-red-700 rounded transition-colors"
                data-testid={"confirm-delete-route-#{route.id}"}
              >
                Yes, delete
              </button>
              <button
                phx-click="cancel_delete_route"
                class="text-xs px-2 py-1 text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-100"
                data-testid={"cancel-delete-route-#{route.id}"}
              >
                Cancel
              </button>
            <% else %>
              <%!-- Disable delete for last general route --%>
              <% is_last = route.route_type == :general and @general_route_count <= 1 %>
              <button
                phx-click="confirm_delete_route"
                phx-value-id={route.id}
                disabled={is_last}
                class={[
                  "text-xs px-2 py-1 rounded transition-colors",
                  if(is_last,
                    do: "text-gray-400 dark:text-zinc-600 cursor-not-allowed",
                    else:
                      "text-red-600 dark:text-red-400 hover:text-red-800 dark:hover:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
                  )
                ]}
                title={if is_last, do: "Cannot delete the last general route", else: "Delete route"}
                data-testid={"delete-route-#{route.id}"}
              >
                Delete
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Callback URL --%>
        <div class="mb-3">
          <div class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
            Callback URL
          </div>
          <div class="flex items-center gap-2">
            <code
              class="flex-1 text-xs bg-gray-50 dark:bg-zinc-900 text-gray-700 dark:text-zinc-300 px-2 py-1.5 rounded border border-gray-200 dark:border-zinc-700 break-all"
              data-testid={"route-callback-url-#{route.id}"}
            >
              {InboundRoutes.callback_url(route)}
            </code>
            <button
              id={"copy-url-#{route.id}"}
              phx-hook="CopyToClipboard"
              data-clipboard-text={InboundRoutes.callback_url(route)}
              class="text-xs px-2 py-1.5 text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors whitespace-nowrap"
              data-testid={"copy-url-#{route.id}"}
            >
              Copy URL
            </button>
          </div>
        </div>

        <%!-- Ingress domain (Lettermint routes with a known domain) --%>
        <% ingress_domain = InboundRoute.ingress_domain(route) %>
        <div :if={ingress_domain} class="mb-3">
          <div class="flex items-center gap-2">
            <p
              class="flex-1 text-xs text-gray-600 dark:text-zinc-400"
              data-testid={"route-ingress-domain-#{route.id}"}
            >
              Receives mail at any address
              <code class="text-gray-800 dark:text-zinc-200">@{ingress_domain}</code>
            </p>
            <button
              id={"copy-ingress-domain-#{route.id}"}
              phx-hook="CopyToClipboard"
              data-clipboard-text={ingress_domain}
              class="text-xs px-2 py-1.5 text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors whitespace-nowrap"
              data-testid={"copy-ingress-domain-#{route.id}"}
            >
              Copy domain
            </button>
          </div>
        </div>

        <%!-- Webhook purpose toggles --%>
        <div>
          <div class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
            Webhook Purposes
          </div>
          <div class="space-y-0.5">
            <%= for purpose <- Custyard.InboundRouteWebhook.purposes() do %>
              <% webhook = Enum.find(route.webhooks, fn w -> w.purpose == purpose end) %>
              <%= if purpose == :sender_matching do %>
                <%!-- sender_matching always runs regardless of toggle state (see Dispatcher @moduledoc) --%>
                <div title="Sender matching always runs — it is required to create conversations">
                  <.webhook_purpose_toggle
                    purpose={purpose}
                    enabled={webhook != nil and webhook.enabled}
                    route_id={route.id}
                    disabled={true}
                  />
                </div>
              <% else %>
                <.webhook_purpose_toggle
                  purpose={purpose}
                  enabled={webhook != nil and webhook.enabled}
                  route_id={route.id}
                  disabled={not @can_manage}
                />
              <% end %>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp validate_param(value, allowed, field_name) do
    if value in allowed,
      do: :ok,
      else: {:error, "Invalid #{field_name}: #{value}"}
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end
end
