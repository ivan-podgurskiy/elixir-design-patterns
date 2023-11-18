defmodule Patterns.AgentStateTest do
  use ExUnit.Case, async: true
  alias Patterns.AgentState.{ConfigStore, Counter, Statistics}

  describe "Counter" do
    test "starts with initial value" do
      {:ok, counter} = Counter.start_link(10)
      assert Counter.get(counter) == 10
    end

    test "starts with zero by default" do
      {:ok, counter} = Counter.start_link()
      assert Counter.get(counter) == 0
    end

    test "increments and returns new value" do
      {:ok, counter} = Counter.start_link(5)
      assert Counter.increment(counter) == 6
      assert Counter.increment(counter) == 7
      assert Counter.get(counter) == 7
    end

    test "decrements and returns new value" do
      {:ok, counter} = Counter.start_link(10)
      assert Counter.decrement(counter) == 9
      assert Counter.decrement(counter) == 8
      assert Counter.get(counter) == 8
    end

    test "adds specific amounts" do
      {:ok, counter} = Counter.start_link(10)
      assert Counter.add(counter, 5) == 15
      assert Counter.add(counter, -3) == 12
      assert Counter.get(counter) == 12
    end

    test "resets to zero and returns previous value" do
      {:ok, counter} = Counter.start_link(42)
      assert Counter.reset(counter) == 42
      assert Counter.get(counter) == 0
    end

    test "sets to specific value and returns previous value" do
      {:ok, counter} = Counter.start_link(10)
      assert Counter.set(counter, 100) == 10
      assert Counter.get(counter) == 100
    end

    test "handles concurrent access safely" do
      {:ok, counter} = Counter.start_link(0)

      # Start multiple processes incrementing the counter
      tasks =
        for _i <- 1..100 do
          Task.async(fn -> Counter.increment(counter) end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Counter should be exactly 100 despite concurrent access
      assert Counter.get(counter) == 100
    end
  end

  describe "ConfigStore" do
    test "starts with empty configuration" do
      {:ok, store} = ConfigStore.start_link()
      assert ConfigStore.get_all(store) == %{}
    end

    test "starts with initial configuration" do
      initial = %{database_url: "localhost", timeout: 5000}
      {:ok, store} = ConfigStore.start_link(initial)
      assert ConfigStore.get_all(store) == initial
    end

    test "gets and puts configuration values" do
      {:ok, store} = ConfigStore.start_link()

      # Get non-existent key
      assert ConfigStore.get(store, :missing) == nil
      assert ConfigStore.get(store, :missing, :default) == :default

      # Put a value
      assert ConfigStore.put(store, :api_key, "secret123") == nil
      assert ConfigStore.get(store, :api_key) == "secret123"

      # Update existing value
      assert ConfigStore.put(store, :api_key, "newsecret") == "secret123"
      assert ConfigStore.get(store, :api_key) == "newsecret"
    end

    test "deletes configuration keys" do
      {:ok, store} = ConfigStore.start_link(%{keep: "this", remove: "that"})

      assert ConfigStore.delete(store, :remove) == "that"
      assert ConfigStore.get(store, :remove) == nil
      assert ConfigStore.get(store, :keep) == "this"

      # Delete non-existent key
      assert ConfigStore.delete(store, :missing) == nil
    end

    test "merges configuration" do
      {:ok, store} = ConfigStore.start_link(%{a: 1, b: 2})

      old_config = ConfigStore.merge(store, %{b: 22, c: 3})
      assert old_config == %{a: 1, b: 2}

      new_config = ConfigStore.get_all(store)
      assert new_config == %{a: 1, b: 22, c: 3}
    end

    test "replaces entire configuration" do
      {:ok, store} = ConfigStore.start_link(%{old: "config"})

      old_config = ConfigStore.put_all(store, %{new: "config"})
      assert old_config == %{old: "config"}
      assert ConfigStore.get_all(store) == %{new: "config"}
    end

    test "provides introspection methods" do
      config = %{database_url: "localhost", timeout: 5000, debug: true}
      {:ok, store} = ConfigStore.start_link(config)

      keys = ConfigStore.keys(store)
      assert length(keys) == 3
      assert :database_url in keys
      assert :timeout in keys
      assert :debug in keys
      assert ConfigStore.size(store) == 3
      assert ConfigStore.has_key?(store, :timeout) == true
      assert ConfigStore.has_key?(store, :missing) == false
    end

    test "handles different data types" do
      {:ok, store} = ConfigStore.start_link()

      test_data = [
        {:string_key, "string value"},
        {:atom_key, :atom_value},
        {:number_key, 42},
        {:list_key, [1, 2, 3]},
        {:map_key, %{nested: "value"}},
        {:tuple_key, {:ok, "result"}}
      ]

      for {key, value} <- test_data do
        ConfigStore.put(store, key, value)
        assert ConfigStore.get(store, key) == value
      end
    end
  end

  describe "Statistics" do
    test "starts with empty statistics" do
      {:ok, stats} = Statistics.start_link()
      assert Statistics.get_all(stats) == %{}
    end

    test "increments metrics" do
      {:ok, stats} = Statistics.start_link()

      Statistics.increment(stats, :page_views)
      assert Statistics.get(stats, :page_views) == 1

      Statistics.increment(stats, :page_views)
      Statistics.increment(stats, :page_views)
      assert Statistics.get(stats, :page_views) == 3
    end

    test "adds specific amounts to metrics" do
      {:ok, stats} = Statistics.start_link()

      Statistics.add(stats, :bytes_sent, 1024)
      assert Statistics.get(stats, :bytes_sent) == 1024

      Statistics.add(stats, :bytes_sent, 512)
      assert Statistics.get(stats, :bytes_sent) == 1536
    end

    test "sets metrics to specific values" do
      {:ok, stats} = Statistics.start_link()

      Statistics.set(stats, :current_connections, 42)
      assert Statistics.get(stats, :current_connections) == 42

      Statistics.set(stats, :current_connections, 100)
      assert Statistics.get(stats, :current_connections) == 100
    end

    test "gets non-existent metrics" do
      {:ok, stats} = Statistics.start_link()
      assert Statistics.get(stats, :missing) == nil
    end

    test "resets all statistics" do
      {:ok, stats} = Statistics.start_link()

      Statistics.increment(stats, :errors)
      Statistics.set(stats, :users, 42)

      old_stats = Statistics.reset(stats)
      assert old_stats == %{errors: 1, users: 42}
      assert Statistics.get_all(stats) == %{}
    end

    test "resets specific metrics" do
      {:ok, stats} = Statistics.start_link()

      Statistics.set(stats, :keep, 1)
      Statistics.set(stats, :reset, 2)

      old_value = Statistics.reset(stats, :reset)
      assert old_value == 2
      assert Statistics.get(stats, :reset) == nil
      assert Statistics.get(stats, :keep) == 1
    end

    test "measures timing" do
      {:ok, stats} = Statistics.start_link()

      result =
        Statistics.time(stats, :database_query, fn ->
          # Simulate some work
          Process.sleep(10)
          "query result"
        end)

      assert result == "query result"

      # Check that timing metrics were recorded
      total_ms = Statistics.get(stats, :database_query_total_ms)
      count = Statistics.get(stats, :database_query_count)

      assert is_number(total_ms) and total_ms >= 10
      assert count == 1

      # Time another operation
      Statistics.time(stats, :database_query, fn ->
        Process.sleep(5)
        "another result"
      end)

      assert Statistics.get(stats, :database_query_count) == 2
      new_total = Statistics.get(stats, :database_query_total_ms)
      assert new_total > total_ms
    end

    test "calculates average timing" do
      {:ok, stats} = Statistics.start_link()

      # No data yet
      assert Statistics.average_time(stats, :api_call) == nil

      # Record some timings
      Statistics.time(stats, :api_call, fn -> Process.sleep(10) end)
      Statistics.time(stats, :api_call, fn -> Process.sleep(20) end)

      average = Statistics.average_time(stats, :api_call)
      assert is_float(average)
      # Should be around 15ms average
      assert average >= 15.0

      # Verify it's actually averaging
      Statistics.time(stats, :api_call, fn -> Process.sleep(0) end)
      new_average = Statistics.average_time(stats, :api_call)
      # Average should decrease
      assert new_average < average
    end

    test "handles concurrent statistics updates" do
      {:ok, stats} = Statistics.start_link()

      # Start multiple processes updating statistics
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            Statistics.increment(stats, :concurrent_ops)
            Statistics.add(stats, :total_work, i)
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Verify final counts
      assert Statistics.get(stats, :concurrent_ops) == 50
      # Sum of 1..50 is 1275
      assert Statistics.get(stats, :total_work) == 1275
    end
  end

  describe "integration scenarios" do
    test "using agents together for application state" do
      # Simulate a web application using all three agent types
      {:ok, request_counter} = Counter.start_link(0)
      {:ok, config} = ConfigStore.start_link(%{max_requests: 1000})
      {:ok, stats} = Statistics.start_link()

      # Simulate handling requests
      for i <- 1..10 do
        # Increment request counter
        count = Counter.increment(request_counter)

        # Record statistics
        Statistics.increment(stats, :requests_handled)

        # Check if we're approaching the limit
        max_requests = ConfigStore.get(config, :max_requests, 500)

        if count >= max_requests - 100 do
          Statistics.increment(stats, :approaching_limit_warnings)
        end

        # Simulate some processing time
        Statistics.time(stats, :request_processing, fn ->
          Process.sleep(1)
          "processed request #{i}"
        end)
      end

      # Verify the final state
      assert Counter.get(request_counter) == 10
      assert Statistics.get(stats, :requests_handled) == 10
      assert Statistics.get(stats, :approaching_limit_warnings) == nil
      assert Statistics.get(stats, :request_processing_count) == 10

      average_processing = Statistics.average_time(stats, :request_processing)
      assert is_float(average_processing) and average_processing >= 1.0
    end

    test "configuration hot-reloading scenario" do
      {:ok, config} =
        ConfigStore.start_link(%{
          database_pool_size: 10,
          api_timeout: 5000,
          debug_mode: false
        })

      # Initial configuration
      assert ConfigStore.get(config, :database_pool_size) == 10

      # Hot reload - update configuration at runtime
      ConfigStore.merge(config, %{
        database_pool_size: 20,
        new_feature_enabled: true
      })

      # Verify changes
      assert ConfigStore.get(config, :database_pool_size) == 20
      # Unchanged
      assert ConfigStore.get(config, :api_timeout) == 5000
      assert ConfigStore.get(config, :new_feature_enabled) == true

      # Feature flag check
      if ConfigStore.get(config, :new_feature_enabled, false) do
        ConfigStore.put(config, :feature_usage_count, 1)
      end

      assert ConfigStore.get(config, :feature_usage_count) == 1
    end
  end
end
