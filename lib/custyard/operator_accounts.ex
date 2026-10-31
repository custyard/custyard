defmodule Custyard.OperatorAccounts do
  @moduledoc """
  Creating, listing and removing operator accounts outside the web UI: the
  container boot bootstrap and `bin/operator` (`Custyard.Release`),
  `mix dev.create_operator`, and the dev auto-created account.

  Everything here needs only `Custyard.Repo`, never the rest of the
  application, so release commands run it inside `Ecto.Migrator.with_repo/2`.
  """

  import Ecto.Query

  alias Custyard.{AuditEvent, Message, OperatorAccount, Organization, Repo}

  require Custyard.Log, as: Log

  @placeholder_email "admin@custyard.local"

  # Ids are signed 64-bit integers in SQLite (and Postgres bigserial).
  @max_id 9_223_372_036_854_775_807

  @doc """
  The address older images seeded as the first super_admin. Nothing routes
  mail to it in production, so it can never receive a login link.
  """
  def placeholder_email, do: @placeholder_email

  @doc """
  Looks up an operator by email, normalized the same way as on login.
  """
  def get_by_email(email) when is_binary(email) do
    Repo.get_by(OperatorAccount, email: OperatorAccount.normalize_email(email))
  end

  @doc """
  All operators, oldest first.
  """
  def list_operators do
    Repo.all(from(o in OperatorAccount, order_by: o.id))
  end

  @doc """
  Creates an operator unless one with the normalized email already exists.

  Never modifies an existing account: a match returns `{:exists, operator}`
  whatever role or organization was asked for, and the input is validated
  only when an account is actually created. The insert and its
  `:operator_created` audit event share one transaction.

  Options:

    * `:via` (required) - `"boot"`, `"cli"` or `"mix"`, recorded in the audit event
    * `:role` - defaults to `"super_admin"`
    * `:organization_id` - required for admin and agent
    * `:allow_placeholder` - permit creating #{@placeholder_email} (dev only)

  Returns `{:created, operator}`, `{:exists, operator}` or `{:error, message}`.
  """
  def create_operator(email, opts) when is_binary(email) do
    case get_by_email(email) do
      %OperatorAccount{} = existing -> {:exists, existing}
      nil -> insert_operator(email, opts)
    end
  end

  @doc false
  # The insert half of create_operator/2. Public so the race it handles
  # (another creator inserting the same email between the lookup and this
  # insert) can be tested directly.
  def insert_operator(email, opts) do
    via = Keyword.fetch!(opts, :via)

    with {:ok, role} <- fetch_role(opts),
         {:ok, organization_id} <- fetch_organization_id(opts) do
      changeset =
        OperatorAccount.changeset(%OperatorAccount{}, %{
          email: email,
          role: role,
          organization_id: organization_id
        })

      cond do
        not changeset.valid? ->
          {:error, describe_errors(changeset)}

        Ecto.Changeset.get_field(changeset, :email) == @placeholder_email and
            not Keyword.get(opts, :allow_placeholder, false) ->
          {:error,
           "#{@placeholder_email} is a non-routable placeholder that can never receive " <>
             "a login link; use a real address"}

        true ->
          insert_with_audit(changeset, via)
      end
    end
  end

  @doc """
  Whether `id` can be a database id: an integer from 1 to the largest
  signed 64-bit value. Anything larger makes the SQLite driver raise.
  """
  def valid_id?(id), do: is_integer(id) and id >= 1 and id <= @max_id

  # A role is either absent (default super_admin) or one of the roles. A
  # present but empty one must be refused here: cast/4 turns "" into the
  # field default, so `--role ""` would otherwise create a super_admin.
  defp fetch_role(opts) do
    case Keyword.fetch(opts, :role) do
      :error ->
        {:ok, "super_admin"}

      {:ok, role} ->
        if role in OperatorAccount.roles(),
          do: {:ok, role},
          else: {:error, "role: must be one of: #{Enum.join(OperatorAccount.roles(), ", ")}"}
    end
  end

  defp fetch_organization_id(opts) do
    case Keyword.get(opts, :organization_id) do
      nil ->
        {:ok, nil}

      id ->
        if valid_id?(id),
          do: {:ok, id},
          else: {:error, "organization_id: must be an integer from 1 to #{@max_id}"}
    end
  end

  defp insert_with_audit(changeset, via) do
    result =
      Repo.transaction(fn ->
        with :ok <- check_organization(changeset),
             {:ok, operator} <- Repo.insert(changeset),
             :ok <- audit(:operator_created, operator, via) do
          operator
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, operator} ->
        Log.info(:operator_account_created,
          operator_id: operator.id,
          role: operator.role,
          organization_id: operator.organization_id
        )

        {:created, operator}

      {:error, %Ecto.Changeset{} = failed} ->
        race_or_error(failed, Ecto.Changeset.get_field(changeset, :email))

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  # A unique-constraint failure on email means another creator won the race
  # after our lookup missed; that account exists and is left alone.
  defp race_or_error(%Ecto.Changeset{errors: errors} = failed, email) do
    with {_message, opts} <- Keyword.get(errors, :email),
         :unique <- Keyword.get(opts, :constraint),
         %OperatorAccount{} = existing <- get_by_email(email) do
      {:exists, existing}
    else
      _ -> {:error, describe_errors(failed)}
    end
  end

  # ecto_sqlite3 reports FK violations without a constraint name, so
  # foreign_key_constraint/2 never matches; check the organization first.
  defp check_organization(changeset) do
    case Ecto.Changeset.get_field(changeset, :organization_id) do
      nil ->
        :ok

      id ->
        if Repo.exists?(from(o in Organization, where: o.id == ^id)),
          do: :ok,
          else: {:error, "organization #{id} does not exist"}
    end
  end

  @doc """
  Deletes the operator with this email, in one transaction with its
  `:operator_removed` audit event.

  A row whose stored email is exactly `email` is the one removed. Otherwise
  the email is matched case-insensitively. Rows whose stored email is not
  normalized (left behind by the normalization migration when they
  collided) can share a normalized value; then only the exact stored email
  picks one, and anything else is refused as ambiguous.

  The lookup, the checks and the delete share one immediate transaction,
  which holds SQLite's write lock throughout: a concurrent removal or
  creation cannot change which row matches, or its role, before the delete.

  Refuses to remove the last super_admin who can log in (one with a
  normalized email other than #{@placeholder_email}), and refuses to remove
  any super_admin while no such account exists. `messages.deleted_by_operator_id`
  is ON DELETE SET NULL, so the ids of messages this operator soft-deleted
  are kept in the audit event before the column is cleared. A foreign key
  that blocks the delete is reported, not raised.

  Returns `{:ok, %{operator: operator, soft_deleted_message_ids: ids}}` or
  `{:error, message}`.
  """
  def remove_operator(email, opts) when is_binary(email) do
    via = Keyword.fetch!(opts, :via)

    result =
      Repo.transaction(
        fn ->
          case find_for_removal(email) do
            {:ok, operator} ->
              delete_with_audit(operator, via, Keyword.get(opts, :actor_operator_id))

            {:error, message} ->
              Repo.rollback(message)
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, {operator, message_ids}} ->
        Log.info(:operator_account_removed,
          operator_id: operator.id,
          role: operator.role,
          organization_id: operator.organization_id
        )

        {:ok, %{operator: operator, soft_deleted_message_ids: message_ids}}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  defp find_for_removal(email) do
    normalized = OperatorAccount.normalize_email(email)

    case Repo.get_by(OperatorAccount, email: email) do
      %OperatorAccount{} = exact ->
        {:ok, exact}

      nil ->
        matches =
          Enum.filter(
            list_operators(),
            &(OperatorAccount.normalize_email(&1.email) == normalized)
          )

        case matches do
          [] ->
            {:error, "no operator with email #{normalized}"}

          [operator] ->
            {:ok, operator}

          several ->
            ids = Enum.map_join(several, ", ", & &1.id)

            {:error,
             "#{length(several)} operators match #{normalized} ignoring case (ids #{ids}); " <>
               "pass the exact email shown by `bin/operator list`"}
        end
    end
  end

  # Runs inside remove_operator/2's transaction; returns its result or rolls back.
  defp delete_with_audit(operator, via, actor_operator_id) do
    message_ids =
      Repo.all(
        from(m in Message,
          where: m.deleted_by_operator_id == ^operator.id,
          order_by: m.id,
          select: m.id
        )
      )

    payload = %{"soft_deleted_message_ids" => message_ids}

    payload =
      if is_nil(actor_operator_id),
        do: payload,
        else: Map.put(payload, "actor_operator_id", actor_operator_id)

    with :ok <- delete(operator),
         :ok <- keep_a_super_admin(operator),
         :ok <- audit(:operator_removed, operator, via, payload) do
      {operator, message_ids}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp delete(operator) do
    case Repo.delete(operator, stale_error_field: :id) do
      {:ok, _deleted} -> :ok
      {:error, _stale} -> {:error, "operator #{operator.id} no longer exists"}
    end
  rescue
    Ecto.ConstraintError ->
      {:error,
       "other records still reference operator #{operator.id} (foreign key); nothing was removed"}
  end

  # Runs after the delete, inside the transaction, so a concurrent removal
  # cannot slip between the count and the delete.
  defp keep_a_super_admin(%OperatorAccount{role: "super_admin"} = removed) do
    remaining =
      from(o in OperatorAccount, where: o.role == "super_admin")
      |> Repo.all()
      |> Enum.count(&can_log_in?/1)

    cond do
      remaining > 0 ->
        :ok

      can_log_in?(removed) ->
        {:error,
         "refusing to remove the last super_admin who can log in; add another super_admin " <>
           "first (#{@placeholder_email} and emails that are not normalized cannot log in " <>
           "and do not count)"}

      true ->
        {:error,
         "refusing to remove #{removed.email}: no super_admin who can log in exists yet. " <>
           "Add one first with `bin/operator add you@example.com`, then remove #{removed.email}."}
    end
  end

  defp keep_a_super_admin(_operator), do: :ok

  # Login looks emails up normalized, and nothing delivers mail to the
  # placeholder, so only these accounts can ever sign in. Compared in Elixir
  # because normalization is Unicode-aware and SQLite lower() is not.
  defp can_log_in?(%OperatorAccount{email: email}),
    do: email == OperatorAccount.normalize_email(email) and email != @placeholder_email

  # organization_id goes in the payload only: audit_events.organization_id is
  # a foreign key without ON DELETE, so setting the column would block
  # deleting that organization later.
  defp audit(event_type, operator, via, extra \\ %{}) do
    attrs = %{
      event_type: event_type,
      source: via,
      payload:
        Map.merge(
          %{
            "operator_id" => operator.id,
            "tenant_id" => operator.tenant_id,
            "role" => operator.role,
            "organization_id" => operator.organization_id,
            "via" => via
          },
          extra
        )
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        {:error, "could not record the audit event (#{describe_errors(changeset)})"}
    end
  end

  defp describe_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
    |> Enum.join("; ")
  end
end
