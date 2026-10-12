defmodule Custyard.Acknowledgments do
  @moduledoc "Stores immutable Colonel evidence and explicit organization mappings. Callers authorize operator reads."
  import Ecto.Query
  alias Custyard.Repo
  alias Custyard.Acknowledgments.{Acknowledgment, Config, Consumer, Evidence, OrganizationBinding}

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

  defp present(value) when is_binary(value) and value != "", do: value
  defp present(_), do: nil

  def create_binding(attrs),
    do: %OrganizationBinding{} |> OrganizationBinding.changeset(attrs) |> Repo.insert()

  @doc "Idempotently provisions a mapping; an existing mapping cannot be reassigned."
  def bind(source, external_id, organization_id) do
    changeset =
      OrganizationBinding.changeset(%OrganizationBinding{}, %{
        source: source,
        source_organization_id: external_id,
        organization_id: organization_id
      })

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:source, :source_organization_id]
         ) do
      {:ok, _} ->
        binding = get_binding(source, external_id)

        if binding.organization_id == Ecto.Changeset.get_field(changeset, :organization_id),
          do: {:ok, binding},
          else: {:error, :conflicting_binding}

      error ->
        error
    end
  end

  def get_binding(source, external_id),
    do: Repo.get_by(OrganizationBinding, source: source, source_organization_id: external_id)

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
