defmodule Custyard.Email.SieveHeaderMapperTest do
  use Custyard.DataCase, async: true

  alias Custyard.Email.SieveHeaderMapper
  alias Custyard.Settings

  describe "extract_properties/1" do
    setup do
      # Ensure Settings singleton exists with sieve_header_mappings configured
      Settings.get_or_create()

      Settings.update_sieve_header_mappings(%{
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
      })

      :ok
    end

    test "extracts urgency from header" do
      headers = %{"X-Priority" => "high"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{urgency: :urgent}
    end

    test "extracts tier from header" do
      headers = %{"X-Customer-Tier" => "ent"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{tier: :enterprise}
    end

    test "extracts multiple properties from headers" do
      headers = %{
        "X-Customer-Tier" => "std",
        "X-Priority" => "medium"
      }

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{tier: :standard, urgency: :elevated}
    end

    test "case-insensitive header name lookup" do
      headers = %{"x-priority" => "urgent"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{urgency: :urgent}
    end

    test "case-insensitive value lookup" do
      headers = %{"X-Priority" => "HIGH"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{urgency: :urgent}
    end

    test "ignores unmapped header values" do
      headers = %{"X-Priority" => "unknown_priority"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{}
    end

    test "ignores headers not in configuration" do
      headers = %{"X-Unknown-Header" => "some-value"}

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{}
    end

    test "returns empty map for non-map input" do
      assert SieveHeaderMapper.extract_properties(nil) == %{}
      assert SieveHeaderMapper.extract_properties("not a map") == %{}
    end

    test "ignores unknown property names in config" do
      # Update settings with an unknown property
      Settings.update_sieve_header_mappings(%{
        "X-Unknown-Prop" => %{
          "property" => "unknown_prop",
          "mapping" => %{"val" => "value"}
        }
      })

      headers = %{"X-Unknown-Prop" => "val"}

      # Should silently ignore the unknown property
      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{}
    end

    test "rejects invalid values for known properties" do
      headers = %{"X-Priority" => "invalid-urgency-value"}

      # Even if mapped, invalid values are rejected
      Settings.update_sieve_header_mappings(%{
        "X-Priority" => %{
          "property" => "urgency",
          "mapping" => %{
            "invalid-urgency-value" => "not-a-valid-urgency"
          }
        }
      })

      result = SieveHeaderMapper.extract_properties(headers)

      assert result == %{}
    end
  end

  describe "merge_overrides/2" do
    setup do
      Settings.get_or_create()

      Settings.update_sieve_header_mappings(%{
        "X-Priority" => %{
          "property" => "urgency",
          "mapping" => %{"high" => "urgent"}
        }
      })

      :ok
    end

    test "overrides urgency in attrs" do
      attrs = %{subject: "Test", urgency: :normal}
      headers = %{"X-Priority" => "high"}

      result = SieveHeaderMapper.merge_overrides(attrs, headers)

      assert result.urgency == :urgent
      assert result.subject == "Test"
    end

    test "preserves attrs when no matching headers" do
      attrs = %{subject: "Test", urgency: :normal}
      headers = %{}

      result = SieveHeaderMapper.merge_overrides(attrs, headers)

      assert result == attrs
    end

    test "preserves existing attrs when header values are invalid" do
      attrs = %{subject: "Test", urgency: :normal}
      headers = %{"X-Priority" => "unknown"}

      result = SieveHeaderMapper.merge_overrides(attrs, headers)

      assert result.urgency == :normal
    end
  end
end
