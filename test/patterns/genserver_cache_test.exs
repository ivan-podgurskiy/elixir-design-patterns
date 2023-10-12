defmodule Patterns.GenServerCacheTest do
  use ExUnit.Case, async: true
  alias Patterns.GenServerCache

  setup do
    {:ok, pid} = GenServerCache.start_link()
    {:ok, cache: pid}
  end

  describe "basic cache operations" do
    test "stores and retrieves values", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      assert {:ok, "value1"} = GenServerCache.get(cache, "key1")
    end

    test "returns error for missing keys", %{cache: cache} do
      assert :error = GenServerCache.get(cache, "nonexistent")
    end

    test "overwrites existing keys", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      :ok = GenServerCache.put(cache, "key1", "value2")
      assert {:ok, "value2"} = GenServerCache.get(cache, "key1")
    end

    test "deletes keys", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      :ok = GenServerCache.delete(cache, "key1")
      assert :error = GenServerCache.get(cache, "key1")
    end

    test "clears all keys", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      :ok = GenServerCache.put(cache, "key2", "value2")
      :ok = GenServerCache.clear(cache)
      assert :error = GenServerCache.get(cache, "key1")
      assert :error = GenServerCache.get(cache, "key2")
    end
  end

  describe "TTL expiration" do
    test "expires keys after TTL", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1", 50)
      assert {:ok, "value1"} = GenServerCache.get(cache, "key1")

      Process.sleep(60)
      assert :error = GenServerCache.get(cache, "key1")
    end

    test "keeps keys without TTL indefinitely", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      Process.sleep(10)
      assert {:ok, "value1"} = GenServerCache.get(cache, "key1")
    end

    test "accessing expired key removes it from cache", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1", 10)
      Process.sleep(15)

      keys_before = GenServerCache.keys(cache)
      assert "key1" in keys_before

      assert :error = GenServerCache.get(cache, "key1")

      keys_after = GenServerCache.keys(cache)
      refute "key1" in keys_after
    end
  end

  describe "statistics" do
    test "tracks hits and misses", %{cache: cache} do
      initial_stats = GenServerCache.stats(cache)
      assert %{hits: 0, misses: 0, total_keys: 0} = initial_stats

      :ok = GenServerCache.put(cache, "key1", "value1")
      stats_after_put = GenServerCache.stats(cache)
      assert %{hits: 0, misses: 0, total_keys: 1} = stats_after_put

      {:ok, _} = GenServerCache.get(cache, "key1")
      stats_after_hit = GenServerCache.stats(cache)
      assert %{hits: 1, misses: 0, total_keys: 1} = stats_after_hit

      :error = GenServerCache.get(cache, "nonexistent")
      stats_after_miss = GenServerCache.stats(cache)
      assert %{hits: 1, misses: 1, total_keys: 1} = stats_after_miss
    end

    test "updates total_keys correctly on operations", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1")
      :ok = GenServerCache.put(cache, "key2", "value2")
      assert %{total_keys: 2} = GenServerCache.stats(cache)

      :ok = GenServerCache.delete(cache, "key1")
      assert %{total_keys: 1} = GenServerCache.stats(cache)

      :ok = GenServerCache.clear(cache)
      assert %{total_keys: 0} = GenServerCache.stats(cache)
    end

    test "counts expired key access as miss and decreases total_keys", %{cache: cache} do
      :ok = GenServerCache.put(cache, "key1", "value1", 10)
      assert %{total_keys: 1} = GenServerCache.stats(cache)

      Process.sleep(15)
      :error = GenServerCache.get(cache, "key1")

      stats = GenServerCache.stats(cache)
      assert %{hits: 0, misses: 1, total_keys: 0} = stats
    end
  end

  describe "automatic cleanup" do
    test "cleans up expired entries automatically", %{cache: _cache} do
      # Use a very short cleanup interval for testing
      {:ok, cache} = GenServerCache.start_link(cleanup_interval: 50)

      :ok = GenServerCache.put(cache, "key1", "value1", 10)
      # no TTL
      :ok = GenServerCache.put(cache, "key2", "value2")

      assert %{total_keys: 2} = GenServerCache.stats(cache)

      # Wait for expiration and cleanup
      Process.sleep(100)

      # After cleanup, only the non-expiring key should remain
      stats = GenServerCache.stats(cache)
      assert %{total_keys: 1} = stats

      assert {:ok, "value2"} = GenServerCache.get(cache, "key2")
      assert :error = GenServerCache.get(cache, "key1")
    end
  end

  describe "keys inspection" do
    test "returns all cache keys", %{cache: cache} do
      assert [] = GenServerCache.keys(cache)

      :ok = GenServerCache.put(cache, "key1", "value1")
      :ok = GenServerCache.put(cache, :atom_key, "value2")

      keys = GenServerCache.keys(cache)
      assert length(keys) == 2
      assert "key1" in keys
      assert :atom_key in keys
    end
  end

  describe "concurrent access" do
    test "handles concurrent reads and writes safely", %{cache: cache} do
      # Start multiple tasks that write to the cache
      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            :ok = GenServerCache.put(cache, "key#{i}", "value#{i}")
            {:ok, _} = GenServerCache.get(cache, "key#{i}")
          end)
        end

      # Wait for all tasks to complete
      Enum.each(tasks, &Task.await/1)

      # Verify all keys are present
      stats = GenServerCache.stats(cache)
      assert %{hits: 10, misses: 0, total_keys: 10} = stats
    end
  end

  describe "data types" do
    test "handles various data types as keys and values", %{cache: cache} do
      test_cases = [
        {"string_key", %{map: "value"}},
        {:atom_key, [1, 2, 3]},
        {123, {:tuple, :value}},
        {{:compound, :key}, "string_value"}
      ]

      for {key, value} <- test_cases do
        :ok = GenServerCache.put(cache, key, value)
        assert {:ok, ^value} = GenServerCache.get(cache, key)
      end
    end
  end
end
