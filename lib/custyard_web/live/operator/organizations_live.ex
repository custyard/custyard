defmodule CustyardWeb.Operator.OrganizationsLive do
  use CustyardWeb, :live_view

  alias Custyard.{Organization, Organizations}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
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
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_org, nil)}
  end

  def handle_event("edit_org", %{"id" => id}, socket) do
    org = Organizations.get_organization!(id)

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
  end

  @form_fields ~w(name domain tier primary_color secondary_color custom_domain)a

  def handle_event("update_form", %{"field" => field, "value" => value}, socket) do
    field_atom = String.to_existing_atom(field)

    if field_atom in @form_fields do
      form_data = Map.put(socket.assigns.form_data, field_atom, value)
      {:noreply, assign(socket, :form_data, form_data)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  def handle_event("validate_form", _params, socket) do
    # Just validate uploads, form fields are handled by update_form
    {:noreply, socket}
  end

  def handle_event("save_org", _params, socket) do
    attrs = build_org_attrs(socket)

    result =
      case socket.assigns.editing_org do
        nil -> Organizations.create_organization(attrs)
        org -> Organizations.update_organization(org, attrs)
      end

    handle_save_result(socket, result)
  end

  defp build_org_attrs(socket) do
    form_data = socket.assigns.form_data
    logo_url = consume_uploaded_logo(socket)

    %{
      name: form_data.name,
      domain: empty_to_nil(form_data.domain),
      tier: String.to_existing_atom(form_data.tier),
      primary_color: empty_to_nil(form_data.primary_color),
      secondary_color: empty_to_nil(form_data.secondary_color),
      custom_domain: empty_to_nil(form_data.custom_domain)
    }
    |> maybe_add_logo(logo_url)
  end

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

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_error/1)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp consume_uploaded_logo(socket) do
    uploaded_files =
      consume_uploaded_entries(socket, :logo, fn %{path: path}, entry ->
        # Generate a unique filename
        ext = Path.extname(entry.client_name)
        filename = "#{Ecto.UUID.generate()}#{ext}"
        dest_dir = Path.join([:code.priv_dir(:custyard), "static", "uploads", "logos"])
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
        <h1 class="text-lg font-semibold text-gray-900" data-testid="operator-orgs-heading">
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

      <div class="space-y-2">
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
      class="bg-white border border-gray-200 rounded-lg p-4 mb-4"
      data-testid="operator-org-form-card"
    >
      <h2 class="text-sm font-semibold text-gray-900 mb-4">
        {if @editing, do: "Edit organization", else: "New organization"}
      </h2>

      <form
        phx-submit="save_org"
        phx-change="validate_form"
        class="space-y-4"
        data-testid="operator-org-form"
      >
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
          <label class="block text-sm font-medium text-gray-700 mb-1">Custom Domain</label>
          <input
            type="text"
            name="custom_domain"
            value={@form_data.custom_domain}
            phx-change="update_form"
            phx-value-field="custom_domain"
            placeholder="support.example.com"
            class="w-full border border-gray-300 rounded px-3 py-2 text-sm"
          />
          <p class="text-xs text-gray-500 mt-1">
            White-label portal domain. Requires CNAME pointing to app host.
          </p>
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

        <div class="border-t border-gray-200 pt-4 mt-4">
          <h3 class="text-sm font-medium text-gray-900 mb-3">Branding</h3>

          <div class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-gray-700 mb-1">Logo</label>
              <div class="flex items-start gap-4">
                <div :if={@editing_org && @editing_org.logo_url} class="flex-shrink-0">
                  <img
                    src={@editing_org.logo_url}
                    alt="Current logo"
                    class="w-16 h-16 rounded object-cover border border-gray-200"
                  />
                  <span class="text-xs text-gray-500 mt-1 block">Current</span>
                </div>
                <div class="flex-1">
                  <.live_file_input upload={@uploads.logo} class="text-sm" />
                  <p class="text-xs text-gray-500 mt-1">
                    JPG, PNG, GIF, or WebP. Max 2MB.
                  </p>
                  <div :for={entry <- @uploads.logo.entries} class="mt-2 flex items-center gap-2">
                    <div class="text-sm text-gray-600">{entry.client_name}</div>
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
                  <div :for={err <- upload_errors(@uploads.logo)} class="text-red-500 text-xs mt-1">
                    {upload_error_to_string(err)}
                  </div>
                </div>
              </div>
            </div>

            <div class="grid grid-cols-2 gap-4">
              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Primary Color
                </label>
                <div class="flex items-center gap-2">
                  <input
                    type="color"
                    name="primary_color_picker"
                    value={
                      if(@form_data.primary_color != "",
                        do: @form_data.primary_color,
                        else: "#4f46e5"
                      )
                    }
                    phx-change="update_form"
                    phx-value-field="primary_color"
                    class="w-10 h-10 rounded border border-gray-300 cursor-pointer"
                  />
                  <input
                    type="text"
                    name="primary_color"
                    value={@form_data.primary_color}
                    phx-change="update_form"
                    phx-value-field="primary_color"
                    placeholder="#4f46e5"
                    pattern="^#[0-9A-Fa-f]{6}$"
                    class="flex-1 border border-gray-300 rounded px-3 py-2 text-sm"
                  />
                </div>
              </div>

              <div>
                <label class="block text-sm font-medium text-gray-700 mb-1">
                  Secondary Color
                </label>
                <div class="flex items-center gap-2">
                  <input
                    type="color"
                    name="secondary_color_picker"
                    value={
                      if(@form_data.secondary_color != "",
                        do: @form_data.secondary_color,
                        else: "#6366f1"
                      )
                    }
                    phx-change="update_form"
                    phx-value-field="secondary_color"
                    class="w-10 h-10 rounded border border-gray-300 cursor-pointer"
                  />
                  <input
                    type="text"
                    name="secondary_color"
                    value={@form_data.secondary_color}
                    phx-change="update_form"
                    phx-value-field="secondary_color"
                    placeholder="#6366f1"
                    pattern="^#[0-9A-Fa-f]{6}$"
                    class="flex-1 border border-gray-300 rounded px-3 py-2 text-sm"
                  />
                </div>
              </div>
            </div>
          </div>
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
    <div
      class="bg-white border border-gray-200 rounded-lg p-4 hover:shadow-md transition-shadow"
      data-testid={"operator-org-card-#{@org.id}"}
    >
      <div class="flex items-start justify-between">
        <div class="flex items-start gap-3">
          <div :if={@org.logo_url} class="flex-shrink-0">
            <img
              src={@org.logo_url}
              alt={"#{@org.name} logo"}
              class="w-10 h-10 rounded object-cover border border-gray-100"
            />
          </div>
          <div
            :if={!@org.logo_url}
            class="flex-shrink-0 w-10 h-10 rounded bg-gray-100 flex items-center justify-center"
          >
            <span class="text-gray-400 text-sm font-medium">
              {String.first(@org.name)}
            </span>
          </div>
          <div>
            <div class="flex items-center gap-2 mb-1">
              <span class="font-semibold text-gray-900" data-testid="operator-org-name">
                {@org.name}
              </span>
              <.tier_badge tier={@org.tier} />
            </div>
            <div :if={@org.domain} class="text-sm text-gray-500 mb-2">{@org.domain}</div>
            <div class="text-xs text-gray-400">
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
            class="text-xs text-gray-500 hover:text-gray-700 px-2 py-1 rounded hover:bg-gray-100"
            data-testid={"operator-org-edit-#{@org.id}"}
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
