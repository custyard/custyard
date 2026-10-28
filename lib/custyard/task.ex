defmodule Custyard.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:open, :in_progress, :done]

  schema "tasks" do
    belongs_to(:tenant, Custyard.Tenant)
    field(:title, :string)
    field(:state, Ecto.Enum, values: @states, default: :open)
    field(:portal_visible, :boolean, default: false)
    field(:due_at, :utc_datetime)

    belongs_to(:organization, Custyard.Organization)
    belongs_to(:thread, Custyard.Thread)
    belongs_to(:project, Custyard.Project)

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(normalize_due_at(attrs), [
      :tenant_id,
      :title,
      :state,
      :portal_visible,
      :due_at,
      :organization_id,
      :thread_id,
      :project_id
    ])
    |> validate_required([:title])
    |> validate_length(:title, max: 300)
    |> validate_inclusion(:state, @states)
    |> validate_has_parent_or_org()
    |> validate_parent_scope()
    |> validate_required([:tenant_id])
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:thread_id)
    |> foreign_key_constraint(:project_id)
  end

  # A datetime-local control carries no zone. The staff forms explicitly
  # label it UTC; preserve invalid input so Ecto reports it instead of silently
  # removing an existing due date.
  defp normalize_due_at(attrs) do
    key = if Map.has_key?(attrs, :due_at), do: :due_at, else: "due_at"

    case Map.get(attrs, key) do
      "" ->
        Map.put(attrs, key, nil)

      value when is_binary(value) ->
        value = if byte_size(value) == 16, do: value <> ":00", else: value

        case NaiveDateTime.from_iso8601(value) do
          {:ok, datetime} -> Map.put(attrs, key, DateTime.from_naive!(datetime, "Etc/UTC"))
          _ -> attrs
        end

      _ ->
        attrs
    end
  end

  defp validate_parent_scope(changeset) do
    thread = parent(Custyard.Thread, get_field(changeset, :thread_id))
    project = parent(Custyard.Project, get_field(changeset, :project_id))
    org_id = get_field(changeset, :organization_id)
    parent_orgs = Enum.map(Enum.reject([thread, project], &is_nil/1), & &1.organization_id)
    organization = parent(Custyard.Organization, org_id)

    parent_tenants =
      Enum.map(Enum.reject([thread, project, organization], &is_nil/1), & &1.tenant_id)

    changeset = put_parent_tenant(changeset, Enum.uniq(parent_tenants))
    validate_parent_customer(changeset, org_id, parent_orgs, parent_tenants)
  end

  defp put_parent_tenant(changeset, [tenant_id]) do
    case get_field(changeset, :tenant_id) do
      nil -> put_change(changeset, :tenant_id, tenant_id)
      ^tenant_id -> changeset
      _ -> add_error(changeset, :tenant_id, "must match the parent tenant")
    end
  end

  defp put_parent_tenant(changeset, _), do: changeset

  defp validate_parent_customer(changeset, org_id, parent_orgs, parent_tenants) do
    cond do
      length(Enum.uniq(parent_tenants)) > 1 ->
        add_error(changeset, :project_id, "must belong to the thread's workspace")

      length(Enum.uniq(parent_orgs)) > 1 ->
        add_error(changeset, :project_id, "must belong to the thread's organization")

      org_id && Enum.any?(parent_orgs, &(&1 != org_id)) ->
        add_error(changeset, :organization_id, "must match the task's parent organization")

      is_nil(org_id) && parent_orgs != [] ->
        put_change(changeset, :organization_id, hd(parent_orgs))

      true ->
        changeset
    end
  end

  defp parent(_schema, nil), do: nil
  defp parent(schema, id), do: Custyard.Repo.get(schema, id)

  @doc """
  Changeset for transitioning task state.
  """
  def state_changeset(task, new_state) do
    task
    |> cast(%{state: new_state}, [:state])
    |> validate_inclusion(:state, @states)
  end

  # Tasks must have at least one of: organization_id, thread_id, or project_id
  # This prevents orphaned tasks that cannot be attributed to any organization
  defp validate_has_parent_or_org(changeset) do
    org_id = get_field(changeset, :organization_id)
    conv_id = get_field(changeset, :thread_id)
    proj_id = get_field(changeset, :project_id)

    if is_nil(org_id) and is_nil(conv_id) and is_nil(proj_id) do
      add_error(
        changeset,
        :organization_id,
        "task must have an organization, thread, or project"
      )
    else
      changeset
    end
  end
end
