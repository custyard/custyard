defmodule Custyard.Project do
  @moduledoc """
  Project entity that groups related Tasks.

  Projects can be linked to an Organization (customer projects) or exist
  independently (internal projects per US-11).

  Projects can optionally link to a Conversation (e.g., the initial onboarding request).

  ## Project Types

  - `:customer` - Projects linked to an organization for customer work
  - `:internal` - Projects for internal work (OSS libraries, experiments, web tools)

  Internal projects:
  - Have no organization_id
  - Are never visible in the client portal
  - Use tags for categorization (e.g., "oss-library", "experiment", "web-tool")
  - Appear in operator attention queue based on task due dates
  """
  use Ecto.Schema
  import Ecto.Changeset

  @project_types [:customer, :internal]

  schema "projects" do
    field :title, :string
    field :description, :string
    field :start_date, :date
    field :target_completion_date, :date
    field :portal_visible, :boolean, default: true
    field :project_type, Ecto.Enum, values: @project_types, default: :customer

    # Tags for categorization (especially useful for internal projects)
    field :tags, {:array, :string}, default: []

    belongs_to :organization, Custyard.Organization
    belongs_to :conversation, Custyard.Conversation
    has_many :tasks, Custyard.Task

    timestamps(type: :utc_datetime)
  end

  @doc "Returns the list of valid project types."
  def project_types, do: @project_types

  @doc false
  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :title,
      :description,
      :start_date,
      :target_completion_date,
      :portal_visible,
      :project_type,
      :tags,
      :organization_id,
      :conversation_id
    ])
    |> validate_required([:title])
    |> validate_inclusion(:project_type, @project_types)
    |> validate_completion_after_start()
    |> validate_internal_project_constraints()
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:conversation_id)
  end

  @doc """
  Changeset for creating an internal project.
  Sets appropriate defaults and validates constraints.
  """
  def internal_project_changeset(project, attrs) do
    attrs =
      attrs
      |> Map.put(:project_type, :internal)
      |> Map.put(:portal_visible, false)
      |> Map.put_new(:organization_id, nil)
      |> Map.put_new(:conversation_id, nil)

    changeset(project, attrs)
  end

  @doc "Returns true if this project is internal (not linked to an organization)."
  def internal?(%__MODULE__{project_type: :internal}), do: true
  def internal?(%__MODULE__{organization_id: nil}), do: true
  def internal?(_), do: false

  @doc "Returns true if this project is a customer project."
  def customer?(%__MODULE__{} = project), do: not internal?(project)

  defp validate_completion_after_start(changeset) do
    start_date = get_field(changeset, :start_date)
    target_date = get_field(changeset, :target_completion_date)

    if start_date && target_date && Date.compare(target_date, start_date) == :lt do
      add_error(changeset, :target_completion_date, "must be on or after start date")
    else
      changeset
    end
  end

  # Internal projects must not be portal visible and should not have an organization
  defp validate_internal_project_constraints(changeset) do
    project_type = get_field(changeset, :project_type)
    portal_visible = get_field(changeset, :portal_visible)
    organization_id = get_field(changeset, :organization_id)

    changeset =
      if project_type == :internal and portal_visible do
        add_error(changeset, :portal_visible, "internal projects cannot be portal visible")
      else
        changeset
      end

    if project_type == :internal and organization_id do
      add_error(changeset, :organization_id, "internal projects cannot be linked to an organization")
    else
      changeset
    end
  end
end
