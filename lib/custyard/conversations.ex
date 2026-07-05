defmodule Custyard.Conversations do
  @moduledoc """
  Context for conversation queries and operations.
  """

  alias Custyard.{Conversation, Message, Repo}
  import Ecto.Query

  @doc """
  List conversations for the operator attention queue.
  Excludes resolved and currently-snoozed conversations, ordered by cached_score descending.
  Returns list of `%{conversation: conversation, message_count: count}` maps.

  Options:
    - :filter - state filter ("all", "new", "active", "waiting", "dormant", "snoozed")
    - :organization_id - scope to a specific organization (nil for all - super_admin only)
  """
  def list_for_attention_queue(opts \\ []) do
    filter = Keyword.get(opts, :filter, "all")
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    message_count_subquery =
      from m in Message,
        group_by: m.conversation_id,
        select: %{conversation_id: m.conversation_id, count: count(m.id)}

    query =
      from c in Conversation,
        # Left join: disambiguation conversations have nil organization_id
        left_join: o in assoc(c, :organization),
        left_join: ct in assoc(c, :contact),
        left_join: mc in subquery(message_count_subquery),
        on: mc.conversation_id == c.id,
        # Exclude resolved conversations (snoozed filter handled separately)
        where: c.state != :resolved,
        order_by: [desc: c.cached_score],
        preload: [organization: o, contact: ct],
        select: %{conversation: c, message_count: coalesce(mc.count, 0)}

    query
    |> apply_organization_filter(organization_id)
    |> apply_snooze_filter(filter, now)
    |> apply_state_filter(filter)
    |> Repo.all()
  end

  # Filter for snoozed conversations - only show snoozed when explicitly filtered
  defp apply_snooze_filter(query, "snoozed", now) do
    from c in query, where: c.snoozed_until >= ^now
  end

  defp apply_snooze_filter(query, _filter, now) do
    from c in query, where: is_nil(c.snoozed_until) or c.snoozed_until < ^now
  end

  defp apply_organization_filter(query, nil), do: query

  defp apply_organization_filter(query, org_id) when is_integer(org_id) do
    from c in query, where: c.organization_id == ^org_id
  end

  defp apply_state_filter(query, "all"), do: query
  defp apply_state_filter(query, "new"), do: from(c in query, where: c.state == :new)
  defp apply_state_filter(query, "active"), do: from(c in query, where: c.state == :active)
  defp apply_state_filter(query, "waiting"), do: from(c in query, where: c.state == :waiting)
  defp apply_state_filter(query, "dormant"), do: from(c in query, where: c.state == :dormant)
  defp apply_state_filter(query, _), do: query

  @doc """
  List all conversations that are currently at or past neglect thresholds.
  Returns conversations with organization preloaded, excluding resolved and snoozed.

  Options:
    - :organization_id - scope to a specific organization (nil for all - super_admin only)
  """
  def list_neglected(opts \\ []) do
    organization_id = Keyword.get(opts, :organization_id)
    now = DateTime.utc_now()

    from(c in Conversation,
      # Left join: disambiguation conversations have nil organization_id
      left_join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      # Order by org name (nil sorts first), then by score
      order_by: [asc_nulls_first: o.name, desc: c.cached_score],
      preload: [organization: o, contact: ct]
    )
    |> apply_organization_filter(organization_id)
    |> Repo.all()
  end

  @doc """
  List conversations for an organization's portal view.

  Options:
    - :include_resolved - include resolved conversations (default: false)
    - :contact_id - filter to only this contact's conversations (default: nil = all)
  """
  def list_for_organization(org_id, opts \\ []) do
    include_resolved = Keyword.get(opts, :include_resolved, false)
    contact_id = Keyword.get(opts, :contact_id)

    query =
      from c in Conversation,
        where: c.organization_id == ^org_id,
        order_by: [desc: c.inserted_at],
        preload: [:contact]

    query =
      if contact_id do
        from c in query, where: c.contact_id == ^contact_id
      else
        query
      end

    query =
      if include_resolved do
        query
      else
        from c in query, where: c.state != :resolved
      end

    Repo.all(query)
  end

  @doc """
  Get a single conversation by ID.
  """
  def get_conversation(id) do
    Repo.get(Conversation, id)
  end

  @doc """
  Get a single conversation by ID or raise.
  """
  def get_conversation!(id) do
    Repo.get!(Conversation, id)
  end

  @doc """
  Get conversation for organization with ownership check.
  Returns `{:ok, conversation}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_conversation_for_organization(id, org_id) do
    case Repo.get(Conversation, id) |> Repo.preload([:contact, :organization]) do
      nil ->
        {:error, :not_found}

      conversation ->
        if conversation.organization_id == org_id do
          {:ok, conversation}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Get conversation with preloaded messages and associations.
  WARNING: No org scoping - use get_with_messages_for_organization/2 for user-facing requests.
  """
  def get_with_messages(id) do
    Repo.get!(Conversation, id)
    |> Repo.preload([
      :organization,
      :contact,
      :tasks,
      messages: from(m in Message, order_by: m.inserted_at)
    ])
  end

  @doc """
  Get conversation with preloaded messages, scoped to organization.
  Returns `{:ok, conversation}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  Use this for user-facing requests to prevent IDOR.
  """
  def get_with_messages_for_organization(id, org_id) do
    case Repo.get(Conversation, id) do
      nil ->
        {:error, :not_found}

      conversation ->
        if conversation.organization_id == org_id do
          preloaded =
            Repo.preload(conversation, [
              :organization,
              :contact,
              :tasks,
              messages: from(m in Message, order_by: m.inserted_at)
            ])

          {:ok, preloaded}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Get public messages for a conversation (excludes internal notes).
  """
  def list_public_messages(conversation_id) do
    from(m in Message,
      where: m.conversation_id == ^conversation_id,
      where: m.is_internal_note == false,
      order_by: [asc: m.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Count messages for a conversation.
  """
  def count_messages(conversation_id) do
    from(m in Message, where: m.conversation_id == ^conversation_id, select: count(m.id))
    |> Repo.one()
  end

  @doc """
  Create a new conversation.
  """
  def create_conversation(attrs) do
    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update conversation state.
  """
  def update_state(conversation, new_state) do
    conversation
    |> Conversation.state_changeset(new_state)
    |> Repo.update()
  end

  @doc """
  Snooze a conversation until the given datetime.
  """
  def snooze(conversation, until) do
    conversation
    |> Conversation.snooze_changeset(until)
    |> Repo.update()
  end

  @doc """
  Un-snooze a conversation, making it appear in the attention queue again.
  """
  def unsnooze(conversation) do
    conversation
    |> Conversation.snooze_changeset(nil)
    |> Repo.update()
  end

  @doc """
  Update conversation with allowed changes (goes through changeset for validation).
  Note: cached_score and last_neglect_notification are not allowed - they are computed fields.
  """
  def update_conversation(conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Atomically transition a conversation from one state to another.

  Uses a conditional UPDATE to prevent race conditions when multiple operators
  access the same conversation simultaneously. Only updates if the conversation
  is still in the expected `from_state`.

  Returns:
    - `{:ok, updated_conversation}` if the transition succeeded
    - `{:ok, :already_transitioned}` if conversation was already in a different state
    - `{:error, changeset}` if the update failed for other reasons

  ## Examples

      # Transition from :new to :active when operator views
      transition_state(conversation, :new, :active, last_operator_action_at: now)

  """
  def transition_state(conversation, from_state, to_state, additional_attrs \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    attrs = Keyword.merge([state: to_state, updated_at: now], additional_attrs)

    # Build the update query with a WHERE condition on current state
    query =
      from c in Conversation,
        where: c.id == ^conversation.id and c.state == ^from_state

    case Repo.update_all(query, set: attrs) do
      {1, _} ->
        # Successfully updated - reload to get fresh data
        {:ok, Repo.get!(Conversation, conversation.id) |> Repo.preload([:organization, :contact])}

      {0, _} ->
        # No rows updated - state was already different, check current state
        current =
          Repo.get!(Conversation, conversation.id) |> Repo.preload([:organization, :contact])

        if current.state == to_state do
          # Already in target state - another operator transitioned it first
          {:ok, :already_transitioned}
        else
          # In some other state - return the current conversation
          {:ok, :already_transitioned}
        end
    end
  end

  @doc """
  Reload a conversation from the database.
  """
  def reload!(conversation) do
    Repo.reload!(conversation)
  end

  @doc """
  Create a message for a conversation.
  Also touches the conversation's updated_at for accurate last-activity tracking.
  """
  def create_message(attrs) do
    Repo.transaction(fn ->
      case %Message{}
           |> Message.changeset(attrs)
           |> Repo.insert() do
        {:ok, message} ->
          # Touch conversation updated_at so it reflects latest activity
          touch_conversation_updated_at(attrs[:conversation_id] || attrs["conversation_id"])
          message

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Create a message for a conversation, raising on failure.
  Also touches the conversation's updated_at for accurate last-activity tracking.
  """
  def create_message!(attrs) do
    message =
      %Message{}
      |> Message.changeset(attrs)
      |> Repo.insert!()

    # Touch conversation updated_at so it reflects latest activity
    touch_conversation_updated_at(attrs[:conversation_id] || attrs["conversation_id"])
    message
  end

  @doc """
  Send an operator reply to a conversation.

  Creates the outbound message with email metadata (sender_email, in_reply_to,
  message_id, delivery_status), updates conversation state and timestamps,
  recalculates the attention score, and broadcasts PubSub events.

  The entire operation runs inside a transaction so the message and conversation
  update succeed or fail atomically.

  ## Options

    * `:operator_email` - email of the operator sending the reply (optional)

  ## Returns

    * `{:ok, message}` on success
    * `{:error, reason}` on failure (changeset or atom)

  ## Examples

      send_reply(conversation, "Thanks for reaching out!", operator_email: "agent@co.com")

  """
  def send_reply(conversation, body, opts \\ []) do
    conversation =
      Repo.preload(conversation, [
        :contact,
        :organization,
        messages: from(m in Message, order_by: [desc: m.inserted_at])
      ])

    Repo.transaction(fn ->
      with {:ok, message} <- insert_reply_message(conversation, body, opts),
           {:ok, _conv} <- update_conversation_after_reply(conversation) do
        # Side effects outside the transaction boundary aren't critical —
        # a failed broadcast doesn't warrant rolling back the message.
        message
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, message} ->
        # Post-transaction side effects: scoring + broadcasts
        perform_reply_side_effects(conversation)

        # Deliver the email asynchronously so we don't block the caller.
        # The message is already persisted with delivery_status: :pending;
        # Email.Outbound.deliver/1 will update it to :sent or :failed.
        deliver_async(message)

        {:ok, message}

      {:error, _reason} = error ->
        error
    end
  end

  # Fire-and-forget delivery via a supervised task.
  # Failures are logged by Email.Outbound and reflected in delivery_status.
  # Disabled in config/test.exs to avoid sandbox ownership issues with async
  # tasks; tests exercise Email.Outbound.deliver/1 directly.
  defp deliver_async(%Message{} = message) do
    alias Custyard.Email.Outbound

    if Application.get_env(:custyard, :deliver_replies_async?, true) do
      Task.Supervisor.start_child(
        Custyard.TaskSupervisor,
        fn -> Outbound.deliver(message) end
      )
    end

    :ok
  end

  # Build and insert the operator reply message with email metadata.
  defp insert_reply_message(conversation, body, opts) do
    last_customer_msg = find_last_customer_message(conversation.messages)

    attrs = %{
      source: :operator,
      origin: resolve_outbound_origin(conversation),
      body: body,
      is_internal_note: false,
      conversation_id: conversation.id,
      delivery_status: :pending,
      message_id: generate_outbound_message_id(conversation),
      in_reply_to: last_customer_msg && last_customer_msg.message_id,
      sender_email: resolve_sender_email(conversation, opts)
    }

    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  # Update conversation state and timestamps after an operator reply.
  # Uses state_changeset/2 to respect the state machine:
  #   - Already :active -> no-op on state (just updates timestamps)
  #   - :new, :waiting, :dormant, :resolved -> transitions to :active
  defp update_conversation_after_reply(conversation) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # First, build the state transition changeset (validates or no-ops)
    state_cs = Conversation.state_changeset(conversation, :active)

    # Merge in the operator action timestamp via the regular changeset
    state_cs
    |> Ecto.Changeset.cast(%{last_operator_action_at: now}, [:last_operator_action_at])
    |> Repo.update()
  end

  # Recalculate score and broadcast events after a successful reply.
  defp perform_reply_side_effects(conversation) do
    alias Custyard.Scoring
    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations:org:#{conversation.organization_id}",
      {:conversation_updated, conversation.id}
    )

    :ok
  end

  # Find the most recent non-operator message to thread In-Reply-To.
  defp find_last_customer_message(messages) do
    Enum.find(messages, fn msg ->
      msg.source != :operator and not msg.is_internal_note
    end)
  end

  # Determine the from address for outbound email.
  # Priority: inbound route from_address > operator_email option > fallback
  defp resolve_sender_email(conversation, opts) do
    route_address = lookup_route_from_address(conversation)
    operator_email = Keyword.get(opts, :operator_email)

    route_address || operator_email
  end

  # Determine origin for outbound replies based on the conversation's source.
  # The origin reflects which integration/adapter the reply is routed through,
  # matching the channel the conversation originally arrived on.
  defp resolve_outbound_origin(conversation) do
    case conversation.source do
      :lettermint -> :lettermint
      :email -> :email
      :zendesk -> :zendesk
      :intercom -> :intercom
      :slack -> :slack
      :portal -> :portal
      # For disambiguation or unknown sources, default to :email
      _ -> :email
    end
  end

  defp lookup_route_from_address(conversation) do
    alias Custyard.InboundRoutes

    case conversation.organization_id do
      nil ->
        nil

      org_id ->
        case InboundRoutes.get_general_route(org_id) do
          %{from_address: addr} when is_binary(addr) and addr != "" -> addr
          _ -> nil
        end
    end
  end

  # Generate a unique Message-ID for outbound emails following RFC 5322.
  defp generate_outbound_message_id(conversation) do
    unique = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    domain = outbound_domain()
    "<#{unique}.c#{conversation.id}@#{domain}>"
  end

  defp outbound_domain do
    Application.get_env(:custyard, :outbound_email_domain, "custyard.local")
  end

  # Update conversation's updated_at without changing any other fields
  defp touch_conversation_updated_at(nil), do: :ok

  defp touch_conversation_updated_at(conversation_id) do
    import Ecto.Query

    from(c in Conversation, where: c.id == ^conversation_id)
    |> Repo.update_all(set: [updated_at: DateTime.utc_now()])

    :ok
  end

  # --- Task functions ---

  alias Custyard.Task

  @doc """
  Get a task by ID.
  WARNING: No org scoping - use get_task_for_organization/2 for user-facing requests.
  """
  def get_task!(id) do
    Repo.get!(Task, id)
  end

  @doc """
  Get a task by ID, scoped to organization.
  Checks task's organization_id, conversation's organization_id, or project's organization_id.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def get_task_for_organization(id, org_id) do
    case Repo.get(Task, id) |> Repo.preload([:conversation, :project]) do
      nil ->
        {:error, :not_found}

      task ->
        # Task can be scoped via direct org_id, or via conversation/project
        task_org = task.organization_id
        conv_org = task.conversation && task.conversation.organization_id
        proj_org = task.project && task.project.organization_id

        if org_id in [task_org, conv_org, proj_org] and not is_nil(org_id) do
          {:ok, task}
        else
          {:error, :unauthorized}
        end
    end
  end

  @doc """
  Create a task.
  """
  def create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update task state.
  """
  def update_task_state(task, new_state) do
    task
    |> Task.state_changeset(new_state)
    |> Repo.update()
  end

  @doc """
  Update a task with the given attributes.
  """
  def update_task(task, attrs) do
    task
    |> Task.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a task.
  WARNING: No org scoping - use delete_task_for_organization/2 for user-facing requests.
  """
  def delete_task(task) do
    Repo.delete(task)
  end

  @doc """
  Delete a task, scoped to organization.
  Returns `{:ok, task}` or `{:error, :not_found}` or `{:error, :unauthorized}`.
  """
  def delete_task_for_organization(id, org_id) do
    case get_task_for_organization(id, org_id) do
      {:ok, task} -> Repo.delete(task)
      error -> error
    end
  end

  @doc """
  List portal-visible tasks for a conversation.
  """
  def list_portal_visible_tasks(conversation_id) do
    from(t in Task,
      where: t.conversation_id == ^conversation_id,
      where: t.portal_visible == true,
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
  end

  @doc """
  Delete orphaned tasks that have no organization, conversation, or project.
  These can occur due to SQLite FK constraints using nilify_all on delete.
  Returns the number of tasks deleted.
  """
  def delete_orphaned_tasks do
    {count, _} =
      from(t in Task,
        where: is_nil(t.organization_id),
        where: is_nil(t.conversation_id),
        where: is_nil(t.project_id)
      )
      |> Repo.delete_all()

    count
  end

  @doc """
  Delete resolved conversations older than the given number of days.
  Also deletes associated messages (via FK cascade) and cleans up orphaned contacts.
  Returns the number of conversations deleted.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
  """
  def cleanup_resolved_conversations(days_old, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    cutoff = DateTime.utc_now() |> DateTime.add(-days_old * 24 * 60 * 60, :second)

    query =
      from(c in Conversation,
        where: c.state == :resolved,
        where: c.updated_at < ^cutoff
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      {count, _} = Repo.delete_all(query)
      count
    end
  end

  @doc """
  Delete contacts that have no conversations.
  These can accumulate when conversations are deleted.
  Returns the number of contacts deleted.

  Options:
    - :dry_run - if true, returns count without deleting (default: false)
  """
  def cleanup_orphaned_contacts(opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)

    # Find contacts with no conversations
    query =
      from(ct in Custyard.Contact,
        left_join: c in Conversation,
        on: c.contact_id == ct.id,
        where: is_nil(c.id)
      )

    if dry_run do
      Repo.aggregate(query, :count)
    else
      {count, _} = Repo.delete_all(query)
      count
    end
  end

  @doc """
  Run all cleanup operations.
  Returns a map with counts for each cleanup type.

  Options:
    - :resolved_days - delete resolved conversations older than this (default: 90)
    - :dry_run - if true, returns counts without deleting (default: false)
  """
  def run_cleanup(opts \\ []) do
    resolved_days = Keyword.get(opts, :resolved_days, 90)
    dry_run = Keyword.get(opts, :dry_run, false)

    resolved_count = cleanup_resolved_conversations(resolved_days, dry_run: dry_run)
    contacts_count = cleanup_orphaned_contacts(dry_run: dry_run)
    tasks_count = if dry_run, do: count_orphaned_tasks(), else: delete_orphaned_tasks()

    %{
      resolved_conversations: resolved_count,
      orphaned_contacts: contacts_count,
      orphaned_tasks: tasks_count
    }
  end

  defp count_orphaned_tasks do
    from(t in Task,
      where: is_nil(t.organization_id),
      where: is_nil(t.conversation_id),
      where: is_nil(t.project_id)
    )
    |> Repo.aggregate(:count)
  end
end
