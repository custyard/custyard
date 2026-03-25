defmodule Custyard.Settings do
  @moduledoc """
  Application settings for scoring weights and neglect thresholds.

  Uses a single-row pattern - there's only ever one settings record.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Custyard.Repo

  @default_weights %{
    idle: 1.0,
    state: 1.0,
    tier: 1.0,
    urgency: 1.0,
    velocity: 1.0,
    neglect: 1.0
  }

  @default_thresholds %{
    enterprise: {4, 8},
    standard: {24, 48},
    basic: {48, 72}
  }

  @valid_weight_keys Map.keys(@default_weights) |> Enum.map(&to_string/1)
  @valid_threshold_keys Map.keys(@default_thresholds) |> Enum.map(&to_string/1)

  schema "settings" do
    # Score weights (stored as map in JSON column)
    field :score_weights, :map, default: @default_weights

    # Neglect thresholds per tier: %{tier => [warning_hours, critical_hours]}
    field :neglect_thresholds, :map

    # Sieve header mappings for email metadata extraction
    # Format: %{header_name => %{property => property_name, mapping => %{value => property_value}}}
    # Example: %{"X-Customer-Tier" => %{"property" => "tier", "mapping" => %{"ent" => "enterprise"}}}
    field :sieve_header_mappings, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Get the current settings, creating defaults if none exist.
  """
  def get do
    case Repo.one(__MODULE__) do
      nil -> create_defaults()
      settings -> settings
    end
  end

  @doc """
  Get score weights as a map with atom keys.
  """
  def get_weights do
    settings = get()

    settings.score_weights
    |> Enum.filter(fn {k, _v} -> k in @valid_weight_keys end)
    |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
    |> Map.new()
    |> then(fn weights ->
      Map.merge(@default_weights, weights)
    end)
  end

  @doc """
  Get neglect thresholds as a map with atom tier keys and {warning, critical} tuples.
  """
  def get_neglect_thresholds do
    settings = get()

    settings.neglect_thresholds
    |> Enum.filter(fn {k, _v} -> k in @valid_threshold_keys end)
    |> Enum.map(fn {tier, [warning, critical]} ->
      {String.to_existing_atom(tier), {warning, critical}}
    end)
    |> Map.new()
    |> then(fn thresholds ->
      Map.merge(@default_thresholds, thresholds)
    end)
  end

  @doc """
  Update score weights.
  """
  def update_weights(weights) when is_map(weights) do
    settings = get()

    settings
    |> change(score_weights: stringify_keys(weights))
    |> Repo.update()
  end

  @doc """
  Update neglect thresholds.
  """
  def update_thresholds(thresholds) when is_map(thresholds) do
    settings = get()

    # Convert {warning, critical} tuples to [warning, critical] lists for JSON
    thresholds_for_db =
      thresholds
      |> Enum.map(fn {tier, {warning, critical}} ->
        {to_string(tier), [warning, critical]}
      end)
      |> Map.new()

    settings
    |> change(neglect_thresholds: thresholds_for_db)
    |> Repo.update()
  end

  @doc """
  Get Sieve header mappings.

  Returns a map of header name => mapping config.
  Example: %{"X-Customer-Tier" => %{"property" => "tier", "mapping" => %{"ent" => "enterprise"}}}
  """
  def get_sieve_header_mappings do
    settings = get()
    settings.sieve_header_mappings || %{}
  end

  @doc """
  Update Sieve header mappings.

  Each mapping should be: %{header_name => %{"property" => name, "mapping" => %{value => property_value}}}

  Supported properties:
  - "tier" - maps to organization tier (enterprise, standard, basic)
  - "urgency" - maps to conversation urgency (urgent, elevated, normal)
  - "queue" - reserved for future queue assignment
  """
  def update_sieve_header_mappings(mappings) when is_map(mappings) do
    settings = get()

    settings
    |> change(sieve_header_mappings: mappings)
    |> Repo.update()
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:score_weights, :neglect_thresholds])
    |> validate_weights()
    |> validate_thresholds()
  end

  defp validate_weights(changeset) do
    case get_change(changeset, :score_weights) do
      nil ->
        changeset

      weights ->
        required_keys = ~w(idle state tier urgency velocity neglect)

        if Enum.all?(required_keys, &Map.has_key?(weights, &1)) do
          changeset
        else
          add_error(changeset, :score_weights, "must contain all required weight keys")
        end
    end
  end

  defp validate_thresholds(changeset) do
    case get_change(changeset, :neglect_thresholds) do
      nil -> changeset
      thresholds -> validate_threshold_values(changeset, thresholds)
    end
  end

  defp validate_threshold_values(changeset, thresholds) do
    if Enum.all?(thresholds, &valid_threshold?/1) do
      changeset
    else
      add_error(changeset, :neglect_thresholds, "invalid threshold format")
    end
  end

  defp valid_threshold?({_tier, [warning, critical]})
       when is_number(warning) and is_number(critical) do
    warning > 0 and critical > warning
  end

  defp valid_threshold?(_), do: false

  defp create_defaults do
    # Convert thresholds to JSON-friendly format
    thresholds_for_db =
      @default_thresholds
      |> Enum.map(fn {tier, {warning, critical}} ->
        {to_string(tier), [warning, critical]}
      end)
      |> Map.new()

    # Use a fixed ID and on_conflict: :nothing to handle concurrent first-access
    # race conditions safely. If another process inserts first, this is a no-op.
    %__MODULE__{
      id: 1,
      score_weights: stringify_keys(@default_weights),
      neglect_thresholds: thresholds_for_db
    }
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:id])

    # Always re-read to return the persisted row (whether we inserted or not)
    Repo.one!(__MODULE__)
  end

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
