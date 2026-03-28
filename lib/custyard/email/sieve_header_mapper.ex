defmodule Custyard.Email.SieveHeaderMapper do
  @moduledoc """
  Maps Sieve-injected email headers to conversation properties.

  Operators can configure Sieve rules on their MTA to inject custom headers
  before forwarding email to the platform. This module reads those headers
  and maps their values to conversation properties.

  ## Supported Properties

  - `tier` - Organization service tier (enterprise, standard, basic)
  - `urgency` - Conversation urgency level (urgent, elevated, normal)

  ## Configuration

  Header mappings are stored in Settings.sieve_header_mappings. Example:

      %{
        "X-Customer-Tier" => %{
          "property" => "tier",
          "mapping" => %{
            "ent" => "enterprise",
            "std" => "standard",
            "basic" => "basic"
          }
        },
        "X-Priority" => %{
          "property" => "urgency",
          "mapping" => %{
            "high" => "urgent",
            "medium" => "elevated",
            "low" => "normal"
          }
        }
      }

  ## Usage

  Called during email processing to extract property overrides from headers:

      headers = %{"X-Customer-Tier" => "ent", "X-Priority" => "high"}
      overrides = SieveHeaderMapper.extract_properties(headers)
      # => %{tier: :enterprise, urgency: :urgent}
  """

  alias Custyard.Email.Normalizer
  alias Custyard.Settings

  # Allowed properties and their valid values
  # Using atoms directly to ensure they exist at compile time
  @valid_properties %{
    "tier" => %{atom: :tier, values: ~w(enterprise standard basic)},
    "urgency" => %{atom: :urgency, values: ~w(urgent elevated normal)}
  }

  @doc """
  Extract conversation property overrides from email headers.

  Takes a map of headers and returns a map of property atoms to their values.
  Only returns properties that have valid mappings configured and valid values.
  """
  @spec extract_properties(map()) :: map()
  def extract_properties(headers) when is_map(headers) do
    mappings = Settings.get_sieve_header_mappings()

    mappings
    |> Enum.map(fn {header_name, config} ->
      header_value = get_header(headers, header_name)
      map_header_to_property(header_value, config)
    end)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  def extract_properties(_), do: %{}

  defp get_header(headers, name), do: Normalizer.get_header(headers, name)

  # Map a header value to a property using the config
  defp map_header_to_property(nil, _config), do: nil

  defp map_header_to_property(header_value, config) do
    property = config["property"]
    mapping = config["mapping"] || %{}

    # Validate property is in allowlist first - prevents atom exhaustion
    # and ensures we use pre-existing atoms from @valid_properties
    case Map.get(@valid_properties, property) do
      nil ->
        # Unknown property - ignore silently to avoid crashing email processing
        nil

      %{atom: property_atom, values: valid_values} ->
        # Look up the mapped value (case-insensitive)
        mapped_value = find_mapped_value(header_value, mapping)

        case validate_value(mapped_value, valid_values) do
          {:ok, value_atom} -> {property_atom, value_atom}
          :error -> nil
        end
    end
  end

  defp find_mapped_value(header_value, mapping) do
    lowercase_value = String.downcase(String.trim(header_value))

    Enum.find_value(mapping, fn {k, v} ->
      if String.downcase(k) == lowercase_value, do: v
    end)
  end

  # Validate the value is in the allowed list for this property
  defp validate_value(nil, _valid_values), do: :error

  defp validate_value(value, valid_values) do
    if value in valid_values do
      # Safe because valid_values contains only strings for atoms that exist
      # (enterprise, standard, basic, urgent, elevated, normal)
      {:ok, String.to_existing_atom(value)}
    else
      :error
    end
  end

  @doc """
  Merge extracted properties into conversation attributes.

  Takes existing attrs and applies property overrides from headers.
  Sieve-injected properties take precedence over auto-detected values.
  """
  @spec merge_overrides(map(), map()) :: map()
  def merge_overrides(attrs, headers) do
    overrides = extract_properties(headers)

    # Override urgency if provided
    attrs =
      case overrides[:urgency] do
        nil -> attrs
        urgency -> Map.put(attrs, :urgency, urgency)
      end

    # Note: tier is on Organization, not Conversation
    # If tier override is needed, it should be handled separately

    attrs
  end
end
