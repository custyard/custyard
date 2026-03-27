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
  Remaining purposes run asynchronously via Task.
  """

  alias Custyard.{InboundRoute, Repo}
  alias Custyard.Webhooks.Purposes

  @doc """
  Dispatch an incoming webhook through the route's registered purposes.

  ## Parameters
  - `route` - the InboundRoute (with webhooks preloaded)
  - `normalized` - the normalized payload from the adapter

  Returns `{:ok, conversation}` or `{:error, reason}`.
  """
  def dispatch(%InboundRoute{} = route, normalized) do
    route = Repo.preload(route, :webhooks)
    enabled_purposes = get_enabled_purposes(route)

    # Build route context for sender matching
    route_context = %{
      organization_id: route.organization_id,
      project_id: route.project_id,
      route_type: route.route_type
    }

    # Step 1: Sender matching (synchronous, blocking)
    case run_sender_matching(normalized, route_context, enabled_purposes) do
      {:ok, conversation} ->
        # Step 2-4: Async purposes (enrichment, notification, audit)
        run_async_purposes(conversation, normalized, route_context, enabled_purposes)

        {:ok, conversation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Dispatch a legacy (non-routed) webhook using default processing.

  Used for backward compatibility with the existing `POST /api/webhook/inbound`.
  """
  def dispatch_legacy(normalized) do
    Purposes.SenderMatching.process(normalized, %{})
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
      Task.start(fn ->
        Purposes.Enrichment.process(conversation, normalized, route_context)
      end)
    end

    if MapSet.member?(enabled_purposes, :notification) do
      Task.start(fn ->
        Purposes.Notification.process(conversation, normalized, route_context)
      end)
    end

    if MapSet.member?(enabled_purposes, :audit) do
      Task.start(fn ->
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
end
