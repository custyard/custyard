defmodule Custyard.Labels do
  @moduledoc "Tenant-owned, staff-only thread labels."
  import Ecto.Query

  alias Custyard.{
    Authorization,
    ThreadLabel,
    Threads,
    Label,
    Repo,
    Scope
  }

  def list(%Scope{tenant_id: tenant_id, role: role} = scope) when role in ["admin", "agent"] do
    if Scope.current_staff(scope),
      do: Repo.all(from l in Label, where: l.tenant_id == ^tenant_id, order_by: l.name),
      else: []
  end

  def list(_), do: []

  def for_thread(%Scope{} = scope, thread) do
    if Scope.current_staff(scope) && Authorization.can_access_thread?(scope, thread) do
      case tenant_id(thread) do
        nil ->
          %{available: [], assigned: []}

        tenant_id ->
          available =
            Repo.all(from l in Label, where: l.tenant_id == ^tenant_id, order_by: l.name)

          assigned_ids =
            Repo.all(
              from cl in ThreadLabel,
                where: cl.thread_id == ^thread.id,
                select: cl.label_id
            )

          %{available: available, assigned: Enum.filter(available, &(&1.id in assigned_ids))}
      end
    else
      %{available: [], assigned: []}
    end
  end

  def for_threads(threads) do
    ids = Enum.map(threads, & &1.id)

    Repo.all(
      from cl in ThreadLabel,
        join: l in Label,
        on: l.id == cl.label_id,
        join: c in Custyard.Thread,
        on: c.id == cl.thread_id,
        where: cl.thread_id in ^ids and c.tenant_id == l.tenant_id,
        select: {cl.thread_id, l},
        order_by: l.name
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  def create_and_assign(%Scope{} = scope, thread, name) do
    mutate(scope, thread, fn current, current_staff ->
      tenant_id = tenant_id(current)

      cond do
        is_nil(tenant_id) ->
          {:error, :tenant_required}

        current_staff.role not in ["admin"] ->
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

  def assign(%Scope{} = scope, thread, label_id) do
    mutate(scope, thread, fn current, _ ->
      case scoped_label(current, label_id) do
        %Label{} = label -> insert_assignment(current, label)
        _ -> {:error, :not_found}
      end
    end)
  end

  def remove(%Scope{} = scope, thread, label_id) do
    mutate(scope, thread, fn current, _ ->
      case scoped_label(current, label_id) do
        %Label{id: id} ->
          Repo.delete_all(
            from cl in ThreadLabel,
              where: cl.thread_id == ^current.id and cl.label_id == ^id
          )

          {:ok, :removed}

        _ ->
          {:error, :not_found}
      end
    end)
  end

  defp mutate(%Scope{} = scope, thread, fun) do
    result = Threads.with_access(scope, thread.id, fun)

    if match?({:ok, _}, result) do
      event = {:thread_updated, thread.id}
      Phoenix.PubSub.broadcast(Custyard.PubSub, "threads", event)
      Phoenix.PubSub.broadcast(Custyard.PubSub, "thread:#{thread.id}", event)
      Threads.broadcast_to_org(thread.organization_id, event)
    end

    result
  end

  defp scoped_label(thread, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         tenant_id when is_integer(tenant_id) <- tenant_id(thread) do
      Repo.one(from l in Label, where: l.id == ^id and l.tenant_id == ^tenant_id)
    else
      _ -> nil
    end
  end

  defp insert_assignment(thread, label) do
    %ThreadLabel{
      tenant_id: thread.tenant_id,
      thread_id: thread.id,
      label_id: label.id
    }
    |> Repo.insert(on_conflict: :nothing)
  end

  defp tenant_id(thread) do
    Repo.one(from c in Custyard.Thread, where: c.id == ^thread.id, select: c.tenant_id)
  end
end
