defmodule CustyardWeb.Operator.IntakeSourcesLive do
  @moduledoc """
  Super-admin CRUD for public intake sources (CTAs).

  Stays thin: all validation lives in `Custyard.IntakeSource.changeset/2`.
  Mount is gated to super admins by the router live_session, and every
  mutating event re-checks `Authorization.can_modify_settings?/1`
  (settings double-gate pattern).

  The key is a public URL segment: it is set once at creation and never
  cast on update (`IntakeSource.update_changeset/2` enforces this at the
  context boundary) - the edit form additionally renders it read-only and
  the save path strips it from the params.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.FormHelpers, only: [format_error: 1]

  alias Custyard.{Authorization, Intake, IntakeSource}

  @permission_error "Only super admins can modify intake sources"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Intake Sources")
      |> assign(:show_form, false)
      |> assign(:editing_source, nil)
      |> assign(:form, nil)
      |> assign(:form_params, %{})
      |> assign(:questions, [])
      |> load_sources()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("new", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_source, nil)
     |> assign(:form_params, %{})
     |> rebuild_form([])}
  end

  @impl true
  def handle_event("edit", %{"id" => id}, socket) do
    case parse_id_or_flash(id, socket) do
      {:ok, int_id} ->
        case Intake.get_source(int_id) do
          nil ->
            {:noreply,
             socket
             |> put_flash(:error, "Intake source not found")
             |> load_sources()}

          source ->
            {:noreply,
             socket
             |> assign(:show_form, true)
             |> assign(:editing_source, source)
             |> assign(:form_params, %{})
             |> rebuild_form(source.questions)}
        end

      {:error, socket} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("cancel", _params, socket) do
    {:noreply, close_form(socket)}
  end

  @impl true
  def handle_event("validate", %{"intake_source" => params}, socket) do
    socket = assign(socket, :form_params, params)
    {:noreply, rebuild_form(socket, parse_questions(params))}
  end

  @impl true
  def handle_event("add_question", _params, socket) do
    questions = socket.assigns.questions

    if length(questions) < IntakeSource.max_questions() do
      {:noreply, rebuild_form(socket, questions ++ [%{"question" => "", "answer" => ""}])}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("remove_question", %{"index" => index}, socket) do
    case Integer.parse(index) do
      {i, ""} ->
        {:noreply, rebuild_form(socket, List.delete_at(socket.assigns.questions, i))}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("save", %{"intake_source" => params}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      save_source(socket, params)
    else
      {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  @impl true
  def handle_event("toggle_enabled", %{"id" => id}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      case parse_id_or_flash(id, socket) do
        {:ok, int_id} -> toggle_enabled(socket, int_id)
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      case parse_id_or_flash(id, socket) do
        {:ok, int_id} -> delete_source(socket, int_id)
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  defp parse_id_or_flash(id, socket) do
    case Integer.parse(id) do
      {int_id, ""} ->
        {:ok, int_id}

      _ ->
        {:error,
         socket
         |> put_flash(:error, "Intake source not found")
         |> load_sources()}
    end
  end

  defp save_source(socket, params) do
    questions = params |> parse_questions() |> drop_blank_questions()
    attrs = Map.put(params, "questions", questions)

    result =
      case socket.assigns.editing_source do
        nil ->
          Intake.create_source(attrs)

        source ->
          # The key is immutable after creation (public URL segment).
          # update_changeset/2 never casts it; stripping here is a second
          # layer so forged params never even reach the context.
          Intake.update_source(source, Map.delete(attrs, "key"))
      end

    socket =
      socket
      |> assign(:form_params, params)
      |> assign(:questions, questions)

    handle_save_result(socket, result)
  end

  defp handle_save_result(socket, {:ok, _source}) do
    action = if socket.assigns.editing_source, do: "updated", else: "created"

    {:noreply,
     socket
     |> put_flash(:info, "Intake source #{action} successfully")
     |> close_form()
     |> load_sources()}
  end

  defp handle_save_result(socket, {:error, changeset}) do
    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  defp toggle_enabled(socket, id) do
    case Intake.get_source(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Intake source not found")
         |> load_sources()}

      source ->
        case Intake.update_source(source, %{enabled: not source.enabled}) do
          {:ok, _source} ->
            {:noreply, load_sources(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update intake source")}
        end
    end
  end

  defp delete_source(socket, id) do
    case Intake.get_source(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Intake source not found")
         |> load_sources()}

      source ->
        case Intake.delete_source(source) do
          {:ok, _source} ->
            {:noreply,
             socket
             |> put_flash(:info, "Intake source deleted")
             |> maybe_close_form_for(source)
             |> load_sources()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to delete intake source")}
        end
    end
  end

  defp maybe_close_form_for(socket, source) do
    case socket.assigns.editing_source do
      %IntakeSource{id: id} when id == source.id -> close_form(socket)
      _ -> socket
    end
  end

  defp close_form(socket) do
    socket
    |> assign(:show_form, false)
    |> assign(:editing_source, nil)
    |> assign(:form_params, %{})
    |> assign(:questions, [])
  end

  # Rebuild the changeset-backed form from the latest typed params plus the
  # given question rows. The key is stripped on edit so it can never be
  # revalidated or changed through this form.
  defp rebuild_form(socket, questions) do
    editing_source = socket.assigns.editing_source
    base = editing_source || %IntakeSource{}

    attrs =
      socket.assigns.form_params
      |> Map.put("questions", questions)
      |> maybe_strip_key(editing_source)

    base_changeset =
      if editing_source do
        IntakeSource.update_changeset(base, attrs)
      else
        IntakeSource.changeset(base, attrs)
      end

    changeset = Map.put(base_changeset, :action, :validate)

    socket
    |> assign(:questions, questions)
    |> assign(:form, to_form(changeset))
  end

  defp maybe_strip_key(attrs, nil), do: attrs
  defp maybe_strip_key(attrs, %IntakeSource{}), do: Map.delete(attrs, "key")

  # Question rows arrive as %{"0" => %{"question" => q, "answer" => a}, ...};
  # normalize to an ordered list of two-key maps (the shape the changeset
  # validates).
  defp parse_questions(params) do
    params
    |> Map.get("questions", %{})
    |> Enum.sort_by(fn {index, _row} ->
      case Integer.parse(index) do
        {i, ""} -> i
        _ -> 0
      end
    end)
    |> Enum.map(fn {_index, row} ->
      %{"question" => Map.get(row, "question", ""), "answer" => Map.get(row, "answer", "")}
    end)
  end

  defp drop_blank_questions(questions) do
    Enum.reject(questions, fn %{"question" => question, "answer" => answer} ->
      String.trim(question) == "" and String.trim(answer) == ""
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-4 overflow-y-auto" data-testid="operator-intake-sources-page">
      <div class="flex items-center justify-between mb-6">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="operator-intake-sources-heading"
        >
          Intake Sources
        </h1>
        <button
          :if={not @show_form}
          phx-click="new"
          class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
          data-testid="operator-intake-sources-add-btn"
        >
          Add intake source
        </button>
      </div>

      <.source_form
        :if={@show_form && @form}
        form={@form}
        editing_source={@editing_source}
        questions={@questions}
      />

      <div
        :if={@sources == []}
        class="text-center py-12"
        data-testid="operator-intake-sources-empty"
      >
        <p class="text-gray-600 dark:text-zinc-400 text-sm mb-2">No intake sources yet</p>
        <p class="text-gray-400 dark:text-zinc-500 text-xs">
          Click "Add intake source" to create your first public intake entry point.
        </p>
      </div>

      <div :if={@sources != []} class="space-y-2">
        <.source_card :for={source <- @sources} source={source} />
      </div>
    </div>
    """
  end

  attr :form, Phoenix.HTML.Form, required: true
  attr :editing_source, IntakeSource, default: nil
  attr :questions, :list, required: true

  defp source_form(assigns) do
    ~H"""
    <div
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
      data-testid="operator-intake-source-form-card"
    >
      <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100 mb-4">
        {if @editing_source, do: "Edit intake source", else: "New intake source"}
      </h2>

      <.form
        for={@form}
        phx-change="validate"
        phx-submit="save"
        class="space-y-4"
        data-testid="operator-intake-source-form"
      >
        <div :if={is_nil(@editing_source)}>
          <.input
            field={@form[:key]}
            type="text"
            label="Key"
            placeholder="landing-page"
            data-testid="operator-intake-source-key-input"
          />
          <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
            Public URL segment: lowercase letters, numbers, hyphens, underscores.
            Cannot be changed after creation.
          </p>
        </div>

        <div :if={@editing_source} data-testid="operator-intake-source-key-readonly">
          <span class="block text-sm font-semibold leading-6 text-zinc-800 dark:text-zinc-200">
            Key
          </span>
          <p class="mt-2 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-900 px-3 py-2 rounded">
            {@editing_source.key}
          </p>
          <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
            The key is a public URL segment and cannot be changed.
          </p>
        </div>

        <.input
          field={@form[:name]}
          type="text"
          label="Name"
          data-testid="operator-intake-source-name-input"
        />

        <.input
          field={@form[:mode]}
          type="select"
          label="Mode"
          options={[{"Active (form-first)", "active"}, {"Passive (informational)", "passive"}]}
          data-testid="operator-intake-source-mode-select"
        />

        <.input
          field={@form[:headline]}
          type="text"
          label="Headline"
          data-testid="operator-intake-source-headline-input"
        />

        <.input
          field={@form[:intro_copy]}
          type="textarea"
          label="Intro copy"
          data-testid="operator-intake-source-intro-copy-input"
        />

        <fieldset class="border-t border-gray-200 dark:border-zinc-700 pt-4">
          <legend class="sr-only">Questions and answers</legend>
          <div class="flex items-center justify-between mb-2">
            <span class="text-sm font-semibold text-zinc-800 dark:text-zinc-200">
              Questions &amp; answers
            </span>
            <button
              :if={length(@questions) < IntakeSource.max_questions()}
              type="button"
              phx-click="add_question"
              class="text-xs text-indigo-600 hover:text-indigo-800 dark:text-indigo-400 dark:hover:text-indigo-300"
              data-testid="operator-intake-source-add-question"
            >
              Add question
            </button>
            <span
              :if={length(@questions) >= IntakeSource.max_questions()}
              class="text-xs text-gray-400 dark:text-zinc-500"
              data-testid="operator-intake-source-questions-cap"
            >
              Maximum of {IntakeSource.max_questions()} questions reached
            </span>
          </div>

          <p :if={@questions == []} class="text-xs text-gray-400 dark:text-zinc-500">
            No questions yet. Shown on passive intake pages as a Q&amp;A list.
          </p>

          <div
            :for={{row, index} <- Enum.with_index(@questions)}
            class="border border-gray-200 dark:border-zinc-700 rounded p-3 mb-2"
            data-testid={"operator-intake-source-question-row-#{index}"}
          >
            <div class="flex items-center justify-between mb-2">
              <label
                for={"intake_source_questions_#{index}_question"}
                class="text-xs font-medium text-gray-700 dark:text-zinc-300"
              >
                Question {index + 1}
              </label>
              <button
                type="button"
                phx-click="remove_question"
                phx-value-index={index}
                class="text-xs text-red-500 hover:text-red-700"
                data-testid={"operator-intake-source-remove-question-#{index}"}
              >
                Remove
              </button>
            </div>
            <input
              type="text"
              id={"intake_source_questions_#{index}_question"}
              name={"intake_source[questions][#{index}][question]"}
              value={row["question"]}
              class="w-full border border-gray-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 rounded px-3 py-2 text-sm mb-2"
              data-testid={"operator-intake-source-question-input-#{index}"}
            />
            <label
              for={"intake_source_questions_#{index}_answer"}
              class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1"
            >
              Answer
            </label>
            <textarea
              id={"intake_source_questions_#{index}_answer"}
              name={"intake_source[questions][#{index}][answer]"}
              rows="2"
              class="w-full border border-gray-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 text-zinc-900 dark:text-zinc-100 rounded px-3 py-2 text-sm"
              data-testid={"operator-intake-source-answer-input-#{index}"}
            >{row["answer"]}</textarea>
          </div>

          <p
            :for={err <- @form[:questions].errors}
            class="text-xs text-rose-600 dark:text-rose-400 mt-1"
            data-testid="operator-intake-source-questions-error"
          >
            {format_error(err)}
          </p>
        </fieldset>

        <.input
          field={@form[:enabled]}
          type="checkbox"
          label="Enabled"
          data-testid="operator-intake-source-enabled-input"
        />

        <div class="flex gap-2 pt-2 border-t border-gray-100 dark:border-zinc-700">
          <button
            type="submit"
            class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
            data-testid="operator-intake-source-submit-btn"
          >
            {if @editing_source, do: "Update", else: "Create"}
          </button>
          <button
            type="button"
            phx-click="cancel"
            class="text-gray-600 dark:text-zinc-400 text-sm px-4 py-2 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid="operator-intake-source-cancel-btn"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

  attr :source, IntakeSource, required: true

  defp source_card(assigns) do
    ~H"""
    <div
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4"
      data-testid={"operator-intake-source-card-#{@source.id}"}
    >
      <div class="flex items-start justify-between gap-4">
        <div class="min-w-0 flex-1">
          <div class="flex items-center gap-2 mb-1">
            <span
              class="font-semibold text-gray-900 dark:text-zinc-100 truncate"
              data-testid="operator-intake-source-name"
            >
              {@source.name}
            </span>
            <span
              class={"text-xs px-1.5 py-0.5 rounded #{mode_colors(@source.mode)}"}
              data-testid={"operator-intake-source-mode-badge-#{@source.mode}"}
            >
              {to_string(@source.mode)}
            </span>
            <span
              :if={not @source.enabled}
              class="text-xs px-1.5 py-0.5 rounded text-gray-500 dark:text-zinc-400 bg-gray-100 dark:bg-zinc-700"
              data-testid="operator-intake-source-disabled-badge"
            >
              disabled
            </span>
          </div>
          <div class="text-xs font-mono text-gray-500 dark:text-zinc-400 truncate">
            {@source.key}
          </div>
          <div
            :if={@source.questions != []}
            class="text-xs text-gray-400 dark:text-zinc-500 mt-1"
            data-testid="operator-intake-source-question-count"
          >
            {length(@source.questions)} {if length(@source.questions) == 1,
              do: "question",
              else: "questions"}
          </div>
        </div>

        <div class="flex items-center gap-2 shrink-0">
          <button
            type="button"
            phx-click="toggle_enabled"
            phx-value-id={@source.id}
            aria-label={"#{if @source.enabled, do: "Disable", else: "Enable"} #{@source.name}"}
            class={[
              "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200",
              if(@source.enabled, do: "bg-indigo-600", else: "bg-gray-200 dark:bg-zinc-600")
            ]}
            data-testid={"operator-intake-source-toggle-#{@source.id}"}
          >
            <span class={[
              "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow transform transition-transform duration-200",
              if(@source.enabled, do: "translate-x-4", else: "translate-x-0")
            ]} />
          </button>
          <button
            phx-click="edit"
            phx-value-id={@source.id}
            class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid={"operator-intake-source-edit-#{@source.id}"}
          >
            Edit
          </button>
          <button
            phx-click="delete"
            phx-value-id={@source.id}
            data-confirm={"Delete intake source \"#{@source.name}\"? Existing conversations keep their provenance tag."}
            class="text-xs text-red-500 hover:text-red-700 px-2 py-1 rounded hover:bg-red-50 dark:hover:bg-red-950"
            data-testid={"operator-intake-source-delete-#{@source.id}"}
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp mode_colors(:active),
    do: "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"

  defp mode_colors(:passive), do: "text-blue-700 dark:text-blue-300 bg-blue-50 dark:bg-blue-950"
  defp mode_colors(_other), do: "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"

  defp load_sources(socket) do
    assign(socket, :sources, Intake.list_sources())
  end
end
