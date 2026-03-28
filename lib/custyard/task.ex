defmodule Custyard.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:open, :in_progress, :done]

  schema "tasks" do
    field :title, :string
    field :state, Ecto.Enum, values: @states, default: :open
    field :portal_visible, :boolean, default: true
    field :due_at, :utc_datetime

    belongs_to :organization, Custyard.Organization
    belongs_to :conversation, Custyard.Conversation
    belongs_to :project, Custyard.Project

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [
      :title,
      :state,
      :portal_visible,
      :due_at,
      :organization_id,
      :conversation_id,
      :project_id
    ])
    |> validate_required([:title])
    |> validate_inclusion(:state, @states)
    |> validate_has_parent_or_org()
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:conversation_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Changeset for transitioning task state.
  """
  def state_changeset(task, new_state) do
    task
    |> cast(%{state: new_state}, [:state])
    |> validate_inclusion(:state, @states)
  end

  # Tasks must have at least one of: organization_id, conversation_id, or project_id
  # This prevents orphaned tasks that cannot be attributed to any organization
  defp validate_has_parent_or_org(changeset) do
    org_id = get_field(changeset, :organization_id)
    conv_id = get_field(changeset, :conversation_id)
    proj_id = get_field(changeset, :project_id)

    if is_nil(org_id) and is_nil(conv_id) and is_nil(proj_id) do
      add_error(
        changeset,
        :organization_id,
        "task must have an organization, conversation, or project"
      )
    else
      changeset
    end
  end
end
