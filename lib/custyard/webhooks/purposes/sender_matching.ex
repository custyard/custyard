defmodule Custyard.Webhooks.Purposes.SenderMatching do
  @moduledoc """
  Identity resolution, conversation creation, and org/project assignment.

  This is the first webhook purpose to fire and is synchronous — it creates
  the conversation record that all other purposes reference.

  When route context is available, uses it as the primary routing signal
  (organization_id and project_id from the inbound route). Falls back to
  sender matching when no route context is provided.

  Route context may also carry the triage outcome
  (docs/design/spec-inbound-channels.md, D5/D6): `channel_id` (nil on a
  legacy route) is stamped on the conversation and every message as
  `inbound_channel_id`; `triage_class` `:suspect` creates the conversation
  with `suspect: true` and urgency pinned to `:normal`. Email facts (To, CC,
  Reply-To, authentication summary, spam score) are copied from the
  normalized metadata onto each inbound message.
  """

  alias Custyard.{Conversation, Conversations, Message, Repo, Scoring}
  alias Custyard.Email.{Normalizer, SenderMatcher, SieveHeaderMapper, ThreadMatcher}

  require Logger

  @doc """
  Process an incoming normalized payload and create/update a conversation.

  Route context (from InboundRoute) provides org/project when available.
  """
  def process(normalized, route_context \\ %{}) do
    with {:ok, org, contact} <- resolve_sender(normalized, route_context),
         {:ok, {conversation, is_new}} <-
           transact_conversation(normalized, org, contact, route_context) do
      broadcast_updates(conversation, is_new)
      {:ok, Repo.reload!(conversation)}
    end
  end

  defp transact_conversation(normalized, org, contact, route_context) do
    Repo.transaction(fn ->
      case find_or_create_conversation(normalized, org, contact, route_context) do
        {:ok, conversation, is_new} ->
          # Create message with idempotent insert to handle race conditions.
          # If a concurrent request already created a message with this message_id,
          # we need to use that message's conversation instead.
          case create_message_with_dedup(conversation, normalized, is_new, route_context) do
            {:ok, final_conversation, final_is_new} ->
              {final_conversation, final_is_new}

            {:error, reason} ->
              Repo.rollback(reason)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp broadcast_updates(conversation, is_new) do
    Scoring.calculate_and_cache(conversation.id)

    event = if is_new, do: :conversation_created, else: :conversation_updated
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {event, conversation.id})

    # Broadcast to org-scoped topic for portal LiveViews (skipped for nil org)
    Conversations.broadcast_to_org(conversation.organization_id, {event, conversation.id})

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )
  end

  defp resolve_sender(normalized, route_context) do
    case route_context do
      %{organization_id: org_id} when not is_nil(org_id) ->
        # Route context provides org — use it as primary signal
        SenderMatcher.match_within_org(normalized.from, org_id)

      _ ->
        # No route context — fall back to domain-based matching
        SenderMatcher.match(normalized.from)
    end
  end

  defp find_or_create_conversation(normalized, org, contact, route_context) do
    dedup_scope = delivery_scope(org.id, normalized, route_context)
    # A retried provider delivery (same provider_delivery_id) is a replay of a
    # message already stored, with or without a Message-ID header. Then check
    # for a duplicate message_id to prevent a race condition: if this exact
    # message was already processed (perhaps concurrently), return its existing
    # conversation instead of creating a duplicate.
    with :not_found <- find_by_provider_delivery_id(provider_delivery_id(normalized), org.id),
         :not_found <- find_by_message_id(normalized.message_id, org.id, dedup_scope),
         :not_found <- find_thread(normalized, org.id, dedup_scope) do
      case create_conversation(normalized, org, contact, route_context) do
        {:ok, conversation} -> {:ok, conversation, true}
        error -> error
      end
    else
      # A replayed delivery changes nothing: the first delivery already
      # reactivated the conversation if that was warranted.
      {:replay, conversation} ->
        {:ok, conversation, false}

      {:ok, conversation} ->
        conversation = maybe_reactivate(conversation)
        {:ok, conversation, false}
    end
  end

  defp provider_delivery_id(normalized) do
    case get_in(normalized, [:metadata, :provider_delivery_id]) do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  defp lettermint_message_id(normalized) do
    case get_in(normalized, [:metadata, :lettermint_message_id]) do
      id when is_binary(id) -> id
      _other -> nil
    end
  end

  # Find the conversation that already holds this provider delivery. Delivery
  # ids are global, so the match is only honoured inside the resolved org; a
  # cross-org hit is a provider or routing fault and is processed normally
  # (the unique index then rejects the second copy).
  defp find_by_provider_delivery_id(nil, _org_id), do: :not_found

  defp find_by_provider_delivery_id(delivery_id, org_id) do
    import Ecto.Query

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.provider_delivery_id == ^delivery_id,
        select: c,
        limit: 1

    case Repo.one(query) do
      nil ->
        :not_found

      %Conversation{organization_id: ^org_id} = conversation ->
        {:replay, conversation}

      %Conversation{organization_id: other_org_id} ->
        Logger.warning(
          "Provider delivery id already stored for organization #{other_org_id}, " <>
            "resolved to organization #{org_id}; processing as a new message"
        )

        :not_found
    end
  end

  # Find conversation by existing message_id (for race condition prevention)
  defp find_by_message_id(nil, _org_id, _dedup_scope), do: :not_found

  defp find_by_message_id(message_id, org_id, dedup_scope) do
    import Ecto.Query

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.message_id == ^message_id,
        # NULL covers messages created before the scoped index migration and
        # direct imports that do not use insert_idempotent/1.
        where: m.dedup_scope == ^dedup_scope or is_nil(m.dedup_scope),
        where: c.organization_id == ^org_id,
        select: c,
        limit: 1

    case Repo.one(query) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  # Ticket and chat providers reference the thread they belong to (ticket id,
  # Intercom conversation id, Slack thread_ts) rather than the previous
  # message, so match on either side of that marker: the root event carries
  # it as message_id, every reply carries it as in_reply_to. Matching
  # in_reply_to is what keeps replies together when the root was never
  # stored (subscription added mid-thread, root event rejected or lost).
  defp find_thread(%{source: source, in_reply_to: marker}, org_id, dedup_scope)
       when source in [:zendesk, :intercom, :slack] and is_binary(marker) do
    import Ecto.Query

    query =
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: c.organization_id == ^org_id,
        where: c.source == ^source,
        where: m.message_id == ^marker or m.in_reply_to == ^marker,
        where: m.dedup_scope == ^dedup_scope or is_nil(m.dedup_scope),
        order_by: [asc: c.id],
        select: c,
        limit: 1

    case Repo.one(query) do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  defp find_thread(%{source: source} = normalized, org_id, dedup_scope)
       when source in [:intercom, :slack],
       do: ThreadMatcher.find_thread(normalized, org_id, dedup_scope)

  defp find_thread(normalized, org_id, _dedup_scope),
    do: ThreadMatcher.find_thread(normalized, org_id)

  defp delivery_scope(org_id, normalized, route_context) do
    Message.dedup_scope(org_id, normalized[:source], route_context[:route_id])
  end

  defp create_conversation(normalized, org, contact, route_context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    suspect? = route_context[:triage_class] == :suspect

    base_attrs = %{
      organization_id: org.id,
      contact_id: contact && contact.id,
      subject: Normalizer.presence(normalized.subject) || "(no subject)",
      state: :new,
      urgency: detect_urgency(normalized.subject, normalized.body),
      source: normalized[:source] || :email,
      last_customer_action_at: now,
      inbound_channel_id: route_context[:channel_id]
    }

    # Set project_id from route context if available
    base_attrs =
      case route_context do
        %{project_id: pid} when not is_nil(pid) -> Map.put(base_attrs, :project_id, pid)
        _ -> base_attrs
      end

    # Apply Sieve header overrides for email sources
    attrs = SieveHeaderMapper.merge_overrides(base_attrs, normalized.headers)

    # A suspect delivery never earns an urgency bump, neither from its own
    # words nor from a priority header it chose to send (D6). Pinned after
    # the Sieve overrides so a mapped header cannot undo it.
    attrs = if suspect?, do: Map.put(attrs, :urgency, :normal), else: attrs

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Conversation.suspect_changeset(suspect?)
    |> Repo.insert()
  end

  # Create message and handle race condition where duplicate message_id means
  # a concurrent request already processed this email
  defp create_message_with_dedup(conversation, normalized, is_new, route_context) do
    dedup_scope = delivery_scope(conversation.organization_id, normalized, route_context)

    # A previously imported message may have no dedup_scope. Its conversation
    # was found above; do not insert a second copy under the new scoped index.
    # Likewise a retried provider delivery already has its message stored.
    if already_delivered?(normalized, conversation.id, dedup_scope) do
      {:ok, conversation, false}
    else
      insert_message(conversation, normalized, is_new, route_context)
    end
  end

  defp already_delivered?(normalized, conversation_id, dedup_scope) do
    delivery_recorded?(provider_delivery_id(normalized), conversation_id) or
      message_recorded?(normalized.message_id, conversation_id, dedup_scope)
  end

  defp delivery_recorded?(nil, _conversation_id), do: false

  defp delivery_recorded?(delivery_id, conversation_id) do
    import Ecto.Query

    Repo.exists?(
      from m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.provider_delivery_id == ^delivery_id
    )
  end

  defp message_recorded?(nil, _conversation_id, _dedup_scope), do: false

  defp message_recorded?(message_id, conversation_id, dedup_scope) do
    import Ecto.Query

    Repo.exists?(
      from m in Message,
        where: m.conversation_id == ^conversation_id,
        where: m.message_id == ^message_id,
        where: m.dedup_scope == ^dedup_scope or is_nil(m.dedup_scope)
    )
  end

  @doc """
  Attributes for an inbound message in `conversation` built from the
  normalized payload: source/origin, sender, body, threading ids, the dedup
  scope and provider ids, and the D5 email facts. `route_context` supplies
  `channel_id` and `triage_class`. The triage class is recorded for email
  sources only (`:customer` by default); ticket, chat and portal sources
  leave it nil.

  Shared with the dispatcher, which appends auto-responses to an existing
  thread without running sender matching.
  """
  def inbound_message_attrs(conversation, normalized, route_context) do
    origin = normalized[:source]
    source = message_source(origin)
    dedup_scope = delivery_scope(conversation.organization_id, normalized, route_context)
    metadata = normalized[:metadata] || %{}

    %{
      conversation_id: conversation.id,
      source: source,
      origin: origin,
      sender_email: normalized.from,
      # Message.changeset requires a body; an attachment-only email or a
      # text-less chat event must still be recorded rather than rejected.
      body: Normalizer.presence(normalized.body) || "(empty message)",
      message_id: normalized.message_id,
      in_reply_to: normalized.in_reply_to,
      is_internal_note: false,
      dedup_scope: dedup_scope,
      to_addresses: to_addresses(normalized, metadata),
      cc_addresses: cc_addresses(metadata)
    }
    |> put_present(:provider_delivery_id, provider_delivery_id(normalized))
    |> put_present(:lettermint_message_id, lettermint_message_id(normalized))
    |> put_present(:inbound_channel_id, route_context[:channel_id])
    |> put_present(:triage_class, triage_class(source, route_context))
    |> put_present(:reply_to, SenderMatcher.extract_email(metadata[:reply_to]))
    |> put_present(:authentication, authentication(metadata[:authentication]))
    |> put_present(:spam_score, spam_score(metadata[:spam_score]))
    |> put_present(:html_body, html_body(metadata[:html_body]))
  end

  # Already sanitised by the adapter (D9); anything else is not trusted.
  defp html_body(html) when is_binary(html) and html != "", do: html
  defp html_body(_html), do: nil

  defp triage_class(:email, route_context), do: route_context[:triage_class] || :customer
  defp triage_class(_source, _route_context), do: nil

  # The header To addresses, as the customer wrote them. The envelope
  # recipient is routing data: on a forwarding channel it is the secret
  # `local+token@domain` ingress address, which must not be shown to agents
  # as the message's To. When the adapter supplied no header To, the
  # delivery address stands in with its subaddress removed.
  defp to_addresses(normalized, metadata) do
    case metadata[:to] do
      [_ | _] = to ->
        Enum.filter(to, &is_binary/1)

      _none ->
        case normalized[:to] do
          to when is_binary(to) and to != "" -> [strip_subaddress(to)]
          _other -> []
        end
    end
  end

  defp strip_subaddress(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> "#{local |> String.split("+", parts: 2) |> hd()}@#{domain}"
      _other -> address
    end
  end

  defp cc_addresses(%{cc: cc}) when is_list(cc), do: Enum.filter(cc, &is_binary/1)
  defp cc_addresses(_metadata), do: []

  # Stored string-keyed; omitted when the adapter learned nothing.
  defp authentication(%{} = auth) do
    auth = Map.new(auth, fn {k, v} -> {to_string(k), v} end)
    if Enum.all?(auth, fn {_k, v} -> is_nil(v) end), do: nil, else: auth
  end

  defp authentication(_auth), do: nil

  defp spam_score(score) when is_number(score), do: score / 1
  defp spam_score(_score), do: nil

  defp insert_message(conversation, normalized, is_new, route_context) do
    attrs = inbound_message_attrs(conversation, normalized, route_context)

    case Message.insert_idempotent(attrs) do
      {:ok, message} ->
        # Check if the message was newly inserted or already existed
        if message.conversation_id == conversation.id do
          # Message was inserted into our conversation - normal path
          update_conversation_timestamp(conversation)
          {:ok, conversation, is_new}
        else
          # Message already existed in a DIFFERENT conversation (race condition)
          # Delete the duplicate conversation we just created (if we created one)
          if is_new do
            Repo.delete!(conversation)
          end

          # Return the existing conversation
          existing_conv = Repo.get!(Conversation, message.conversation_id)
          {:ok, existing_conv, false}
        end

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value), do: Map.put(attrs, key, value)

  defp update_conversation_timestamp(conversation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation
    |> Ecto.Changeset.change(last_customer_action_at: now)
    |> Repo.update!()
  end

  # Map adapter source to message source enum
  # Source = message type (email, portal, operator)
  # Origin = original adapter (tracked separately for audit/reporting)
  defp message_source(:lettermint), do: :email
  defp message_source(:zendesk), do: :portal
  defp message_source(:intercom), do: :portal
  defp message_source(:slack), do: :portal
  defp message_source(:disambiguation), do: :email
  defp message_source(:public_intake), do: :prospect
  defp message_source(source) when source in [:email, :portal, :operator], do: source

  defp message_source(other) do
    Logger.warning("Unknown message source #{inspect(other)}, defaulting to :email")
    :email
  end

  # A customer message unblocks a conversation that was waiting on the
  # customer, exactly as the portal and public-intake reply paths already do;
  # leaving it :waiting kept the reply out of the attention queue.
  defp maybe_reactivate(conversation) do
    if conversation.state in [:waiting, :dormant, :resolved] do
      conversation
      |> Conversation.state_changeset(:active)
      |> Repo.update!()
    else
      conversation
    end
  end

  # Urgency patterns - use word boundaries to reduce false positives
  # "down" is context-sensitive: "site is down" vs "scroll down"
  @urgent_patterns [
    ~r/\burgent\b/i,
    ~r/\bemergency\b/i,
    ~r/\bcritical\b/i,
    ~r/\boutage\b/i,
    # "down" with service context: "is down", "went down", "site down", "server down"
    ~r/\b(is|went|site|server|service|system|app|application|website)\s+down\b/i,
    ~r/\bdown\s*(for|since|again)\b/i
  ]
  @elevated_patterns [
    ~r/\bimportant\b/i,
    ~r/\basap\b/i,
    ~r/\bpriority\b/i
  ]

  defp detect_urgency(subject, body) do
    # Limit scan to first 2000 chars to avoid scanning huge email bodies
    text = String.slice((subject || "") <> " " <> (body || ""), 0, 2000)

    cond do
      Enum.any?(@urgent_patterns, &Regex.match?(&1, text)) -> :urgent
      Enum.any?(@elevated_patterns, &Regex.match?(&1, text)) -> :elevated
      true -> :normal
    end
  end
end
