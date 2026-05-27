defmodule Patterns.ProcessPool do
  @moduledoc """
  Demonstrates a fixed-size worker process pool (mini-Poolboy).

  This pattern showcases:
  - Pre-warmed interchangeable workers
  - Checkout/checkin lifecycle with blocking and timeouts
  - Transaction-style work execution with guaranteed checkin
  - Automatic worker replacement after crashes
  - Pool utilization introspection

  ## Examples

      iex> {:ok, pool} = Patterns.ProcessPool.start(size: 2)
      iex> {:ok, result} = Patterns.ProcessPool.transaction(pool, fn worker ->
      ...>   Patterns.ProcessPool.Worker.process(worker, {:echo, "hello"})
      ...> end)
      iex> result == "hello"

  """

  use Supervisor

  alias Patterns.ProcessPool.Pool
  alias Patterns.ProcessPool.Worker

  @default_size 3
  @default_checkout_timeout 5_000

  @type pool :: pid()
  @type worker :: pid()
  @type job :: term()
  @type result :: term()
  @type transaction_fun :: (worker() -> result())

  @doc """
  Starts a process pool with the configured number of workers.

  ## Options
  - `:size` - Number of workers in the pool (default: #{@default_size})
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Starts an unlinked process pool for testing or embedding.
  """
  @spec start(keyword()) :: {:ok, pool()} | {:error, term()}
  def start(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts) do
      {:ok, supervisor} ->
        Process.unlink(supervisor)
        {:ok, pool_pid(supervisor)}

      error ->
        error
    end
  end

  defp pool_pid(supervisor) do
    supervisor
    |> Supervisor.which_children()
    |> List.keyfind(Patterns.ProcessPool.Pool, 0)
    |> case do
      {Patterns.ProcessPool.Pool, pid, _, _} -> pid
      _ -> raise "pool child not found"
    end
  end

  @doc """
  Checks out a worker from the pool.

  Blocks until a worker is available or the timeout is reached.
  """
  @spec checkout(pool(), timeout()) :: {:ok, worker()} | {:error, :timeout}
  def checkout(pool, timeout \\ @default_checkout_timeout) do
    Pool.checkout(pool, timeout)
  end

  @doc """
  Returns a worker to the pool.
  """
  @spec checkin(pool(), worker()) :: :ok | {:error, :unknown_worker}
  def checkin(pool, worker) do
    Pool.checkin(pool, worker)
  end

  @doc """
  Checks out a worker, runs `fun`, and checks the worker back in.

  The worker is always returned to the pool, even if `fun` raises.
  """
  @spec transaction(pool(), transaction_fun(), timeout()) ::
          {:ok, result()} | {:error, :timeout}
  def transaction(pool, fun, timeout \\ @default_checkout_timeout) when is_function(fun, 1) do
    case checkout(pool, timeout) do
      {:ok, worker} ->
        try do
          {:ok, fun.(worker)}
        after
          checkin(pool, worker)
        end

      {:error, :timeout} = error ->
        error
    end
  end

  @doc """
  Runs a job on a pooled worker via `Worker.process/2`.
  """
  def process(pool, job, timeout \\ @default_checkout_timeout) do
    transaction(pool, &Worker.process(&1, job), timeout)
  end

  @doc """
  Returns pool utilization and worker status.
  """
  @spec info(pool()) :: %{
          size: pos_integer(),
          available_count: non_neg_integer(),
          in_use_count: non_neg_integer(),
          waiting_count: non_neg_integer(),
          workers: [map()]
        }
  def info(pool) do
    Pool.info(pool)
  end

  @impl Supervisor
  def init(opts) do
    size = Keyword.get(opts, :size, @default_size)

    children = [
      {Pool, Keyword.put(opts, :size, size)}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Patterns.ProcessPool.Pool do
  @moduledoc false

  use GenServer

  alias Patterns.ProcessPool.Worker

  @type from :: GenServer.from()

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @spec checkout(GenServer.server(), timeout()) ::
          {:ok, Patterns.ProcessPool.worker()} | {:error, :timeout}
  def checkout(server, timeout) do
    GenServer.call(server, {:checkout, timeout}, timeout + 1_000)
  end

  @spec checkin(GenServer.server(), Patterns.ProcessPool.worker()) ::
          :ok | {:error, :unknown_worker}
  def checkin(server, worker) do
    if Process.alive?(worker) do
      GenServer.call(server, {:checkin, worker})
    else
      GenServer.call(server, {:release, worker})
    end
  end

  @spec info(GenServer.server()) :: map()
  def info(server) do
    GenServer.call(server, :info)
  end

  @impl GenServer
  def init(opts) do
    size = Keyword.get(opts, :size, 3)
    {workers, worker_meta} = create_workers(size)

    monitors =
      Map.new(workers, fn worker ->
        {Process.monitor(worker), worker}
      end)

    state = %{
      size: size,
      next_worker_id: size + 1,
      workers: worker_meta,
      available: :queue.from_list(workers),
      in_use: %{},
      waiting: :queue.new(),
      monitors: monitors
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:checkout, timeout}, from, state) do
    case :queue.out(state.available) do
      {{:value, worker}, available} ->
        {:reply, {:ok, worker}, checkout_worker(state, worker, from, available)}

      {:empty, _} ->
        ref = :erlang.unique_integer([:positive])
        timer = Process.send_after(self(), {:checkout_timeout, ref, from}, timeout)
        waiting = :queue.in({from, ref, timer}, state.waiting)
        {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_call({:checkin, worker}, _from, state) do
    cond do
      Map.has_key?(state.in_use, worker) ->
        {:reply, :ok, return_worker(state, worker)}

      Map.has_key?(state.workers, worker) ->
        {:reply, :ok, state}

      true ->
        {:reply, {:error, :unknown_worker}, state}
    end
  end

  @impl GenServer
  def handle_call({:release, worker}, _from, state) do
    if Map.has_key?(state.in_use, worker) do
      {:reply, :ok, pop_in_use(state, worker) |> fulfill_waiting()}
    else
      {:reply, :ok, state}
    end
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply, pool_info(state), state}
  end

  @impl GenServer
  def handle_info({:checkout_timeout, ref, from}, state) do
    case dequeue_waiting(state.waiting, ref) do
      {nil, _} ->
        {:noreply, state}

      {{^from, ^ref, timer}, waiting} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | waiting: waiting}}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, monitor_ref) do
      {nil, _} ->
        {:noreply, state}

      {crashed_worker, monitors} ->
        {in_use_entry, in_use} = Map.pop(state.in_use, crashed_worker)
        available = :queue.filter(fn w -> w != crashed_worker end, state.available)
        workers = Map.delete(state.workers, crashed_worker)

        state =
          %{state | monitors: monitors, in_use: in_use, available: available, workers: workers}

        # in_use_entry is set when worker was checked out — caller already received {:ok, pid}
        _ = in_use_entry

        {:noreply, replace_worker(state)}
    end
  end

  defp checkout_worker(state, worker, from, available) do
    now = System.monotonic_time(:millisecond)

    %{
      state
      | available: available,
        in_use: Map.put(state.in_use, worker, %{from: from, at: now}),
        workers:
          Map.update!(state.workers, worker, fn meta ->
            %{meta | status: :in_use, checked_out_at: now}
          end)
    }
  end

  defp return_worker(state, worker) do
    if Map.has_key?(state.workers, worker) do
      state
      |> pop_in_use(worker)
      |> assign_available(worker)
      |> fulfill_waiting()
    else
      state
    end
  end

  defp pop_in_use(state, worker) do
    %{state | in_use: Map.delete(state.in_use, worker)}
  end

  defp assign_available(state, worker) do
    %{
      state
      | available: :queue.in(worker, state.available),
        workers:
          Map.update!(state.workers, worker, fn meta ->
            %{meta | status: :available, checked_out_at: nil}
          end)
    }
  end

  defp fulfill_waiting(state) do
    case :queue.out(state.waiting) do
      {{:value, {from, _ref, timer}}, waiting} ->
        case :queue.out(state.available) do
          {{:value, worker}, available} ->
            Process.cancel_timer(timer)
            GenServer.reply(from, {:ok, worker})

            state
            |> Map.put(:waiting, waiting)
            |> checkout_worker(worker, from, available)

          {:empty, _} ->
            state
        end

      {:empty, _} ->
        state
    end
  end

  defp replace_worker(state) do
    id = state.next_worker_id
    {:ok, worker} = Worker.start(id)
    monitor_ref = Process.monitor(worker)

    meta = %{id: id, status: :available, checked_out_at: nil}

    state = %{
      state
      | next_worker_id: id + 1,
        workers: Map.put(state.workers, worker, meta),
        monitors: Map.put(state.monitors, monitor_ref, worker),
        available: :queue.in(worker, state.available)
    }

    fulfill_waiting(state)
  end

  defp create_workers(size) do
    workers =
      for id <- 1..size do
        {:ok, worker} = Worker.start(id)
        worker
      end

    meta =
      Map.new(workers, fn worker ->
        {worker, %{id: Worker.id(worker), status: :available, checked_out_at: nil}}
      end)

    {workers, meta}
  end

  defp pool_info(state) do
    worker_details =
      Enum.map(state.workers, fn {pid, meta} ->
        %{
          pid: pid,
          id: meta.id,
          status: meta.status,
          checked_out_at: meta.checked_out_at,
          alive?: Process.alive?(pid)
        }
      end)
      |> Enum.sort_by(& &1.id)

    %{
      size: state.size,
      available_count: :queue.len(state.available),
      in_use_count: map_size(state.in_use),
      waiting_count: :queue.len(state.waiting),
      workers: worker_details
    }
  end

  defp dequeue_waiting(queue, ref) do
    dequeue_waiting(queue, :queue.new(), ref)
  end

  defp dequeue_waiting(:empty, acc, _ref), do: {nil, acc}

  defp dequeue_waiting(queue, acc, ref) do
    {{:value, {_from, current_ref, _timer} = entry}, rest} = :queue.out(queue)

    if current_ref == ref do
      {entry, :queue.join(acc, rest)}
    else
      dequeue_waiting(rest, :queue.in(entry, acc), ref)
    end
  end
end

defmodule Patterns.ProcessPool.Worker do
  @moduledoc """
  A pooled GenServer worker that processes interchangeable jobs.
  """

  use GenServer

  @dialyzer {:nowarn_function, handle_cast: 2}

  @type worker_id :: pos_integer()
  @type job :: term()

  @spec start_link(worker_id()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  @spec start(worker_id()) :: GenServer.on_start()
  def start(id) do
    GenServer.start(__MODULE__, id)
  end

  @spec process(GenServer.server(), job()) :: term()
  def process(worker, job) do
    GenServer.call(worker, {:process, job})
  end

  @spec id(GenServer.server()) :: worker_id()
  def id(worker) do
    GenServer.call(worker, :id)
  end

  @spec crash(GenServer.server()) :: :ok
  def crash(worker) do
    GenServer.cast(worker, :crash)
  end

  @impl GenServer
  def init(id) do
    {:ok, %{id: id, jobs_processed: 0}}
  end

  @impl GenServer
  def handle_call(:id, _from, %{id: id} = state) do
    {:reply, id, state}
  end

  @impl GenServer
  def handle_call({:process, {:echo, value}}, _from, state) do
    {:reply, value, increment_jobs(state)}
  end

  @impl GenServer
  def handle_call({:process, {:add, a, b}}, _from, state) do
    {:reply, a + b, increment_jobs(state)}
  end

  @impl GenServer
  def handle_call({:process, {:delay, ms}}, _from, state)
      when is_integer(ms) and ms >= 0 do
    Process.sleep(ms)
    {:reply, :done, increment_jobs(state)}
  end

  @impl GenServer
  def handle_call({:process, job}, _from, state) do
    {:reply, {:processed, job}, increment_jobs(state)}
  end

  @impl GenServer
  def handle_cast(:crash, %{id: id}) do
    raise "Worker #{id} crashed intentionally for testing"
  end

  defp increment_jobs(%{jobs_processed: count} = state) do
    %{state | jobs_processed: count + 1}
  end
end
