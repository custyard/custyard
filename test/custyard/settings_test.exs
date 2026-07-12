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

    test "create_defaults leaves branding empty with nil-defaulted reads" do
      settings = Settings.get()

      assert settings.branding == %{}
      assert Settings.get_branding() == %{name: nil, logo_url: nil, primary_color: nil}
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

  describe "get_intake_config/0" do
    test "returns defaults when nothing is stored" do
      config = Settings.get_intake_config()

      assert config.unlinked_tier_score == 10
      assert config.slug_claim_ttl_hours == 72
    end

    test "skips malformed values and uses defaults" do
      # First ensure settings exist
      Settings.get()

      # Directly update with invalid data
      Repo.update_all(Settings,
        set: [intake_config: %{"unlinked_tier_score" => "high", "slug_claim_ttl_hours" => 24}]
      )

      config = Settings.get_intake_config()

      # "high" should be skipped, default 10 used
      assert config.unlinked_tier_score == 10
      # valid entry preserved
      assert config.slug_claim_ttl_hours == 24
    end

    test "skips out-of-range values and unknown keys" do
      Settings.get()

      Repo.update_all(Settings,
        set: [intake_config: %{"unlinked_tier_score" => 500, "surprise" => 1}]
      )

      config = Settings.get_intake_config()

      assert config.unlinked_tier_score == 10
      refute Map.has_key?(config, :surprise)
    end
  end

  describe "update_intake_config/1" do
    test "round-trips valid values" do
      assert {:ok, _} =
               Settings.update_intake_config(%{
                 unlinked_tier_score: 25,
                 slug_claim_ttl_hours: 48
               })

      config = Settings.get_intake_config()
      assert config.unlinked_tier_score == 25
      assert config.slug_claim_ttl_hours == 48
    end

    test "rejects out-of-range unlinked_tier_score" do
      assert {:error, changeset} =
               Settings.update_intake_config(%{
                 unlinked_tier_score: 101,
                 slug_claim_ttl_hours: 72
               })

      assert [error] = errors_on(changeset).intake_config
      assert error =~ "unlinked_tier_score"
    end

    test "rejects out-of-range slug_claim_ttl_hours" do
      assert {:error, _} =
               Settings.update_intake_config(%{unlinked_tier_score: 10, slug_claim_ttl_hours: 0})

      assert {:error, _} =
               Settings.update_intake_config(%{
                 unlinked_tier_score: 10,
                 slug_claim_ttl_hours: 721
               })
    end

    test "rejects non-integer values" do
      assert {:error, _} =
               Settings.update_intake_config(%{
                 unlinked_tier_score: 10.5,
                 slug_claim_ttl_hours: 72
               })
    end

    test "rejects unknown keys" do
      assert {:error, changeset} = Settings.update_intake_config(%{bogus: 1})

      assert [error] = errors_on(changeset).intake_config
      assert error =~ "bogus"
    end

    test "merges over the stored config so a partial update preserves untouched keys" do
      assert {:ok, _} =
               Settings.update_intake_config(%{
                 unlinked_tier_score: 25,
                 slug_claim_ttl_hours: 48
               })

      # Partial update touching only one key must not reset the other.
      assert {:ok, _} = Settings.update_intake_config(%{unlinked_tier_score: 30})

      config = Settings.get_intake_config()
      assert config.unlinked_tier_score == 30
      # The untouched key keeps its previously-set value, not the default 72.
      assert config.slug_claim_ttl_hours == 48
    end
  end

  describe "get_branding/0" do
    test "returns all-nil defaults when nothing is stored" do
      assert Settings.get_branding() == %{name: nil, logo_url: nil, primary_color: nil}
    end

    test "drops unknown keys and malformed values stored in the column" do
      Settings.get()

      Repo.update_all(Settings,
        set: [
          branding: %{
            "name" => "Acme Support",
            "primary_color" => "not-a-color",
            "surprise" => "x"
          }
        ]
      )

      branding = Settings.get_branding()

      assert branding.name == "Acme Support"
      assert branding.primary_color == nil
      refute Map.has_key?(branding, :surprise)
    end
  end

  describe "update_branding/1" do
    test "round-trips valid values" do
      assert {:ok, _} =
               Settings.update_branding(%{
                 name: "Acme Support",
                 logo_url: "/uploads/logos/acme.png",
                 primary_color: "#1a2b3c"
               })

      branding = Settings.get_branding()

      assert branding.name == "Acme Support"
      assert branding.logo_url == "/uploads/logos/acme.png"
      assert branding.primary_color == "#1a2b3c"
    end

    test "omitted keys clear back to defaults (whole-map replace)" do
      assert {:ok, _} = Settings.update_branding(%{name: "Acme", primary_color: "#112233"})
      assert {:ok, _} = Settings.update_branding(%{name: "Acme"})

      branding = Settings.get_branding()

      assert branding.name == "Acme"
      assert branding.primary_color == nil
    end

    test "rejects unknown keys" do
      assert {:error, changeset} = Settings.update_branding(%{bogus: "x"})

      assert [error] = errors_on(changeset).branding
      assert error =~ "bogus"
    end

    test "rejects logo paths outside /uploads/ and traversal attempts" do
      bad_paths = [
        "/uploads/../secrets",
        "http://evil",
        "//host/x",
        "/uploads/%2E%2e/x",
        "/uploads/a%00.png",
        "/uploads/a\0.png"
      ]

      for bad <- bad_paths do
        assert {:error, changeset} = Settings.update_branding(%{logo_url: bad}),
               "expected #{inspect(bad)} to be rejected"

        assert [error] = errors_on(changeset).branding
        assert error =~ "logo_url"
      end

      assert Settings.get_branding().logo_url == nil
    end

    test "enforces the hex color format" do
      for bad <- ["1a2b3c", "#1a2b3", "#1a2b3cff", "red", "#12345g", "#1a2b3c\n"] do
        assert {:error, _} = Settings.update_branding(%{primary_color: bad}),
               "expected #{inspect(bad)} to be rejected"
      end

      assert {:ok, _} = Settings.update_branding(%{primary_color: "#ABCdef"})
      assert Settings.get_branding().primary_color == "#ABCdef"
    end

    test "enforces the name length bound" do
      assert {:error, _} = Settings.update_branding(%{name: String.duplicate("a", 101)})
      assert {:error, _} = Settings.update_branding(%{name: 42})
      assert {:ok, _} = Settings.update_branding(%{name: String.duplicate("a", 100)})
    end

    test "rejects blank names (consumers fall back to \"Custyard\" only on nil)" do
      assert {:error, _} = Settings.update_branding(%{name: ""})
      assert {:error, _} = Settings.update_branding(%{name: "   "})
      assert {:error, _} = Settings.update_branding(%{name: "\n\t"})

      assert Settings.get_branding().name == nil
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

    test "validates intake config structure" do
      settings = Settings.get()

      changeset =
        Settings.changeset(settings, %{
          intake_config: %{"unlinked_tier_score" => -1}
        })

      refute changeset.valid?
      assert [error] = errors_on(changeset).intake_config
      assert error =~ "unlinked_tier_score"
    end

    test "validates branding structure" do
      settings = Settings.get()

      changeset =
        Settings.changeset(settings, %{
          branding: %{"primary_color" => "blue"}
        })

      refute changeset.valid?
      assert [error] = errors_on(changeset).branding
      assert error =~ "primary_color"
    end
  end
end
