defmodule CustyardWeb.Operator.OrganizationsLive do
  use CustyardWeb, :live_view

  alias Custyard.{Repo, Organization}
  import Ecto.Query

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:show_form, false)
      |> assign(:editing_org, nil)
      |> assign(:form_data, %{name: "", domain: "", tier: "standard"})
      |> load_organizations()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("show_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_org, nil)
     |> assign(:form_data, %{name: "", domain: "", tier: "standard"})}
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_org, nil)}
  end

  def handle_event("edit_org", %{"id" => id}, socket) do
    org = Repo.get!(Organization, id)

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_org, org)
     |> assign(:form_data, %{
       name: org.name,
       domain: org.domain || "",
       tier: to_string(org.tier)
     })}
  end

  def handle_event("update_form", %{"field" => field, "value" => value}, socket) do
    form_data = Map.put(socket.assigns.form_data, String.to_existing_atom(field), value)
    {:noreply, assign(socket, :form_data, form_data)}
  end

  def handle_event("save_org", _params, socket) do
    form_data = socket.assigns.form_data

    attrs = %{
      name: form_data.name,
      domain: if(form_data.domain == "", do: nil, else: form_data.domain),
      tier: String.to_existing_atom(form_data.tier)
    }

    result =
      case socket.assigns.editing_org do
        nil ->
          %Organization{}
          |> Organization.changeset(attrs)
          |> Repo.insert()

        org ->
          org
          |> Organization.changeset(attrs)
          |> Repo.update()
      end

    case result do
      {:ok, _org} ->
        {:noreply,
         socket
         |> assign(:show_form, false)
         |> assign(:editing_org, nil)
         |> load_organizations()}

      {:error, _changeset} ->
        {:noreply, socket}
    end
  end

  defp load_organizations(socket) do
    orgs =
      from(o in Organization,
        left_join: c in assoc(o, :conversations),
        group_by: o.id,
        select: %{org: o, conversation_count: count(c.id)},
        order_by: [asc: o.name]
      )
      |> Repo.all()

    assign(socket, :organizations, orgs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4">
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-lg font-semibold text-gray-900">Organizations</h1>
        <button
          phx-click="show_form"
          class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
        >
          Add organization
        </button>
      </div>

      <%= if @show_form do %>
        <.org_form
          form_data={@form_data}
          editing={@editing_org != nil}
        />
      <% end %>

      <div class="space-y-2">
        <%= for item <- @organizations do %>
          <.org_card org={item.org} conversation_count={item.conversation_count} />
        <% end %>
      </div>
    </div>
    """
  end

  attr :form_data, :map, required: true
  attr :editing, :boolean, required: true

  defp org_form(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-lg p-4 mb-4">
      <h2 class="text-sm font-semibold text-gray-900 mb-4">
        {if @editing, do: "Edit organization", else: "New organization"}
      </h2>

      <form phx-submit="save_org" class="space-y-4">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Name</label>
          <input
            type="text"
            name="name"
            value={@form_data.name}
            phx-change="update_form"
            phx-value-field="name"
            required
            class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Domain</label>
          <input
            type="text"
            name="domain"
            value={@form_data.domain}
            phx-change="update_form"
            phx-value-field="domain"
            placeholder="example.com"
            class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Tier</label>
          <select
            name="tier"
            phx-change="update_form"
            phx-value-field="tier"
            class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
          >
            <option value="basic" selected={@form_data.tier == "basic"}>Basic</option>
            <option value="standard" selected={@form_data.tier == "standard"}>Standard</option>
            <option value="enterprise" selected={@form_data.tier == "enterprise"}>Enterprise</option>
          </select>
        </div>

        <div class="flex gap-2">
          <button
            type="submit"
            class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
          >
            {if @editing, do: "Update", else: "Create"}
          </button>
          <button
            type="button"
            phx-click="hide_form"
            class="text-gray-600 text-sm px-4 py-2 rounded hover:bg-gray-100"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :org, Organization, required: true
  attr :conversation_count, :integer, required: true

  defp org_card(assigns) do
    ~H"""
    <div class="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-md transition-shadow">
      <div class="flex items-start justify-between">
        <div>
          <div class="flex items-center gap-2 mb-1">
            <span class="font-semibold text-gray-900">{@org.name}</span>
            <.tier_badge tier={@org.tier} />
          </div>
          <%= if @org.domain do %>
            <div class="text-sm text-gray-500 mb-2">{@org.domain}</div>
          <% end %>
          <div class="text-xs text-gray-400">
            {@conversation_count} {if @conversation_count == 1,
              do: "conversation",
              else: "conversations"}
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            phx-click="edit_org"
            phx-value-id={@org.id}
            class="text-xs text-gray-500 hover:text-gray-700 px-2 py-1 rounded hover:bg-gray-100"
          >
            Edit
          </button>
        </div>
      </div>

      <div class="mt-3 pt-3 border-t border-gray-100">
        <div class="text-xs text-gray-400 mb-1">Portal link</div>
        <code class="text-xs text-gray-600 bg-gray-50 px-2 py-1 rounded break-all">
          /p/{@org.token}
        </code>
      </div>
    </div>
    """
  end

  attr :tier, :atom, required: true

  defp tier_badge(assigns) do
    colors =
      case assigns.tier do
        :enterprise -> "text-purple-700 bg-purple-50"
        :standard -> "text-gray-600 bg-gray-50"
        :basic -> "text-gray-400 bg-gray-50"
        _ -> "text-gray-600 bg-gray-50"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}>
      {to_string(@tier)}
    </span>
    """
  end
end
