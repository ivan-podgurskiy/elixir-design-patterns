defmodule Patterns.CircuitBreaker do
  @moduledoc """
  Demonstrates the circuit breaker pattern for protecting calls to unreliable services.

  A circuit breaker wraps a risky operation and tracks its failures. When failures
  exceed a threshold, the breaker "trips" and fails fast for a cooldown period,
  giving the downstream service time to recover instead of being hammered with
  doomed requests.

  This pattern showcases:
  - The three-state machine: `:closed`, `:open`, `:half_open`
  - Failure-threshold tripping in the closed state
  - Fail-fast behaviour in the open state
  - Probationary recovery via the half-open state
  - Call timeouts and configurable failure classification

  ## States

  - **`:closed`** — Calls pass through. Consecutive failures are counted; reaching
    `failure_threshold` trips the breaker to `:open`.
  - **`:open`** — Calls fail immediately with `{:error, :circuit_open}`. After
    `reset_timeout` milliseconds the breaker moves to `:half_open`.
  - **`:half_open`** — A limited number of trial calls are allowed. `success_threshold`
    consecutive successes close the breaker; any failure re-opens it.

  ## Examples

      iex> {:ok, breaker} = Patterns.CircuitBreaker.start_link(failure_threshold: 2)
      iex> Patterns.CircuitBreaker.call(breaker, fn -> {:ok, 42} end)
      {:ok, 42}
      iex> Patterns.CircuitBreaker.state(breaker)
      :closed

  """

  use GenServer

  @default_failure_threshold 5
  @default_success_threshold 2
  @default_reset_timeout 5_000
  @default_call_timeout 5_000

  @type breaker_state :: :closed | :open | :half_open
  @type call_result :: {:ok, term()} | {:error, term()}
  @type stats :: %{
          state: breaker_state(),
          failure_count: non_neg_integer(),
          success_count: non_neg_integer(),
          total_calls: non_neg_integer(),
          total_failures: non_neg_integer(),
          total_successes: non_neg_integer(),
          total_rejected: non_neg_integer()
        }

  @doc """
  Starts a circuit breaker.

  ## Options
  - `:failure_threshold` - Consecutive failures before tripping (default: #{@default_failure_threshold})
  - `:success_threshold` - Consecutive successes in half-open before closing (default: #{@default_success_threshold})
  - `:reset_timeout` - Milliseconds to stay open before trialing recovery (default: #{@default_reset_timeout})
  - `:call_timeout` - Milliseconds to wait for a wrapped call (default: #{@default_call_timeout})
  - `:name` - Optional registered name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Executes `fun` through the circuit breaker.

  Returns the function's result when the breaker is closed or half-open and the
  call succeeds. Returns `{:error, :circuit_open}` when the breaker is open, or
  `{:error, {:exception, reason}}` / `{:error, :timeout}` when the call fails.

  A call is considered successful unless it raises, exits, times out, or returns
  a value matching the configured failure predicate (`{:error, _}` by default).
  """
  @spec call(GenServer.server(), (-> term()), timeout()) :: term() | {:error, term()}
  def call(breaker, fun, timeout \\ @default_call_timeout) when is_function(fun, 0) do
    case GenServer.call(breaker, :request_permission, timeout) do
      {:ok, predicate} ->
        run_and_report(breaker, fun, predicate, timeout)

      {:error, :circuit_open} = rejected ->
        rejected
    end
  end

  @doc """
  Returns the current breaker state.
  """
  @spec state(GenServer.server()) :: breaker_state()
  def state(breaker) do
    GenServer.call(breaker, :state)
  end

  @doc """
  Returns breaker statistics and counters.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(breaker) do
    GenServer.call(breaker, :stats)
  end

  @doc """
  Forces the breaker back to the closed state and clears counters.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(breaker) do
    GenServer.call(breaker, :reset)
  end

  @doc """
  Forces the breaker into the open state.
  """
  @spec trip(GenServer.server()) :: :ok
  def trip(breaker) do
    GenServer.call(breaker, :trip)
  end

  # Internal: run the protected function and report the outcome to the breaker.

  defp run_and_report(breaker, fun, predicate, timeout) do
    parent = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        outcome =
          try do
            {:returned, fun.()}
          rescue
            exception -> {:raised, exception}
          catch
            kind, reason -> {:caught, kind, reason}
          end

        send(parent, {ref, outcome})
      end)

    receive do
      {^ref, {:returned, value}} ->
        Process.demonitor(monitor_ref, [:flush])
        report(breaker, predicate, value)

      {^ref, {:raised, exception}} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.cast(breaker, :failure)
        {:error, {:exception, exception}}

      {^ref, {:caught, kind, reason}} ->
        Process.demonitor(monitor_ref, [:flush])
        GenServer.cast(breaker, :failure)
        {:error, {kind, reason}}

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        GenServer.cast(breaker, :failure)
        {:error, {:exception, reason}}
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        GenServer.cast(breaker, :failure)
        {:error, :timeout}
    end
  end

  defp report(breaker, predicate, value) do
    if predicate.(value) do
      GenServer.cast(breaker, :failure)
    else
      GenServer.cast(breaker, :success)
    end

    value
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    state = %{
      circuit_state: :closed,
      failure_threshold: Keyword.get(opts, :failure_threshold, @default_failure_threshold),
      success_threshold: Keyword.get(opts, :success_threshold, @default_success_threshold),
      reset_timeout: Keyword.get(opts, :reset_timeout, @default_reset_timeout),
      failure_predicate: Keyword.get(opts, :failure_predicate, &default_failure_predicate/1),
      failure_count: 0,
      success_count: 0,
      open_timer: nil,
      total_calls: 0,
      total_failures: 0,
      total_successes: 0,
      total_rejected: 0
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:request_permission, _from, state) do
    case state.circuit_state do
      :open ->
        {:reply, {:error, :circuit_open}, %{state | total_rejected: state.total_rejected + 1}}

      _ ->
        {:reply, {:ok, state.failure_predicate}, %{state | total_calls: state.total_calls + 1}}
    end
  end

  @impl GenServer
  def handle_call(:state, _from, state) do
    {:reply, state.circuit_state, state}
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, build_stats(state), state}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    {:reply, :ok, to_closed(cancel_timer(state))}
  end

  @impl GenServer
  def handle_call(:trip, _from, state) do
    {:reply, :ok, to_open(state)}
  end

  @impl GenServer
  def handle_cast(:success, state) do
    {:noreply, record_success(state)}
  end

  @impl GenServer
  def handle_cast(:failure, state) do
    {:noreply, record_failure(state)}
  end

  @impl GenServer
  def handle_info(:attempt_reset, %{circuit_state: :open} = state) do
    {:noreply, to_half_open(%{state | open_timer: nil})}
  end

  @impl GenServer
  def handle_info(:attempt_reset, state) do
    {:noreply, %{state | open_timer: nil}}
  end

  # State transitions

  defp record_success(%{circuit_state: :half_open} = state) do
    success_count = state.success_count + 1

    state = %{
      state
      | success_count: success_count,
        total_successes: state.total_successes + 1
    }

    if success_count >= state.success_threshold do
      to_closed(state)
    else
      state
    end
  end

  defp record_success(state) do
    %{
      state
      | failure_count: 0,
        total_successes: state.total_successes + 1
    }
  end

  defp record_failure(%{circuit_state: :half_open} = state) do
    to_open(%{state | total_failures: state.total_failures + 1})
  end

  defp record_failure(%{circuit_state: :closed} = state) do
    failure_count = state.failure_count + 1

    state = %{
      state
      | failure_count: failure_count,
        total_failures: state.total_failures + 1
    }

    if failure_count >= state.failure_threshold do
      to_open(state)
    else
      state
    end
  end

  defp record_failure(state) do
    %{state | total_failures: state.total_failures + 1}
  end

  defp to_open(state) do
    state = cancel_timer(state)
    timer = Process.send_after(self(), :attempt_reset, state.reset_timeout)

    %{
      state
      | circuit_state: :open,
        failure_count: 0,
        success_count: 0,
        open_timer: timer
    }
  end

  defp to_half_open(state) do
    %{state | circuit_state: :half_open, failure_count: 0, success_count: 0}
  end

  defp to_closed(state) do
    %{state | circuit_state: :closed, failure_count: 0, success_count: 0}
  end

  defp cancel_timer(%{open_timer: nil} = state), do: state

  defp cancel_timer(%{open_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | open_timer: nil}
  end

  defp build_stats(state) do
    %{
      state: state.circuit_state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      total_calls: state.total_calls,
      total_failures: state.total_failures,
      total_successes: state.total_successes,
      total_rejected: state.total_rejected
    }
  end

  defp default_failure_predicate({:error, _}), do: true
  defp default_failure_predicate(:error), do: true
  defp default_failure_predicate(_), do: false
end
