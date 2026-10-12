defmodule Custyard.Acknowledgments do
  @moduledoc "Stores immutable Colonel evidence and explicit organization mappings. Callers authorize operator reads."
  import Ecto.Query
  require Logger
  alias Custyard.{AuditEvent, OperatorAccount, Organization, Repo}

  alias Custyard.Acknowledgments.{
    Acknowledgment,
    Config,
    Consumer,
    Evidence,
    Operations,
    OrganizationBinding
  }

  @doc """
  `:disabled`, `:not_configured`, `:connecting` or `:connected`. Reads published
  state only, so it never waits on the consumer.
  """
  def subscription_status do
    case Config.mode(Config.load()) do
      :disabled -> :disabled
      :configured -> Consumer.status()
      _ -> :not_configured
    end
  end

  @doc """
  What the operator UI may show about the subscription. Deliberately excludes
  the URL: the map is assigned to LiveView sockets.
  """
  def subscription_overview do
    config = Config.load()

    %{
      status: subscription_status(),
      broker_configured?: Config.connection_mode(config) == :configured,
      source: present(config[:source]),
      queue: config[:queue],
      prefetch: config[:prefetch],
      required_variables: Config.required_variables()
    }
  end

  @doc "The configured source when it is a valid identity, for source-pinned binding."
  def configured_source do
    source = Config.load()[:source]
    if Evidence.valid_identity?(source), do: source
  end

  def create_binding(attrs),
    do: %OrganizationBinding{} |> OrganizationBinding.changeset(attrs) |> Repo.insert()

  @doc """
  Idempotently provisions a mapping; an existing mapping cannot be reassigned.
  Returns `{:ok, :created, binding}` or `{:ok, :existing, binding}`, or
  `{:error, :conflicting_binding | :organization_not_found | changeset}`. Only a
  real insert writes an `:acknowledgment_binding_created` audit event, in the
  same transaction. `actor` is an operator account or a channel name such as
  `"cli"`.
  """
  def bind(source, external_id, organization_id, actor \\ "console") do
    changeset =
      OrganizationBinding.changeset(%OrganizationBinding{}, %{
        source: source,
        source_organization_id: external_id,
        organization_id: organization_id
      })

    cond do
      not changeset.valid? ->
        {:error, changeset}

      # ecto_sqlite3 reports a foreign key violation without a constraint
      # name, so foreign_key_constraint/2 cannot turn it into an error.
      not organization_exists?(Ecto.Changeset.get_field(changeset, :organization_id)) ->
        {:error, :organization_not_found}

      true ->
        insert_binding(changeset, actor)
    end
  end

  defp insert_binding(changeset, actor) do
    Repo.transaction(fn ->
      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: [:source, :source_organization_id]
           ) do
        {:ok, %OrganizationBinding{id: id} = binding} when not is_nil(id) ->
          audit!(:acknowledgment_binding_created, actor, binding.organization_id, %{
            "source" => binding.source,
            "source_organization_id" => binding.source_organization_id,
            "organization_id" => binding.organization_id
          })

          {:created, binding}

        {:ok, _} ->
          existing(changeset)

        {:error, changeset} ->
          Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, {outcome, binding}} -> {:ok, outcome, binding}
      {:error, reason} -> {:error, reason}
    end
  rescue
    Ecto.ConstraintError -> {:error, :organization_not_found}
  end

  defp existing(changeset) do
    source = Ecto.Changeset.get_field(changeset, :source)
    external_id = Ecto.Changeset.get_field(changeset, :source_organization_id)
    binding = get_binding(source, external_id)

    if binding.organization_id == Ecto.Changeset.get_field(changeset, :organization_id),
      do: {:existing, binding},
      else: Repo.rollback(:conflicting_binding)
  end

  defp organization_exists?(id) when is_integer(id),
    do: Repo.exists?(from o in Organization, where: o.id == ^id)

  defp organization_exists?(_), do: false

  def get_binding(source, external_id),
    do: Repo.get_by(OrganizationBinding, source: source, source_organization_id: external_id)

  @doc "Every binding with its organization's name, for super admins."
  def list_bindings do
    Repo.all(from b in binding_rows(), order_by: [asc: b.source, asc: b.source_organization_id])
  end

  @doc "Bindings that attribute evidence to one organization."
  def list_bindings_for_organization(organization_id) do
    Repo.all(
      from b in binding_rows(),
        where: b.organization_id == ^organization_id,
        order_by: [asc: b.source, asc: b.source_organization_id]
    )
  end

  # Selects the organization's name only, never the struct with its portal token.
  defp binding_rows do
    from b in OrganizationBinding,
      join: o in assoc(b, :organization),
      select: %{
        id: b.id,
        source: b.source,
        source_organization_id: b.source_organization_id,
        organization_id: b.organization_id,
        organization_name: o.name,
        inserted_at: b.inserted_at
      }
  end

  @doc """
  Replays the oldest failed message and audits the attempt in this process, so
  the record is written even when the requesting LiveView has gone away.
  `expected` is the inspected submission ID, or nil to replay whatever is
  oldest (release and Mix commands only).
  """
  def replay_failure(expected, actor) do
    {result, summary} = Operations.replay_head(expected)
    summary = summary || %{}

    audit(:acknowledgment_replayed, actor, nil, %{
      "source" => summary[:source],
      "submission_id" => summary[:submission_id],
      "category" => summary[:category],
      "attempt" => summary[:attempt],
      "outcome" => replay_outcome(result)
    })

    result
  end

  defp replay_outcome(:ok), do: "replayed"
  defp replay_outcome(:empty), do: "empty"
  defp replay_outcome({:error, {:unroutable, _}}), do: "unroutable"
  defp replay_outcome({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp replay_outcome(_), do: "operation_failed"

  # A replay has already happened (or not) at the broker, so a failed audit
  # write is logged rather than turned into an error.
  defp audit(event_type, actor, organization_id, payload) do
    audit!(event_type, actor, organization_id, payload)
  rescue
    error ->
      Logger.error("Failed to record #{event_type} audit event: #{Exception.message(error)}")
      :error
  catch
    :exit, _ ->
      Logger.error("Failed to record #{event_type} audit event: repository unavailable")
      :error
  end

  defp audit!(event_type, actor, organization_id, payload) do
    {channel, actor_fields} = actor_fields(actor)

    AuditEvent.changeset(%AuditEvent{}, %{
      event_type: event_type,
      source: channel,
      organization_id: organization_id,
      payload: Map.merge(payload, actor_fields)
    })
    |> Repo.insert!()
  end

  defp actor_fields(%OperatorAccount{id: id, email: email}),
    do: {"operator", %{"actor" => "operator", "operator_id" => id, "operator_email" => email}}

  defp actor_fields(channel) when channel in ["cli", "mix", "console"],
    do: {channel, %{"actor" => channel}}

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  def list_for_organization(id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20) |> max(1) |> min(100)
    offset = Keyword.get(opts, :offset, 0) |> max(0)

    Repo.all(
      from a in Acknowledgment,
        where: a.organization_id == ^id,
        order_by: [desc: a.received_at, desc: a.id],
        limit: ^limit,
        offset: ^offset
    )
  end

  def ingest(payload) do
    with {:ok, attrs} <- Evidence.validate(payload) do
      case Repo.get_by(Acknowledgment, source: attrs.source, submission_id: attrs.submission_id) do
        nil -> insert(attrs)
        record -> compare(record, attrs)
      end
    end
  end

  defp insert(attrs) do
    case get_binding(attrs.source, attrs.source_organization_id) do
      nil ->
        {:error, :unmapped_organization}

      binding ->
        changeset =
          Acknowledgment.changeset(
            %Acknowledgment{},
            Map.merge(attrs, %{
              organization_id: binding.organization_id,
              received_at: DateTime.utc_now()
            })
          )

        case Repo.insert(changeset,
               on_conflict: :nothing,
               conflict_target: [:source, :submission_id]
             ) do
          {:ok, _} ->
            Repo.get_by!(Acknowledgment, source: attrs.source, submission_id: attrs.submission_id)
            |> compare(attrs)

          error ->
            error
        end
    end
  end

  defp compare(record, attrs) do
    if Enum.all?(attrs, fn {key, value} -> Map.fetch!(record, key) === value end),
      do: {:ok, record},
      else: {:error, :conflicting_submission}
  end
end
