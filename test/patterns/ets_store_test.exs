defmodule Patterns.EtsStoreTest do
  use ExUnit.Case, async: true

  doctest Patterns.EtsStore

  alias Patterns.EtsStore

  setup do
    {:ok, pid} = EtsStore.start_link([])
    %{store: pid}
  end

  describe "set table (default)" do
    test "put and get round-trip", %{store: store} do
      assert :ok = EtsStore.put(store, :name, "alice")
      assert {:ok, "alice"} = EtsStore.get(store, :name)
      assert EtsStore.member?(store, :name)
    end

    test "overwrites an existing key", %{store: store} do
      :ok = EtsStore.put(store, :k, 1)
      :ok = EtsStore.put(store, :k, 2)
      assert {:ok, 2} = EtsStore.get(store, :k)
      assert 1 = EtsStore.size(store)
    end

    test "returns :error for missing keys and tracks misses", %{store: store} do
      assert :error = EtsStore.get(store, :missing)
      assert %{hits: 0, misses: 1, size: 0} = EtsStore.stats(store)
    end

    test "delete removes a key", %{store: store} do
      :ok = EtsStore.put(store, :k, 1)
      :ok = EtsStore.delete(store, :k)
      refute EtsStore.member?(store, :k)
      assert :error = EtsStore.get(store, :k)
    end

    test "clear empties the table", %{store: store} do
      :ok = EtsStore.put(store, :a, 1)
      :ok = EtsStore.put(store, :b, 2)
      :ok = EtsStore.clear(store)
      assert 0 = EtsStore.size(store)
      assert :error = EtsStore.get(store, :a)
    end
  end

  describe "fetch/2 (direct ETS read)" do
    test "reads without messaging the owner", %{store: store} do
      table = EtsStore.table(store)
      :ok = EtsStore.put(store, :x, 10)
      assert {:ok, 10} = EtsStore.fetch(table, :x)
      assert :error = EtsStore.fetch(table, :nope)
    end

    test "works from another process", %{store: store} do
      table = EtsStore.table(store)
      :ok = EtsStore.put(store, :shared, :value)

      parent = self()

      task =
        Task.async(fn ->
          send(parent, EtsStore.fetch(table, :shared))
        end)

      assert {:ok, :value} = Task.await(task)
    end
  end

  describe "bag table" do
    setup do
      {:ok, pid} = EtsStore.start_link(table_type: :bag)
      %{store: pid}
    end

    test "stores multiple values per key", %{store: store} do
      :ok = EtsStore.put(store, :tag, "elixir")
      :ok = EtsStore.put(store, :tag, "otp")
      assert {:ok, values} = EtsStore.get(store, :tag)
      assert Enum.sort(values) == ["elixir", "otp"]
    end
  end

  describe "compare_reads/2" do
    test "direct ETS reads are faster than GenServer reads", %{store: store} do
      result = EtsStore.compare_reads(store, 5_000)

      assert result.iterations == 5_000
      assert result.genserver_microseconds > 0
      assert result.ets_direct_microseconds > 0
      assert result.speedup > 1.0
      assert result.genserver_microseconds > result.ets_direct_microseconds
    end
  end
end
