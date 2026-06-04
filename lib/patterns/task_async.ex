defmodule Patterns.TaskAsync do
  @moduledoc """
  Demonstrates asynchronous task patterns using Task.async/await.

  This pattern showcases:
  - Parallel HTTP fetches and I/O operations
  - Timeout handling and error recovery
  - Task supervision and fault tolerance
  - Concurrent data processing
  - Result aggregation from multiple tasks

  ## Examples

      iex> urls = ["http://httpbin.org/delay/1", "http://httpbin.org/delay/2"]
      iex> {:ok, results} = Patterns.TaskAsync.parallel_fetch(urls, timeout: 5000)
      iex> length(results) == 2

  """

  require Logger

  @type url :: String.t()
  @type timeout_ms :: pos_integer()
  @type http_result :: {:ok, term()} | {:error, term()}
  @type task_result :: {:ok, term()} | {:error, term()} | {:timeout, term()}

  @default_timeout 5000
  @default_http_timeout 3000

  @task_supervisor __MODULE__.TaskSupervisor

  @doc """
  Fetches multiple URLs in parallel using Task.async/await.

  URLs containing `/delay/N` simulate N-second response times for testing.
  Returns results in the same order as the input URLs.
  Individual failures don't stop other requests.
  """
  @spec parallel_fetch([url()], keyword()) :: {:ok, [http_result()]} | {:error, term()}
  def parallel_fetch(urls, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    http_timeout = Keyword.get(opts, :http_timeout, @default_http_timeout)

    try do
      tasks =
        urls
        |> Enum.with_index()
        |> Enum.map(fn {url, index} ->
          Task.async(fn ->
            fetch_single_url(url, http_timeout, index)
          end)
        end)

      results =
        tasks
        |> Task.await_many(timeout)
        |> Enum.sort_by(fn {index, _result} -> index end)
        |> Enum.map(fn {_index, result} -> result end)

      {:ok, results}
    rescue
      e ->
        Logger.error("Parallel fetch failed: #{inspect(e)}")
        {:error, e}
    catch
      :exit, {:timeout, _} ->
        Logger.error("Parallel fetch timed out")
        {:error, :timeout}
    end
  end

  @doc """
  Processes a list of items concurrently with a specified function.

  Returns results as they complete (not necessarily in order).
  """
  @spec parallel_map([term()], (term() -> term()), keyword()) :: [term()]
  def parallel_map(items, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online() * 2)

    items
    |> Enum.chunk_every(max_concurrency)
    |> Enum.flat_map(fn chunk ->
      chunk
      |> Enum.map(&Task.async(fn -> fun.(&1) end))
      |> Task.await_many(timeout)
    end)
  end

  @doc """
  Races multiple tasks and returns the result of the first one to complete.

  Other tasks are automatically cancelled.
  """
  @spec race([(-> term())], timeout_ms()) :: task_result()
  def race(functions, timeout \\ @default_timeout) do
    parent = self()

    tasks =
      functions
      |> Enum.with_index()
      |> Enum.map(fn {fun, index} ->
        Task.async(fn ->
          try do
            result = fun.()
            send(parent, {:task_complete, index, {:ok, result}})
          rescue
            e ->
              send(parent, {:task_complete, index, {:error, e}})
          end
        end)
      end)

    result =
      receive do
        {:task_complete, _index, result} -> result
      after
        timeout -> {:timeout, :race_timeout}
      end

    # Cancel remaining tasks
    Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))

    result
  end

  @doc """
  Executes tasks with a timeout and provides fallback values for timeouts.
  """
  @spec with_fallback([(-> term())], keyword()) :: [task_result()]
  def with_fallback(functions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    fallback_value = Keyword.get(opts, :fallback, nil)

    tasks = Enum.map(functions, &async_safe/1)

    Enum.map(tasks, fn task ->
      try do
        case Task.await(task, timeout) do
          {:ok, result} -> {:ok, result}
          {:task_error, exception} -> {:error, exception}
          {:task_exit, reason} -> {:error, reason}
        end
      catch
        :exit, {:timeout, _} ->
          Task.shutdown(task, :brutal_kill)
          {:timeout, fallback_value}

        :exit, reason ->
          {:error, reason}
      end
    end)
  end

  @doc """
  Retry a task with exponential backoff.

  Delay between attempts uses the [`jitter`](https://hexdocs.pm/jitter) package,
  which implements the strategies from Marc Brooker's
  [Exponential Backoff and Jitter](https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/).

  ## Options

  - `:max_attempts` — total tries (default: `3`)
  - `:base_delay` — base delay in milliseconds (default: `100`)
  - `:max_delay` — cap on delay in milliseconds (default: `5000`)
  - `:jitter` — `:full` (default), `:equal`, `:decorrelated`, or `false` for no jitter.
    `true` is accepted as an alias for `:full`.
  """
  @spec retry((-> term()), keyword()) :: {:ok, term()} | {:error, Exception.t()}
  def retry(fun, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, 3)
    base_delay = Keyword.get(opts, :base_delay, 100)
    max_delay = Keyword.get(opts, :max_delay, 5000)
    jitter = normalize_jitter(Keyword.get(opts, :jitter, :full))

    do_retry(fun, max_attempts, base_delay, max_delay, jitter, 1, base_delay)
  end

  @doc """
  Supervised task execution that won't crash the caller.
  """
  @spec supervised_task((-> term()), keyword()) ::
          {:ok, term()} | {:error, term()} | {:timeout, :supervised_task_timeout}
  def supervised_task(fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    task = Task.Supervisor.async_nolink(@task_supervisor, fun)

    try do
      result = Task.await(task, timeout)
      {:ok, result}
    catch
      :exit, {:timeout, _} ->
        Task.Supervisor.terminate_child(@task_supervisor, task.pid)
        {:timeout, :supervised_task_timeout}

      :exit, reason ->
        {:error, reason}
    end
  end

  @doc """
  Pipeline pattern: pass result of one async task to the next.
  """
  @spec pipeline([(-> term()) | (term() -> term())], keyword()) :: task_result()
  def pipeline(functions, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    functions
    |> Enum.reduce_while({:ok, nil}, fn fun, {:ok, acc} ->
      task =
        Task.async(fn ->
          try do
            if acc == nil, do: fun.(), else: fun.(acc)
          rescue
            e -> {:pipeline_error, e}
          end
        end)

      case Task.await(task, timeout) do
        {:pipeline_error, exception} ->
          {:halt, {:error, exception}}

        result ->
          {:cont, {:ok, result}}
      end
    end)
    |> case do
      {:ok, result} -> {:ok, result}
      {:error, _} = error -> error
    end
  catch
    :exit, {:timeout, _} ->
      {:timeout, :pipeline_timeout}

    :exit, reason ->
      {:error, reason}
  end

  # Private Functions

  @spec fetch_single_url(url(), timeout_ms(), non_neg_integer()) ::
          {non_neg_integer(), http_result()}
  defp fetch_single_url(url, http_timeout, index) do
    result =
      try do
        delay = extract_delay_from_url(url)
        Process.sleep(min(delay, http_timeout))

        if delay > http_timeout do
          {:error, :timeout}
        else
          {:ok, %{url: url, status: 200, body: "Response from #{url}", delay: delay}}
        end
      rescue
        e ->
          {:error, e}
      catch
        :exit, reason ->
          {:error, reason}
      end

    {index, result}
  end

  @spec extract_delay_from_url(url()) :: non_neg_integer()
  defp extract_delay_from_url(url) do
    case Regex.run(~r/delay\/(\d+)/, url) do
      [_, delay_str] -> String.to_integer(delay_str) * 1000
      _ -> 100
    end
  end

  @type jitter_strategy :: false | :full | :equal | :decorrelated

  @spec normalize_jitter(boolean() | jitter_strategy()) :: jitter_strategy()
  defp normalize_jitter(true), do: :full
  defp normalize_jitter(false), do: false
  defp normalize_jitter(strategy) when strategy in [:full, :equal, :decorrelated], do: strategy

  @spec do_retry(
          (-> term()),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          jitter_strategy(),
          pos_integer(),
          pos_integer()
        ) :: {:ok, term()} | {:error, term()}
  defp do_retry(fun, max_attempts, base_delay, max_delay, jitter, attempt, prev_delay) do
    result = fun.()
    {:ok, result}
  rescue
    e ->
      if attempt < max_attempts do
        delay = backoff_delay(jitter, attempt, base_delay, max_delay, prev_delay)
        Process.sleep(delay)
        do_retry(fun, max_attempts, base_delay, max_delay, jitter, attempt + 1, delay)
      else
        {:error, e}
      end
  end

  @spec backoff_delay(
          jitter_strategy(),
          pos_integer(),
          pos_integer(),
          pos_integer(),
          pos_integer()
        ) :: pos_integer()
  defp backoff_delay(false, attempt, base_delay, max_delay, _prev_delay) do
    Jitter.no_jitter(attempt - 1, base: base_delay, cap: max_delay)
  end

  defp backoff_delay(:full, attempt, base_delay, max_delay, _prev_delay) do
    Jitter.full(attempt - 1, base: base_delay, cap: max_delay)
  end

  defp backoff_delay(:equal, attempt, base_delay, max_delay, _prev_delay) do
    Jitter.equal(attempt - 1, base: base_delay, cap: max_delay)
  end

  defp backoff_delay(:decorrelated, _attempt, base_delay, max_delay, prev_delay) do
    Jitter.decorrelated(prev_delay, base: base_delay, cap: max_delay)
  end

  defmodule Utils do
    @moduledoc """
    Common utilities for async task patterns.
    """

    @doc """
    Batches items and processes each batch concurrently.
    """
    @spec batch_process([term()], (term() -> term()), keyword()) :: [term()]
    def batch_process(items, processor_fun, opts \\ []) do
      batch_size = Keyword.get(opts, :batch_size, 10)
      timeout = Keyword.get(opts, :timeout, 10_000)

      items
      |> Enum.chunk_every(batch_size)
      |> Enum.map(fn batch ->
        Task.async(fn ->
          Enum.map(batch, processor_fun)
        end)
      end)
      |> Task.await_many(timeout)
      |> List.flatten()
    end

    @doc """
    Fetches data from multiple sources with different strategies.
    """
    @spec multi_source_fetch(keyword()) :: %{atom() => term()}
    def multi_source_fetch(opts \\ []) do
      timeout = Keyword.get(opts, :timeout, 5000)

      sources = %{
        database: fn -> simulate_db_query() end,
        cache: fn -> simulate_cache_lookup() end,
        api: fn -> simulate_api_call() end
      }

      tasks =
        Enum.map(sources, fn {name, fun} ->
          {name, Task.async(fun)}
        end)

      Enum.reduce(tasks, %{}, fn {name, task}, acc ->
        try do
          result = Task.await(task, timeout)
          Map.put(acc, name, {:ok, result})
        catch
          :exit, {:timeout, _} ->
            Task.shutdown(task)
            Map.put(acc, name, {:error, :timeout})

          :exit, reason ->
            Map.put(acc, name, {:error, reason})
        end
      end)
    end

    # Simulate different data sources
    defp simulate_db_query do
      Process.sleep(100)
      "db_data"
    end

    defp simulate_cache_lookup do
      Process.sleep(10)
      "cache_data"
    end

    defp simulate_api_call do
      Process.sleep(200)
      "api_data"
    end
  end

  @spec async_safe((-> term())) :: Task.t()
  defp async_safe(fun) do
    Task.async(fn ->
      try do
        {:ok, fun.()}
      rescue
        e -> {:task_error, e}
      catch
        :exit, reason -> {:task_exit, reason}
      end
    end)
  end
end
