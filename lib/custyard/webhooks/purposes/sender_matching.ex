defmodule Custyard.Webhooks.Purposes.SenderMatching do
  @moduledoc """
  Identity resolution, conversation creation, and org/project assignment.

  This is the first webhook purpose to fire and is synchronous — it creates
  the conversation record that all other purposes reference.

  When route context is available, uses it as the primary routing signal
  (organization_id and project_id from the inbound route). Falls back to
  sender matching when no route context is provided.
  """

  alias Custyard.{Conversation, Message, Repo, Scoring}
  alias Custyard.Email.{SenderMatcher, SieveHeaderMapper, ThreadMatcher}

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
          create_message(conversation, normalized)
          {conversation, is_new}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp broadcast_updates(conversation, is_new) do
    Scoring.calculate_and_cache(conversation.id)

    event = if is_new, do: :conversation_created, else: :conversation_updated
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {event, conversation.id})

    # Broadcast to org-scoped topic for portal LiveViews
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations:org:#{conversation.organization_id}",
      {event, conversation.id}
    )

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
    # Thread matching is scoped to organization to prevent cross-org leakage
    case ThreadMatcher.find_thread(normalized, org.id) do
      {:ok, conversation} ->
        conversation = maybe_reactivate(conversation)
        {:ok, conversation, false}

      :not_found ->
        case create_conversation(normalized, org, contact, route_context) do
          {:ok, conversation} -> {:ok, conversation, true}
          error -> error
        end
    end
  end

  defp create_conversation(normalized, org, contact, route_context) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    base_attrs = %{
      organization_id: org.id,
      contact_id: contact && contact.id,
      subject: normalized.subject,
      state: :new,
      urgency: detect_urgency(normalized.subject, normalized.body),
      source: normalized[:source] || :email,
      last_customer_action_at: now
    }

    # Set project_id from route context if available
    base_attrs =
      case route_context do
        %{project_id: pid} when not is_nil(pid) -> Map.put(base_attrs, :project_id, pid)
        _ -> base_attrs
      end

    # Apply Sieve header overrides for email sources
    attrs = SieveHeaderMapper.merge_overrides(base_attrs, normalized.headers)

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  defp create_message(conversation, normalized) do
    # Original adapter source (for audit/reporting)
    origin = normalized[:source]
    # Simplified message type
    source = message_source(origin)

    # Use idempotent insert for webhook retry safety
    attrs = %{
      conversation_id: conversation.id,
      source: source,
      origin: origin,
      sender_email: normalized.from,
      body: normalized.body,
      message_id: normalized.message_id,
      in_reply_to: normalized.in_reply_to,
      is_internal_note: false
    }

    case Message.insert_idempotent(attrs) do
      {:ok, _message} ->
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        conversation
        |> Ecto.Changeset.change(last_customer_action_at: now)
        |> Repo.update!()

      {:error, changeset} ->
        raise Ecto.InvalidChangesetError, action: :insert, changeset: changeset
    end
  end

  # Map adapter source to message source enum
  # Source = message type (email, portal, operator)
  # Origin = original adapter (tracked separately for audit/reporting)
  defp message_source(:lettermint), do: :email
  defp message_source(:zendesk), do: :portal
  defp message_source(:intercom), do: :portal
  defp message_source(:slack), do: :portal
  defp message_source(:disambiguation), do: :email
  defp message_source(source) when source in [:email, :portal, :operator], do: source

  defp message_source(other) do
    Logger.warning("Unknown message source #{inspect(other)}, defaulting to :email")
    :email
  end

  defp maybe_reactivate(conversation) do
    if conversation.state in [:dormant, :resolved] do
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
