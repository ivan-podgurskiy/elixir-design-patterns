defmodule Patterns.GenServerCache do
  @moduledoc """
  An in-memory key-value cache implemented as a GenServer with TTL expiration and hit/miss statistics.

  This pattern demonstrates:
  - GenServer state management
  - TTL (Time-To-Live) expiration handling
  - Performance monitoring with statistics
  - Periodic cleanup processes

  ## Examples

      iex> {:ok, pid} = Patterns.GenServerCache.start_link([])
      iex> :ok = Patterns.GenServerCache.put(pid, "key1", "value1", 1000)
      iex> {:ok, "value1"} = Patterns.GenServerCache.get(pid, "key1")
      iex> %{hits: 1, misses: 0, total_keys: 1} = Patterns.GenServerCache.stats(pid)

  """

  use GenServer
  require Logger

  @type key :: any()
  @type value :: any()
  @type ttl_ms :: non_neg_integer()
  @type cache_entry :: {value(), expires_at :: integer()}
  @type stats :: %{
          hits: non_neg_integer(),
          misses: non_neg_integer(),
          total_keys: non_neg_integer()
        }

  @type state :: %{
          cache: %{key() => cache_entry()},
          stats: stats(),
          cleanup_interval: pos_integer()
        }

  @default_cleanup_interval 30_000

  @doc """
  Starts the cache GenServer.

  ## Options
  - `:cleanup_interval` - Milliseconds between cleanup runs (default: 30_000)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Stores a key-value pair in the cache with optional TTL.
  """
  @spec put(GenServer.server(), key(), value(), ttl_ms() | nil) :: :ok
  def put(server, key, value, ttl_ms \\ nil) do
    GenServer.cast(server, {:put, key, value, ttl_ms})
  end

  @doc """
  Retrieves a value from the cache.
  Returns `{:ok, value}` if found and not expired, `:error` otherwise.
  """
  @spec get(GenServer.server(), key()) :: {:ok, value()} | :error
  def get(server, key) do
    GenServer.call(server, {:get, key})
  end

  @doc """
  Deletes a key from the cache.
  """
  @spec delete(GenServer.server(), key()) :: :ok
  def delete(server, key) do
    GenServer.cast(server, {:delete, key})
  end

  @doc """
  Clears all entries from the cache.
  """
  @spec clear(GenServer.server()) :: :ok
  def clear(server) do
    GenServer.cast(server, :clear)
  end

  @doc """
  Returns cache statistics.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Returns all cache keys (for debugging).
  """
  @spec keys(GenServer.server()) :: [key()]
  def keys(server) do
    GenServer.call(server, :keys)
  end

  # GenServer Callbacks

  @impl GenServer
  def init(opts) do
    cleanup_interval = Keyword.get(opts, :cleanup_interval, @default_cleanup_interval)

    state = %{
      cache: %{},
      stats: %{hits: 0, misses: 0, total_keys: 0},
      cleanup_interval: cleanup_interval
    }

    schedule_cleanup(cleanup_interval)
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:get, key}, _from, %{cache: cache, stats: stats} = state) do
    case Map.get(cache, key) do
      {value, expires_at} when is_integer(expires_at) ->
        if System.monotonic_time(:millisecond) < expires_at do
          new_stats = %{stats | hits: stats.hits + 1}
          {:reply, {:ok, value}, %{state | stats: new_stats}}
        else
          new_cache = Map.delete(cache, key)
          new_stats = %{stats | misses: stats.misses + 1, total_keys: stats.total_keys - 1}
          {:reply, :error, %{state | cache: new_cache, stats: new_stats}}
        end

      {value, nil} ->
        new_stats = %{stats | hits: stats.hits + 1}
        {:reply, {:ok, value}, %{state | stats: new_stats}}

      nil ->
        new_stats = %{stats | misses: stats.misses + 1}
        {:reply, :error, %{state | stats: new_stats}}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, %{stats: stats} = state) do
    {:reply, stats, state}
  end

  @impl GenServer
  def handle_call(:keys, _from, %{cache: cache} = state) do
    keys = Map.keys(cache)
    {:reply, keys, state}
  end

  @impl GenServer
  def handle_cast({:put, key, value, ttl_ms}, %{cache: cache, stats: stats} = state) do
    expires_at = if ttl_ms, do: System.monotonic_time(:millisecond) + ttl_ms, else: nil
    entry = {value, expires_at}

    new_cache = Map.put(cache, key, entry)
    key_count_delta = if Map.has_key?(cache, key), do: 0, else: 1
    new_stats = %{stats | total_keys: stats.total_keys + key_count_delta}

    {:noreply, %{state | cache: new_cache, stats: new_stats}}
  end

  @impl GenServer
  def handle_cast({:delete, key}, %{cache: cache, stats: stats} = state) do
    if Map.has_key?(cache, key) do
      new_cache = Map.delete(cache, key)
      new_stats = %{stats | total_keys: stats.total_keys - 1}
      {:noreply, %{state | cache: new_cache, stats: new_stats}}
    else
      {:noreply, state}
    end
  end

  @impl GenServer
  def handle_cast(:clear, %{stats: stats} = state) do
    new_state = %{state | cache: %{}, stats: %{stats | total_keys: 0}}
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:cleanup_expired, %{cache: cache, stats: stats} = state) do
    current_time = System.monotonic_time(:millisecond)

    {expired_keys, valid_cache} =
      Enum.reduce(cache, {[], %{}}, fn {key, {_value, expires_at} = entry}, {expired, valid} ->
        if expires_at && current_time >= expires_at do
          {[key | expired], valid}
        else
          {expired, Map.put(valid, key, entry)}
        end
      end)

    expired_count = length(expired_keys)

    if expired_count > 0 do
      Logger.debug("Cache cleanup: removed #{expired_count} expired entries")
    end

    new_stats = %{stats | total_keys: stats.total_keys - expired_count}
    new_state = %{state | cache: valid_cache, stats: new_stats}

    schedule_cleanup(state.cleanup_interval)
    {:noreply, new_state}
  end

  @spec schedule_cleanup(pos_integer()) :: reference()
  defp schedule_cleanup(interval) do
    Process.send_after(self(), :cleanup_expired, interval)
  end
end
