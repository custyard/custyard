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
  """
  def list_for_attention_queue(opts \\ []) do
    filter = Keyword.get(opts, :filter, "all")
    now = DateTime.utc_now()

    message_count_subquery =
      from m in Message,
        group_by: m.conversation_id,
        select: %{conversation_id: m.conversation_id, count: count(m.id)}

    query =
      from c in Conversation,
        join: o in assoc(c, :organization),
        left_join: ct in assoc(c, :contact),
        left_join: mc in subquery(message_count_subquery),
        on: mc.conversation_id == c.id,
        where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
        order_by: [desc: c.cached_score],
        preload: [organization: o, contact: ct],
        select: %{conversation: c, message_count: coalesce(mc.count, 0)}

    query
    |> apply_state_filter(filter)
    |> Repo.all()
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
  """
  def list_neglected do
    now = DateTime.utc_now()

    from(c in Conversation,
      join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      order_by: [asc: o.name, desc: c.cached_score],
      preload: [organization: o, contact: ct]
    )
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
  Update conversation with arbitrary changes.
  """
  def update_conversation(conversation, attrs) do
    conversation
    |> Ecto.Changeset.change(attrs)
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
  """
  def create_message(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Create a message for a conversation, raising on failure.
  """
  def create_message!(attrs) do
    %Message{}
    |> Message.changeset(attrs)
    |> Repo.insert!()
  end

  # --- Task functions ---

  alias Custyard.Task

  @doc """
  Get a task by ID.
  """
  def get_task!(id) do
    Repo.get!(Task, id)
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
  """
  def delete_task(task) do
    Repo.delete(task)
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
end
