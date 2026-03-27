defmodule Custyard.SettingsTest do
  use Custyard.DataCase, async: true

  alias Custyard.Settings

  describe "get/0" do
    test "creates defaults when no settings exist" do
      settings = Settings.get()

      assert settings.id == 1
      assert is_map(settings.score_weights)
      assert is_map(settings.neglect_thresholds)
    end

    test "returns existing settings on subsequent calls" do
      settings1 = Settings.get()
      settings2 = Settings.get()

      assert settings1.id == settings2.id
    end
  end

  describe "get_weights/0" do
    test "returns default weights when using defaults" do
      weights = Settings.get_weights()

      assert weights.idle == 1.0
      assert weights.state == 1.0
      assert weights.tier == 1.0
      assert weights.urgency == 1.0
      assert weights.velocity == 1.0
      assert weights.neglect == 1.0
    end

    test "skips non-numeric values and uses defaults" do
      # First ensure settings exist
      Settings.get()

      # Directly update with invalid data
      Repo.update_all(Settings, set: [score_weights: %{"idle" => "invalid", "state" => 2.0}])

      weights = Settings.get_weights()

      # "invalid" should be skipped, default 1.0 used
      assert weights.idle == 1.0
      # 2.0 should be preserved
      assert weights.state == 2.0
      # Other defaults should still apply
      assert weights.tier == 1.0
    end
  end

  describe "get_neglect_thresholds/0" do
    test "returns default thresholds" do
      thresholds = Settings.get_neglect_thresholds()

      assert thresholds.enterprise == {4, 8}
      assert thresholds.standard == {24, 48}
      assert thresholds.basic == {48, 72}
    end

    test "skips malformed threshold entries" do
      # First ensure settings exist
      Settings.get()

      # Directly update with invalid data
      Repo.update_all(Settings,
        set: [
          neglect_thresholds: %{
            "enterprise" => "invalid",
            "standard" => [12, 24]
          }
        ]
      )

      thresholds = Settings.get_neglect_thresholds()

      # "invalid" should be skipped, default used
      assert thresholds.enterprise == {4, 8}
      # valid entry preserved
      assert thresholds.standard == {12, 24}
    end
  end

  describe "update_weights/1" do
    test "successfully updates valid weights" do
      _settings = Settings.get()

      new_weights = %{
        idle: 2.0,
        state: 2.0,
        tier: 2.0,
        urgency: 2.0,
        velocity: 2.0,
        neglect: 2.0
      }

      assert {:ok, _} = Settings.update_weights(new_weights)

      weights = Settings.get_weights()
      assert weights.idle == 2.0
    end

    test "rejects negative values" do
      _settings = Settings.get()

      new_weights = %{
        idle: -1.0,
        state: 1.0,
        tier: 1.0,
        urgency: 1.0,
        velocity: 1.0,
        neglect: 1.0
      }

      assert {:error, changeset} = Settings.update_weights(new_weights)
      assert "contains invalid values" <> _ = errors_on(changeset).score_weights |> hd()
    end

    test "rejects values over 1000" do
      _settings = Settings.get()

      new_weights = %{
        idle: 1001.0,
        state: 1.0,
        tier: 1.0,
        urgency: 1.0,
        velocity: 1.0,
        neglect: 1.0
      }

      assert {:error, changeset} = Settings.update_weights(new_weights)
      assert "contains invalid values" <> _ = errors_on(changeset).score_weights |> hd()
    end

    test "rejects missing required keys" do
      _settings = Settings.get()

      # Missing some keys
      new_weights = %{idle: 1.0, state: 1.0}

      assert {:error, changeset} = Settings.update_weights(new_weights)
      assert "must contain all required weight keys" in errors_on(changeset).score_weights
    end
  end

  describe "update_thresholds/1" do
    test "successfully updates valid thresholds" do
      _settings = Settings.get()

      new_thresholds = %{
        enterprise: {2, 4},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:ok, _} = Settings.update_thresholds(new_thresholds)

      thresholds = Settings.get_neglect_thresholds()
      assert thresholds.enterprise == {2, 4}
    end

    test "rejects invalid threshold format" do
      _settings = Settings.get()

      # warning must be positive
      new_thresholds = %{
        enterprise: {0, 4},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:error, changeset} = Settings.update_thresholds(new_thresholds)
      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end

    test "rejects thresholds where warning >= critical" do
      _settings = Settings.get()

      new_thresholds = %{
        enterprise: {10, 5},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:error, changeset} = Settings.update_thresholds(new_thresholds)
      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end
  end

  describe "update_sieve_header_mappings/1" do
    test "successfully updates valid mappings" do
      _settings = Settings.get()

      mappings = %{
        "X-Customer-Tier" => %{
          "property" => "tier",
          "mapping" => %{
            "ent" => "enterprise",
            "std" => "standard"
          }
        }
      }

      assert {:ok, _} = Settings.update_sieve_header_mappings(mappings)

      result = Settings.get_sieve_header_mappings()
      assert result["X-Customer-Tier"]["property"] == "tier"
    end

    test "rejects invalid property name" do
      _settings = Settings.get()

      mappings = %{
        "X-Header" => %{
          "property" => "invalid_property",
          "mapping" => %{"a" => "b"}
        }
      }

      assert {:error, changeset} = Settings.update_sieve_header_mappings(mappings)
      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "rejects missing property key" do
      _settings = Settings.get()

      mappings = %{
        "X-Header" => %{
          "mapping" => %{"a" => "b"}
        }
      }

      assert {:error, changeset} = Settings.update_sieve_header_mappings(mappings)
      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "rejects non-string mapping values" do
      _settings = Settings.get()

      mappings = %{
        "X-Header" => %{
          "property" => "tier",
          "mapping" => %{"a" => 123}
        }
      }

      assert {:error, changeset} = Settings.update_sieve_header_mappings(mappings)
      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "accepts valid properties: tier, urgency, queue" do
      _settings = Settings.get()

      for property <- ["tier", "urgency", "queue"] do
        mappings = %{
          "X-Header" => %{
            "property" => property,
            "mapping" => %{"a" => "b"}
          }
        }

        assert {:ok, _} = Settings.update_sieve_header_mappings(mappings),
               "Expected #{property} to be valid"
      end
    end
  end

  describe "changeset/2" do
    test "validates weights structure" do
      settings = Settings.get()

      changeset =
        Settings.changeset(settings, %{
          score_weights: %{"idle" => 1.0}
        })

      refute changeset.valid?
      assert "must contain all required weight keys" in errors_on(changeset).score_weights
    end

    test "validates threshold structure" do
      settings = Settings.get()

      changeset =
        Settings.changeset(settings, %{
          neglect_thresholds: %{"enterprise" => [0, 4]}
        })

      refute changeset.valid?
      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end
  end
end
