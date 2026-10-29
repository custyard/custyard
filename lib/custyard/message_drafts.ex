defmodule Custyard.MessageDrafts do
  @moduledoc "Authorized, versioned draft persistence. Drafts expire after 30 days without edits."
  import Ecto.Query
  alias Custyard.{Repo, Scope, StaffAccess, StaffMessageDraft, Threads}

  def get(scope, thread_id) do
    if Scope.current_staff(scope) && Threads.get(scope, thread_id) do
      Repo.get_by(StaffMessageDraft, staff_account_id: scope.staff_id, thread_id: thread_id)
    end
  end

  def save(scope, thread_id, attrs, expected_version) do
    Repo.transaction(fn ->
      staff = Scope.current_staff(scope) || Repo.rollback(:unauthorized)
      current = StaffAccess.lock_current(staff) || Repo.rollback(:unauthorized)

      unless current.tenant_id == scope.tenant_id && Scope.current_staff(scope) &&
               Threads.get(scope, thread_id),
             do: Repo.rollback(:unauthorized)

      validate_channel(scope, attrs)
      persist(current.id, thread_id, attrs, expected_version)
    end)
  end

  defp persist(staff_id, thread_id, attrs, expected_version) do
    case Repo.get_by(StaffMessageDraft, staff_account_id: staff_id, thread_id: thread_id) do
      nil when expected_version in [nil, 0] ->
        %StaffMessageDraft{staff_account_id: staff_id, thread_id: thread_id}
        |> StaffMessageDraft.changeset(attrs)
        |> insert_or_rollback()

      %StaffMessageDraft{lock_version: ^expected_version} = draft ->
        draft
        |> StaffMessageDraft.changeset(attrs)
        |> Ecto.Changeset.optimistic_lock(:lock_version)
        |> update_or_rollback()

      _ ->
        Repo.rollback(:draft_conflict)
    end
  end

  @doc "Check a reviewed draft version inside an already authorized write transaction."
  def verify_version!(staff_id, thread_id, expected_version) do
    query =
      from(d in StaffMessageDraft,
        where:
          d.staff_account_id == ^staff_id and d.thread_id == ^thread_id and
            d.lock_version == ^expected_version,
        update: [set: [lock_version: d.lock_version]]
      )

    case Repo.update_all(query, []) do
      {1, _} ->
        :ok

      {0, _} ->
        if expected_version == 0 and
             not Repo.exists?(
               from(d in StaffMessageDraft,
                 where: d.staff_account_id == ^staff_id and d.thread_id == ^thread_id
               )
             ),
           do: :ok,
           else: Repo.rollback(:draft_conflict)
    end
  end

  defp validate_channel(scope, attrs) do
    case Map.get(attrs, :reply_channel_id, Map.get(attrs, "reply_channel_id")) do
      nil ->
        :ok

      value ->
        with {:ok, id} <- Ecto.Type.cast(:id, value),
             true <-
               Repo.exists?(
                 from(c in Custyard.InboundChannel,
                   where: c.id == ^id and c.tenant_id == ^scope.tenant_id
                 )
               ) do
          :ok
        else
          _ -> Repo.rollback(:invalid_channel)
        end
    end
  end

  defp insert_or_rollback(changeset) do
    case Repo.insert(changeset) do
      {:ok, draft} -> draft
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp update_or_rollback(changeset) do
    case Repo.update(changeset) do
      {:ok, draft} -> draft
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def sweep_expired do
    cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
    {count, _} = Repo.delete_all(from(d in StaffMessageDraft, where: d.updated_at < ^cutoff))
    count
  end
end
