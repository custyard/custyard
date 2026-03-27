defmodule CustyardWeb.Portal.NewRequestLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversation, Message, Repo, Scoring}
  alias Ecto.Multi

  @impl true
  def mount(_params, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount

    {:ok,
     socket
     |> assign(:page_title, "New Request")
     |> assign(:form, to_form(%{"subject" => "", "body" => "", "urgency" => "normal"}))}
  end

  @allowed_urgencies ~w(normal elevated urgent)

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign(socket, :form, to_form(params))}
  end

  @impl true
  def handle_event("submit", %{"urgency" => urgency} = params, socket)
      when urgency in @allowed_urgencies do
    org = socket.assigns.current_org
    portal_path = socket.assigns.portal_path

    result =
      Multi.new()
      |> Multi.insert(
        :conversation,
        Conversation.changeset(%Conversation{}, %{
          organization_id: org.id,
          subject: params["subject"],
          state: :new,
          urgency: String.to_existing_atom(urgency),
          last_customer_action_at: DateTime.utc_now()
        })
      )
      |> Multi.insert(:message, fn %{conversation: conv} ->
        Message.changeset(%Message{}, %{
          conversation_id: conv.id,
          source: :portal,
          sender_email: "portal@#{org.domain || "portal"}",
          body: params["body"],
          is_internal_note: false
        })
      end)
      |> Repo.transaction()

    case result do
      {:ok, %{conversation: conv}} ->
        Scoring.calculate_and_cache(conv.id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations",
          {:conversation_created, conv.id}
        )

        {:noreply, push_navigate(socket, to: "#{portal_path}/request/#{conv.id}")}

      {:error, _step, changeset, _changes} ->
        errors =
          Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
          |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

        {:noreply,
         socket
         |> assign(:form, to_form(params))
         |> put_flash(:error, "Could not create request: #{errors}")}
    end
  end

  def handle_event("submit", params, socket) do
    {:noreply,
     socket
     |> assign(:form, to_form(params))
     |> put_flash(:error, "Invalid urgency value")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8 px-4" data-testid="portal-new-request">
      <h1
        class="text-2xl font-semibold text-gray-900 dark:text-zinc-100 mb-6"
        data-testid="portal-new-request-heading"
      >
        New Request
      </h1>

      <form phx-submit="submit" phx-change="validate" class="space-y-4" data-testid="portal-new-request-form">
        <div>
          <label
            for="subject"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
            data-testid="portal-subject-label"
          >
            Subject
          </label>
          <input
            type="text"
            name="subject"
            id="subject"
            required
            minlength="3"
            maxlength="200"
            data-testid="portal-subject-input"
            class="w-full border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100 rounded-lg focus:ring-indigo-500 focus:border-indigo-500 phx-submit-loading:opacity-50"
            value={@form[:subject].value}
          />
          <p class="mt-1 text-xs text-gray-500 dark:text-zinc-400">3-200 characters</p>
        </div>

        <div>
          <label
            for="urgency"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
            data-testid="portal-urgency-label"
          >
            Urgency
          </label>
          <select
            name="urgency"
            id="urgency"
            class="w-full border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100 rounded-lg focus:ring-indigo-500 focus:border-indigo-500 phx-submit-loading:opacity-50"
            data-testid="portal-urgency-select"
          >
            <option value="normal" selected={@form[:urgency].value == "normal"}>Normal</option>
            <option value="elevated" selected={@form[:urgency].value == "elevated"}>Elevated</option>
            <option value="urgent" selected={@form[:urgency].value == "urgent"}>Urgent</option>
          </select>
        </div>

        <div>
          <label
            for="body"
            class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1"
            data-testid="portal-body-label"
          >
            Description
          </label>
          <textarea
            name="body"
            id="body"
            rows="6"
            required
            minlength="10"
            data-testid="portal-body-textarea"
            class="w-full border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500 phx-submit-loading:opacity-50"
          ><%= @form[:body].value %></textarea>
          <p class="mt-1 text-xs text-gray-500 dark:text-zinc-400">Minimum 10 characters</p>
        </div>

        <div class="flex justify-end gap-3">
          <.link
            navigate={@portal_home_path}
            class="px-4 py-2 text-gray-700 dark:text-zinc-300 hover:text-gray-900 dark:hover:text-zinc-100"
            data-testid="portal-cancel-link"
          >
            Cancel
          </.link>
          <button
            type="submit"
            phx-disable-with="Submitting..."
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700 phx-submit-loading:opacity-75"
            data-testid="portal-submit"
          >
            Submit Request
          </button>
        </div>
      </form>
    </div>
    """
  end
end
