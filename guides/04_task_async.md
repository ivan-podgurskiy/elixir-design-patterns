# Task.async Pattern

## Overview

The Task.async pattern enables concurrent and parallel execution in Elixir. Tasks are lightweight processes designed for short-lived concurrent operations. They're perfect for I/O-bound operations, parallel data processing, and scenarios where you want to execute multiple operations simultaneously without blocking.

## Problem it Solves

- **I/O Bottlenecks**: Execute multiple HTTP requests, database queries, or file operations concurrently
- **CPU-intensive Work**: Distribute computational work across available cores
- **Timeout Management**: Control execution time with configurable timeouts
- **Error Isolation**: Handle failures in individual tasks without affecting others
- **Result Coordination**: Collect and aggregate results from multiple concurrent operations

## When to Use

✅ **Good for:**
- HTTP API calls and external service requests
- Database queries that can run independently
- File I/O operations
- Image/data processing that can be parallelized
- Racing multiple approaches to pick the fastest
- Fan-out/fan-in patterns

❌ **Avoid when:**
- Operations need to share mutable state
- Sequential dependencies between operations
- Memory usage is a critical concern (tasks create processes)
- Very short-lived operations (overhead may outweigh benefits)

## Core Patterns

### 1. Basic Async/Await

```elixir
# Start async task
task = Task.async(fn ->
  # Some expensive operation
  HTTPoison.get("https://api.example.com/data")
end)

# Do other work...
other_result = local_computation()

# Get the async result
{:ok, response} = Task.await(task, 5000)
```

### 2. Parallel Execution

```elixir
# Start multiple tasks
tasks = [
  Task.async(fn -> fetch_user(1) end),
  Task.async(fn -> fetch_user(2) end),
  Task.async(fn -> fetch_user(3) end)
]

# Wait for all to complete
results = Task.await_many(tasks, 10_000)
```

### 3. Racing Tasks

```elixir
# Race multiple approaches
fastest_result = Task.async_stream([
  fn -> slow_database_query() end,
  fn -> fast_cache_lookup() end
], max_concurrency: 2)
|> Enum.take(1)  # Take first result
|> List.first()
```

## Implementation Examples

### Parallel HTTP Fetching

```elixir
def parallel_fetch(urls, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 5000)

  tasks =
    urls
    |> Enum.with_index()
    |> Enum.map(fn {url, index} ->
      Task.async(fn ->
        case HTTPoison.get(url, [], timeout: timeout) do
          {:ok, response} -> {index, {:ok, response.body}}
          {:error, reason} -> {index, {:error, reason}}
        end
      end)
    end)

  # Await all tasks and sort by original order
  Task.await_many(tasks, timeout)
  |> Enum.sort_by(fn {index, _} -> index end)
  |> Enum.map(fn {_, result} -> result end)
end
```

### Parallel Data Processing

```elixir
def parallel_map(items, fun, opts \\ []) do
  max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())
  timeout = Keyword.get(opts, :timeout, 5000)

  items
  |> Task.async_stream(fun,
       max_concurrency: max_concurrency,
       timeout: timeout)
  |> Enum.map(fn {:ok, result} -> result end)
end

# Usage
large_dataset
|> parallel_map(&expensive_computation/1, max_concurrency: 8)
```

### Retry with Backoff

```elixir
def retry_with_backoff(fun, opts \\ []) do
  max_attempts = Keyword.get(opts, :max_attempts, 3)
  base_delay = Keyword.get(opts, :base_delay, 100)

  Enum.reduce_while(1..max_attempts, nil, fn attempt, _acc ->
    task = Task.async(fn ->
      try do
        {:ok, fun.()}
      rescue
        e -> {:error, e}
      end
    end)

    case Task.await(task, 10_000) do
      {:ok, result} -> {:halt, {:ok, result}}
      {:error, _} when attempt < max_attempts ->
        delay = base_delay * :math.pow(2, attempt - 1)
        Process.sleep(trunc(delay))
        {:cont, nil}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end)
end
```

### Pipeline Processing

```elixir
def async_pipeline(data, steps, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 10_000)

  Enum.reduce(steps, {:ok, data}, fn step_fun, {:ok, acc} ->
    task = Task.async(fn -> step_fun.(acc) end)

    case Task.await(task, timeout) do
      result -> {:ok, result}
      error -> error
    end
  end)
end

# Usage
{:ok, result} = async_pipeline(input_data, [
  &validate_data/1,
  &transform_data/1,
  &save_to_database/1
])
```

## Real-World Examples

### Microservice Data Aggregation

```elixir
defmodule DataAggregator do
  def fetch_user_profile(user_id) do
    # Fetch from multiple services concurrently
    tasks = %{
      profile: Task.async(fn -> UserService.get_profile(user_id) end),
      preferences: Task.async(fn -> PreferenceService.get_preferences(user_id) end),
      activity: Task.async(fn -> ActivityService.get_recent_activity(user_id) end),
      permissions: Task.async(fn -> AuthService.get_permissions(user_id) end)
    }

    # Collect results with individual error handling
    results = Enum.map(tasks, fn {key, task} ->
      try do
        {key, {:ok, Task.await(task, 3000)}}
      catch
        :exit, {:timeout, _} -> {key, {:error, :timeout}}
        :exit, reason -> {key, {:error, reason}}
      end
    end)

    build_user_profile(results)
  end

  defp build_user_profile(results) do
    # Build profile even if some services fail
    Enum.reduce(results, %{}, fn {key, result}, acc ->
      case result do
        {:ok, data} -> Map.put(acc, key, data)
        {:error, _} -> Map.put(acc, key, nil)  # Graceful degradation
      end
    end)
  end
end
```

### Batch Processing System

```elixir
defmodule BatchProcessor do
  def process_batch(items, opts \\ []) do
    batch_size = Keyword.get(opts, :batch_size, 100)
    max_concurrency = Keyword.get(opts, :max_concurrency, 4)

    items
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(&process_chunk/1,
         max_concurrency: max_concurrency,
         timeout: 30_000)
    |> Enum.reduce({[], []}, fn
         {:ok, {:ok, results}}, {successes, failures} ->
           {successes ++ results, failures}
         {:ok, {:error, error}}, {successes, failures} ->
           {successes, [error | failures]}
         {:exit, reason}, {successes, failures} ->
           {successes, [reason | failures]}
       end)
  end

  defp process_chunk(chunk) do
    try do
      results = Enum.map(chunk, &process_item/1)
      {:ok, results}
    rescue
      e -> {:error, e}
    end
  end
end
```

## Usage Examples

### Basic Parallel Fetching

```elixir
# Fetch multiple URLs concurrently
urls = [
  "https://api.github.com/users/octocat",
  "https://api.github.com/users/defunkt",
  "https://api.github.com/users/mojombo"
]

{:ok, responses} = Patterns.TaskAsync.parallel_fetch(urls, timeout: 10_000)

responses
|> Enum.each(fn
     {:ok, response} -> IO.puts("Success: #{response.url}")
     {:error, reason} -> IO.puts("Failed: #{reason}")
   end)
```

### Racing Multiple Strategies

```elixir
# Try multiple approaches and use the fastest
result = Patterns.TaskAsync.race([
  fn -> slow_but_reliable_method() end,
  fn -> fast_but_unreliable_method() end,
  fn -> fallback_method() end
])

case result do
  {:ok, data} -> process_data(data)
  {:error, _} -> handle_all_failed()
  {:timeout, _} -> handle_timeout()
end
```

### Batch Processing with Concurrency Control

```elixir
large_dataset = 1..10_000 |> Enum.to_list()

results = Patterns.TaskAsync.parallel_map(
  large_dataset,
  &expensive_computation/1,
  max_concurrency: System.schedulers_online() * 2,
  timeout: 30_000
)
```

## Try It Live in IEx

```bash
iex -S mix
```

```elixir
# Simple parallel execution
tasks = [
  Task.async(fn -> Process.sleep(1000) && :task1 end),
  Task.async(fn -> Process.sleep(2000) && :task2 end),
  Task.async(fn -> Process.sleep(500) && :task3 end)
]

# This will take ~2 seconds (longest task), not 3.5 seconds
Task.await_many(tasks, 5000)
# => [:task1, :task2, :task3]

# Test parallel fetching
urls = ["http://httpbin.org/delay/1", "http://httpbin.org/delay/2"]
{:ok, results} = Patterns.TaskAsync.parallel_fetch(urls, timeout: 5000)
length(results)  # => 2

# Race different approaches
winner = Patterns.TaskAsync.race([
  fn -> Process.sleep(100) && :slow end,
  fn -> Process.sleep(50) && :fast end,
  fn -> Process.sleep(200) && :very_slow end
])
# => {:ok, :fast}

# Batch processing
1..20
|> Patterns.TaskAsync.parallel_map(fn x ->
     Process.sleep(100)  # Simulate work
     x * x
   end, max_concurrency: 4)
|> Enum.sum()  # Much faster than sequential
```

## Real-World Usage

I've used Task.async patterns for:

1. **API Gateway**: Aggregate data from multiple microservices in parallel
2. **ETL Pipelines**: Process large datasets with controlled concurrency
3. **Image Processing**: Resize/transform multiple images simultaneously
4. **Web Scraping**: Fetch data from multiple sources concurrently
5. **Report Generation**: Collect data from various sources and generate reports

## Performance Characteristics

- **Startup Overhead**: ~2-3μs per task (very lightweight)
- **Memory Usage**: ~2KB per task process
- **Concurrency**: Limited by available schedulers (default: cores * 2)
- **Scalability**: Can handle thousands of concurrent tasks

## Best Practices

### 1. Set Appropriate Timeouts

```elixir
# Different timeouts for different operations
Task.await(db_task, 5_000)      # Database queries
Task.await(api_task, 10_000)    # External APIs
Task.await(file_task, 30_000)   # File operations
```

### 2. Control Concurrency

```elixir
# Don't overwhelm external services
Task.async_stream(requests, &make_request/1,
  max_concurrency: 10,  # Limit concurrent requests
  timeout: 5_000
)
```

### 3. Handle Failures Gracefully

```elixir
tasks
|> Task.await_many(timeout)
|> Enum.map(fn
     {:ok, result} -> result
     {:error, reason} -> default_value  # Graceful degradation
   end)
```

### 4. Use Supervision for Long-running Tasks

```elixir
# For tasks that should be supervised
task = Task.Supervisor.async(MySupervisor, fn ->
  long_running_work()
end)

Task.await(task)
```

## Common Pitfalls

1. **Memory Leaks**: Not awaiting tasks can leave processes hanging
2. **Timeout Errors**: Not setting appropriate timeouts for different operations
3. **Resource Exhaustion**: Creating too many concurrent tasks
4. **Error Propagation**: Not handling individual task failures properly

## Testing Strategy

The test suite covers:
- Parallel execution correctness
- Timeout handling
- Error scenarios and recovery
- Concurrency control
- Performance characteristics
- Integration scenarios

## Alternatives

- **GenServer**: For stateful, long-running processes
- **Agent**: For simple shared state
- **Task.Supervisor**: For supervised task execution
- **Flow**: For complex data processing pipelines
- **Broadway**: For robust data processing with back-pressure

The Task.async pattern is essential for building responsive, efficient Elixir applications that can handle multiple operations concurrently while maintaining fault tolerance and predictable performance.