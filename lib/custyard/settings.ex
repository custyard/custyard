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

    # Singleton constraint - always true, unique constraint ensures only one row
    field :singleton, :boolean, default: true

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

  Malformed weight entries (non-numeric values) are silently skipped and
  the default weight for that key is used instead.
  """
  def get_weights do
    settings = get()

    parsed_weights =
      settings.score_weights
      |> Enum.filter(fn {k, _v} -> k in @valid_weight_keys end)
      |> Enum.flat_map(fn
        {k, v} when is_number(v) ->
          [{String.to_existing_atom(k), v}]

        _malformed_entry ->
          # Skip non-numeric values - defaults will be used via Map.merge below
          []
      end)
      |> Map.new()

    Map.merge(@default_weights, parsed_weights)
  end

  @doc """
  Get neglect thresholds as a map with atom tier keys and {warning, critical} tuples.

  Malformed threshold entries in the database (wrong structure, missing values, etc.)
  are silently skipped and the default threshold for that tier is used instead.
  """
  def get_neglect_thresholds do
    settings = get()

    parsed_thresholds =
      settings.neglect_thresholds
      |> Enum.filter(fn {k, _v} -> k in @valid_threshold_keys end)
      |> Enum.flat_map(fn
        {tier, [warning, critical]} when is_number(warning) and is_number(critical) ->
          [{String.to_existing_atom(tier), {warning, critical}}]

        _malformed_entry ->
          # Skip malformed entries - defaults will be used via Map.merge below
          []
      end)
      |> Map.new()

    Map.merge(@default_thresholds, parsed_thresholds)
  end

  @doc """
  Update score weights.
  Returns `{:ok, settings}` or `{:error, changeset}` if validation fails.
  """
  def update_weights(weights) when is_map(weights) do
    settings = get()
    stringified = stringify_keys(weights)

    settings
    |> cast(%{score_weights: stringified}, [:score_weights])
    |> validate_weights()
    |> validate_weight_values()
    |> Repo.update()
  end

  @doc """
  Update neglect thresholds.
  Returns `{:ok, settings}` or `{:error, changeset}` if validation fails.
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
    |> cast(%{neglect_thresholds: thresholds_for_db}, [:neglect_thresholds])
    |> validate_thresholds()
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
    |> cast(%{sieve_header_mappings: mappings}, [:sieve_header_mappings])
    |> validate_sieve_header_mappings()
    |> Repo.update()
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:score_weights, :neglect_thresholds, :sieve_header_mappings])
    |> validate_weights()
    |> validate_weight_values()
    |> validate_thresholds()
    |> validate_sieve_header_mappings()
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

  # Validate that weight values are finite positive numbers
  defp validate_weight_values(changeset) do
    case get_change(changeset, :score_weights) do
      nil ->
        changeset

      weights ->
        invalid_values =
          weights
          |> Enum.reject(fn {_k, v} ->
            is_number(v) and v >= 0 and v <= 1000 and not is_nan_or_inf?(v)
          end)
          |> Enum.map(fn {k, _v} -> k end)

        if Enum.empty?(invalid_values) do
          changeset
        else
          add_error(
            changeset,
            :score_weights,
            "contains invalid values for: #{Enum.join(invalid_values, ", ")}. Values must be numbers between 0 and 1000."
          )
        end
    end
  end

  # Check for Infinity (NaN cannot occur from Elixir arithmetic)
  # Values from external sources (JSON) would fail earlier in parsing
  defp is_nan_or_inf?(value) when is_float(value) do
    # Check for infinity by comparing to maximum finite float
    abs(value) > 1.0e308
  end

  defp is_nan_or_inf?(_), do: false

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

  # Supported properties for sieve header mappings
  @valid_sieve_properties ~w(tier urgency queue)

  defp validate_sieve_header_mappings(changeset) do
    case get_change(changeset, :sieve_header_mappings) do
      nil ->
        changeset

      mappings when is_map(mappings) ->
        if Enum.all?(mappings, &valid_sieve_mapping?/1) do
          changeset
        else
          add_error(
            changeset,
            :sieve_header_mappings,
            "invalid format: expected %{header => %{\"property\" => string, \"mapping\" => %{value => mapped_value}}}"
          )
        end

      _ ->
        add_error(changeset, :sieve_header_mappings, "must be a map")
    end
  end

  defp valid_sieve_mapping?({header_name, config})
       when is_binary(header_name) and is_map(config) do
    with %{"property" => property, "mapping" => mapping} <- config,
         true <- is_binary(property),
         true <- property in @valid_sieve_properties,
         true <- is_map(mapping),
         true <- Enum.all?(mapping, fn {k, v} -> is_binary(k) and is_binary(v) end) do
      true
    else
      _ -> false
    end
  end

  defp valid_sieve_mapping?(_), do: false

  defp create_defaults do
    # Handle race condition: multiple processes may call this concurrently on first access.
    # We use on_conflict: :nothing so only one insert succeeds; others become no-ops.
    # IMPORTANT: We must ALWAYS re-read from DB because:
    # 1. With on_conflict: :nothing, the returned struct has in-memory values, not DB values
    # 2. Another process may have won the race and inserted different defaults
    # 3. Schema changes could cause divergence between built struct and persisted row
    #
    # This is wrapped in a transaction to ensure atomicity of the insert-then-read pattern.
    Repo.transaction(fn ->
      thresholds_for_db =
        @default_thresholds
        |> Enum.map(fn {tier, {warning, critical}} ->
          {to_string(tier), [warning, critical]}
        end)
        |> Map.new()

      %__MODULE__{
        score_weights: stringify_keys(@default_weights),
        neglect_thresholds: thresholds_for_db,
        singleton: true
      }
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:singleton])

      # Always re-read the persisted row - this is the authoritative source of truth
      Repo.one!(__MODULE__)
    end)
    |> case do
      {:ok, settings} -> settings
      {:error, reason} -> raise "Failed to create default settings: #{inspect(reason)}"
    end
  end

  defp stringify_keys(map) do
    map
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end
end
