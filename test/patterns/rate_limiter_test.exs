defmodule Patterns.RateLimiterTest do
  use ExUnit.Case, async: true

  alias Patterns.RateLimiter

  describe "global bucket" do
    test "allows requests while tokens remain" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 3, refill_rate: 0)

      assert {:ok, 2} = RateLimiter.allow(limiter)
      assert {:ok, 1} = RateLimiter.allow(limiter)
      assert {:ok, 0} = RateLimiter.allow(limiter)
    end

    test "rejects when the bucket is empty" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 0)

      assert {:ok, 0} = RateLimiter.allow(limiter)
      assert {:error, :rate_limited, retry_after_ms} = RateLimiter.allow(limiter)
      assert retry_after_ms >= 1
    end

    test "supports multi-token costs" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 5, refill_rate: 0)

      assert {:ok, 2} = RateLimiter.consume(limiter, 3)
      assert {:ok, 0} = RateLimiter.consume(limiter, 2)
      assert {:error, :rate_limited, _} = RateLimiter.consume(limiter, 1)
    end

    test "refills tokens over time" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 10)

      assert {:ok, 0} = RateLimiter.allow(limiter)
      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter)

      Process.sleep(150)

      assert {:ok, 0} = RateLimiter.allow(limiter)
    end

    test "reset restores full capacity" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 2, refill_rate: 0)

      assert {:ok, 1} = RateLimiter.allow(limiter)
      assert {:ok, 0} = RateLimiter.allow(limiter)
      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter)

      :ok = RateLimiter.reset(limiter)

      assert {:ok, 1} = RateLimiter.allow(limiter)
    end

    test "tracks stats" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 0)

      assert {:ok, 0} = RateLimiter.allow(limiter)
      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter)

      stats = RateLimiter.stats(limiter)

      assert stats.total_allowed == 1
      assert stats.total_rejected == 1
      assert stats.capacity == 1
      assert stats.tokens == 0.0
      assert stats.keys == nil
    end

    test "rejects keys in global mode" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 0)

      assert {:error, :key_not_allowed} = RateLimiter.allow(limiter, "user:1")
    end
  end

  describe "per-key buckets" do
    test "limits each key independently" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 0, per_key: true)

      assert {:ok, 0} = RateLimiter.allow(limiter, "user:a")
      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter, "user:a")
      assert {:ok, 0} = RateLimiter.allow(limiter, "user:b")
    end

    test "requires a key" do
      {:ok, limiter} = RateLimiter.start_link(per_key: true)

      assert {:error, :key_required} = RateLimiter.allow(limiter)
    end

    test "reset clears a single key" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 1, refill_rate: 0, per_key: true)

      assert {:ok, 0} = RateLimiter.allow(limiter, "user:a")
      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter, "user:a")

      :ok = RateLimiter.reset(limiter, "user:a")

      assert {:ok, 0} = RateLimiter.allow(limiter, "user:a")
    end

    test "tracks key count in stats" do
      {:ok, limiter} = RateLimiter.start_link(per_key: true)

      assert {:ok, _} = RateLimiter.allow(limiter, "user:a")
      assert {:ok, _} = RateLimiter.allow(limiter, "user:b")

      assert RateLimiter.stats(limiter).keys == 2
    end
  end

  describe "concurrency" do
    test "serializes concurrent consumers" do
      {:ok, limiter} = RateLimiter.start_link(capacity: 5, refill_rate: 0)

      tasks =
        for _ <- 1..5 do
          Task.async(fn -> RateLimiter.allow(limiter) end)
        end

      results = Task.await_many(tasks, 1000)
      assert Enum.count(results, &match?({:ok, _}, &1)) == 5

      assert {:error, :rate_limited, _} = RateLimiter.allow(limiter)
    end
  end
end
