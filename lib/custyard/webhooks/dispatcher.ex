defmodule Custyard.Webhooks.Dispatcher do
  @moduledoc """
  Dispatches incoming webhooks through the multi-webhook pipeline.

  Each inbound route can have multiple webhook purposes. The dispatcher
  executes them in order:
  1. `sender_matching` — identity resolution, conversation creation (blocking)
  2. `enrichment` — urgency scoring, keyword extraction (async)
  3. `notification` — operator notifications (async)
  4. `audit` — activity log (async)
  5. `disambiguation` — ambiguous sender resolution (conditional)

  The sender_matching step is always executed first and synchronously.
  Remaining purposes run asynchronously via Task.Supervisor with:
  - max_children: 100 (backpressure limit)
  - Proper error tracking via Logger
  - Graceful shutdown during application stop
  """

  require Logger

  alias Custyard.{InboundRoute, Repo}
  alias Custyard.Webhooks.Purposes

  @task_supervisor Custyard.TaskSupervisor

  @doc """
  Dispatch an incoming webhook through the route's registered purposes.

  ## Parameters
  - `route` - the InboundRoute (with webhooks preloaded)
  - `normalized` - the normalized payload from the adapter

  Returns `{:ok, conversation}` or `{:error, reason}`.
  """
  def dispatch(%InboundRoute{} = route, normalized) do
    start_time = System.monotonic_time()
    adapter = normalized[:source] || :unknown

    route = Repo.preload(route, :webhooks)
    enabled_purposes = get_enabled_purposes(route)

    # Build route context for sender matching
    route_context = %{
      organization_id: route.organization_id,
      project_id: route.project_id,
      route_type: route.route_type
    }

    # Step 1: Sender matching (synchronous, blocking)
    result =
      case run_sender_matching(normalized, route_context, enabled_purposes) do
        {:ok, conversation} ->
          # Step 2-4: Async purposes (enrichment, notification, audit)
          run_async_purposes(conversation, normalized, route_context, enabled_purposes)

          {:ok, conversation}

        {:error, reason} ->
          {:error, reason}
      end

    # Emit telemetry for webhook dispatch
    duration = System.monotonic_time() - start_time
    result_tag = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:custyard, :webhook, :dispatch, :stop],
      %{duration: duration},
      %{adapter: adapter, result: result_tag}
    )

    result
  end

  @doc """
  Dispatch a legacy (non-routed) webhook using default processing.

  Used for backward compatibility with the existing `POST /api/webhook/inbound`.
  """
  def dispatch_legacy(normalized) do
    start_time = System.monotonic_time()
    result = Purposes.SenderMatching.process(normalized, %{})
    duration = System.monotonic_time() - start_time
    result_tag = if match?({:ok, _}, result), do: :ok, else: :error

    :telemetry.execute(
      [:custyard, :webhook, :legacy, :stop],
      %{duration: duration},
      %{result: result_tag}
    )

    result
  end

  defp get_enabled_purposes(route) do
    route.webhooks
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.purpose)
    |> MapSet.new()
  end

  defp run_sender_matching(normalized, route_context, _enabled_purposes) do
    # Always run sender matching — it's required to create the conversation
    Purposes.SenderMatching.process(normalized, route_context)
  end

  defp run_async_purposes(conversation, normalized, route_context, enabled_purposes) do
    if MapSet.member?(enabled_purposes, :enrichment) do
      start_purpose_task(:enrichment, fn ->
        Purposes.Enrichment.process(conversation, normalized, route_context)
      end)
    end

    if MapSet.member?(enabled_purposes, :notification) do
      start_purpose_task(:notification, fn ->
        Purposes.Notification.process(conversation, normalized, route_context)
      end)
    end

    if MapSet.member?(enabled_purposes, :audit) do
      start_purpose_task(:audit, fn ->
        Purposes.Audit.process(conversation, normalized, route_context)
      end)
    end

    # Disambiguation is reserved for future implementation
    # (sends DM to ambiguous senders asking them to clarify their identity)
    # Currently a no-op - the purpose is in the schema but not yet implemented
    if MapSet.member?(enabled_purposes, :disambiguation) do
      # TODO: Implement Purposes.Disambiguation.process/3
      :noop
    end

    :ok
  end

  # Start a supervised task for async webhook purposes.
  # Uses Task.Supervisor for proper lifecycle management:
  # - max_children limits concurrent tasks (backpressure)
  # - Tasks are awaited during shutdown
  # - Errors are logged without crashing the dispatcher
  defp start_purpose_task(purpose, fun) do
    case Task.Supervisor.start_child(@task_supervisor, fn ->
           try do
             fun.()
           rescue
             e ->
               Logger.error(
                 "Webhook purpose #{purpose} failed: #{Exception.message(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
               )
           end
         end) do
      {:ok, _pid} ->
        :ok

      {:error, :max_children} ->
        Logger.warning("Webhook purpose #{purpose} dropped: task supervisor at capacity")
        :dropped

      {:error, reason} ->
        Logger.error("Failed to start webhook purpose #{purpose}: #{inspect(reason)}")
        :error
    end
  end
end
