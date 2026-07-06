defmodule Custyard.RateLimitTest do
  # Shared named ETS table — must not run concurrently with itself
  use ExUnit.Case, async: false

  alias Custyard.RateLimit

  @table :custyard_rate_limit

  setup do
    RateLimit.reset()
    on_exit(fn -> RateLimit.reset() end)
    :ok
  end

  describe "check_rate/4 window arithmetic" do
    test "allows up to the limit, denies at limit + 1" do
      assert {:allow, 1} = RateLimit.check_rate(:arith, "ip-1", 3, 60_000)
      assert {:allow, 2} = RateLimit.check_rate(:arith, "ip-1", 3, 60_000)
      assert {:allow, 3} = RateLimit.check_rate(:arith, "ip-1", 3, 60_000)

      assert {:deny, retry_after_ms} = RateLimit.check_rate(:arith, "ip-1", 3, 60_000)
      assert retry_after_ms > 0
      assert retry_after_ms <= 60_000
    end

    test "the window slides per event rather than resetting wholesale" do
      # Discriminates sliding from fixed windows: limit 2, window W, with
      # events at t0 and t0+0.6W. At t0+1.1W only t0 has aged out, so the
      # first check must allow and the immediate second must deny. A
      # fixed-window counter that resets on expiry would allow both.
      w = 10_000
      t0 = System.monotonic_time(:millisecond)

      assert {:allow, 1} = RateLimit.check_rate(:slide, "ip-1", 2, w, t0)
      assert {:allow, 2} = RateLimit.check_rate(:slide, "ip-1", 2, w, t0 + 6_000)
      assert {:deny, _} = RateLimit.check_rate(:slide, "ip-1", 2, w, t0 + 7_000)

      assert {:allow, 2} = RateLimit.check_rate(:slide, "ip-1", 2, w, t0 + 11_000)
      assert {:deny, _} = RateLimit.check_rate(:slide, "ip-1", 2, w, t0 + 11_000)
    end

    test "denied events do not extend the deny window" do
      w = 10_000
      t0 = System.monotonic_time(:millisecond)

      assert {:allow, 1} = RateLimit.check_rate(:no_extend, "ip-1", 1, w, t0)
      assert {:deny, _} = RateLimit.check_rate(:no_extend, "ip-1", 1, w, t0 + 5_000)
      assert {:deny, _} = RateLimit.check_rate(:no_extend, "ip-1", 1, w, t0 + 9_000)

      # Only the single allowed event occupied the window; the denies did not
      assert {:allow, 1} = RateLimit.check_rate(:no_extend, "ip-1", 1, w, t0 + 11_000)
    end

    test "a non-positive limit always denies" do
      assert {:deny, 1000} = RateLimit.check_rate(:zero, "ip-1", 0, 1000)
      assert {:deny, 1000} = RateLimit.check_rate(:zero, "ip-1", -1, 1000)
    end
  end

  describe "every-event counting" do
    test "each allowed check increments the count (successes count too)" do
      counts =
        for _ <- 1..5 do
          {:allow, count} = RateLimit.check_rate(:every_event, "ip-1", 10, 60_000)
          count
        end

      assert counts == [1, 2, 3, 4, 5]
    end
  end

  describe "isolation" do
    test "keys are isolated within a bucket" do
      assert {:allow, 1} = RateLimit.check_rate(:keys, "ip-1", 1, 60_000)
      assert {:deny, _} = RateLimit.check_rate(:keys, "ip-1", 1, 60_000)

      assert {:allow, 1} = RateLimit.check_rate(:keys, "ip-2", 1, 60_000)
    end

    test "buckets are isolated for the same key" do
      assert {:allow, 1} = RateLimit.check_rate(:bucket_a, "ip-1", 1, 60_000)
      assert {:deny, _} = RateLimit.check_rate(:bucket_a, "ip-1", 1, 60_000)

      assert {:allow, 1} = RateLimit.check_rate(:bucket_b, "ip-1", 1, 60_000)
    end
  end

  describe "serialization" do
    test "concurrent checks cannot over-admit past the limit" do
      results =
        1..50
        |> Task.async_stream(
          fn _ -> RateLimit.check_rate(:race, "ip-1", 5, 60_000) end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:allow, _}, &1)) == 5
      assert Enum.count(results, &match?({:deny, _}, &1)) == 45
    end
  end

  describe "check_rate/2 config resolution" do
    setup do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(:custyard, :rate_limit_buckets,
        tiny_bucket: [limit: 2, window_ms: 60_000]
      )

      on_exit(fn -> Application.put_env(:custyard, :rate_limit_buckets, original) end)
      :ok
    end

    test "resolves limit and window from app config" do
      assert {:allow, 1} = RateLimit.check_rate(:tiny_bucket, "ip-1")
      assert {:allow, 2} = RateLimit.check_rate(:tiny_bucket, "ip-1")
      assert {:deny, _} = RateLimit.check_rate(:tiny_bucket, "ip-1")
    end

    test "raises for an unconfigured bucket" do
      assert_raise ArgumentError, ~r/unknown rate-limit bucket :nope/, fn ->
        RateLimit.check_rate(:nope, "ip-1")
      end
    end
  end

  describe "peek/3" do
    setup do
      original = Application.get_env(:custyard, :rate_limit_buckets)

      Application.put_env(:custyard, :rate_limit_buckets,
        peek_bucket: [limit: 2, window_ms: 60_000],
        closed_bucket: [limit: 0, window_ms: 1000]
      )

      on_exit(fn -> Application.put_env(:custyard, :rate_limit_buckets, original) end)
      :ok
    end

    test "reports the in-window count without recording an event" do
      # Any number of peeks consumes nothing.
      assert {:allow, 0} = RateLimit.peek(:peek_bucket, "ip-1")
      assert {:allow, 0} = RateLimit.peek(:peek_bucket, "ip-1")

      assert {:allow, 1} = RateLimit.check_rate(:peek_bucket, "ip-1")
      assert {:allow, 1} = RateLimit.peek(:peek_bucket, "ip-1")
      assert {:allow, 2} = RateLimit.check_rate(:peek_bucket, "ip-1")
    end

    test "denies once the counting surface has exhausted the budget" do
      assert {:allow, 1} = RateLimit.check_rate(:peek_bucket, "ip-1")
      assert {:allow, 2} = RateLimit.check_rate(:peek_bucket, "ip-1")

      assert {:deny, retry_after_ms} = RateLimit.peek(:peek_bucket, "ip-1")
      assert retry_after_ms > 0
      assert retry_after_ms <= 60_000

      # Peeking while denied never extends the window either.
      assert {:deny, _} = RateLimit.peek(:peek_bucket, "ip-1")
    end

    test "a non-positive limit always denies" do
      assert {:deny, 1000} = RateLimit.peek(:closed_bucket, "ip-1")
    end

    test "raises for an unconfigured bucket" do
      assert_raise ArgumentError, ~r/unknown rate-limit bucket :nope/, fn ->
        RateLimit.peek(:nope, "ip-1")
      end
    end
  end

  describe "bucket_config!/1" do
    test "returns the configured intake buckets" do
      assert RateLimit.bucket_config!(:intake_get) == {60, 60_000}
      assert RateLimit.bucket_config!(:intake_post) == {5, 3_600_000}
      assert RateLimit.bucket_config!(:resume_mount) == {30, 600_000}
      assert RateLimit.bucket_config!(:resume_reply) == {20, 3_600_000}
      assert RateLimit.bucket_config!(:email_capture) == {5, 3_600_000}
      assert RateLimit.bucket_config!(:claim_submit) == {3, 3_600_000}
      assert RateLimit.bucket_config!(:claim_confirm) == {10, 60_000}
      assert RateLimit.bucket_config!(:claim_email_send) == {5, 86_400_000}
    end
  end

  describe "sweep/1 boundedness" do
    test "removes entries whose window has expired, keeps live ones" do
      # Windows long enough that the periodic sweep cannot race this test
      assert {:allow, 1} = RateLimit.check_rate(:sweep_short, "ip-1", 5, 5_000)
      assert {:allow, 1} = RateLimit.check_rate(:sweep_long, "ip-1", 5, 60_000)
      assert :ets.info(@table, :size) == 2

      now = System.monotonic_time(:millisecond)

      # Nothing has expired yet
      assert RateLimit.sweep(now) == 0
      assert :ets.info(@table, :size) == 2

      # Past the short window: only the short-window entry is reclaimed
      assert RateLimit.sweep(now + 6_000) == 1
      assert :ets.info(@table, :size) == 1

      # Past both windows: table is empty again
      assert RateLimit.sweep(now + 61_000) == 1
      assert :ets.info(@table, :size) == 0
    end
  end

  describe "reset/0" do
    test "clears all rate-limit state" do
      assert {:allow, 1} = RateLimit.check_rate(:reset, "ip-1", 1, 60_000)
      assert {:deny, _} = RateLimit.check_rate(:reset, "ip-1", 1, 60_000)

      assert :ok = RateLimit.reset()

      assert {:allow, 1} = RateLimit.check_rate(:reset, "ip-1", 1, 60_000)
    end
  end

  describe "supervision" do
    test "the limiter GenServer owns the named table" do
      pid = Process.whereis(Custyard.RateLimit)
      assert is_pid(pid)
      assert :ets.info(@table, :owner) == pid
    end
  end
end
