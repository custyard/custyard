defmodule CustyardWeb.Operator.OrganizationsLive do
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents
  import CustyardWeb.FormHelpers

  alias Custyard.{Authorization, Organization, Organizations}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Organizations")
      |> assign(:show_form, false)
      |> assign(:editing_org, nil)
      |> assign(:form_data, %{
        name: "",
        domain: "",
        tier: "standard",
        primary_color: "",
        secondary_color: "",
        custom_domain: ""
      })
      |> allow_upload(:logo,
        accept: ~w(.jpg .jpeg .png .gif .webp),
        max_entries: 1,
        max_file_size: 2_000_000
      )
      |> load_organizations()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("show_form", _params, socket) do
    if Authorization.can_create_organization?(socket.assigns.current_operator) do
      {:noreply,
       socket
       |> assign(:show_form, true)
       |> assign(:editing_org, nil)
       |> assign(:form_data, %{
         name: "",
         domain: "",
         tier: "standard",
         primary_color: "",
         secondary_color: "",
         custom_domain: ""
       })}
    else
      {:noreply, put_flash(socket, :error, "Only super admins can create organizations")}
    end
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_org, nil)}
  end

  def handle_event("edit_org", %{"id" => id}, socket) do
    case Organizations.get_organization(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Organization not found")
         |> load_organizations()}

      org ->
        if Authorization.can_manage_organization?(socket.assigns.current_operator, org.id) do
          {:noreply,
           socket
           |> assign(:show_form, true)
           |> assign(:editing_org, org)
           |> assign(:form_data, %{
             name: org.name,
             domain: org.domain || "",
             tier: to_string(org.tier),
             primary_color: org.primary_color || "",
             secondary_color: org.secondary_color || "",
             custom_domain: org.custom_domain || ""
           })}
        else
          {:noreply,
           put_flash(socket, :error, "You do not have permission to edit this organization")}
        end
    end
  end

  @form_fields ~w(name domain tier primary_color secondary_color custom_domain)a

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  def handle_event("validate_form", params, socket) do
    form_data = socket.assigns.form_data

    form_data =
      Enum.reduce(@form_fields, form_data, fn field, acc ->
        Map.put(acc, field, Map.get(params, to_string(field), Map.get(acc, field)))
      end)

    form_data =
      case Map.get(params, "_target") do
        ["primary_color_picker"] ->
          %{form_data | primary_color: Map.get(params, "primary_color_picker", "")}

        ["secondary_color_picker"] ->
          %{form_data | secondary_color: Map.get(params, "secondary_color_picker", "")}

        _ ->
          form_data
      end

    {:noreply, assign(socket, :form_data, form_data)}
  end

  def handle_event("save_org", _params, socket) do
    operator = socket.assigns.current_operator

    authorized? =
      case socket.assigns.editing_org do
        nil -> Authorization.can_create_organization?(operator)
        org -> Authorization.can_manage_organization?(operator, org.id)
      end

    if authorized? do
      attrs = build_org_attrs(socket)

      result =
        case socket.assigns.editing_org do
          nil -> Organizations.create_organization(attrs)
          org -> Organizations.update_organization(org, attrs)
        end

      handle_save_result(socket, result)
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to perform this action")}
    end
  end

  @valid_tiers ~w(enterprise standard basic)

  defp build_org_attrs(socket) do
    form_data = socket.assigns.form_data
    old_logo_url = get_old_logo_url(socket)
    logo_url = consume_uploaded_logo(socket)

    # Clean up old logo file when uploading a new one
    if logo_url && old_logo_url do
      delete_old_logo(old_logo_url)
    end

    %{
      name: form_data.name,
      domain: empty_to_nil(form_data.domain),
      tier: parse_tier(form_data.tier),
      primary_color: empty_to_nil(form_data.primary_color),
      secondary_color: empty_to_nil(form_data.secondary_color),
      custom_domain: empty_to_nil(form_data.custom_domain)
    }
    |> maybe_add_logo(logo_url)
  end

  defp get_old_logo_url(socket) do
    case socket.assigns[:editing_org] do
      %{logo_url: url} when is_binary(url) -> url
      _ -> nil
    end
  end

  defp delete_old_logo("/uploads/logos/" <> filename) do
    upload_dir = Application.get_env(:custyard, :upload_dir)
    path = Path.join([upload_dir, "logos", filename])
    File.rm(path)
  end

  defp delete_old_logo(_), do: :ok

  defp parse_tier(tier) when tier in @valid_tiers, do: String.to_existing_atom(tier)
  defp parse_tier(_), do: :standard

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp maybe_add_logo(attrs, nil), do: attrs
  defp maybe_add_logo(attrs, logo_url), do: Map.put(attrs, :logo_url, logo_url)

  defp handle_save_result(socket, {:ok, _org}) do
    action = if socket.assigns.editing_org, do: "updated", else: "created"

    {:noreply,
     socket
     |> put_flash(:info, "Organization #{action} successfully.")
     |> assign(:show_form, false)
     |> assign(:editing_org, nil)
     |> load_organizations()}
  end

  defp handle_save_result(socket, {:error, changeset}) do
    {:noreply, put_flash(socket, :error, "Failed to save: #{format_changeset_errors(changeset)}")}
  end

  defp consume_uploaded_logo(socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, entry ->
        # Generate a unique filename
        ext = Path.extname(entry.client_name)
        filename = "#{Ecto.UUID.generate()}#{ext}"
        upload_dir = Application.get_env(:custyard, :upload_dir)
        dest_dir = Path.join(upload_dir, "logos")
        File.mkdir_p!(dest_dir)
        dest = Path.join(dest_dir, filename)

        # Copy the uploaded file
        File.cp!(path, dest)

        # Return the public URL path
        {:ok, "/uploads/logos/#{filename}"}
      end)

    # Return the first uploaded file URL, or nil if none
    List.first(uploaded_files)
  end

  defp load_organizations(socket) do
    orgs = Organizations.list_organizations_with_counts()
    assign(socket, :organizations, orgs)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4" data-testid="operator-orgs-page">
      <div class="flex items-center justify-between mb-6">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="operator-orgs-heading"
        >
          Organizations
        </h1>
        <button
          phx-click="show_form"
          class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
          data-testid="operator-orgs-add-btn"
        >
          Add organization
        </button>
      </div>

      <.org_form
        :if={@show_form}
        form_data={@form_data}
        editing={@editing_org != nil}
        uploads={@uploads}
        editing_org={@editing_org}
      />

      <div :if={@organizations == []} class="text-center py-12" data-testid="operator-orgs-empty">
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
              d="M19 21V5a2 2 0 00-2-2H7a2 2 0 00-2 2v16m14 0h2m-2 0h-5m-9 0H3m2 0h5M9 7h1m-1 4h1m4-4h1m-1 4h1m-5 10v-5a1 1 0 011-1h2a1 1 0 011 1v5m-4 0h4"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm mb-2">No organizations yet</p>
        <p class="text-gray-400 dark:text-zinc-500 text-xs">
          Click "Add organization" to create your first customer organization.
        </p>
      </div>

      <div :if={@organizations != []} class="space-y-2">
        <.org_card
          :for={item <- @organizations}
          org={item.org}
          conversation_count={item.conversation_count}
        />
      </div>
    </div>
    """
  end

  # Helper for upload error messages - defined before org_form to be available in HEEx
  defp upload_error_to_string(:too_large), do: "File is too large (max 2MB)"
  defp upload_error_to_string(:not_accepted), do: "Invalid file type"
  defp upload_error_to_string(:too_many_files), do: "Only one file allowed"
  defp upload_error_to_string(_), do: "Upload error"

  attr :form_data, :map, required: true
  attr :editing, :boolean, required: true
  attr :uploads, :map, required: true
  attr :editing_org, :any, default: nil

  defp org_form(assigns) do
    ~H"""
    <div
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
      data-testid="operator-org-form-card"
    >
      <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100 mb-4">
        {if @editing, do: "Edit organization", else: "New organization"}
      </h2>

      <form
        phx-submit="save_org"
        phx-change="validate_form"
        class="space-y-4"
        data-testid="operator-org-form"
      >
        <div>
          <label
            for="org-name"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Name
          </label>
          <input
            type="text"
            name="name"
            id="org-name"
            value={@form_data.name}
            required
            phx-debounce="300"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-org-name-input"
          />
        </div>

        <div>
          <label
            for="org-domain"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Domain
          </label>
          <input
            type="text"
            name="domain"
            id="org-domain"
            value={@form_data.domain}
            placeholder="example.com"
            phx-debounce="300"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-org-domain-input"
          />
        </div>

        <div>
          <label
            for="org-custom-domain"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Custom Domain
          </label>
          <input
            type="text"
            name="custom_domain"
            id="org-custom-domain"
            value={@form_data.custom_domain}
            placeholder="support.example.com"
            phx-debounce="300"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-org-custom-domain-input"
          />
          <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
            White-label portal domain. Requires CNAME pointing to app host.
          </p>
        </div>

        <div>
          <label
            for="org-tier"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
          >
            Tier
          </label>
          <select
            name="tier"
            id="org-tier"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-org-tier-select"
          >
            <option value="basic" selected={@form_data.tier == "basic"}>Basic</option>
            <option value="standard" selected={@form_data.tier == "standard"}>Standard</option>
            <option value="enterprise" selected={@form_data.tier == "enterprise"}>Enterprise</option>
          </select>
        </div>

        <div class="border-t border-gray-200 dark:border-zinc-700 pt-4 mt-4">
          <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100 mb-3">Branding</h3>

          <div class="space-y-4">
            <div>
              <label
                for={@uploads.logo.ref}
                class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
              >
                Logo
              </label>
              <div class="flex items-start gap-4">
                <div :if={@editing_org && @editing_org.logo_url} class="shrink-0">
                  <img
                    src={@editing_org.logo_url}
                    alt="Current logo"
                    class="w-16 h-16 rounded object-cover border border-gray-200 dark:border-zinc-700"
                  />
                  <span class="text-xs text-gray-500 dark:text-zinc-400 mt-1 block">Current</span>
                </div>
                <div class="flex-1">
                  <.live_file_input upload={@uploads.logo} class="text-sm" />
                  <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
                    JPG, PNG, GIF, or WebP. Max 2MB.
                  </p>
                  <div :for={entry <- @uploads.logo.entries} class="mt-2">
                    <div class="flex items-center gap-2">
                      <div class="text-sm text-gray-600 dark:text-zinc-400">{entry.client_name}</div>
                      <progress value={entry.progress} max="100" class="w-20 h-2" />
                      <button
                        type="button"
                        phx-click="cancel_upload"
                        phx-value-ref={entry.ref}
                        class="text-red-500 text-xs hover:text-red-700"
                      >
                        Cancel
                      </button>
                    </div>
                    <div
                      :for={err <- upload_errors(@uploads.logo, entry)}
                      class="text-red-500 text-xs mt-1"
                    >
                      {upload_error_to_string(err)}
                    </div>
                  </div>
                  <div :for={err <- upload_errors(@uploads.logo)} class="text-red-500 text-xs mt-1">
                    {upload_error_to_string(err)}
                  </div>
                </div>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label
                  for="org-primary-color"
                  class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
                >
                  Primary Color
                </label>
                <div class="flex items-center gap-2">
                  <div class="relative">
                    <input
                      type="color"
                      name="primary_color_picker"
                      id="org-primary-color-picker"
                      aria-label="Primary color picker"
                      value={
                        if(@form_data.primary_color != "",
                          do: @form_data.primary_color,
                          else: "#808080"
                        )
                      }
                      class={[
                        "w-10 h-10 rounded border cursor-pointer",
                        if(@form_data.primary_color == "",
                          do: "border-dashed border-gray-400 dark:border-zinc-500 opacity-50",
                          else: "border-gray-300 dark:border-zinc-600"
                        )
                      ]}
                      data-testid="operator-org-primary-color-picker"
                    />
                    <span
                      :if={@form_data.primary_color == ""}
                      class="absolute inset-0 flex items-center justify-center text-gray-400 dark:text-zinc-500 text-xs pointer-events-none"
                    >
                      ?
                    </span>
                  </div>
                  <input
                    type="text"
                    name="primary_color"
                    id="org-primary-color"
                    value={@form_data.primary_color}
                    placeholder="#4f46e5 (default)"
                    pattern="^#[0-9A-Fa-f]{6}$"
                    phx-debounce="300"
                    class="flex-1 border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm dark:bg-zinc-700 dark:text-zinc-100"
                    data-testid="operator-org-primary-color-input"
                  />
                </div>
                <p
                  :if={@form_data.primary_color == ""}
                  class="text-xs text-gray-400 dark:text-zinc-500 mt-1"
                >
                  Uses default indigo if not set
                </p>
              </div>

              <div>
                <label
                  for="org-secondary-color"
                  class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
                >
                  Secondary Color
                </label>
                <div class="flex items-center gap-2">
                  <div class="relative">
                    <input
                      type="color"
                      name="secondary_color_picker"
                      id="org-secondary-color-picker"
                      aria-label="Secondary color picker"
                      value={
                        if(@form_data.secondary_color != "",
                          do: @form_data.secondary_color,
                          else: "#808080"
                        )
                      }
                      class={[
                        "w-10 h-10 rounded border cursor-pointer",
                        if(@form_data.secondary_color == "",
                          do: "border-dashed border-gray-400 dark:border-zinc-500 opacity-50",
                          else: "border-gray-300 dark:border-zinc-600"
                        )
                      ]}
                      data-testid="operator-org-secondary-color-picker"
                    />
                    <span
                      :if={@form_data.secondary_color == ""}
                      class="absolute inset-0 flex items-center justify-center text-gray-400 dark:text-zinc-500 text-xs pointer-events-none"
                    >
                      ?
                    </span>
                  </div>
                  <input
                    type="text"
                    name="secondary_color"
                    id="org-secondary-color"
                    value={@form_data.secondary_color}
                    placeholder="#6366f1 (default)"
                    pattern="^#[0-9A-Fa-f]{6}$"
                    phx-debounce="300"
                    class="flex-1 border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm dark:bg-zinc-700 dark:text-zinc-100"
                    data-testid="operator-org-secondary-color-input"
                  />
                </div>
                <p
                  :if={@form_data.secondary_color == ""}
                  class="text-xs text-gray-400 dark:text-zinc-500 mt-1"
                >
                  Uses default indigo if not set
                </p>
              </div>
            </div>
          </div>
        </div>

        <div class="flex gap-2">
          <button
            type="submit"
            class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
            data-testid="operator-org-submit-btn"
          >
            {if @editing, do: "Update", else: "Create"}
          </button>
          <button
            type="button"
            phx-click="hide_form"
            data-confirm="Discard unsaved changes?"
            class="text-gray-600 dark:text-zinc-400 text-sm px-4 py-2 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid="operator-org-cancel-btn"
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
    <div
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 hover:shadow-md transition-shadow"
      data-testid={"operator-org-card-#{@org.id}"}
    >
      <div class="flex items-start justify-between">
        <div class="flex items-start gap-3">
          <button
            :if={@org.logo_url}
            type="button"
            phx-click="edit_org"
            phx-value-id={@org.id}
            class="shrink-0 cursor-pointer hover:opacity-80 transition-opacity"
          >
            <img
              src={@org.logo_url}
              alt={"#{@org.name} logo"}
              class="w-10 h-10 rounded object-cover border border-gray-100 dark:border-zinc-700"
            />
          </button>
          <button
            :if={!@org.logo_url}
            type="button"
            phx-click="edit_org"
            phx-value-id={@org.id}
            class="shrink-0 w-10 h-10 rounded bg-gray-100 dark:bg-zinc-800 flex items-center justify-center cursor-pointer hover:bg-gray-200 dark:hover:bg-zinc-700 transition-colors"
          >
            <span class="text-gray-400 dark:text-zinc-500 text-sm font-medium">
              {String.first(@org.name)}
            </span>
          </button>
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2 mb-1">
              <button
                type="button"
                phx-click="edit_org"
                phx-value-id={@org.id}
                class="font-semibold text-gray-900 dark:text-zinc-100 truncate hover:text-indigo-600 dark:hover:text-indigo-400 transition-colors cursor-pointer text-left"
                data-testid="operator-org-name"
                title="Click to view and edit organization details"
              >
                {@org.name}
              </button>
              <.tier_badge tier={@org.tier} />
            </div>
            <div
              :if={@org.domain}
              class="text-sm text-gray-500 dark:text-zinc-400 mb-2 truncate"
              title={@org.domain}
            >
              {@org.domain}
            </div>
            <div
              class="text-xs text-gray-400 dark:text-zinc-500"
              data-testid="operator-org-conv-count"
            >
              {@conversation_count} {if @conversation_count == 1,
                do: "conversation",
                else: "conversations"}
            </div>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            phx-click="edit_org"
            phx-value-id={@org.id}
            class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid={"operator-org-edit-#{@org.id}"}
          >
            Edit
          </button>
        </div>
      </div>

      <div
        class="mt-3 pt-3 border-t border-gray-100 dark:border-zinc-700"
        data-testid={"operator-org-portal-link-#{@org.id}"}
      >
        <div class="text-xs text-gray-400 dark:text-zinc-500 mb-1">Portal link</div>
        <a
          href={"#{CustyardWeb.Endpoint.url()}/p/#{@org.token}"}
          target="_blank"
          rel="noopener noreferrer"
          class="text-xs text-indigo-600 hover:text-indigo-800 dark:text-indigo-400 dark:hover:text-indigo-300 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded break-all inline-block"
        >
          {CustyardWeb.Endpoint.url()}/p/{@org.token}
        </a>
      </div>
    </div>
    """
  end
end
