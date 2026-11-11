defmodule Custyard.Boot.StateTest do
  # :persistent_term is global, so these tests are not async.
  use ExUnit.Case, async: false

  alias Custyard.Boot.State

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
  end

  test "defaults to ready with pending first-run steps" do
    assert State.mode() == :ready
    refute State.doctor?()

    assert Enum.map(State.get().first_run.steps, & &1.key) == [
             :schema,
             :instance_admin,
             :mail,
             :sign_in
           ]

    assert Enum.all?(State.get().first_run.steps, &(&1.status == :pending))
  end

  test "update writes through and returns the new state" do
    state = State.update(&%{&1 | mode: :unconfigured})
    assert state.mode == :unconfigured
    assert State.mode() == :unconfigured
    assert State.doctor?()
  end

  test "doctor? is true while starting" do
    State.update(&%{&1 | mode: :starting})
    assert State.doctor?()

    State.update(&%{&1 | mode: :database_unavailable})
    assert State.doctor?()

    State.update(&%{&1 | mode: :first_run})
    refute State.doctor?()
  end

  test "put_step replaces a known step and appends an unknown one" do
    State.put_step(:schema, :ok, "41 migrations")
    State.put_step(:volume, :failed, "not a mount")

    steps = State.get().first_run.steps
    assert %{status: :ok, detail: "41 migrations"} = Enum.find(steps, &(&1.key == :schema))
    assert List.last(steps) == %{key: :volume, status: :failed, detail: "not a mount"}
    assert length(steps) == 5
  end
end
