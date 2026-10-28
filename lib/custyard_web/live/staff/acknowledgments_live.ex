defmodule CustyardWeb.Staff.AcknowledgmentsLive do
  @moduledoc """
  Tenant administrator operation of the Colonel acknowledgment subscription: status,
  queue counts, the oldest failed message (sanitized) with a guarded replay,
  and organization bindings.

  Broker work runs in `start_async` tasks, one at a time; events that would
  start another are ignored while one runs. The task is linked to this view
  and is killed with it, so `Operations` closes the broker connection when its
  caller dies; only a confirmed replay runs on to completion. Nothing touches
  the broker from mount beyond read-only queue counts, and nothing reads query
  params. Assigns never hold the broker URL or a message body: only the
  overview map and sanitized summaries.
  """
  use CustyardWeb, :live_view

  alias Custyard.{Acknowledgments, StaffAccounts, Organizations}
  alias Custyard.Acknowledgments.{Evidence, Operations}

  # Longer than a connect timeout plus a publisher confirm; a broker that
  # stops answering mid-operation must not leave the page disabled.
  @operation_timeout 30_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Acknowledgments")
      |> assign(:in_flight, nil)
      |> assign(:operation_ref, nil)
      |> assign(:counts, nil)
      |> assign(:failure, nil)
      |> assign(:confirming_replay, false)
      |> assign(:replay_result, nil)
      |> assign(:pending_bind, nil)
      |> assign(:bind_result, nil)
      |> assign(:bind_errors, [])
      |> assign(:bind_form, bind_form(%{}))
      |> load_overview()
      |> load_bindings()

    socket =
      if connected?(socket) and socket.assigns.overview.broker_configured?,
        do: start_operation(socket, :counts),
        else: socket

    {:ok, socket, layout: {CustyardWeb.Layouts, :staff}}
  end

  def handle_event("configure_integration", %{"integration" => attrs}, socket) do
    when_allowed(socket, fn ->
      case Acknowledgments.configure_integration(socket.assigns.current_scope, attrs) do
        {:ok, _} ->
          socket |> load_overview() |> load_bindings() |> put_flash(:info, "Integration saved")

        {:error, _} ->
          put_flash(socket, :error, "Integration settings are invalid")
      end
    end)
  end

  # --- Broker operations ---

  @impl true
  def handle_event("refresh", _params, socket) do
    when_allowed(socket, fn ->
      socket = socket |> load_overview() |> load_bindings()

      if socket.assigns.overview.broker_configured?,
        do: start_operation(socket, :counts),
        else: socket
    end)
  end

  def handle_event("inspect", _params, socket) do
    when_allowed(socket, fn ->
      socket
      |> assign(:confirming_replay, false)
      |> assign(:replay_result, nil)
      |> start_operation(:inspect)
    end)
  end

  def handle_event("confirm_replay", _params, socket) do
    when_allowed(socket, fn ->
      assign(socket, :confirming_replay, replayable?(socket.assigns.failure))
    end)
  end

  def handle_event("cancel_replay", _params, socket),
    do: {:noreply, assign(socket, :confirming_replay, false)}

  # The submission ID and body digest come from the inspected summary held
  # server-side, never from the client.
  def handle_event("replay", _params, socket) do
    when_allowed(socket, fn ->
      confirmed? = socket.assigns.confirming_replay
      socket = assign(socket, :confirming_replay, false)

      case socket.assigns.failure do
        {:summary, %{readable: true, submission_id: id, body_sha256: hash}} when confirmed? ->
          expected = %{submission_id: id, body_sha256: hash}
          start_operation(socket, {:replay, expected, socket.assigns.current_staff})

        _ ->
          socket
      end
    end)
  end

  # --- Bindings ---

  def handle_event("review_bind", %{"binding" => params}, socket) do
    when_allowed(socket, fn -> review_bind(socket, params) end)
  end

  def handle_event("review_bind", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_bind", _params, socket),
    do: {:noreply, assign(socket, :pending_bind, nil)}

  def handle_event("confirm_bind", _params, socket) do
    when_allowed(socket, fn ->
      case socket.assigns.pending_bind do
        nil -> socket
        pending -> confirm_bind(socket, pending)
      end
    end)
  end

  # Every handler that reaches the broker or the database re-checks the role
  # on the staff StaffAuth just reloaded, and does nothing while another
  # operation runs.
  defp when_allowed(socket, fun) do
    cond do
      not match?(
        %Custyard.StaffAccount{role: "admin"},
        Custyard.Scope.current_staff(socket.assigns.current_scope)
      ) ->
        {:noreply,
         put_flash(socket, :error, "Only tenant administrators can operate acknowledgments")}

      socket.assigns.in_flight ->
        {:noreply, socket}

      true ->
        {:noreply, fun.()}
    end
  end

  defp review_bind(socket, params) do
    source = Acknowledgments.configured_source(socket.assigns.current_scope)
    external_id = Map.get(params, "source_organization_id", "")

    organization =
      find_organization(Map.get(params, "organization_id"), socket.assigns.current_scope)

    errors =
      [
        is_nil(source) &&
          "Configure this tenant integration before adding customer bindings",
        not Evidence.valid_identity?(external_id) &&
          "Source organization ID must be a nonblank identity of at most 255 bytes without surrounding spaces or control characters",
        is_nil(organization) && "Choose an existing organization"
      ]
      |> Enum.filter(&is_binary/1)

    socket =
      socket
      |> assign(:bind_form, bind_form(params))
      |> assign(:bind_errors, errors)
      |> assign(:bind_result, nil)

    if errors == [] do
      assign(socket, :pending_bind, %{
        source: source,
        source_organization_id: external_id,
        organization_id: organization.id,
        organization_name: organization.name
      })
    else
      assign(socket, :pending_bind, nil)
    end
  end

  defp confirm_bind(socket, pending) do
    # The form is pinned to the configured source; a source changed since
    # review is not bound under the old name.
    result =
      if Acknowledgments.configured_source(socket.assigns.current_scope) == pending.source,
        do:
          Acknowledgments.bind(
            socket.assigns.current_scope,
            pending.source,
            pending.source_organization_id,
            pending.organization_id
          ),
        else: {:error, :source_changed}

    socket
    |> assign(:pending_bind, nil)
    |> assign(:bind_result, bind_result(result, pending))
    |> then(fn socket ->
      if match?({:ok, _, _}, result),
        do: assign(socket, :bind_form, bind_form(%{})),
        else: socket
    end)
    |> load_bindings()
  end

  defp bind_result({:ok, :created, _}, pending),
    do: {:info, "Bound #{pending.source_organization_id} to #{pending.organization_name}"}

  defp bind_result({:ok, :existing, _}, pending),
    do:
      {:info,
       "#{pending.source_organization_id} was already bound to #{pending.organization_name}; nothing changed"}

  defp bind_result({:error, :conflicting_binding}, pending),
    do:
      {:error,
       "#{pending.source_organization_id} is already bound to another organization; bindings cannot be reassigned"}

  defp bind_result({:error, :organization_not_found}, _),
    do: {:error, "That organization no longer exists"}

  defp bind_result({:error, :source_changed}, _),
    do: {:error, "The configured source changed; review the binding again"}

  defp bind_result({:error, _}, _),
    do: {:error, "The binding is invalid; check the source organization ID"}

  # --- Async plumbing ---

  defp start_operation(socket, operation) do
    ref = make_ref()
    Process.send_after(self(), {:operation_timeout, ref}, @operation_timeout)
    key = operation_key(operation)

    socket
    |> assign(:in_flight, key)
    |> assign(:operation_ref, ref)
    |> start_async(key, operation_fun(operation, socket.assigns.current_scope))
  end

  defp operation_key({:replay, _, _}), do: :replay
  defp operation_key(key), do: key

  defp operation_fun(:counts, scope), do: fn -> Operations.status(scope) end
  defp operation_fun(:inspect, scope), do: fn -> Operations.failure_summary(scope) end

  # A confirmed replay runs in an unlinked task that this view's task only
  # awaits, so closing the tab cannot interrupt it between publishing and
  # acknowledging, and the audit record (written in that task, never in
  # handle_async) always follows the broker outcome.
  defp operation_fun({:replay, expected, _staff}, scope) do
    fn ->
      Custyard.TaskSupervisor
      |> Task.Supervisor.async_nolink(fn -> Operations.replay(scope, expected) end)
      |> Task.await(:infinity)
    end
  end

  @impl true
  def handle_async(:counts, result, socket) do
    counts =
      case result do
        {:ok, {:ok, queues}} -> {:ok, queues}
        {:ok, error} -> {:error, Operations.error_message(error)}
        {:exit, _} -> {:error, Operations.error_message(:operation_failed)}
      end

    {:noreply, socket |> finish_operation() |> assign(:counts, counts)}
  end

  def handle_async(:inspect, result, socket) do
    failure =
      case result do
        {:ok, {:ok, summary}} -> {:summary, summary}
        {:ok, :empty} -> :empty
        {:ok, error} -> {:error, Operations.error_message(error)}
        {:exit, _} -> {:error, Operations.error_message(:operation_failed)}
      end

    {:noreply, socket |> finish_operation() |> assign(:failure, failure)}
  end

  def handle_async(:replay, result, socket) do
    {replay_result, failure} =
      case result do
        {:ok, :ok} -> {{:info, "Replayed to the work queue"}, nil}
        {:ok, :empty} -> {{:info, "No failed messages"}, :empty}
        {:ok, error} -> {{:error, Operations.error_message(error)}, nil}
        {:exit, _} -> {{:error, Operations.error_message(:operation_failed)}, nil}
      end

    socket =
      socket
      |> finish_operation()
      |> assign(:replay_result, replay_result)
      |> assign(:failure, failure)

    {:noreply, start_operation(socket, :counts)}
  end

  @impl true
  def handle_info({:operation_timeout, ref}, %{assigns: %{operation_ref: ref}} = socket) do
    key = socket.assigns.in_flight
    message = {:error, Operations.error_message(:timeout)}

    socket =
      socket
      |> cancel_async(key)
      |> finish_operation()
      |> then(fn socket ->
        case key do
          :counts ->
            assign(socket, :counts, message)

          :inspect ->
            assign(socket, :failure, message)

          # Only the wait is cancelled: the unlinked replay may still finish
          # (and is audited either way), so the inspected summary is stale.
          :replay ->
            socket
            |> assign(:failure, nil)
            |> assign(
              :replay_result,
              {:error,
               "The broker has not answered yet. The replay may still complete; inspect again before retrying."}
            )
        end
      end)

    {:noreply, socket}
  end

  def handle_info({:operation_timeout, _stale}, socket), do: {:noreply, socket}

  defp finish_operation(socket),
    do: socket |> assign(:in_flight, nil) |> assign(:operation_ref, nil)

  # --- Loading ---

  defp load_overview(socket),
    do:
      assign(
        socket,
        :overview,
        Acknowledgments.subscription_overview(socket.assigns.current_scope)
      )

  defp load_bindings(socket) do
    socket
    |> assign(:bindings, Acknowledgments.list_bindings(socket.assigns.current_scope))
    |> assign(
      :organizations,
      Enum.map(
        Organizations.list(socket.assigns.current_scope),
        &{&1.name, &1.id}
      )
    )
  end

  defp find_organization(id, staff) when is_binary(id) do
    # An id beyond signed 64 bits would make the SQLite driver raise.
    case Integer.parse(id) do
      {id, ""} ->
        if StaffAccounts.valid_id?(id),
          do: Organizations.get(staff, id)

      _ ->
        nil
    end
  end

  defp find_organization(_, _), do: nil

  defp bind_form(params) do
    to_form(
      %{
        "source_organization_id" => Map.get(params, "source_organization_id", ""),
        "organization_id" => Map.get(params, "organization_id", "")
      },
      as: :binding
    )
  end

  defp replayable?({:summary, %{readable: true}}), do: true
  defp replayable?(_), do: false

  # --- Rendering ---

  defp status_label(:connected), do: "Connected"
  defp status_label(:connecting), do: "Connecting"
  defp status_label(:not_configured), do: "Not configured"
  defp status_label(:disabled), do: "Disabled"

  defp status_class(:connected),
    do: "bg-green-50 text-green-700 dark:bg-green-950 dark:text-green-300"

  defp status_class(:connecting),
    do: "bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300"

  defp status_class(_), do: "bg-gray-100 text-gray-700 dark:bg-zinc-700 dark:text-zinc-300"

  defp role_label(:work), do: "Work"
  defp role_label({:retry, attempt}), do: "Retry #{attempt}"
  defp role_label(:failed), do: "Failed"

  defp role_id(:work), do: "work"
  defp role_id({:retry, attempt}), do: "retry-#{attempt}"
  defp role_id(:failed), do: "failed"

  defp busy?(in_flight, key), do: in_flight == key

  attr :summary, :map, required: true
  attr :confirming_replay, :boolean, required: true
  attr :in_flight, :atom, default: nil

  defp failure_summary(assigns) do
    ~H"""
    <div data-testid="acknowledgments-summary">
      <dl class="grid gap-2 text-sm text-gray-600 dark:text-zinc-400 sm:grid-cols-2">
        <div>
          <dt class="font-medium">Source</dt>
          <dd class="break-all">{if @summary.readable, do: @summary.source, else: "Unreadable"}</dd>
        </div>
        <div>
          <dt class="font-medium">Submission ID</dt>
          <dd class="break-all" data-testid="acknowledgments-summary-submission">
            {if @summary.readable, do: @summary.submission_id, else: "Unreadable"}
          </dd>
        </div>
        <div>
          <dt class="font-medium">Failure category</dt>
          <dd>{@summary.category || "Unknown"}</dd>
        </div>
        <div>
          <dt class="font-medium">Attempt</dt>
          <dd>{@summary.attempt || "Unknown"}</dd>
        </div>
      </dl>
      <p
        :if={not @summary.readable}
        class="mt-4 text-sm text-gray-600 dark:text-zinc-400"
        data-testid="acknowledgments-unreadable"
      >
        This message cannot be identified, so it cannot be replayed from here. Use
        bin/acknowledgments inspect --evidence and replay from an authorized terminal.
      </p>
      <div :if={@summary.readable and not @confirming_replay} class="mt-4">
        <button
          type="button"
          phx-click="confirm_replay"
          disabled={@in_flight != nil}
          class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded disabled:opacity-50"
          data-testid="acknowledgments-replay"
        >
          Replay
        </button>
      </div>
      <div
        :if={@summary.readable and @confirming_replay}
        class="mt-4 rounded border border-amber-200 bg-amber-50 dark:border-amber-800 dark:bg-amber-950 p-3 text-sm text-amber-900 dark:text-amber-200"
        data-testid="acknowledgments-replay-confirmation"
      >
        <p>
          Replay submission <span class="font-mono break-all">{@summary.submission_id}</span>
          to the work queue? Correct the cause first, or it fails again. If another
          message has become the oldest, nothing is replayed.
        </p>
        <div class="mt-3 flex gap-2">
          <button
            type="button"
            phx-click="replay"
            disabled={@in_flight != nil}
            class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded disabled:opacity-50"
            data-testid="acknowledgments-confirm-replay"
          >
            Replay now
          </button>
          <button
            type="button"
            phx-click="cancel_replay"
            class="text-xs text-gray-600 dark:text-zinc-400 px-3 py-1"
            data-testid="acknowledgments-cancel-replay"
          >
            Cancel
          </button>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4 overflow-y-auto" data-testid="staff-acknowledgments-page">
      <form
        phx-submit="configure_integration"
        class="mb-6 space-y-3"
        data-testid="acknowledgments-integration-form"
      >
        <h2 class="font-semibold">Configure tenant subscription</h2>
        <label>Source<input name="integration[source]" value={@overview.source || ""} required /></label>
        <label>Broker URL<input
          name="integration[url]"
          type="password"
          autocomplete="off"
          placeholder={
            if @overview.broker_configured?, do: "Saved; leave blank to keep", else: "amqps://..."
          }
          required={!@overview.broker_configured?}
        /></label>
        <label>Queue<input name="integration[queue]" value={@overview.queue || ""} required /></label>
        <input name="integration[enabled]" type="hidden" value="false" />
        <label><input
          name="integration[enabled]"
          type="checkbox"
          value="true"
          checked={@overview.status != :disabled}
        />Enable subscription</label>
        <.button>Save integration</.button>
      </form>
      <div class="flex items-center justify-between mb-6">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-acknowledgments-heading"
        >
          Colonel acknowledgments
        </h1>
        <button
          type="button"
          phx-click="refresh"
          disabled={@in_flight != nil}
          class="text-xs text-blue-600 hover:text-blue-800 disabled:opacity-50"
          data-testid="acknowledgments-refresh"
        >
          {if busy?(@in_flight, :counts), do: "Refreshing…", else: "Refresh"}
        </button>
      </div>

      <section
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="acknowledgments-subscription"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Subscription</h2>
          <span
            class={["text-xs font-medium px-2 py-1 rounded", status_class(@overview.status)]}
            data-testid="acknowledgments-status"
          >
            {status_label(@overview.status)}
          </span>
        </div>
        <dl class="grid gap-2 text-sm text-gray-600 dark:text-zinc-400 sm:grid-cols-3">
          <div>
            <dt class="font-medium">Source</dt>
            <dd class="break-all" data-testid="acknowledgments-source">
              {@overview.source || "Not set"}
            </dd>
          </div>
          <div>
            <dt class="font-medium">Queue</dt>
            <dd class="break-all">{@overview.queue}</dd>
          </div>
          <div>
            <dt class="font-medium">Prefetch</dt>
            <dd>{@overview.prefetch}</dd>
          </div>
        </dl>
        <p
          :if={@overview.status == :not_configured}
          class="mt-4 text-sm text-gray-600 dark:text-zinc-400"
          data-testid="acknowledgments-not-configured"
        >
          The consumer is enabled but not running. Set these secrets to start it:
          <code :for={name <- @overview.required_fields} class="mx-1 font-mono text-xs">
            {name}
          </code>
        </p>
        <p
          :if={@overview.status == :disabled}
          class="mt-4 text-sm text-gray-600 dark:text-zinc-400"
          data-testid="acknowledgments-disabled"
        >
          This tenant subscription is disabled. Enable it in the integration settings.
        </p>
      </section>

      <section
        :if={@overview.broker_configured?}
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="acknowledgments-queues"
      >
        <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100 mb-4">Queues</h2>
        <p :if={@counts == nil} class="text-sm text-gray-600 dark:text-zinc-400">
          Loading queue counts…
        </p>
        <p
          :if={match?({:error, _}, @counts)}
          class="text-sm text-red-700 dark:text-red-400"
          data-testid="acknowledgments-counts-error"
        >
          {elem(@counts, 1)}
        </p>
        <table :if={match?({:ok, _}, @counts)} class="w-full text-sm">
          <thead>
            <tr class="text-left text-gray-500 dark:text-zinc-400">
              <th class="font-medium py-1">Queue</th>
              <th class="font-medium py-1">Ready</th>
              <th class="font-medium py-1">Consumers</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={queue <- elem(@counts, 1)}
              class="border-t border-gray-100 dark:border-zinc-700 text-gray-700 dark:text-zinc-300"
              data-testid={"acknowledgments-queue-#{role_id(queue.role)}"}
            >
              <td class="py-1">
                {role_label(queue.role)}
                <span class="block text-xs text-gray-500 dark:text-zinc-400 break-all">
                  {queue.queue}
                </span>
              </td>
              <%= if Map.has_key?(queue, :error) do %>
                <td colspan="2" class="py-1 text-red-700 dark:text-red-400">
                  {Operations.error_message(queue.error)}
                </td>
              <% else %>
                <td class="py-1 font-mono">{queue.ready}</td>
                <td class="py-1 font-mono">{queue.consumers}</td>
              <% end %>
            </tr>
          </tbody>
        </table>
      </section>

      <section
        :if={@overview.broker_configured?}
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="acknowledgments-failure"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">
            Oldest failed message
          </h2>
          <button
            type="button"
            phx-click="inspect"
            disabled={@in_flight != nil}
            class="text-xs text-blue-600 hover:text-blue-800 disabled:opacity-50"
            data-testid="acknowledgments-inspect"
          >
            {if busy?(@in_flight, :inspect), do: "Inspecting…", else: "Inspect"}
          </button>
        </div>
        <p :if={@failure == nil} class="text-sm text-gray-600 dark:text-zinc-400">
          Inspect shows the source, submission ID, failure category and attempt of the
          oldest retained failure. The message stays in its queue.
        </p>
        <p
          :if={@failure == :empty}
          class="text-sm text-gray-600 dark:text-zinc-400"
          data-testid="acknowledgments-failure-empty"
        >
          No failed messages.
        </p>
        <p
          :if={match?({:error, _}, @failure)}
          class="text-sm text-red-700 dark:text-red-400"
          data-testid="acknowledgments-failure-error"
        >
          {elem(@failure, 1)}
        </p>
        <.failure_summary
          :if={match?({:summary, _}, @failure)}
          summary={elem(@failure, 1)}
          confirming_replay={@confirming_replay}
          in_flight={@in_flight}
        />
        <p
          :if={busy?(@in_flight, :replay)}
          class="mt-4 text-sm text-gray-600 dark:text-zinc-400"
        >
          Replaying…
        </p>
        <p
          :if={@replay_result}
          class={[
            "mt-4 text-sm",
            if(elem(@replay_result, 0) == :info,
              do: "text-green-700 dark:text-green-400",
              else: "text-red-700 dark:text-red-400"
            )
          ]}
          data-testid="acknowledgments-replay-result"
        >
          {elem(@replay_result, 1)}
        </p>
      </section>
      <section
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="acknowledgments-bindings"
      >
        <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100 mb-2">
          Organization bindings
        </h2>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
          Evidence is attributed only through an explicit binding of a source organization ID
          to a Custyard organization.
        </p>
        <p
          :if={@bindings == []}
          class="text-sm text-gray-600 dark:text-zinc-400"
          data-testid="acknowledgments-bindings-empty"
        >
          No bindings yet.
        </p>
        <table :if={@bindings != []} class="w-full text-sm mb-4">
          <thead>
            <tr class="text-left text-gray-500 dark:text-zinc-400">
              <th class="font-medium py-1">Source</th>
              <th class="font-medium py-1">Source organization</th>
              <th class="font-medium py-1">Custyard organization</th>
              <th class="font-medium py-1">Bound (UTC)</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={binding <- @bindings}
              class="border-t border-gray-100 dark:border-zinc-700 text-gray-700 dark:text-zinc-300"
              data-testid={"acknowledgments-binding-#{binding.id}"}
            >
              <td class="py-1 break-all">{binding.source}</td>
              <td class="py-1 break-all">{binding.source_organization_id}</td>
              <td class="py-1">
                <.link
                  navigate={~p"/app/customers/#{binding.organization_id}?tab=acknowledgments"}
                  class="text-blue-600 hover:text-blue-800"
                >
                  {binding.organization_name}
                </.link>
              </td>
              <td class="py-1 font-mono text-xs">
                {Calendar.strftime(binding.inserted_at, "%Y-%m-%d %H:%M")}
              </td>
            </tr>
          </tbody>
        </table>

        <div :if={@overview.source == nil} class="text-sm text-gray-600 dark:text-zinc-400">
          Configure this tenant integration to bind customers here. Bindings for other sources
          are made with bin/acknowledgments bind.
        </div>

        <.form
          :if={@overview.source != nil and @pending_bind == nil}
          for={@bind_form}
          phx-submit="review_bind"
          class="space-y-3 border-t border-gray-100 dark:border-zinc-700 pt-4"
          data-testid="acknowledgments-bind-form"
        >
          <p class="text-sm text-gray-600 dark:text-zinc-400">
            Bind an organization of source <span class="font-mono break-all">{@overview.source}</span>
          </p>
          <.input
            field={@bind_form[:source_organization_id]}
            label="Source organization ID"
            autocomplete="off"
          />
          <.input
            field={@bind_form[:organization_id]}
            type="select"
            label="Custyard organization"
            prompt="Choose an organization"
            options={@organizations}
          />
          <ul
            :if={@bind_errors != []}
            class="text-sm text-red-700 dark:text-red-400"
            data-testid="acknowledgments-bind-errors"
          >
            <li :for={error <- @bind_errors}>{error}</li>
          </ul>
          <button
            type="submit"
            disabled={@in_flight != nil}
            class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded disabled:opacity-50"
            data-testid="acknowledgments-bind-review"
          >
            Review binding
          </button>
        </.form>

        <div
          :if={@pending_bind}
          class="rounded border border-amber-200 bg-amber-50 dark:border-amber-800 dark:bg-amber-950 p-3 text-sm text-amber-900 dark:text-amber-200"
          data-testid="acknowledgments-bind-confirmation"
        >
          <dl class="grid gap-2 sm:grid-cols-3">
            <div>
              <dt class="font-medium">Source</dt>
              <dd class="break-all">{@pending_bind.source}</dd>
            </div>
            <div>
              <dt class="font-medium">Source organization ID</dt>
              <dd class="break-all">{@pending_bind.source_organization_id}</dd>
            </div>
            <div>
              <dt class="font-medium">Custyard organization</dt>
              <dd>{@pending_bind.organization_name}</dd>
            </div>
          </dl>
          <p class="mt-3">
            This binding is permanent: bindings cannot be deleted or reassigned. All evidence
            for this source organization will be attributed to {@pending_bind.organization_name}.
          </p>
          <div class="mt-3 flex gap-2">
            <button
              type="button"
              phx-click="confirm_bind"
              disabled={@in_flight != nil}
              class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded disabled:opacity-50"
              data-testid="acknowledgments-confirm-bind"
            >
              Bind permanently
            </button>
            <button
              type="button"
              phx-click="cancel_bind"
              class="text-xs text-gray-600 dark:text-zinc-400 px-3 py-1"
              data-testid="acknowledgments-cancel-bind"
            >
              Cancel
            </button>
          </div>
        </div>

        <p
          :if={@bind_result}
          class={[
            "mt-4 text-sm",
            if(elem(@bind_result, 0) == :info,
              do: "text-green-700 dark:text-green-400",
              else: "text-red-700 dark:text-red-400"
            )
          ]}
          data-testid="acknowledgments-bind-result"
        >
          {elem(@bind_result, 1)}
        </p>
      </section>
    </div>
    """
  end
end
