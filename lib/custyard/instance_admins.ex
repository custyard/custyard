defmodule Custyard.InstanceAdmins do
  @moduledoc "Installation administrator provisioning and removal."
  import Ecto.Query
  alias Custyard.{Auth.Account, InstanceAdmin, Repo}
  def get_by_email(email), do: Repo.get_by(InstanceAdmin, email: Account.normalize_email(email))
  def list_admins, do: Repo.all(from a in InstanceAdmin, order_by: a.id)

  def create_admin(email) do
    case get_by_email(email) do
      %InstanceAdmin{} = admin ->
        {:exists, admin}

      nil ->
        case %InstanceAdmin{} |> InstanceAdmin.changeset(%{email: email}) |> Repo.insert() do
          {:ok, admin} ->
            Custyard.AuditEvent.create(%{
              event_type: :instance_admin_created,
              source: "instance_admin",
              payload: %{instance_admin_id: admin.id}
            })

            {:created, admin}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  end

  def remove_admin(email) do
    Repo.transaction(
      fn ->
        admin = get_by_email(email) || Repo.rollback(:not_found)

        unless Repo.exists?(from a in InstanceAdmin, where: a.id != ^admin.id),
          do: Repo.rollback(:last_admin)

        removed = Repo.delete!(admin)

        case Custyard.AuditEvent.create(%{
               event_type: :instance_admin_removed,
               source: "instance_admin",
               payload: %{instance_admin_id: removed.id}
             }) do
          {:ok, _} -> removed
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      mode: :immediate
    )
  end
end
