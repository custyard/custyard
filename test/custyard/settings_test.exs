defmodule Custyard.SettingsTest do
  use Custyard.DataCase, async: true

  alias Custyard.Settings

  setup do
    tenant = Custyard.Factory.insert_tenant()
    Process.put(:settings_tenant_id, tenant.id)
    :ok
  end

  defp tenant_id, do: Process.get(:settings_tenant_id)

  describe "get/0" do
    test "creates defaults when no settings exist" do
      settings = Settings.get(tenant_id())

      assert settings.tenant_id == tenant_id()
      assert is_map(settings.score_weights)
      assert is_map(settings.neglect_thresholds)
    end

    test "returns existing settings on subsequent calls" do
      settings1 = Settings.get(tenant_id())
      settings2 = Settings.get(tenant_id())

      assert settings1.id == settings2.id
    end
  end

  describe "get_weights/0" do
    test "returns default weights when using defaults" do
      weights = Settings.get_weights(tenant_id())

      assert weights.idle == 1.0
      assert weights.state == 1.0
      assert weights.tier == 1.0
      assert weights.urgency == 1.0
      assert weights.velocity == 1.0
      assert weights.neglect == 1.0
    end

    test "skips non-numeric values and uses defaults" do
      # First ensure settings exist
      Settings.get(tenant_id())

      # Directly update with invalid data
      Repo.update_all(Settings, set: [score_weights: %{"idle" => "invalid", "state" => 2.0}])

      weights = Settings.get_weights(tenant_id())

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
      thresholds = Settings.get_neglect_thresholds(tenant_id())

      assert thresholds.enterprise == {4, 8}
      assert thresholds.standard == {24, 48}
      assert thresholds.basic == {48, 72}
    end

    test "skips malformed threshold entries" do
      # First ensure settings exist
      Settings.get(tenant_id())

      # Directly update with invalid data
      Repo.update_all(Settings,
        set: [
          neglect_thresholds: %{
            "enterprise" => "invalid",
            "standard" => [12, 24]
          }
        ]
      )

      thresholds = Settings.get_neglect_thresholds(tenant_id())

      # "invalid" should be skipped, default used
      assert thresholds.enterprise == {4, 8}
      # valid entry preserved
      assert thresholds.standard == {12, 24}
    end
  end

  describe "update_weights/1" do
    test "successfully updates valid weights" do
      _settings = Settings.get(tenant_id())

      new_weights = %{
        idle: 2.0,
        state: 2.0,
        tier: 2.0,
        urgency: 2.0,
        velocity: 2.0,
        neglect: 2.0
      }

      assert {:ok, _} =
               Settings.update_weights(Custyard.Factory.staff_scope(tenant_id()), new_weights)

      weights = Settings.get_weights(tenant_id())
      assert weights.idle == 2.0
    end

    test "rejects negative values" do
      _settings = Settings.get(tenant_id())

      new_weights = %{
        idle: -1.0,
        state: 1.0,
        tier: 1.0,
        urgency: 1.0,
        velocity: 1.0,
        neglect: 1.0
      }

      assert {:error, changeset} =
               Settings.update_weights(Custyard.Factory.staff_scope(tenant_id()), new_weights)

      assert "contains invalid values" <> _ = errors_on(changeset).score_weights |> hd()
    end

    test "rejects values over 1000" do
      _settings = Settings.get(tenant_id())

      new_weights = %{
        idle: 1001.0,
        state: 1.0,
        tier: 1.0,
        urgency: 1.0,
        velocity: 1.0,
        neglect: 1.0
      }

      assert {:error, changeset} =
               Settings.update_weights(Custyard.Factory.staff_scope(tenant_id()), new_weights)

      assert "contains invalid values" <> _ = errors_on(changeset).score_weights |> hd()
    end

    test "rejects missing required keys" do
      _settings = Settings.get(tenant_id())

      # Missing some keys
      new_weights = %{idle: 1.0, state: 1.0}

      assert {:error, changeset} =
               Settings.update_weights(Custyard.Factory.staff_scope(tenant_id()), new_weights)

      assert "must contain all required weight keys" in errors_on(changeset).score_weights
    end
  end

  describe "update_thresholds/1" do
    test "successfully updates valid thresholds" do
      _settings = Settings.get(tenant_id())

      new_thresholds = %{
        enterprise: {2, 4},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:ok, _} =
               Settings.update_thresholds(
                 Custyard.Factory.staff_scope(tenant_id()),
                 new_thresholds
               )

      thresholds = Settings.get_neglect_thresholds(tenant_id())
      assert thresholds.enterprise == {2, 4}
    end

    test "rejects invalid threshold format" do
      _settings = Settings.get(tenant_id())

      # warning must be positive
      new_thresholds = %{
        enterprise: {0, 4},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:error, changeset} =
               Settings.update_thresholds(
                 Custyard.Factory.staff_scope(tenant_id()),
                 new_thresholds
               )

      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end

    test "rejects thresholds where warning >= critical" do
      _settings = Settings.get(tenant_id())

      new_thresholds = %{
        enterprise: {10, 5},
        standard: {12, 24},
        basic: {24, 48}
      }

      assert {:error, changeset} =
               Settings.update_thresholds(
                 Custyard.Factory.staff_scope(tenant_id()),
                 new_thresholds
               )

      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end
  end

  describe "update_sieve_header_mappings/1" do
    test "successfully updates valid mappings" do
      _settings = Settings.get(tenant_id())

      mappings = %{
        "X-Customer-Tier" => %{
          "property" => "tier",
          "mapping" => %{
            "ent" => "enterprise",
            "std" => "standard"
          }
        }
      }

      assert {:ok, _} =
               Settings.update_sieve_header_mappings(
                 Custyard.Factory.staff_scope(tenant_id()),
                 mappings
               )

      result = Settings.get_sieve_header_mappings(tenant_id())
      assert result["X-Customer-Tier"]["property"] == "tier"
    end

    test "rejects invalid property name" do
      _settings = Settings.get(tenant_id())

      mappings = %{
        "X-Header" => %{
          "property" => "invalid_property",
          "mapping" => %{"a" => "b"}
        }
      }

      assert {:error, changeset} =
               Settings.update_sieve_header_mappings(
                 Custyard.Factory.staff_scope(tenant_id()),
                 mappings
               )

      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "rejects missing property key" do
      _settings = Settings.get(tenant_id())

      mappings = %{
        "X-Header" => %{
          "mapping" => %{"a" => "b"}
        }
      }

      assert {:error, changeset} =
               Settings.update_sieve_header_mappings(
                 Custyard.Factory.staff_scope(tenant_id()),
                 mappings
               )

      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "rejects non-string mapping values" do
      _settings = Settings.get(tenant_id())

      mappings = %{
        "X-Header" => %{
          "property" => "tier",
          "mapping" => %{"a" => 123}
        }
      }

      assert {:error, changeset} =
               Settings.update_sieve_header_mappings(
                 Custyard.Factory.staff_scope(tenant_id()),
                 mappings
               )

      assert "invalid format" <> _ = errors_on(changeset).sieve_header_mappings |> hd()
    end

    test "accepts valid properties: tier, urgency, queue" do
      _settings = Settings.get(tenant_id())

      for property <- ["tier", "urgency", "queue"] do
        mappings = %{
          "X-Header" => %{
            "property" => property,
            "mapping" => %{"a" => "b"}
          }
        }

        assert {:ok, _} =
                 Settings.update_sieve_header_mappings(
                   Custyard.Factory.staff_scope(tenant_id()),
                   mappings
                 ),
               "Expected #{property} to be valid"
      end
    end
  end

  describe "get_intake_config/0" do
    test "returns defaults when nothing is stored" do
      config = Settings.get_intake_config(tenant_id())

      assert config.unlinked_tier_score == 10
      assert config.slug_claim_ttl_hours == 72
    end

    test "skips malformed values and uses defaults" do
      # First ensure settings exist
      Settings.get(tenant_id())

      # Directly update with invalid data
      Repo.update_all(Settings,
        set: [intake_config: %{"unlinked_tier_score" => "high", "slug_claim_ttl_hours" => 24}]
      )

      config = Settings.get_intake_config(tenant_id())

      # "high" should be skipped, default 10 used
      assert config.unlinked_tier_score == 10
      # valid entry preserved
      assert config.slug_claim_ttl_hours == 24
    end

    test "skips out-of-range values and unknown keys" do
      Settings.get(tenant_id())

      Repo.update_all(Settings,
        set: [intake_config: %{"unlinked_tier_score" => 500, "surprise" => 1}]
      )

      config = Settings.get_intake_config(tenant_id())

      assert config.unlinked_tier_score == 10
      refute Map.has_key?(config, :surprise)
    end
  end

  describe "update_intake_config/1" do
    test "round-trips valid values" do
      assert {:ok, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 25,
                 slug_claim_ttl_hours: 48
               })

      config = Settings.get_intake_config(tenant_id())
      assert config.unlinked_tier_score == 25
      assert config.slug_claim_ttl_hours == 48
    end

    test "rejects out-of-range unlinked_tier_score" do
      assert {:error, changeset} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 101,
                 slug_claim_ttl_hours: 72
               })

      assert [error] = errors_on(changeset).intake_config
      assert error =~ "unlinked_tier_score"
    end

    test "rejects out-of-range slug_claim_ttl_hours" do
      assert {:error, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 10,
                 slug_claim_ttl_hours: 0
               })

      assert {:error, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 10,
                 slug_claim_ttl_hours: 721
               })
    end

    test "rejects non-integer values" do
      assert {:error, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 10.5,
                 slug_claim_ttl_hours: 72
               })
    end

    test "rejects unknown keys" do
      assert {:error, changeset} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 bogus: 1
               })

      assert [error] = errors_on(changeset).intake_config
      assert error =~ "bogus"
    end

    test "merges over the stored config so a partial update preserves untouched keys" do
      assert {:ok, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 25,
                 slug_claim_ttl_hours: 48
               })

      # Partial update touching only one key must not reset the other.
      assert {:ok, _} =
               Settings.update_intake_config(Custyard.Factory.staff_scope(tenant_id()), %{
                 unlinked_tier_score: 30
               })

      config = Settings.get_intake_config(tenant_id())
      assert config.unlinked_tier_score == 30
      # The untouched key keeps its previously-set value, not the default 72.
      assert config.slug_claim_ttl_hours == 48
    end
  end

  test "branding reads the canonical tenant workspace fields" do
    tenant = Custyard.Tenants.get_tenant!(tenant_id())
    tenant |> Ecto.Changeset.change(name: "Workspace", primary_color: "#123456") |> Repo.update!()
    assert Settings.get_branding(tenant_id()).name == "Workspace"
    assert Settings.get_branding(tenant_id()).primary_color == "#123456"
    refute :branding in Settings.__schema__(:fields)
  end

  describe "changeset/2" do
    test "validates weights structure" do
      settings = Settings.get(tenant_id())

      changeset =
        Settings.changeset(settings, %{
          score_weights: %{"idle" => 1.0}
        })

      refute changeset.valid?
      assert "must contain all required weight keys" in errors_on(changeset).score_weights
    end

    test "validates threshold structure" do
      settings = Settings.get(tenant_id())

      changeset =
        Settings.changeset(settings, %{
          neglect_thresholds: %{"enterprise" => [0, 4]}
        })

      refute changeset.valid?
      assert "invalid threshold format" in errors_on(changeset).neglect_thresholds
    end

    test "validates intake config structure" do
      settings = Settings.get(tenant_id())

      changeset =
        Settings.changeset(settings, %{
          intake_config: %{"unlinked_tier_score" => -1}
        })

      refute changeset.valid?
      assert [error] = errors_on(changeset).intake_config
      assert error =~ "unlinked_tier_score"
    end
  end
end
