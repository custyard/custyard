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
         {:ok, conversation, is_new} <-
           find_or_create_conversation(normalized, org, contact, route_context) do
      create_message(conversation, normalized)
      Scoring.calculate_and_cache(conversation.id)

      event = if is_new, do: :conversation_created, else: :conversation_updated
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {event, conversation.id})

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversation:#{conversation.id}",
        {:message_added, conversation.id}
      )

      {:ok, Repo.reload!(conversation)}
    end
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
    case ThreadMatcher.find_thread(normalized) do
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
    source = message_source(normalized[:source])

    %Message{}
    |> Message.changeset(%{
      conversation_id: conversation.id,
      source: source,
      sender_email: normalized.from,
      body: normalized.body,
      message_id: normalized.message_id,
      in_reply_to: normalized.in_reply_to,
      is_internal_note: false
    })
    |> Repo.insert!()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation
    |> Ecto.Changeset.change(last_customer_action_at: now)
    |> Repo.update!()
  end

  # Map adapter source to message source enum
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

  defp detect_urgency(subject, body) do
    text = String.downcase((subject || "") <> " " <> (body || ""))

    cond do
      String.contains?(text, ["urgent", "emergency", "critical", "down", "outage"]) -> :urgent
      String.contains?(text, ["important", "asap", "priority"]) -> :elevated
      true -> :normal
    end
  end
end
