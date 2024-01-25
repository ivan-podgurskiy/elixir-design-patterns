defmodule Patterns.TaskAsyncTest do
  use ExUnit.Case, async: true
  alias Patterns.TaskAsync

  describe "parallel_fetch/2" do
    test "fetches multiple URLs in parallel" do
      urls = [
        "http://httpbin.org/delay/1",
        "http://httpbin.org/delay/2",
        "http://example.com"
      ]

      {:ok, results} = TaskAsync.parallel_fetch(urls, timeout: 10_000)

      assert length(results) == 3

      # Results should be in the same order as input URLs
      Enum.with_index(results)
      |> Enum.each(fn {result, index} ->
        case result do
          {:ok, response} ->
            assert response.url == Enum.at(urls, index)
            assert response.status == 200

          {:error, _reason} ->
            # Some URLs might fail, which is acceptable
            :ok
        end
      end)
    end

    test "handles individual URL failures gracefully" do
      urls = [
        "http://example.com",
        # This will likely timeout with short http_timeout
        "http://httpbin.org/delay/10"
      ]

      {:ok, results} = TaskAsync.parallel_fetch(urls, timeout: 5000, http_timeout: 500)

      assert length(results) == 2

      # First URL should succeed, second should fail due to timeout
      [first_result, second_result] = results

      case first_result do
        {:ok, _} -> :ok
        # Network issues are acceptable in tests
        {:error, _} -> :ok
      end

      assert {:error, :timeout} = second_result
    end

    test "returns timeout error when overall operation times out" do
      urls = ["http://httpbin.org/delay/1", "http://httpbin.org/delay/2"]

      # Very short timeout
      result = TaskAsync.parallel_fetch(urls, timeout: 50)

      assert {:error, :timeout} = result
    end
  end

  describe "parallel_map/3" do
    test "processes items concurrently" do
      items = [1, 2, 3, 4, 5]

      processor = fn x ->
        Process.sleep(10)
        x * 2
      end

      start_time = System.monotonic_time(:millisecond)
      results = TaskAsync.parallel_map(items, processor, timeout: 1000)
      end_time = System.monotonic_time(:millisecond)

      # Results should contain doubled values
      expected_results = [2, 4, 6, 8, 10]
      assert Enum.sort(results) == expected_results

      # Should be faster than sequential processing
      duration = end_time - start_time
      # Should be much faster than 5 * 10ms = 50ms + overhead
      assert duration < 100
    end

    test "respects max_concurrency setting" do
      items = 1..10 |> Enum.to_list()

      processor = fn x ->
        Process.sleep(50)
        x
      end

      # With max_concurrency of 2, should process in batches
      start_time = System.monotonic_time(:millisecond)
      results = TaskAsync.parallel_map(items, processor, max_concurrency: 2, timeout: 5000)
      end_time = System.monotonic_time(:millisecond)

      assert Enum.sort(results) == items

      # Should take roughly (10 items / 2 concurrent) * 50ms = ~250ms
      duration = end_time - start_time
      # Should take at least several batches worth of time
      assert duration >= 200
    end
  end

  describe "race/2" do
    test "returns result of fastest task" do
      functions = [
        fn -> Process.sleep(100) && :slow end,
        fn -> Process.sleep(10) && :fast end,
        fn -> Process.sleep(200) && :very_slow end
      ]

      {:ok, result} = TaskAsync.race(functions, 1000)
      assert result == :fast
    end

    test "returns error from fastest failing task" do
      functions = [
        fn -> Process.sleep(100) && :slow end,
        fn -> Process.sleep(10) && raise("fast error") end,
        fn -> Process.sleep(200) && :very_slow end
      ]

      {:error, %RuntimeError{message: "fast error"}} = TaskAsync.race(functions, 1000)
    end

    test "returns timeout when all tasks are too slow" do
      functions = [
        fn -> Process.sleep(100) && :result1 end,
        fn -> Process.sleep(200) && :result2 end
      ]

      {:timeout, :race_timeout} = TaskAsync.race(functions, 50)
    end
  end

  describe "with_fallback/2" do
    test "returns successful results and fallbacks for timeouts" do
      functions = [
        fn -> Process.sleep(10) && :success end,
        # Will timeout with short timeout
        fn -> Process.sleep(200) && :timeout end,
        fn -> raise("error") end
      ]

      results =
        TaskAsync.with_fallback(functions,
          timeout: 50,
          fallback: :fallback_value
        )

      assert [
               {:ok, :success},
               {:timeout, :fallback_value},
               {:error, %RuntimeError{message: "error"}}
             ] = results
    end

    test "uses nil as default fallback" do
      functions = [
        fn -> Process.sleep(100) && :slow end
      ]

      results = TaskAsync.with_fallback(functions, timeout: 50)

      assert [{:timeout, nil}] = results
    end
  end

  describe "retry/2" do
    test "succeeds on first attempt when function succeeds" do
      function = fn -> :success end

      {:ok, :success} = TaskAsync.retry(function)
    end

    test "retries failing function up to max attempts" do
      # Function that fails twice then succeeds
      agent_start = fn ->
        {:ok, agent} = Agent.start_link(fn -> 0 end)
        agent
      end

      counter = agent_start.()

      function = fn ->
        count = Agent.get_and_update(counter, fn x -> {x + 1, x + 1} end)

        if count < 3 do
          raise "Attempt #{count} failed"
        else
          "Success on attempt #{count}"
        end
      end

      {:ok, result} = TaskAsync.retry(function, max_attempts: 5)
      assert result == "Success on attempt 3"
    end

    test "returns error after max attempts exceeded" do
      function = fn -> raise("Always fails") end

      {:error, %RuntimeError{message: "Always fails"}} =
        TaskAsync.retry(function, max_attempts: 2)
    end

    test "respects backoff delay configuration" do
      function = fn -> raise("Always fails") end

      start_time = System.monotonic_time(:millisecond)

      TaskAsync.retry(function,
        max_attempts: 3,
        base_delay: 50,
        jitter: false
      )

      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      # Should have delays: 50ms (after 1st failure) + 100ms (after 2nd failure)
      # At least 150ms of delays plus execution time
      assert duration >= 140
    end
  end

  describe "pipeline/2" do
    test "executes functions in sequence passing results through" do
      functions = [
        fn -> 5 end,
        fn x -> x * 2 end,
        fn x -> x + 1 end,
        fn x -> "Result: #{x}" end
      ]

      {:ok, result} = TaskAsync.pipeline(functions)
      # ((5 * 2) + 1) = 11
      assert result == "Result: 11"
    end

    test "stops pipeline on first error" do
      functions = [
        fn -> 5 end,
        fn _x -> raise("Pipeline error") end,
        # This should not execute
        fn x -> x + 1 end
      ]

      {:error, %RuntimeError{message: "Pipeline error"}} = TaskAsync.pipeline(functions)
    end

    test "respects timeout" do
      functions = [
        fn -> Process.sleep(100) && 1 end,
        fn x -> Process.sleep(100) && x + 1 end
      ]

      {:timeout, :pipeline_timeout} = TaskAsync.pipeline(functions, timeout: 50)
    end
  end

  describe "Utils.batch_process/3" do
    test "processes items in batches concurrently" do
      items = 1..25 |> Enum.to_list()

      processor = fn x ->
        Process.sleep(10)
        x * 2
      end

      start_time = System.monotonic_time(:millisecond)

      results =
        TaskAsync.Utils.batch_process(items, processor,
          batch_size: 5,
          timeout: 5000
        )

      end_time = System.monotonic_time(:millisecond)

      # Should get all items doubled
      expected = Enum.map(items, &(&1 * 2))
      assert Enum.sort(results) == expected

      # Should be faster than sequential (25 * 10ms = 250ms)
      duration = end_time - start_time
      # Much faster due to batching and concurrency
      assert duration < 200
    end
  end

  describe "Utils.multi_source_fetch/1" do
    test "fetches from multiple sources concurrently" do
      start_time = System.monotonic_time(:millisecond)
      results = TaskAsync.Utils.multi_source_fetch(timeout: 1000)
      end_time = System.monotonic_time(:millisecond)

      # Should get results from all sources
      assert Map.has_key?(results, :database)
      assert Map.has_key?(results, :cache)
      assert Map.has_key?(results, :api)

      # All should succeed
      assert {:ok, "db_data"} = results[:database]
      assert {:ok, "cache_data"} = results[:cache]
      assert {:ok, "api_data"} = results[:api]

      # Should be concurrent (not sum of all delays)
      duration = end_time - start_time
      # Much less than 100 + 10 + 200 = 310ms
      assert duration < 300
    end

    test "handles timeouts gracefully" do
      results = TaskAsync.Utils.multi_source_fetch(timeout: 50)

      # Cache should succeed (fastest), others should timeout
      assert {:ok, "cache_data"} = results[:cache]
      assert {:error, :timeout} = results[:database]
      assert {:error, :timeout} = results[:api]
    end
  end

  describe "integration scenarios" do
    test "complex async workflow" do
      # Simulate a complex workflow with multiple async operations

      # Step 1: Fetch configuration
      config_task =
        Task.async(fn ->
          Process.sleep(50)
          %{batch_size: 3, timeout: 1000}
        end)

      # Step 2: Fetch initial data
      data_task =
        Task.async(fn ->
          Process.sleep(30)
          1..10 |> Enum.to_list()
        end)

      # Step 3: Get config and data
      config = Task.await(config_task)
      data = Task.await(data_task)

      # Step 4: Process data in batches using the config
      results =
        TaskAsync.Utils.batch_process(
          data,
          # Square each number
          fn x -> x * x end,
          batch_size: config.batch_size,
          timeout: config.timeout
        )

      expected = Enum.map(1..10, &(&1 * &1))
      assert Enum.sort(results) == expected
    end

    test "error handling across multiple patterns" do
      # Mix successful and failing operations

      # Some succeed
      success_tasks = [
        fn -> :result1 end,
        fn -> :result2 end
      ]

      # Some fail
      failing_tasks = [
        fn -> raise("error1") end,
        fn -> raise("error2") end
      ]

      # Test with_fallback handles mix of success and failure
      mixed_results =
        TaskAsync.with_fallback(
          success_tasks ++ failing_tasks,
          timeout: 1000,
          fallback: :default
        )

      assert [
               {:ok, :result1},
               {:ok, :result2},
               {:error, %RuntimeError{message: "error1"}},
               {:error, %RuntimeError{message: "error2"}}
             ] = mixed_results

      # Test race picks fastest (even if others fail)
      race_result =
        TaskAsync.race([
          fn -> Process.sleep(100) && raise("slow error") end,
          fn -> Process.sleep(10) && :fast_success end
        ])

      assert {:ok, :fast_success} = race_result
    end
  end

  describe "performance characteristics" do
    test "parallel execution is actually parallel" do
      # Test that parallel operations are indeed concurrent

      sequential_time =
        measure_time(fn ->
          for _i <- 1..5 do
            Process.sleep(20)
          end
        end)

      parallel_time =
        measure_time(fn ->
          TaskAsync.parallel_map(1..5, fn _x ->
            Process.sleep(20)
            :done
          end)
        end)

      # Parallel should be significantly faster
      ratio = sequential_time / parallel_time
      # At least 3x faster
      assert ratio >= 3.0
    end

    @tag :capture_log
    test "task cancellation works in race conditions" do
      # Verify that losing tasks in a race are properly cancelled

      start_count = Process.list() |> length()

      TaskAsync.race([
        fn -> Process.sleep(10) && :winner end,
        fn -> Process.sleep(1000) && :loser1 end,
        fn -> Process.sleep(2000) && :loser2 end
      ])

      # Give time for cleanup
      Process.sleep(50)

      end_count = Process.list() |> length()

      # Process count should not have grown significantly
      # (allowing some margin for test infrastructure)
      assert end_count - start_count <= 5
    end
  end

  # Helper function to measure execution time
  defp measure_time(fun) do
    start_time = System.monotonic_time(:millisecond)
    fun.()
    end_time = System.monotonic_time(:millisecond)
    end_time - start_time
  end
end
