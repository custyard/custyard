defmodule Custyard.Thread do
  use Ecto.Schema
  import Ecto.Changeset

  @states [:new, :active, :waiting, :dormant, :resolved]
  @urgencies [:normal, :elevated, :urgent]
  @sources [
    :email,
    :lettermint,
    :zendesk,
    :intercom,
    :slack,
    :portal,
    :disambiguation,
    :public_intake
  ]

  # Sources whose threads may exist without an organization:
  # - :disambiguation — limbo threads awaiting manual routing
  # - :public_intake — anonymous prospect threads (linked later, if ever)

  @neglect_levels [:ok, :warning, :critical]

  # Valid state transitions: from_state => [allowed_to_states]
  # Transitions follow this logic:
  # - :new -> :active (staff or customer action), :resolved (resolve without activity)
  # Valid state transitions
  @valid_transitions %{
    new: [:active, :resolved],
    active: [:waiting, :resolved],
    waiting: [:active, :dormant, :resolved],
    dormant: [:active, :resolved],
    resolved: [:active]
  }

  schema "threads" do
    field(:tenant_id, :id)
    belongs_to(:tenant, Custyard.Tenant, define_field: false)
    field(:subject, :string)
    field(:state, Ecto.Enum, values: @states, default: :new)
    field(:urgency, Ecto.Enum, values: @urgencies, default: :normal)
    field(:source, Ecto.Enum, values: @sources, default: :email)
    field(:cached_score, :integer, default: 0)

    # CTA provenance: which public intake source (by key string, not FK)
    # created this thread. Creation-only — deliberately absent from the
    # changeset/2 cast list; set via intake_changeset/2 at creation.
    field(:intake_source_key, :string)

    field(:last_staff_action_at, :utc_datetime)
    field(:last_customer_action_at, :utc_datetime)
    field(:snoozed_until, :utc_datetime)

    # Tracks the last neglect level that triggered a notification
    # Prevents duplicate alerts when recalculating
    field(:last_neglect_notification, Ecto.Enum, values: @neglect_levels)

    # Triage flagged the first message as spam or unauthenticated from an
    # unknown sender (spec-inbound-channels D6). A badge and a notification
    # suppressor, never a filter; cleared via suspect_changeset/2.
    field(:suspect, :boolean, default: false)
    # ISO 639-1 code detected from the first customer message (enrichment);
    # nil when the text was too short or ambiguous.
    field(:language, :string)

    belongs_to(:organization, Custyard.Organization)
    belongs_to(:inbound_channel, Custyard.InboundChannel)
    belongs_to(:contact, Custyard.Contact)
    belongs_to(:project, Custyard.Project)
    has_one(:prospect, Custyard.Prospect)
    has_many(:messages, Custyard.Message)
    has_many(:tasks, Custyard.Task)

    timestamps(type: :utc_datetime)
  end

  def states, do: @states
  def urgencies, do: @urgencies
  def sources, do: @sources

  @doc false
  def changeset(thread, attrs) do
    thread
    |> cast(attrs, [
      :tenant_id,
      :subject,
      :state,
      :urgency,
      :source,
      # Note: :cached_score is computed by Scoring.calculate_and_cache/1
      # Note: :last_neglect_notification is managed by NeglectChecker
      :last_staff_action_at,
      :last_customer_action_at,
      :snoozed_until,
      :organization_id,
      :contact_id,
      :project_id,
      :inbound_channel_id,
      :language
    ])
    |> put_organization_tenant()
    |> validate_tenant_ownership()
    |> validate_customer_relationships()
    |> validate_required([:tenant_id])
    |> foreign_key_constraint(:tenant_id)
    |> validate_required([:subject])
    |> validate_length(:subject, max: 500)
    |> validate_length(:language, max: 8)
    # Note: :state, :urgency, :source use Ecto.Enum which validates values automatically
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:contact_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:inbound_channel_id)
  end

  @doc """
  Changeset for the triage suspect flag. Deliberately outside `changeset/2`
  so the flag is set only by triage at creation and cleared only by an
  explicit staff action.
  """
  def suspect_changeset(thread, suspect?) when is_boolean(suspect?) do
    change(thread, suspect: suspect?)
  end

  @doc """
  Changeset for creating a public-intake thread.

  Extends `changeset/2` with `:intake_source_key`, which is creation-only
  provenance: it is deliberately absent from the `changeset/2` cast list so
  staff-facing update paths can never set or change it.
  """
  def intake_changeset(thread, attrs) do
    thread
    |> changeset(attrs)
    |> cast(attrs, [:intake_source_key])
    |> validate_format(:intake_source_key, Custyard.IntakeSource.key_format())
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
  Changeset for transitioning thread state.

  Validates that the transition is allowed according to the state machine.
  Invalid transitions will add an error to the changeset.
  """
  def state_changeset(thread, new_state) do
    changeset =
      thread
      |> cast(%{state: new_state}, [:state])

    current_state = thread.state

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
  Changeset for snoozing a thread.
  """
  def snooze_changeset(thread, until) do
    thread
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
  def internal_changeset(thread, attrs) do
    thread
    |> cast(attrs, [:cached_score, :last_neglect_notification])
  end

  defp put_organization_tenant(changeset) do
    case get_field(changeset, :organization_id) do
      id when is_integer(id) ->
        case Custyard.Repo.get(Custyard.Organization, id) do
          %{tenant_id: tenant_id} ->
            case get_field(changeset, :tenant_id) do
              nil -> put_change(changeset, :tenant_id, tenant_id)
              ^tenant_id -> changeset
              _ -> add_error(changeset, :organization_id, "must belong to the same tenant")
            end

          _ ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_tenant_ownership(changeset) do
    tenant_id = get_field(changeset, :tenant_id)
    changeset = immutable_tenant(changeset, tenant_id)

    Enum.reduce(
      [
        contact_id: Custyard.Contact,
        project_id: Custyard.Project,
        inbound_channel_id: Custyard.InboundChannel
      ],
      changeset,
      fn {field, schema}, acc ->
        validate_reference_tenant(acc, field, schema, tenant_id)
      end
    )
  end

  defp immutable_tenant(changeset, tenant_id) do
    if changeset.data.__meta__.state == :loaded and changeset.data.tenant_id != tenant_id,
      do: add_error(changeset, :tenant_id, "cannot move a thread between tenants"),
      else: changeset
  end

  defp validate_customer_relationships(changeset) do
    organization_id = get_field(changeset, :organization_id)

    Enum.reduce([contact_id: Custyard.Contact, project_id: Custyard.Project], changeset, fn
      {field, schema}, acc ->
        case get_field(acc, field) && Custyard.Repo.get(schema, get_field(acc, field)) do
          %{organization_id: ^organization_id} -> acc
          nil -> acc
          _ -> add_error(acc, field, "must belong to the thread's customer")
        end
    end)
  end

  defp validate_reference_tenant(changeset, field, schema, tenant_id) do
    case get_field(changeset, field) do
      id when is_integer(id) ->
        case reference_tenant(Custyard.Repo.get(schema, id)) do
          nil -> changeset
          ^tenant_id -> changeset
          _ -> add_error(changeset, field, "must belong to the same tenant")
        end

      _ ->
        changeset
    end
  end

  defp reference_tenant(nil), do: nil

  defp reference_tenant(%Custyard.Contact{organization_id: id}) do
    case Custyard.Repo.get(Custyard.Organization, id) do
      %{tenant_id: tenant_id} -> tenant_id
      _ -> nil
    end
  end

  defp reference_tenant(%{tenant_id: tenant_id}), do: tenant_id

  # Disambiguation and public-intake threads can have nil organization_id
end
