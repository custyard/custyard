defmodule Custyard.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:new, :active, :waiting, :dormant, :resolved]
  @urgencies [:normal, :elevated, :urgent]

  @neglect_levels [:ok, :warning, :critical]

  schema "conversations" do
    field :subject, :string
    field :state, Ecto.Enum, values: @states, default: :new
    field :urgency, Ecto.Enum, values: @urgencies, default: :normal
    field :cached_score, :integer, default: 0
    field :last_operator_action_at, :utc_datetime
    field :last_customer_action_at, :utc_datetime
    field :snoozed_until, :utc_datetime

    # Tracks the last neglect level that triggered a notification
    # Prevents duplicate alerts when recalculating
    field :last_neglect_notification, Ecto.Enum, values: @neglect_levels

    belongs_to :organization, Custyard.Organization
    belongs_to :contact, Custyard.Contact
    has_many :messages, Custyard.Message
    has_many :tasks, Custyard.Task
    has_many :projects, Custyard.Project

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def urgencies, do: @urgencies

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :subject,
      :state,
      :urgency,
      :cached_score,
      :last_operator_action_at,
      :last_customer_action_at,
      :snoozed_until,
      :organization_id,
      :contact_id
    ])
    |> validate_required([:subject, :organization_id])
    |> validate_length(:subject, max: 500)
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:urgency, @urgencies)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:contact_id)
  end

  @doc """
  Changeset for transitioning conversation state.
  """
  def state_changeset(conversation, new_state) do
    conversation
    |> cast(%{state: new_state}, [:state])
    |> validate_inclusion(:state, @states)
  end

  @doc """
  Changeset for snoozing a conversation.
  """
  def snooze_changeset(conversation, until) do
    conversation
    |> cast(%{snoozed_until: until}, [:snoozed_until])
  end
end
