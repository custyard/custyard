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
        {:ok, channel} ->
          case triage_and_process(route, normalized, channel) do
            {{:ok, conversation} = stored, class} when class != :auto_response ->
              context = route_context(route, channel, class)

              case Purposes.Attachments.process(conversation, normalized, context) do
                :ok -> stored
                {:error, _reason} = error -> error
              end

            {other, _class} ->
              other
          end

        {:ignored, _reason} = ignored ->
          ignored
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
    classification = Triage.classify(normalized, route, channel)

    result =
      case classification do
        {:own_echo, message} ->
          handle_own_echo(route, normalized, channel, message)

        {:operator_sent, info} ->
          handle_operator_sent(route, normalized, channel, info)

        {:operator_forward, info} ->
          handle_operator_forward(route, normalized, channel, info)

        {:verification, capture} ->
          handle_verification(route, normalized, channel, capture)

        {:auto_response, reason} ->
          handle_auto_response(route, normalized, channel, reason)

        {:suspect, _reason} ->
          process_customer(route, normalized, channel, :suspect)

        {:customer, nil} ->
          process_customer(route, normalized, channel, :customer)
      end

    {result, elem(classification, 0)}
  end

  # Custyard's own reply forwarded back by the operator's mailbox (D4): the
  # message is already stored, so nothing is inserted, no contact is
  # resolved, nobody is notified and the channel health is untouched.
  defp handle_own_echo(route, normalized, channel, %Message{} = message) do
    audit_triaged(route, normalized, channel, "own_echo", message.conversation_id)
    {:ignored, :own_echo}
  end

  # A reply the operator sent from their own mailbox (D6 "operator-sent
  # capture"): appended as an operator message so the thread is complete,
  # with the operator's action stamped on the conversation. No reactivation,
  # no contact resolution, no notification; the operator already knows.
  defp handle_operator_sent(route, normalized, channel, %{conversation: conversation} = info) do
    route_context =
      route
      |> route_context(channel, :operator_sent)
      |> Map.merge(forwarder_context(info))

    attrs =
      conversation
      |> Purposes.SenderMatching.inbound_message_attrs(normalized, route_context)
      |> Map.put(:source, :operator)
      |> Map.put(:sender_email, info.email)
      |> Map.put(:triage_class, :operator_sent)

    case Message.insert_idempotent(attrs) do
      {:ok, message} ->
        conversation = stamp_operator_action(Repo.get!(Conversation, message.conversation_id))

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversation:#{conversation.id}",
          {:message_added, conversation.id}
        )

        mark_received(channel)
        audit_triaged(route, normalized, channel, "operator_sent", conversation.id)
        {:ok, conversation}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Customer mail forwarded in by an operator (D6 "operator manual forward",
  # the backlog-import path): the unwrapped original runs through the
  # customer pipeline with the original sender as the contact, stamped with
  # who forwarded it. The forward's own authentication, spam score and HTML
  # describe the operator's copy, not the customer's mail, and are dropped.
  defp handle_operator_forward(route, normalized, channel, %{original: original} = info) do
    unwrapped =
      normalized
      |> Map.put(:from, original.from)
      |> Map.put(:subject, original.subject || normalized[:subject])
      |> Map.put(:body, original.body)
      |> Map.update(:metadata, %{}, fn metadata ->
        metadata
        |> Map.merge(%{
          to: [],
          cc: [],
          reply_to: nil,
          authentication: nil,
          spam_score: nil,
          is_spam: false,
          html_body: nil
        })
      end)

    process_customer(route, unwrapped, channel, :operator_forward, forwarder_context(info))
  end

  defp forwarder_context(%{operator: operator, email: email}) do
    %{
      forwarded_by_operator_id: operator && operator.id,
      forwarded_by_email: email
    }
  end

  defp stamp_operator_action(%Conversation{} = conversation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation
    |> Ecto.Changeset.change(last_operator_action_at: now)
    |> Repo.update!()
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

  defp process_customer(route, normalized, channel, triage_class, extra_context \\ %{}) do
    route_context = route |> route_context(channel, triage_class) |> Map.merge(extra_context)
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

    if MapSet.member?(enabled_purposes, :notification) and notify?(conversation, route_context) do
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
  # The stored flag is checked too: a replayed or follow-up delivery into a
  # conversation an operator has not yet cleared stays quiet even when this
  # delivery on its own classified as customer mail.
  defp notify?(%Conversation{suspect: true}, _route_context), do: false

  # A manual forward is the operator importing mail they have already read.
  defp notify?(_conversation, %{triage_class: class})
       when class in [:suspect, :auto_response, :operator_forward],
       do: false

  defp notify?(_conversation, _route_context), do: true

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
