defmodule Custyard.ThreadTest do
  use Custyard.DataCase, async: true

  alias Custyard.Thread

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with required fields" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id)
      changeset = Thread.changeset(%Thread{}, attrs)

      assert changeset.valid?
    end

    test "requires subject" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id) |> Map.delete(:subject)
      changeset = Thread.changeset(%Thread{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).subject
    end

    test "requires tenant_id" do
      attrs = build_thread() |> Map.delete(:organization_id)
      changeset = Thread.changeset(%Thread{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).tenant_id
    end
  end

  test "all sources can leave customer identity unassigned inside an explicit tenant" do
    tenant = insert_tenant()

    for source <- Thread.sources() do
      attrs = build_thread(source: source, organization_id: nil, tenant_id: tenant.id)
      assert Thread.changeset(%Thread{}, attrs).valid?
    end
  end

  describe "intake_source_key" do
    test "is not castable via the staff-facing changeset/2" do
      attrs = build_thread(organization_id: insert_organization().id)
      changeset = Thread.changeset(%Thread{}, Map.put(attrs, :intake_source_key, "x"))

      assert get_change(changeset, :intake_source_key) == nil
    end

    test "cannot be changed on an existing thread via changeset/2" do
      conv = insert_thread(source: :public_intake, intake_source_key: "original")

      changeset = Thread.changeset(conv, %{intake_source_key: "tampered"})
      {:ok, updated} = Repo.update(changeset)

      assert updated.intake_source_key == "original"
    end

    test "intake_changeset/2 casts and format-validates it" do
      attrs =
        build_thread(
          source: :public_intake,
          organization_id: nil,
          tenant_id: insert_tenant().id
        )
        |> Map.put(:intake_source_key, "landing-page_2")

      changeset = Thread.intake_changeset(%Thread{}, attrs)
      assert changeset.valid?
      assert get_change(changeset, :intake_source_key) == "landing-page_2"
    end

    test "intake_changeset/2 rejects malformed keys" do
      for key <- ["Bad Key", "-lead", String.duplicate("k", 51)] do
        attrs =
          build_thread(
            source: :public_intake,
            organization_id: nil,
            tenant_id: insert_tenant().id
          )
          |> Map.put(:intake_source_key, key)

        changeset = Thread.intake_changeset(%Thread{}, attrs)
        refute changeset.valid?, "expected key #{inspect(key)} to be rejected"
        assert "has invalid format" in errors_on(changeset).intake_source_key
      end
    end
  end

  describe "state enum" do
    test "accepts valid state values" do
      org = insert_organization()

      for state <- [:new, :active, :waiting, :dormant, :resolved] do
        attrs = build_thread(organization_id: org.id, state: state)
        changeset = Thread.changeset(%Thread{}, attrs)

        assert changeset.valid?, "Expected state #{state} to be valid"
      end
    end

    test "rejects invalid state value" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id, state: :closed)
      changeset = Thread.changeset(%Thread{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end

    test "defaults to new state" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id) |> Map.delete(:state)
      {:ok, conv} = %Thread{} |> Thread.changeset(attrs) |> Repo.insert()

      assert conv.state == :new
    end
  end

  describe "urgency enum" do
    test "accepts valid urgency values" do
      org = insert_organization()

      for urgency <- [:normal, :elevated, :urgent] do
        attrs = build_thread(organization_id: org.id, urgency: urgency)
        changeset = Thread.changeset(%Thread{}, attrs)

        assert changeset.valid?, "Expected urgency #{urgency} to be valid"
      end
    end

    test "rejects invalid urgency value" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id, urgency: :critical)
      changeset = Thread.changeset(%Thread{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).urgency
    end

    test "defaults to normal urgency" do
      org = insert_organization()
      attrs = build_thread(organization_id: org.id) |> Map.delete(:urgency)
      {:ok, conv} = %Thread{} |> Thread.changeset(attrs) |> Repo.insert()

      assert conv.urgency == :normal
    end
  end

  describe "state_changeset/2" do
    test "allows transition to valid state" do
      conv = %Thread{state: :new}
      changeset = Thread.state_changeset(conv, :active)

      assert changeset.valid?
      assert get_change(changeset, :state) == :active
    end

    test "validates state transitions according to state machine" do
      # Test valid transitions from each state
      for {from_state, allowed_to_states} <- Thread.valid_transitions() do
        for to_state <- allowed_to_states do
          conv = %Thread{state: from_state}
          changeset = Thread.state_changeset(conv, to_state)

          assert changeset.valid?,
                 "Expected #{from_state} -> #{to_state} to be valid"
        end
      end
    end

    test "rejects invalid state transitions" do
      # :new cannot go to :waiting or :dormant
      conv = %Thread{state: :new}
      changeset = Thread.state_changeset(conv, :waiting)
      refute changeset.valid?
      assert %{state: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "cannot transition"

      # :resolved can only go to :active
      conv = %Thread{state: :resolved}
      changeset = Thread.state_changeset(conv, :waiting)
      refute changeset.valid?
    end

    test "rejects invalid state value" do
      conv = %Thread{state: :new}
      changeset = Thread.state_changeset(conv, :invalid_state)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end

    test "persists state change to database" do
      conv = insert_thread(state: :new)
      changeset = Thread.state_changeset(conv, :active)
      {:ok, updated} = Repo.update(changeset)

      assert updated.state == :active
    end
  end

  describe "snooze_changeset/2" do
    test "sets snoozed_until timestamp" do
      conv = %Thread{}
      until = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      changeset = Thread.snooze_changeset(conv, until)

      assert changeset.valid?
      assert get_change(changeset, :snoozed_until) == until
    end

    test "clears snooze with nil" do
      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      conv = insert_thread(snoozed_until: until)
      changeset = Thread.snooze_changeset(conv, nil)
      {:ok, updated} = Repo.update(changeset)

      assert updated.snoozed_until == nil
    end
  end

  describe "helper functions" do
    test "states/0 returns all valid states" do
      assert Thread.states() == [:new, :active, :waiting, :dormant, :resolved]
    end

    test "urgencies/0 returns all valid urgencies" do
      assert Thread.urgencies() == [:normal, :elevated, :urgent]
    end
  end
end
