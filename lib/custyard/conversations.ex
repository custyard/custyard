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
    - :filter - state filter ("all", "new", "active", "waiting", "dormant")
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
        # Exclude resolved and snoozed conversations
        where: c.state != :resolved,
        where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
        order_by: [desc: c.cached_score],
        preload: [organization: o, contact: ct],
        select: %{conversation: c, message_count: coalesce(mc.count, 0)}

    query
    |> apply_organization_filter(organization_id)
    |> apply_state_filter(filter)
    |> Repo.all()
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
  Update conversation with allowed changes (goes through changeset for validation).
  Note: cached_score and last_neglect_notification are not allowed - they are computed fields.
  """
  def update_conversation(conversation, attrs) do
    conversation
    |> Conversation.changeset(attrs)
    |> Repo.update()
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
