defmodule Custyard.OperatorAccounts do
  @moduledoc """
  Operator account provisioning, shared by `Custyard.Release`, the
  `dev.create_operator` task, and the dev-boot default operator.
  """

  alias Custyard.{OperatorAccount, Repo}

  @doc """
  Creates a `super_admin` operator account for `email` unless one exists.

  There is no separate lookup: the changeset normalizes the email and the
  insert does nothing when it hits the unique email index. A repeat call in
  any letter case is a no-op, and two concurrent calls (two machines booting
  against one database) cannot both insert.

  Returns `{:ok, :created}`, `{:ok, :exists}`, or `{:error, changeset}`.
  """
  def ensure_exists(email) do
    %OperatorAccount{}
    |> OperatorAccount.changeset(%{email: email})
    |> Repo.insert(on_conflict: :nothing, conflict_target: :email)
    |> case do
      {:ok, %OperatorAccount{id: nil}} -> {:ok, :exists}
      {:ok, %OperatorAccount{}} -> {:ok, :created}
      {:error, changeset} -> {:error, changeset}
    end
  end
end
