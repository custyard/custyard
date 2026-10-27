defmodule Custyard.Labels do
  @moduledoc "Tenant-owned, operator-only conversation labels."
  import Ecto.Query

  alias Custyard.{
    Authorization,
    ConversationLabel,
    Conversations,
    Label,
    Repo
  }

  def list_for_operator(operator, tenant_id \\ nil) do
    tenant_id = tenant_id || operator.tenant_id || Custyard.Tenants.default_tenant().id

    if operator.role == "super_admin" or operator.tenant_id == tenant_id do
      Repo.all(from l in Label, where: l.tenant_id == ^tenant_id, order_by: l.name)
    else
      []
    end
  end

  def for_conversation(operator, conversation) do
    if Authorization.can_access_conversation?(operator, conversation) do
      case tenant_id(conversation) do
        nil ->
          %{available: [], assigned: []}

        tenant_id ->
          available =
            Repo.all(from l in Label, where: l.tenant_id == ^tenant_id, order_by: l.name)

          assigned_ids =
            Repo.all(
              from cl in ConversationLabel,
                where: cl.conversation_id == ^conversation.id,
                select: cl.label_id
            )

          %{available: available, assigned: Enum.filter(available, &(&1.id in assigned_ids))}
      end
    else
      %{available: [], assigned: []}
    end
  end

  def for_conversations(conversations) do
    ids = Enum.map(conversations, & &1.id)

    Repo.all(
      from cl in ConversationLabel,
        join: l in Label,
        on: l.id == cl.label_id,
        join: c in Custyard.Conversation,
        on: c.id == cl.conversation_id,
        where: cl.conversation_id in ^ids and c.tenant_id == l.tenant_id,
        select: {cl.conversation_id, l},
        order_by: l.name
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def create_and_assign(operator, conversation, name) do
    mutate(operator, conversation, fn current, current_operator ->
      tenant_id = tenant_id(current)

      cond do
        is_nil(tenant_id) ->
          {:error, :tenant_required}

        current_operator.role not in ["admin", "super_admin"] ->
          {:error, :unauthorized}

        true ->
          with {:ok, label} <-
                 %Label{} |> Label.changeset(%{tenant_id: tenant_id, name: name}) |> Repo.insert(),
               {:ok, _} <- insert_assignment(current, label) do
            {:ok, label}
          end
      end
    end)
  end

  def assign(operator, conversation, label_id) do
    mutate(operator, conversation, fn current, _ ->
      case scoped_label(current, label_id) do
        %Label{} = label -> insert_assignment(current, label)
        _ -> {:error, :not_found}
      end
    end)
  end

  def remove(operator, conversation, label_id) do
    mutate(operator, conversation, fn current, _ ->
      case scoped_label(current, label_id) do
        %Label{id: id} ->
          Repo.delete_all(
            from cl in ConversationLabel,
              where: cl.conversation_id == ^current.id and cl.label_id == ^id
          )

          {:ok, :removed}

        _ ->
          {:error, :not_found}
      end
    end)
  end

  defp mutate(operator, conversation, fun) do
    result = Conversations.with_operator_access(conversation.id, operator, fun)

    if match?({:ok, _}, result) do
      event = {:conversation_updated, conversation.id}
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", event)
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversation:#{conversation.id}", event)
      Conversations.broadcast_to_org(conversation.organization_id, event)
    end

    result
  end

  defp scoped_label(conversation, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         tenant_id when is_integer(tenant_id) <- tenant_id(conversation) do
      Repo.one(from l in Label, where: l.id == ^id and l.tenant_id == ^tenant_id)
    else
      _ -> nil
    end
  end

  defp insert_assignment(conversation, label) do
    %ConversationLabel{conversation_id: conversation.id, label_id: label.id}
    |> Repo.insert(on_conflict: :nothing)
  end

  defp tenant_id(conversation) do
    Repo.one(
      from c in Custyard.Conversation, where: c.id == ^conversation.id, select: c.tenant_id
    )
  end
end
