defmodule Custyard.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:new, :active, :waiting, :dormant, :resolved]
  @urgencies [:normal, :elevated, :urgent]
  @sources [:email, :lettermint, :zendesk, :intercom, :slack, :portal, :disambiguation]

  @neglect_levels [:ok, :warning, :critical]

  # Valid state transitions: from_state => [allowed_to_states]
  # Transitions follow this logic:
  # - :new -> :active (operator or customer action), :resolved (resolve without activity)
  # Valid state transitions
  @valid_transitions %{
    new: [:active, :resolved],
    active: [:waiting, :resolved],
    waiting: [:active, :dormant, :resolved],
    dormant: [:active, :resolved],
    resolved: [:active]
  }

  schema "conversations" do
    field :subject, :string
    field :state, Ecto.Enum, values: @states, default: :new
    field :urgency, Ecto.Enum, values: @urgencies, default: :normal
    field :source, Ecto.Enum, values: @sources, default: :email
    field :cached_score, :integer, default: 0
    field :last_operator_action_at, :utc_datetime
    field :last_customer_action_at, :utc_datetime
    field :snoozed_until, :utc_datetime

    # Tracks the last neglect level that triggered a notification
    # Prevents duplicate alerts when recalculating
    field :last_neglect_notification, Ecto.Enum, values: @neglect_levels

    belongs_to :organization, Custyard.Organization
    belongs_to :contact, Custyard.Contact
    belongs_to :project, Custyard.Project
    has_many :messages, Custyard.Message
    has_many :tasks, Custyard.Task

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def urgencies, do: @urgencies
  def sources, do: @sources

  @doc false
  def changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [
      :subject,
      :state,
      :urgency,
      :source,
      # Note: :cached_score is computed by Scoring.calculate_and_cache/1
      # Note: :last_neglect_notification is managed by NeglectChecker
      :last_operator_action_at,
      :last_customer_action_at,
      :snoozed_until,
      :organization_id,
      :contact_id,
      :project_id
    ])
    |> validate_required_organization()
    |> validate_required([:subject])
    |> validate_length(:subject, max: 500)
    # Note: :state, :urgency, :source use Ecto.Enum which validates values automatically
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:project_id)
  end

  @doc """
  Returns the map of valid state transitions.
  """
  def valid_transitions, do: @valid_transitions

  @doc """
  Check if a state transition is valid.

  ## Examples

      valid_transition?(:new, :active)     # true
      valid_transition?(:new, :dormant)    # false
      valid_transition?(:resolved, :active) # true (reopen)
  """
  def valid_transition?(from_state, to_state) do
    case Map.get(@valid_transitions, from_state) do
      nil -> false
      allowed -> to_state in allowed
    end
  end

  @doc """
  Changeset for transitioning conversation state.

  Validates that the transition is allowed according to the state machine.
  Invalid transitions will add an error to the changeset.
  """
  def state_changeset(conversation, new_state) do
    changeset =
      conversation
      |> cast(%{state: new_state}, [:state])

    current_state = conversation.state

    # If state hasn't changed, no validation needed
    if current_state == new_state do
      changeset
    else
      validate_state_transition(changeset, current_state, new_state)
    end
  end

  defp validate_state_transition(changeset, from_state, to_state) do
    if valid_transition?(from_state, to_state) do
      changeset
    else
      allowed = Map.get(@valid_transitions, from_state, [])

      add_error(
        changeset,
        :state,
        "cannot transition from #{from_state} to #{to_state}. Allowed: #{Enum.join(allowed, ", ")}"
      )
    end
  end

  @doc """
  Changeset for snoozing a conversation.
  """
  def snooze_changeset(conversation, until) do
    conversation
    |> cast(%{snoozed_until: until}, [:snoozed_until])
  end

  @doc """
  Internal changeset for system-managed fields.

  This changeset allows updating fields that are managed by internal
  processes (NeglectChecker, Scoring, etc.) and should NOT be exposed
  to external/user input.

  Fields included:
  - `:cached_score` - computed by Scoring.calculate_and_cache/1
  - `:last_neglect_notification` - managed by NeglectChecker

  This separation ensures the public changeset/2 remains safe for
  user-provided input while allowing internal processes to update
  computed/system fields.
  """
  def internal_changeset(conversation, attrs) do
    conversation
    |> cast(attrs, [:cached_score, :last_neglect_notification])
  end

  # Disambiguation conversations can have nil organization_id
  defp validate_required_organization(changeset) do
    source = get_field(changeset, :source)

    if source == :disambiguation do
      changeset
    else
      validate_required(changeset, [:organization_id])
    end
  end
end
