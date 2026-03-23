defmodule Custyard.Task do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:open, :in_progress, :done]

  schema "tasks" do
    field :title, :string
    field :state, Ecto.Enum, values: @states, default: :open
    field :portal_visible, :boolean, default: true
    field :due_at, :utc_datetime

    belongs_to :conversation, Custyard.Conversation

    timestamps(type: :utc_datetime)
  end

  def states, do: @states

  @doc false
  def changeset(task, attrs) do
    task
    |> cast(attrs, [:title, :state, :portal_visible, :due_at, :conversation_id])
    |> validate_required([:title])
    |> validate_inclusion(:state, @states)
    |> foreign_key_constraint(:conversation_id)
  end

  @doc """
  Changeset for transitioning task state.
  """
  def state_changeset(task, new_state) do
    task
    |> cast(%{state: new_state}, [:state])
    |> validate_inclusion(:state, @states)
  end
end
