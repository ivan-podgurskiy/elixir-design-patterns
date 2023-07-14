defmodule Patterns.AgentState do
  @moduledoc """
  Demonstrates the Agent pattern for simple shared state management.

  Agents provide a simple abstraction for state that can be shared between processes.
  They're simpler than GenServers and perfect for basic state storage like counters,
  configuration, and caches.

  This pattern showcases:
  - Simple state storage and retrieval
  - Atomic updates with get_and_update
  - Configuration management
  - Counter implementations
  - Thread-safe operations

  ## Examples

      iex> {:ok, counter} = Patterns.AgentState.Counter.start_link(0)
      iex> 1 = Patterns.AgentState.Counter.increment(counter)
      iex> 1 = Patterns.AgentState.Counter.get(counter)

  """

  defmodule Counter do
    @moduledoc """
    A simple counter implemented using an Agent.

    Perfect for tracking metrics, request counts, or any monotonic values.
    """

    @type t :: pid()
    @type count :: integer()

    @doc """
    Starts a counter with an initial value.
    """
    @spec start_link(count()) :: Agent.on_start()
    def start_link(initial_count \\ 0) do
      Agent.start_link(fn -> initial_count end)
    end

    @doc """
    Gets the current count.
    """
    @spec get(t()) :: count()
    def get(counter) do
      Agent.get(counter, & &1)
    end

    @doc """
    Increments the counter and returns the new value.
    """
    @spec increment(t()) :: count()
    def increment(counter) do
      Agent.get_and_update(counter, fn count ->
        new_count = count + 1
        {new_count, new_count}
      end)
    end

    @doc """
    Decrements the counter and returns the new value.
    """
    @spec decrement(t()) :: count()
    def decrement(counter) do
      Agent.get_and_update(counter, fn count ->
        new_count = count - 1
        {new_count, new_count}
      end)
    end

    @doc """
    Adds a specific amount to the counter and returns the new value.
    """
    @spec add(t(), count()) :: count()
    def add(counter, amount) do
      Agent.get_and_update(counter, fn count ->
        new_count = count + amount
        {new_count, new_count}
      end)
    end

    @doc """
    Resets the counter to zero and returns the previous value.
    """
    @spec reset(t()) :: count()
    def reset(counter) do
      Agent.get_and_update(counter, fn count -> {count, 0} end)
    end

    @doc """
    Sets the counter to a specific value and returns the previous value.
    """
    @spec set(t(), count()) :: count()
    def set(counter, new_value) do
      Agent.get_and_update(counter, fn count -> {count, new_value} end)
    end
  end

  defmodule ConfigStore do
    @moduledoc """
    A configuration store implemented using an Agent.

    Useful for runtime configuration that can be updated dynamically.
    """

    @type t :: pid()
    @type key :: term()
    @type value :: term()
    @type config :: %{key() => value()}

    @doc """
    Starts a config store with initial configuration.
    """
    @spec start_link(config()) :: Agent.on_start()
    def start_link(initial_config \\ %{}) do
      Agent.start_link(fn -> initial_config end)
    end

    @doc """
    Gets a configuration value by key.
    """
    @spec get(t(), key()) :: value() | nil
    def get(store, key) do
      Agent.get(store, &Map.get(&1, key))
    end

    @doc """
    Gets a configuration value with a default if key doesn't exist.
    """
    @spec get(t(), key(), value()) :: value()
    def get(store, key, default) do
      Agent.get(store, &Map.get(&1, key, default))
    end

    @doc """
    Sets a configuration value and returns the old value.
    """
    @spec put(t(), key(), value()) :: value() | nil
    def put(store, key, value) do
      Agent.get_and_update(store, fn config ->
        old_value = Map.get(config, key)
        new_config = Map.put(config, key, value)
        {old_value, new_config}
      end)
    end

    @doc """
    Deletes a configuration key and returns the old value.
    """
    @spec delete(t(), key()) :: value() | nil
    def delete(store, key) do
      Agent.get_and_update(store, fn config ->
        {Map.get(config, key), Map.delete(config, key)}
      end)
    end

    @doc """
    Gets all configuration as a map.
    """
    @spec get_all(t()) :: config()
    def get_all(store) do
      Agent.get(store, & &1)
    end

    @doc """
    Updates the entire configuration.
    """
    @spec put_all(t(), config()) :: config()
    def put_all(store, new_config) do
      Agent.get_and_update(store, fn old_config ->
        {old_config, new_config}
      end)
    end

    @doc """
    Merges new configuration with existing configuration.
    """
    @spec merge(t(), config()) :: config()
    def merge(store, config_updates) do
      Agent.get_and_update(store, fn config ->
        new_config = Map.merge(config, config_updates)
        {config, new_config}
      end)
    end

    @doc """
    Gets all configuration keys.
    """
    @spec keys(t()) :: [key()]
    def keys(store) do
      Agent.get(store, &Map.keys/1)
    end

    @doc """
    Checks if a key exists in the configuration.
    """
    @spec has_key?(t(), key()) :: boolean()
    def has_key?(store, key) do
      Agent.get(store, &Map.has_key?(&1, key))
    end

    @doc """
    Gets the number of configuration entries.
    """
    @spec size(t()) :: non_neg_integer()
    def size(store) do
      Agent.get(store, &map_size/1)
    end
  end

  defmodule Statistics do
    @moduledoc """
    A statistics collector using an Agent to track various metrics.

    Useful for collecting application metrics, performance data, or usage statistics.
    """

    @type t :: pid()
    @type metric_name :: atom()
    @type metric_value :: number()
    @type stats :: %{metric_name() => metric_value()}

    @doc """
    Starts a statistics collector.
    """
    @spec start_link() :: Agent.on_start()
    def start_link do
      Agent.start_link(fn -> %{} end)
    end

    @doc """
    Records a single occurrence of a metric.
    """
    @spec increment(t(), metric_name()) :: :ok
    def increment(stats, metric) do
      Agent.update(stats, fn current_stats ->
        Map.update(current_stats, metric, 1, &(&1 + 1))
      end)
    end

    @doc """
    Records multiple occurrences of a metric.
    """
    @spec add(t(), metric_name(), metric_value()) :: :ok
    def add(stats, metric, amount) do
      Agent.update(stats, fn current_stats ->
        Map.update(current_stats, metric, amount, &(&1 + amount))
      end)
    end

    @doc """
    Sets a metric to a specific value.
    """
    @spec set(t(), metric_name(), metric_value()) :: :ok
    def set(stats, metric, value) do
      Agent.update(stats, fn current_stats ->
        Map.put(current_stats, metric, value)
      end)
    end

    @doc """
    Gets the value of a specific metric.
    """
    @spec get(t(), metric_name()) :: metric_value() | nil
    def get(stats, metric) do
      Agent.get(stats, &Map.get(&1, metric))
    end

    @doc """
    Gets all statistics.
    """
    @spec get_all(t()) :: stats()
    def get_all(stats) do
      Agent.get(stats, & &1)
    end

    @doc """
    Resets all statistics.
    """
    @spec reset(t()) :: stats()
    def reset(stats) do
      Agent.get_and_update(stats, fn current_stats ->
        {current_stats, %{}}
      end)
    end

    @doc """
    Resets a specific metric.
    """
    @spec reset(t(), metric_name()) :: metric_value() | nil
    def reset(stats, metric) do
      Agent.get_and_update(stats, fn current_stats ->
        old_value = Map.get(current_stats, metric)
        new_stats = Map.delete(current_stats, metric)
        {old_value, new_stats}
      end)
    end

    @doc """
    Records timing information (in milliseconds).
    """
    @spec time(t(), metric_name(), (-> result)) :: result when result: any()
    def time(stats, metric, fun) do
      start_time = System.monotonic_time(:millisecond)
      result = fun.()
      end_time = System.monotonic_time(:millisecond)
      duration = end_time - start_time

      Agent.update(stats, fn current_stats ->
        # Track both total time and count for average calculations
        total_key = :"#{metric}_total_ms"
        count_key = :"#{metric}_count"

        current_stats
        |> Map.update(total_key, duration, &(&1 + duration))
        |> Map.update(count_key, 1, &(&1 + 1))
      end)

      result
    end

    @doc """
    Gets the average duration for a timed metric.
    """
    @spec average_time(t(), metric_name()) :: float() | nil
    def average_time(stats, metric) do
      Agent.get(stats, fn current_stats ->
        total_key = :"#{metric}_total_ms"
        count_key = :"#{metric}_count"

        with total when is_number(total) <- Map.get(current_stats, total_key),
             count when is_number(count) and count > 0 <- Map.get(current_stats, count_key) do
          total / count
        else
          _ -> nil
        end
      end)
    end
  end
end
