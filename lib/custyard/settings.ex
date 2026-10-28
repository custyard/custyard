defmodule Custyard.Settings do
  @moduledoc """
  Application settings for scoring weights, neglect thresholds, and
  public intake configuration.

  Each tenant owns its settings record.
  """
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]
  alias Custyard.{StaffAccess, StaffAccount, Scope, Tenant}

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

  # unlinked_tier_score deliberately equals the standard tier score:
  # unknown value scores as average (net-not-filter).
  @default_intake_config %{
    unlinked_tier_score: 10,
    slug_claim_ttl_hours: 72
  }

  @valid_weight_keys Map.keys(@default_weights) |> Enum.map(&to_string/1)
  @valid_threshold_keys Map.keys(@default_thresholds) |> Enum.map(&to_string/1)

  schema "settings" do
    # Score weights (stored as map in JSON column)
    field(:score_weights, :map, default: @default_weights)

    # Neglect thresholds per tier: %{tier => [warning_hours, critical_hours]}
    field(:neglect_thresholds, :map)

    # Sieve header mappings for email metadata extraction
    # Format: %{header_name => %{property => property_name, mapping => %{value => property_value}}}
    # Example: %{"X-Customer-Tier" => %{"property" => "tier", "mapping" => %{"ent" => "enterprise"}}}
    field(:sieve_header_mappings, :map, default: %{})

    # Public intake configuration (stored as map in JSON column)
    # Keys: "unlinked_tier_score" (integer 0..100), "slug_claim_ttl_hours" (integer 1..720)
    field(:intake_config, :map, default: %{})

    # One settings record per tenant
    belongs_to(:tenant, Custyard.Tenant)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Get the current settings, creating defaults if none exist.
  """
  def get(tenant_id) when is_integer(tenant_id) do
    case Repo.get_by(__MODULE__, tenant_id: tenant_id) do
      nil -> create_defaults(tenant_id)
      settings -> settings
    end
  end

  @doc """
  Get score weights as a map with atom keys.

  Malformed weight entries (non-numeric values) are silently skipped and
  the default weight for that key is used instead.
  """
  def get_weights(tenant_id) do
    settings = get(tenant_id)

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
  def get_neglect_thresholds(tenant_id) do
    settings = get(tenant_id)

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
  def update_weights(%Scope{} = scope, weights) when is_map(weights) do
    with_admin_scope(scope, fn -> do_update_weights(scope.tenant_id, weights) end)
  end

  defp do_update_weights(tenant_id, weights) do
    settings = get(tenant_id)
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
  def update_thresholds(%Scope{} = scope, thresholds) when is_map(thresholds) do
    with_admin_scope(scope, fn -> do_update_thresholds(scope.tenant_id, thresholds) end)
  end

  defp do_update_thresholds(tenant_id, thresholds) do
    settings = get(tenant_id)

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
  def get_sieve_header_mappings(tenant_id) do
    settings = get(tenant_id)
    settings.sieve_header_mappings || %{}
  end

  @doc """
  Get public intake configuration as a map with atom keys.

  Malformed entries (non-integer or out-of-range values) are silently
  skipped and the default for that key is used instead.

  Keys:
  - `:unlinked_tier_score` - tier-equivalent score for threads without
    an organization (0..100, default 10 = standard tier)
  - `:slug_claim_ttl_hours` - lifetime of an unconfirmed slug claim
    (1..720, default 72)
  """
  def get_intake_config(tenant_id) do
    settings = get(tenant_id)

    parsed_config =
      (settings.intake_config || %{})
      |> Enum.filter(fn {k, v} -> valid_intake_config_entry?(k, v) end)
      |> Enum.map(fn {k, v} -> {String.to_existing_atom(k), v} end)
      |> Map.new()

    Map.merge(@default_intake_config, parsed_config)
  end

  @doc """
  Update public intake configuration.
  Returns `{:ok, settings}` or `{:error, changeset}` if validation fails.
  """
  def update_intake_config(%Scope{} = scope, config) when is_map(config) do
    with_admin_scope(scope, fn -> do_update_intake_config(scope.tenant_id, config) end)
  end

  defp do_update_intake_config(tenant_id, config) do
    settings = get(tenant_id)

    # Merge over the stored map: intake_config holds independent keys driving
    # different subsystems (unlinked_tier_score, slug_claim_ttl_hours), so a
    # partial update must preserve the others rather than reset them to
    # defaults on the next get_intake_config/0. (Unlike update_branding/1,
    # which replaces the whole map so a key can be cleared.)
    merged = Map.merge(settings.intake_config || %{}, stringify_keys(config))

    settings
    |> cast(%{intake_config: merged}, [:intake_config])
    |> validate_intake_config()
    |> Repo.update()
  end

  @doc "Read the tenant's canonical workspace branding."
  def get_branding(tenant_id),
    do: Custyard.Tenants.branding(Custyard.Tenants.get_tenant!(tenant_id))

  @doc """
  Update Sieve header mappings.

  Each mapping should be: %{header_name => %{"property" => name, "mapping" => %{value => property_value}}}

  Supported properties:
  - "tier" - maps to organization tier (enterprise, standard, basic)
  - "urgency" - maps to thread urgency (urgent, elevated, normal)
  - "queue" - reserved for future queue assignment
  """
  def update_sieve_header_mappings(%Scope{} = scope, mappings) when is_map(mappings) do
    with_admin_scope(scope, fn -> do_update_sieve_header_mappings(scope.tenant_id, mappings) end)
  end

  defp do_update_sieve_header_mappings(tenant_id, mappings) do
    settings = get(tenant_id)

    settings
    |> cast(%{sieve_header_mappings: mappings}, [:sieve_header_mappings])
    |> validate_sieve_header_mappings()
    |> Repo.update()
  end

  defp with_admin_scope(scope, fun) do
    Repo.transaction(fn ->
      StaffAccess.lock_current(%StaffAccount{id: scope.staff_id})

      Repo.update_all(from(t in Tenant, where: t.id == ^scope.tenant_id and t.status == "active"),
        set: [updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      )

      case Scope.current_staff(scope) do
        %{role: "admin"} ->
          case fun.() do
            {:ok, settings} -> settings
            {:error, reason} -> Repo.rollback(reason)
          end

        _ ->
          Repo.rollback(:unauthorized)
      end
    end)
  end

  @doc false
  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :tenant_id,
      :score_weights,
      :neglect_thresholds,
      :sieve_header_mappings,
      :intake_config
    ])
    |> validate_required([:tenant_id])
    |> foreign_key_constraint(:tenant_id)
    |> unique_constraint(:tenant_id)
    |> validate_weights()
    |> validate_weight_values()
    |> validate_thresholds()
    |> validate_sieve_header_mappings()
    |> validate_intake_config()
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

  defp validate_intake_config(changeset) do
    case get_change(changeset, :intake_config) do
      nil ->
        changeset

      config when is_map(config) ->
        invalid_keys =
          config
          |> Enum.reject(fn {k, v} -> valid_intake_config_entry?(k, v) end)
          |> Enum.map(fn {k, _v} -> k end)

        if Enum.empty?(invalid_keys) do
          changeset
        else
          add_error(
            changeset,
            :intake_config,
            "contains invalid entries for: #{Enum.join(invalid_keys, ", ")}. " <>
              "unlinked_tier_score must be an integer between 0 and 100; " <>
              "slug_claim_ttl_hours must be an integer between 1 and 720."
          )
        end

      _ ->
        add_error(changeset, :intake_config, "must be a map")
    end
  end

  defp valid_intake_config_entry?("unlinked_tier_score", value),
    do: is_integer(value) and value in 0..100

  defp valid_intake_config_entry?("slug_claim_ttl_hours", value),
    do: is_integer(value) and value in 1..720

  defp valid_intake_config_entry?(_key, _value), do: false

  defp create_defaults(tenant_id) do
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
        tenant_id: tenant_id
      }
      |> Repo.insert!(on_conflict: :nothing, conflict_target: [:tenant_id])

      # Always re-read the persisted row - this is the authoritative source of truth
      Repo.get_by!(__MODULE__, tenant_id: tenant_id)
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
