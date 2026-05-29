defmodule Patterns.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Patterns.CircuitBreaker

  describe "closed state" do
    test "passes successful calls through and stays closed" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 3)

      assert {:ok, 42} = CircuitBreaker.call(breaker, fn -> {:ok, 42} end)
      assert CircuitBreaker.state(breaker) == :closed
    end

    test "returns the raw function result" do
      {:ok, breaker} = CircuitBreaker.start_link()

      assert :anything = CircuitBreaker.call(breaker, fn -> :anything end)
    end

    test "resets the failure count after a success" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 3)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      CircuitBreaker.call(breaker, fn -> {:ok, :recovered} end)

      sync(breaker)
      stats = CircuitBreaker.stats(breaker)
      assert stats.failure_count == 0
      assert CircuitBreaker.state(breaker) == :closed
    end
  end

  describe "tripping open" do
    test "opens after reaching the failure threshold" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 2)

      assert {:error, :boom} = CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :closed

      assert {:error, :boom} = CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open
    end

    test "rejects calls immediately when open" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open

      parent = self()

      assert {:error, :circuit_open} =
               CircuitBreaker.call(breaker, fn ->
                 send(parent, :should_not_run)
                 {:ok, :nope}
               end)

      refute_received :should_not_run
    end

    test "counts exceptions as failures" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      assert {:error, {:exception, _}} =
               CircuitBreaker.call(breaker, fn -> raise "kaboom" end)

      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open
    end

    test "counts timeouts as failures" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      assert {:error, :timeout} =
               CircuitBreaker.call(breaker, fn -> Process.sleep(200) end, 50)

      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open
    end
  end

  describe "half-open recovery" do
    test "transitions to half-open after the reset timeout" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1, reset_timeout: 50)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open

      Process.sleep(80)
      assert CircuitBreaker.state(breaker) == :half_open
    end

    test "closes after enough successes in half-open" do
      {:ok, breaker} =
        CircuitBreaker.start_link(
          failure_threshold: 1,
          reset_timeout: 50,
          success_threshold: 2
        )

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      Process.sleep(80)
      assert CircuitBreaker.state(breaker) == :half_open

      CircuitBreaker.call(breaker, fn -> {:ok, 1} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :half_open

      CircuitBreaker.call(breaker, fn -> {:ok, 2} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :closed
    end

    test "re-opens on a failure while half-open" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1, reset_timeout: 50)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      Process.sleep(80)
      assert CircuitBreaker.state(breaker) == :half_open

      CircuitBreaker.call(breaker, fn -> {:error, :again} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open
    end
  end

  describe "manual control" do
    test "trip/1 forces the breaker open" do
      {:ok, breaker} = CircuitBreaker.start_link()

      :ok = CircuitBreaker.trip(breaker)
      assert CircuitBreaker.state(breaker) == :open
      assert {:error, :circuit_open} = CircuitBreaker.call(breaker, fn -> {:ok, :x} end)
    end

    test "reset/1 forces the breaker closed" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open

      :ok = CircuitBreaker.reset(breaker)
      assert CircuitBreaker.state(breaker) == :closed
      assert {:ok, :ok} = CircuitBreaker.call(breaker, fn -> {:ok, :ok} end)
    end
  end

  describe "custom failure predicate" do
    test "treats matching results as failures" do
      predicate = fn
        {:bad, _} -> true
        _ -> false
      end

      {:ok, breaker} =
        CircuitBreaker.start_link(failure_threshold: 1, failure_predicate: predicate)

      assert {:error, :ignored} =
               CircuitBreaker.call(breaker, fn -> {:error, :ignored} end)

      sync(breaker)
      assert CircuitBreaker.state(breaker) == :closed

      assert {:bad, :now} = CircuitBreaker.call(breaker, fn -> {:bad, :now} end)
      sync(breaker)
      assert CircuitBreaker.state(breaker) == :open
    end
  end

  describe "stats" do
    test "tracks call counters" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 5)

      CircuitBreaker.call(breaker, fn -> {:ok, 1} end)
      CircuitBreaker.call(breaker, fn -> {:error, :x} end)
      sync(breaker)

      stats = CircuitBreaker.stats(breaker)
      assert stats.total_calls == 2
      assert stats.total_successes == 1
      assert stats.total_failures == 1
      assert stats.total_rejected == 0
    end

    test "tracks rejected calls while open" do
      {:ok, breaker} = CircuitBreaker.start_link(failure_threshold: 1)

      CircuitBreaker.call(breaker, fn -> {:error, :boom} end)
      sync(breaker)
      CircuitBreaker.call(breaker, fn -> {:ok, :nope} end)

      stats = CircuitBreaker.stats(breaker)
      assert stats.total_rejected == 1
    end
  end

  # The protected call reports its outcome via an async cast. A synchronous
  # call afterwards guarantees that cast has been processed before assertions.
  defp sync(breaker), do: CircuitBreaker.state(breaker)
end
