defmodule Patterns.EtsStore do
  @moduledoc """
  Demonstrates ETS-backed in-memory storage owned by a GenServer.

  Erlang Term Storage (ETS) keeps data in a table outside the process heap, so
  reads can be shared across processes without copying large terms through
  message passing. The usual production shape is:

  - a **GenServer owns** the table (create, write, delete, lifecycle)
  - **callers read** with `:ets.lookup/2` when the table is `:public`
  - **tune concurrency** with `:read_concurrency` and `:write_concurrency`

  This pattern contrasts with [`Patterns.GenServerCache`](Patterns.GenServerCache),
  which keeps entries in the GenServer's map state — simpler, but every read
  crosses a process boundary.

  ## Examples

      iex> {:ok, pid} = Patterns.EtsStore.start_link([])
      iex> :ok = Patterns.EtsStore.put(pid, :user, %{id: 1})
      iex> {:ok, %{id: 1}} = Patterns.EtsStore.get(pid, :user)
      iex> 1 = Patterns.EtsStore.size(pid)

  """

  use GenServer

  @type key :: term()
  @type value :: term()
  @type table_type :: :set | :ordered_set | :bag | :duplicate_bag
  @type stats :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          size: non_neg_integer()
        }

  @type compare_result :: %{
          iterations: pos_integer(),
          genserver_microseconds: non_neg_integer(),
          ets_direct_microseconds: non_neg_integer(),
          speedup: float()
        }

  @type state :: %{
          table: :ets.tid(),
          stats: %{hits: non_neg_integer(), misses: non_neg_integer()}
        }

  @default_table_type :set

  @doc """
  Starts a store GenServer that owns a `:public` ETS table.

  ## Options

  - `:table_type` — `:set` (default), `:ordered_set`, `:bag`, or `:duplicate_bag`
  - `:read_concurrency` — enable concurrent readers (default: `true`)
  - `:write_concurrency` — enable concurrent writers inside ETS (default: `true`)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Inserts `value` under `key`.

  For `:set` and `:ordered_set` tables, overwrites an existing key.
  For `:bag` tables, multiple values per key are allowed.
  """
  @spec put(GenServer.server(), key(), value()) :: :ok
  def put(server, key, value) do
    GenServer.call(server, {:put, key, value})
  end

  @doc """
  Reads `key` through the GenServer (one message round-trip).

  Returns `{:ok, value}` for `:set` / `:ordered_set`, or `{:ok, values}` (a list)
  for `:bag` / `:duplicate_bag`. Returns `:error` when the key is absent.
  """
  @spec get(GenServer.server(), key()) :: {:ok, value() | [value()]} | :error
  def get(server, key) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  Reads `key` directly from the ETS table without messaging the owner.

  The table must be `:public` (the default for tables created here). Only the
  owner process may insert or delete; any process may call this function.

  ## Examples

      iex> {:ok, pid} = Patterns.EtsStore.start_link([])
      iex> table = Patterns.EtsStore.table(pid)
      iex> :ok = Patterns.EtsStore.put(pid, :k, 99)
      iex> {:ok, 99} = Patterns.EtsStore.fetch(table, :k)

  """
  @spec fetch(:ets.tid() | atom(), key()) :: {:ok, value() | [value()]} | :error
  def fetch(table, key) do
    case :ets.lookup(table, key) do
      [] ->
        :error

      [{^key, value}] ->
        {:ok, value}

      matches when is_list(matches) ->
        {:ok, Enum.map(matches, fn {^key, v} -> v end)}
    end
  end

  @doc """
  Deletes all objects matching `key`.
  """
  @spec delete(GenServer.server(), key()) :: :ok
  def delete(server, key) do
    GenServer.call(server, {:delete, key})
  end

  @doc """
  Removes every object from the table.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  @doc """
  Returns the number of objects in the table.
  """
  @spec size(GenServer.server()) :: non_neg_integer()
  def size(server) do
    GenServer.call(server, :size)
  end

  @doc """
  Returns `true` when `key` exists in the table.
  """
  @spec member?(GenServer.server(), key()) :: boolean()
  def member?(server, key) do
    GenServer.call(server, {:member?, key})
  end

  @doc """
  Returns hit/miss counters and the current table size.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Returns the ETS table identifier for direct reads (see `fetch/2`).
  """
  @spec table(GenServer.server()) :: :ets.tid()
  def table(server) do
    GenServer.call(server, :table)
  end

  @doc """
  Micro-benchmark comparing GenServer reads vs direct `:ets.lookup/2`.

  Inserts a warmup key, then times `iterations` reads on each path. Useful in
  guides and `iex` to see why hot paths often bypass the owner process.

  The result map includes a `speedup` ratio (`genserver_microseconds /
  ets_direct_microseconds`).
  """
  @spec compare_reads(GenServer.server(), pos_integer()) :: compare_result()
  def compare_reads(server, iterations \\ 10_000)
      when is_integer(iterations) and iterations > 0 do
    bench_key = :__ets_store_bench__
    :ok = put(server, bench_key, 1)
    tid = table(server)

    genserver_us = time_reads(iterations, fn -> get(server, bench_key) end)
    ets_direct_us = time_reads(iterations, fn -> fetch(tid, bench_key) end)
    :ok = delete(server, bench_key)

    %{
      iterations: iterations,
      genserver_microseconds: genserver_us,
      ets_direct_microseconds: ets_direct_us,
      speedup: genserver_us / max(ets_direct_us, 1)
    }
  end

  defp time_reads(iterations, read_fun) do
    {microseconds, _} =
      :timer.tc(fn ->
        for _ <- 1..iterations, do: read_fun.()
      end)

    microseconds
  end

  @impl GenServer
  def terminate(_reason, %{table: table}) do
    :ets.delete(table)
    :ok
  end

  @impl GenServer
  def init(opts) do
    table_type = Keyword.get(opts, :table_type, @default_table_type)
    read_concurrency = Keyword.get(opts, :read_concurrency, true)
    write_concurrency = Keyword.get(opts, :write_concurrency, true)

    table_name = :"ets_store_#{System.unique_integer([:positive, :monotonic])}"

    table =
      :ets.new(table_name, [
        table_type,
        :public,
        :protected,
        {:read_concurrency, read_concurrency},
        {:write_concurrency, write_concurrency}
      ])

    {:ok, %{table: table, stats: %{hits: 0, misses: 0}}}
  end

  @impl GenServer
  def handle_call({:put, key, value}, _from, %{table: table} = state) do
    true = :ets.insert(table, {key, value})
    {:reply, :ok, state}
  end

  def handle_call({:get, key}, _from, %{table: table, stats: stats} = state) do
    case lookup(table, key) do
      :error ->
        {:reply, :error, %{state | stats: %{stats | misses: stats.misses + 1}}}

      {:ok, value} ->
        {:reply, {:ok, value}, %{state | stats: %{stats | hits: stats.hits + 1}}}
    end
  end

  def handle_call({:delete, key}, _from, %{table: table} = state) do
    true = :ets.delete(table, key)
    {:reply, :ok, state}
  end

  def handle_call(:clear, _from, %{table: table} = state) do
    :ets.delete_all_objects(table)
    {:reply, :ok, state}
  end

  def handle_call(:size, _from, %{table: table} = state) do
    {:reply, :ets.info(table, :size), state}
  end

  def handle_call({:member?, key}, _from, %{table: table} = state) do
    {:reply, :ets.member(table, key), state}
  end

  def handle_call(:stats, _from, %{table: table, stats: stats} = state) do
    reply = %{
      hits: stats.hits,
      misses: stats.misses,
      size: :ets.info(table, :size)
    }

    {:reply, reply, state}
  end

  def handle_call(:table, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  defp lookup(table, key) do
    case :ets.lookup(table, key) do
      [] -> :error
      [{^key, value}] -> {:ok, value}
      matches when is_list(matches) -> {:ok, Enum.map(matches, fn {^key, v} -> v end)}
    end
  end
end
