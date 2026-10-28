defmodule Custyard.Webhooks.Purposes.SenderMatching do
  @moduledoc """
  Identity resolution, conversation creation, and org/project assignment.

  This is the first webhook purpose to fire and is synchronous — it creates
  the conversation record that all other purposes reference.

  The receiving tenant is required routing context. Existing threads and
  sender identities take precedence over channel customer and project hints.

  Route context may also carry the triage outcome
  (docs/design/spec-inbound-channels.md, D5/D6): `channel_id` (nil on a
  route without a channel) is stamped on the conversation and every message as
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

  Verified route context supplies the tenant and optional channel hints.
  """
  def process(normalized, route_context) do
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

  defp resolve_sender(normalized, %{tenant_id: tenant_id} = context) when is_integer(tenant_id) do
    case ThreadMatcher.find_in_tenant(normalized, tenant_id) do
      {:ok, %Conversation{organization_id: org_id}} when is_integer(org_id) ->
        SenderMatcher.match_within_org(normalized.from, org_id)

      _ ->
        SenderMatcher.match_within_tenant(normalized.from, tenant_id,
          organization_id: context[:default_organization_id]
        )
    end
  end

  defp resolve_sender(_normalized, _context), do: {:error, :tenant_required}

  defp find_or_create_conversation(normalized, org, contact, %{tenant_id: tenant_id} = context) do
    with :not_found <- find_delivery(normalized, tenant_id),
         :not_found <- find_thread(normalized, org, tenant_id) do
      case create_conversation(normalized, org, contact, context) do
        {:ok, conversation} -> {:ok, conversation, true}
        error -> error
      end
    else
      {:replay, conversation} ->
        {:ok, conversation, false}

      {:ok, conversation} ->
        conversation = maybe_link_customer(conversation, org, contact)
        {:ok, maybe_reactivate(conversation), false}
    end
  end

  defp maybe_link_customer(
         %Conversation{organization_id: nil, source: :public_intake} = conversation,
         %{id: org_id},
         contact
       ) do
    conversation
    |> Conversation.changeset(%{organization_id: org_id, contact_id: contact && contact.id})
    |> Repo.update!()
  end

  defp maybe_link_customer(conversation, _org, _contact), do: conversation

  defp find_thread(%{source: source, in_reply_to: marker}, _org, tenant_id)
       when source in [:zendesk, :intercom, :slack] and is_binary(marker) do
    import Ecto.Query

    Repo.one(
      from m in Message,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: m.tenant_id == ^tenant_id and c.source == ^source,
        where: m.message_id == ^marker or m.in_reply_to == ^marker,
        select: c,
        limit: 1
    )
    |> case do
      nil -> :not_found
      conversation -> {:ok, conversation}
    end
  end

  defp find_thread(normalized, org, tenant_id) do
    case ThreadMatcher.find_in_tenant(normalized, tenant_id) do
      :not_found when not is_nil(org) ->
        ThreadMatcher.find_by_subject(normalized, org.id, tenant_id)

      :ambiguous ->
        :not_found

      found ->
        found
    end
  end

  defp provider_delivery_id(normalized),
    do: get_in(normalized, [:metadata, :provider_delivery_id])

  defp lettermint_message_id(normalized),
    do: get_in(normalized, [:metadata, :lettermint_message_id])

  defp find_delivery(normalized, tenant_id) do
    import Ecto.Query
    provider_id = provider_delivery_id(normalized)
    message_id = normalized[:message_id]

    delivery =
      if is_binary(provider_id),
        do: dynamic([m], m.provider_delivery_id == ^provider_id),
        else: dynamic(false)

    mail =
      if is_binary(message_id),
        do: dynamic([m], m.message_id == ^message_id),
        else: dynamic(false)

    from(m in Message,
      join: c in Conversation,
      on: c.id == m.conversation_id,
      where: m.tenant_id == ^tenant_id,
      where: ^dynamic([m], ^delivery or ^mail),
      select: c,
      limit: 1
    )
    |> Repo.one()
    |> case do
      nil -> :not_found
      conversation -> {:replay, conversation}
    end
  end

  defp create_conversation(normalized, org, contact, route_context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    suspect? = route_context[:triage_class] == :suspect

    base_attrs = %{
      tenant_id: route_context.tenant_id,
      organization_id: org && org.id,
      contact_id: contact && contact.id,
      subject: Normalizer.presence(normalized.subject) || "(no subject)",
      state: :new,
      urgency: detect_urgency(normalized.subject, normalized.body),
      source: normalized[:source] || :email,
      last_customer_action_at: now,
      inbound_channel_id: route_context[:channel_id]
    }

    # Set project_id from route context if available
    base_attrs = maybe_project_hint(base_attrs, route_context[:default_project_id])

    # Apply Sieve header overrides for email sources
    attrs =
      SieveHeaderMapper.merge_overrides(base_attrs, normalized.headers, route_context.tenant_id)

    # A suspect delivery never earns an urgency bump, neither from its own
    # words nor from a priority header it chose to send (D6). Pinned after
    # the Sieve overrides so a mapped header cannot undo it.
    attrs = if suspect?, do: Map.put(attrs, :urgency, :normal), else: attrs

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Conversation.suspect_changeset(suspect?)
    |> Repo.insert()
    |> case do
      {:ok, conversation} ->
        maybe_label_hint(conversation, route_context[:default_label_id])
        {:ok, conversation}

      error ->
        error
    end
  end

  defp maybe_label_hint(_conversation, nil), do: :ok

  defp maybe_label_hint(conversation, id) do
    case Repo.get_by(Custyard.Label, id: id, tenant_id: conversation.tenant_id) do
      nil ->
        :ok

      label ->
        Repo.insert!(
          %Custyard.ConversationLabel{
            tenant_id: conversation.tenant_id,
            conversation_id: conversation.id,
            label_id: label.id
          },
          on_conflict: :nothing
        )
    end
  end

  # Create message and handle race condition where duplicate message_id means
  # a concurrent request already processed this email
  defp maybe_project_hint(attrs, nil), do: attrs

  defp maybe_project_hint(attrs, id) do
    case Repo.get(Custyard.Project, id) do
      %{tenant_id: tenant_id, organization_id: org_id}
      when tenant_id == attrs.tenant_id and org_id == attrs.organization_id ->
        Map.put(attrs, :project_id, id)

      _ ->
        attrs
    end
  end

  defp create_message_with_dedup(conversation, normalized, is_new, route_context),
    do: insert_message(conversation, normalized, is_new, route_context)

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
      tenant_id: conversation.tenant_id,
      to_addresses: to_addresses(normalized, metadata, route_context),
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
    # Manual-forward provenance (D6): who brought this message in.
    |> put_present(:forwarded_by_operator_id, route_context[:forwarded_by_operator_id])
    |> put_present(:forwarded_by_email, route_context[:forwarded_by_email])
  end

  # Already sanitised by the adapter (D9); anything else is not trusted.
  defp html_body(html) when is_binary(html) and html != "", do: html
  defp html_body(_html), do: nil

  defp triage_class(:email, route_context), do: route_context[:triage_class] || :customer
  defp triage_class(_source, _route_context), do: nil

  # The header To addresses, as the customer wrote them. The envelope
  # recipient is routing data: on a forwarding channel it is the secret
  # `local+token@domain` ingress address, which must not be shown to agents
  # as the message's To. Only redact a fallback that is the matched channel
  # recipient; direct email and genuine header addresses keep their plus tags.
  defp to_addresses(normalized, metadata, route_context) do
    case metadata[:to] do
      [_ | _] = to ->
        bounded_addresses(to)

      _none ->
        case normalized[:to] do
          to when is_binary(to) and to != "" ->
            recipient = Normalizer.presence(metadata[:recipient]) || to

            if route_context[:channel_id] && to == recipient,
              do: [strip_subaddress(to)],
              else: [to]

          _other ->
            []
        end
    end
  end

  defp strip_subaddress(address) do
    case String.split(address, "@", parts: 2) do
      [local, domain] -> "#{local |> String.split("+", parts: 2) |> hd()}@#{domain}"
      _other -> address
    end
  end

  defp cc_addresses(%{cc: cc}) when is_list(cc), do: bounded_addresses(cc)
  defp cc_addresses(_metadata), do: []

  # Message stores at most 50 addresses per header. Keep mail with longer
  # recipient lists instead of rejecting the entire delivery at insertion.
  defp bounded_addresses(addresses) do
    addresses |> Enum.filter(&is_binary/1) |> Enum.take(50)
  end

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
