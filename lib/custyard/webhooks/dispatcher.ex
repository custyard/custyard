defmodule Custyard.Webhooks.Dispatcher do
  @moduledoc """
  Dispatches incoming webhooks through the multi-webhook pipeline.

  Before any purpose runs, two synchronous stages decide whether the
  delivery becomes a customer message at all
  (docs/design/spec-inbound-channels.md, D2 and D6):

  1. **Channel resolution.** `Custyard.InboundChannels.resolve_for_delivery/2`
     maps the envelope recipient to a channel on the route. A route without
     channels is `:legacy` and behaves exactly as before channels existed. A
     recipient that matches no channel, or a paused or revoked channel, is
     written to the route's rejection log and the delivery is acknowledged
     as `{:ignored, reason}` so the provider does not retry.
  2. **Triage.** `Custyard.Webhooks.Triage.classify/3` sorts the delivery:
     - own outbound echo: audited, ignored; nothing is inserted
     - provider verification: captured on a `pending_verification` channel,
       otherwise logged as a provider notice; never a conversation
     - auto-response / bulk / bounce: appended to the thread it answers as a
       `triage_class: :auto_response` message without reactivating the
       conversation, or logged when it threads to nothing
     - suspect and customer mail: continue to sender matching

  Each inbound route can then have multiple webhook purposes. The dispatcher
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

  The notification purpose is not started for `:suspect` or `:auto_response`
  deliveries (D6: suspect mail is excluded from notifications, auto-responses
  are system messages). Enrichment and audit still run for suspect mail;
  only audit runs for an appended auto-response.

  ## Architectural invariant: sender_matching always runs

  `sender_matching` executes unconditionally regardless of its enabled flag
  in the webhook_purposes table. It is the step that resolves sender identity
  and creates the conversation record — without it, no downstream purpose
  has anything to operate on. The toggle exposed in the operator UI for
  sender_matching is cosmetic: it controls audit visibility and reporting,
  not execution. This is intentional and must not be changed without
  reworking the entire dispatch pipeline.
  """

  require Logger

  alias Custyard.{
    AuditEvent,
    Conversation,
    InboundChannel,
    InboundChannels,
    InboundRoute,
    Message,
    Repo
  }

  alias Custyard.Email.ThreadMatcher
  alias Custyard.Webhooks.{Purposes, Triage}

  @task_supervisor Custyard.TaskSupervisor

  @typedoc "Why a delivery was acknowledged without becoming a customer message."
  @type ignored_reason ::
          :no_channel
          | :channel_paused
          | :channel_revoked
          | :own_echo
          | :verification_captured
          | :provider_notice
          | :auto_response

  @doc """
  Dispatch an incoming webhook through the route's registered purposes.

  ## Parameters
  - `route` - the InboundRoute (with webhooks preloaded)
  - `normalized` - the normalized payload from the adapter

  Returns `{:ok, conversation}` when a message was stored (a new or existing
  conversation, including an appended auto-response), `{:ignored, reason}`
  when the delivery was deliberately not stored (see `t:ignored_reason/0`;
  the caller acknowledges it with 2xx), or `{:error, reason}`.
  """
  @spec dispatch(struct(), map()) ::
          {:ok, struct()} | {:ignored, ignored_reason()} | {:error, term()}
  def dispatch(%InboundRoute{} = route, normalized) do
    start_time = System.monotonic_time()
    adapter = normalized[:source] || :unknown

    route = Repo.preload(route, :webhooks)

    result =
      case resolve_channel(route, normalized) do
        {:ok, channel} -> triage_and_process(route, normalized, channel)
        {:ignored, _reason} = ignored -> ignored
      end

    # Emit telemetry for webhook dispatch
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:custyard, :webhook, :dispatch, :stop],
      %{duration: duration},
      %{adapter: adapter, result: result_tag(result)}
    )

    result
  end

  defp result_tag({:ok, _conversation}), do: :ok
  defp result_tag({:ignored, _reason}), do: :ignored
  defp result_tag({:error, _reason}), do: :error

  # --- Stage 1: channel resolution (D2) ---

  defp resolve_channel(route, normalized) do
    recipient = recipient(normalized)

    case InboundChannels.resolve_for_delivery(route, recipient) do
      :legacy ->
        {:ok, nil}

      {:ok, channel} ->
        {:ok, channel}

      {:error, :no_channel} ->
        log_rejection(route, nil, :no_channel, normalized)
        {:ignored, :no_channel}

      {:paused, channel} ->
        log_rejection(route, channel, :channel_paused, normalized)
        {:ignored, :channel_paused}

      {:revoked, channel} ->
        log_rejection(route, channel, :channel_revoked, normalized)
        {:ignored, :channel_revoked}
    end
  end

  defp recipient(normalized) do
    case get_in(normalized, [:metadata, :recipient]) do
      recipient when is_binary(recipient) and recipient != "" -> recipient
      _other -> normalized[:to]
    end
  end

  # --- Stage 2: triage (D6) ---

  defp triage_and_process(route, normalized, channel) do
    case Triage.classify(normalized, route, channel) do
      {:own_echo, message} ->
        handle_own_echo(route, normalized, channel, message)

      {:verification, capture} ->
        handle_verification(route, normalized, channel, capture)

      {:auto_response, reason} ->
        handle_auto_response(route, normalized, channel, reason)

      {:suspect, _reason} ->
        process_customer(route, normalized, channel, :suspect)

      {:customer, nil} ->
        process_customer(route, normalized, channel, :customer)
    end
  end

  # Custyard's own reply forwarded back by the operator's mailbox (D4): the
  # message is already stored, so nothing is inserted, no contact is
  # resolved, nobody is notified and the channel health is untouched.
  defp handle_own_echo(route, normalized, channel, %Message{} = message) do
    audit_triaged(route, normalized, channel, "own_echo", message.conversation_id)
    {:ignored, :own_echo}
  end

  defp handle_verification(
         route,
         normalized,
         %InboundChannel{state: :pending_verification} = channel,
         capture
       ) do
    case InboundChannels.capture_verification(channel, capture) do
      {:ok, _channel} ->
        audit_triaged(route, normalized, channel, "verification_captured", nil)
        {:ignored, :verification_captured}

      {:error, changeset} ->
        Logger.warning(
          "Verification capture failed on channel #{channel.id}: #{inspect(Keyword.keys(changeset.errors))}"
        )

        log_rejection(route, channel, :provider_notice, normalized)
        {:ignored, :provider_notice}
    end
  end

  # A legacy route, or a channel that is not waiting for confirmation: the
  # notice is kept in the rejection log so the operator can find it.
  defp handle_verification(route, normalized, channel, _capture) do
    log_rejection(route, channel, :provider_notice, normalized)
    {:ignored, :provider_notice}
  end

  # An auto-response that answers a known thread is appended as a system
  # message: no reactivation, no contact resolution, no notification and no
  # enrichment. One that threads to nothing is logged and dropped.
  defp handle_auto_response(route, normalized, channel, _reason) do
    case ThreadMatcher.find_thread(normalized, route.organization_id) do
      {:ok, conversation} ->
        append_auto_response(route, normalized, channel, conversation)

      :not_found ->
        log_rejection(route, channel, :auto_response, normalized)
        {:ignored, :auto_response}
    end
  end

  defp append_auto_response(route, normalized, channel, conversation) do
    route_context = route_context(route, channel, :auto_response)
    attrs = Purposes.SenderMatching.inbound_message_attrs(conversation, normalized, route_context)

    case Message.insert_idempotent(attrs) do
      {:ok, message} ->
        conversation = Repo.get!(Conversation, message.conversation_id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversation:#{conversation.id}",
          {:message_added, conversation.id}
        )

        mark_received(channel)
        run_audit_purpose(conversation, normalized, route_context, enabled_purposes(route))
        {:ok, conversation}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # --- Customer and suspect mail: the existing purpose pipeline ---

  defp process_customer(route, normalized, channel, triage_class) do
    route_context = route_context(route, channel, triage_class)
    enabled_purposes = enabled_purposes(route)

    # Step 1: Sender matching (synchronous, blocking)
    case run_sender_matching(normalized, route_context, enabled_purposes) do
      {:ok, conversation} ->
        mark_received(channel)
        # Step 2-4: Async purposes (enrichment, notification, audit)
        run_async_purposes(conversation, normalized, route_context, enabled_purposes)
        {:ok, conversation}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route_context(route, channel, triage_class) do
    %{
      organization_id: route.organization_id,
      project_id: route.project_id,
      route_type: route.route_type,
      route_id: route.id,
      channel_id: channel && channel.id,
      triage_class: triage_class
    }
  end

  defp enabled_purposes(route) do
    route.webhooks
    |> Enum.filter(& &1.enabled)
    |> Enum.map(& &1.purpose)
    |> MapSet.new()
  end

  # Runs unconditionally — see "Architectural invariant" in @moduledoc.
  # The _enabled_purposes argument is accepted for interface consistency
  # but intentionally ignored.
  defp run_sender_matching(normalized, route_context, _enabled_purposes) do
    Purposes.SenderMatching.process(normalized, route_context)
  end

  defp run_async_purposes(conversation, normalized, route_context, enabled_purposes) do
    if MapSet.member?(enabled_purposes, :enrichment) do
      start_purpose_task(:enrichment, fn ->
        Purposes.Enrichment.process(conversation, normalized, route_context)
      end)
    end

    if MapSet.member?(enabled_purposes, :notification) and notify?(route_context) do
      start_purpose_task(:notification, fn ->
        Purposes.Notification.process(conversation, normalized, route_context)
      end)
    end

    run_audit_purpose(conversation, normalized, route_context, enabled_purposes)

    # Disambiguation is reserved for future implementation
    # (sends DM to ambiguous senders asking them to clarify their identity)
    # Currently a no-op - the purpose is in the schema but not yet implemented
    if MapSet.member?(enabled_purposes, :disambiguation) do
      # TODO: Implement Purposes.Disambiguation.process/3
      :noop
    end

    :ok
  end

  defp run_audit_purpose(conversation, normalized, route_context, enabled_purposes) do
    if MapSet.member?(enabled_purposes, :audit) do
      start_purpose_task(:audit, fn ->
        Purposes.Audit.process(conversation, normalized, route_context)
      end)
    end

    :ok
  end

  # D6: suspect mail and auto-responses never reach operator notifications.
  defp notify?(%{triage_class: class}) when class in [:suspect, :auto_response], do: false
  defp notify?(_route_context), do: true

  # --- Channel health (D7) ---

  defp mark_received(nil), do: :ok

  defp mark_received(%InboundChannel{} = channel) do
    case InboundChannels.mark_received(channel) do
      {:ok, _channel} ->
        :ok

      {:error, changeset} ->
        Logger.warning(
          "mark_received failed on channel #{channel.id}: #{inspect(Keyword.keys(changeset.errors))}"
        )

        :ok
    end
  end

  # --- Rejection log and audit (no addresses, subjects or bodies in logs) ---

  defp log_rejection(route, channel, classification, normalized) do
    InboundChannels.log_rejection(route, classification, %{
      sender_email: normalized[:from],
      recipient: recipient(normalized),
      subject: normalized[:subject],
      provider_delivery_id: get_in(normalized, [:metadata, :provider_delivery_id]),
      inbound_channel_id: channel && channel.id
    })

    :ok
  end

  defp audit_triaged(route, normalized, channel, class, conversation_id) do
    attrs = %{
      event_type: :inbound_triaged,
      source: to_string(normalized[:source] || "unknown"),
      message_id: normalized[:message_id],
      conversation_id: conversation_id,
      organization_id: route.organization_id,
      project_id: route.project_id,
      payload: %{
        "class" => class,
        "channel_id" => channel && channel.id,
        "route_id" => route.id,
        "conversation_id" => conversation_id
      }
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error(
          "Triage audit event failed on route #{route.id}: #{inspect(Keyword.keys(changeset.errors))}"
        )

        :ok
    end
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
