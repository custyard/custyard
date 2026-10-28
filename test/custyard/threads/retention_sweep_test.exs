defmodule Custyard.Threads.RetentionSweepTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Thread, InboundChannelRejection, InboundChannels}
  alias Custyard.Threads.RetentionSweep

  @zero_counts %{
    resolved_threads: 0,
    orphaned_contacts: 0,
    orphaned_tasks: 0,
    channel_rejections: 0,
    channel_verifications: 0,
    channel_tokens: 0,
    attachment_files: 0
  }

  # cleanup_resolved_threads/2 bounds on :updated_at, so ageing a row
  # means backdating that column past the changeset.
  defp aged_thread!(overrides) do
    days = Keyword.fetch!(overrides, :days_old)
    attrs = Keyword.delete(overrides, :days_old)
    thread = insert_thread(attrs)
    stamp = DateTime.add(DateTime.utc_now(), -days * 24, :hour) |> DateTime.truncate(:second)

    thread
    |> Ecto.Changeset.change(updated_at: stamp)
    |> Repo.update!()
  end

  defp hours_ago(hours),
    do: DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

  test "the sweep process is not running in tests (flag off in config/test.exs)" do
    refute Application.get_env(:custyard, :start_intake_sweeps, true)
    refute Process.whereis(RetentionSweep)
  end

  describe "sweep/1" do
    test "deletes resolved threads past the standard bound" do
      org = insert_organization(tier: :standard)

      stale = aged_thread!(organization_id: org.id, state: :resolved, days_old: 120)
      fresh = aged_thread!(organization_id: org.id, state: :resolved, days_old: 30)

      counts = RetentionSweep.sweep()

      assert counts.resolved_threads >= 1
      refute Repo.get(Thread, stale.id)
      assert Repo.get(Thread, fresh.id)
    end

    # Public-intake threads honour the months-later thread path
    # and are held for a year, not 90 days.
    test "holds resolved public-intake threads to the longer bound" do
      held =
        aged_thread!(source: :public_intake, state: :resolved, days_old: 200)

      expired =
        aged_thread!(source: :public_intake, state: :resolved, days_old: 400)

      RetentionSweep.sweep()

      assert Repo.get(Thread, held.id)
      refute Repo.get(Thread, expired.id)
    end

    test "dry_run reports without deleting" do
      org = insert_organization(tier: :standard)
      stale = aged_thread!(organization_id: org.id, state: :resolved, days_old: 120)

      counts = RetentionSweep.sweep(dry_run: true)

      assert counts.resolved_threads >= 1
      assert Repo.get(Thread, stale.id)
    end

    test "unresolved threads are never swept, however old" do
      org = insert_organization(tier: :standard)
      ancient = aged_thread!(organization_id: org.id, state: :active, days_old: 900)

      RetentionSweep.sweep()

      assert Repo.get(Thread, ancient.id)
    end

    test "returns a zeroed count map rather than raising when cleanup fails" do
      # An impossible bound makes run_cleanup/1 raise on the date arithmetic.
      counts = RetentionSweep.sweep(resolved_days: :not_a_number)

      assert counts == @zero_counts
    end

    test "sweeps the inbound channel retention bounds in the same pass" do
      channel = insert_inbound_channel(state: :active)
      route = channel.inbound_route

      {:ok, old_rejection} = InboundChannels.log_rejection(route, :no_channel, %{})
      {:ok, fresh_rejection} = InboundChannels.log_rejection(route, :no_channel, %{})

      old_rejection
      |> Ecto.Changeset.change(inserted_at: hours_ago(15 * 24))
      |> Repo.update!()

      {:ok, channel} = InboundChannels.capture_verification(channel, %{code: "1"})
      {:ok, channel} = InboundChannels.rotate_token(channel, grace_hours: 1)

      channel
      |> Ecto.Changeset.change(
        verification_expires_at: hours_ago(1),
        previous_token_expires_at: hours_ago(1)
      )
      |> Repo.update!()

      counts = RetentionSweep.sweep()

      assert counts.channel_rejections == 1
      assert counts.channel_verifications == 1
      assert counts.channel_tokens == 1
      assert Map.has_key?(counts, :resolved_threads)

      refute Repo.get(InboundChannelRejection, old_rejection.id)
      assert Repo.get(InboundChannelRejection, fresh_rejection.id)

      swept = InboundChannels.get_channel!(channel.id)
      assert is_nil(swept.verification_code)
      assert is_nil(swept.previous_ingress_token)
    end

    test "dry_run leaves channel rows alone and reports zero for them" do
      channel = insert_inbound_channel(state: :active)

      {:ok, old_rejection} =
        InboundChannels.log_rejection(channel.inbound_route, :no_channel, %{})

      old_rejection
      |> Ecto.Changeset.change(inserted_at: hours_ago(15 * 24))
      |> Repo.update!()

      counts = RetentionSweep.sweep(dry_run: true)

      assert counts.channel_rejections == 0
      assert counts.channel_verifications == 0
      assert counts.channel_tokens == 0
      assert Repo.get(InboundChannelRejection, old_rejection.id)
    end
  end
end
