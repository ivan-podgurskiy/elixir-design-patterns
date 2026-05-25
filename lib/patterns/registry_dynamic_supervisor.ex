defmodule Patterns.RegistryDynamicSupervisor do
  @moduledoc """
  Demonstrates runtime process management with `Registry` and `DynamicSupervisor`.

  This pattern showcases:
  - Unique process registration by key
  - On-demand worker startup and teardown
  - Idempotent process lookup and creation
  - Automatic recovery when workers crash
  - Introspection of the managed process pool

  ## Examples

      iex> {:ok, sup} = Patterns.RegistryDynamicSupervisor.start([])
      iex> {:ok, worker} = Patterns.RegistryDynamicSupervisor.start_worker(sup, "room:lobby")
      iex> {:ok, ^worker} = Patterns.RegistryDynamicSupervisor.lookup(sup, "room:lobby")
      iex> :pong = Patterns.RegistryDynamicSupervisor.call(sup, "room:lobby", :ping)

  """

  use Supervisor

  alias Patterns.RegistryDynamicSupervisor.Worker

  @type worker_key :: term()
  @type worker_info :: %{
          key: worker_key(),
          pid: pid(),
          metadata: term(),
          calls: non_neg_integer(),
          uptime_ms: non_neg_integer()
        }

  @doc """
  Starts the registry and dynamic supervisor tree.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Starts an unlinked supervisor tree for testing or embedding.
  """
  @spec start(keyword()) :: Supervisor.on_start()
  def start(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts) do
      {:ok, pid} = result ->
        Process.unlink(pid)
        result

      error ->
        error
    end
  end

  @doc """
  Starts a worker for the given key, or returns the existing worker if already running.
  """
  @spec start_worker(Supervisor.supervisor(), worker_key()) ::
          {:ok, pid()} | {:error, term()}
  def start_worker(supervisor, key) do
    %{registry: registry, dynamic: dynamic} = components(supervisor)

    case Registry.lookup(registry, key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = Worker.child_spec({key, registry, dynamic})
        DynamicSupervisor.start_child(dynamic, child_spec)
    end
  end

  @doc """
  Stops a worker by key.
  """
  @spec stop_worker(Supervisor.supervisor(), worker_key()) ::
          :ok | {:error, :not_found | term()}
  def stop_worker(supervisor, key) do
    %{registry: registry} = components(supervisor)

    case Registry.lookup(registry, key) do
      [{pid, _}] ->
        GenServer.stop(pid)
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Looks up a worker pid by key.
  """
  @spec lookup(Supervisor.supervisor(), worker_key()) ::
          {:ok, pid()} | {:error, :not_found}
  def lookup(supervisor, key) do
    %{registry: registry} = components(supervisor)

    case Registry.lookup(registry, key) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Sends a synchronous call to a worker, starting it if necessary.
  """
  @spec call(Supervisor.supervisor(), worker_key(), term(), timeout()) ::
          term() | {:error, term()}
  def call(supervisor, key, request, timeout \\ 5000) do
    with {:ok, pid} <- start_worker(supervisor, key) do
      GenServer.call(pid, request, timeout)
    end
  end

  @doc """
  Sends an asynchronous cast to a worker, starting it if necessary.
  """
  @spec cast(Supervisor.supervisor(), worker_key(), term()) ::
          :ok | {:error, term()}
  def cast(supervisor, key, message) do
    with {:ok, pid} <- start_worker(supervisor, key) do
      GenServer.cast(pid, message)
      :ok
    end
  end

  @doc """
  Returns metadata for all registered workers.
  """
  @spec list_workers(Supervisor.supervisor()) :: [worker_info()]
  def list_workers(supervisor) do
    %{registry: registry} = components(supervisor)

    Registry.select(registry, [{{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])
    |> Enum.map(fn {key, pid, metadata} ->
      info =
        if Process.alive?(pid) do
          GenServer.call(pid, :info)
        else
          %{calls: 0, uptime_ms: 0}
        end

      Map.merge(info, %{key: key, pid: pid, metadata: metadata})
    end)
    |> Enum.sort_by(& &1.key)
  end

  @doc """
  Returns the number of registered workers.
  """
  @spec worker_count(Supervisor.supervisor()) :: non_neg_integer()
  def worker_count(supervisor) do
    supervisor
    |> list_workers()
    |> length()
  end

  @doc """
  Returns information about the registry and dynamic supervisor tree.
  """
  @spec info(Supervisor.supervisor()) :: %{
          registry: atom(),
          dynamic_supervisor: atom(),
          worker_count: non_neg_integer(),
          workers: [worker_info()]
        }
  def info(supervisor) do
    %{registry: registry, dynamic: dynamic} = components(supervisor)
    workers = list_workers(supervisor)

    %{
      registry: registry,
      dynamic_supervisor: dynamic,
      worker_count: length(workers),
      workers: workers
    }
  end

  @doc """
  Crashes a worker for testing recovery behavior.
  """
  @spec crash_worker(Supervisor.supervisor(), worker_key()) ::
          :ok | {:error, :not_found}
  def crash_worker(supervisor, key) do
    with {:ok, pid} <- lookup(supervisor, key) do
      Worker.crash(pid)
      :ok
    end
  end

  @impl Supervisor
  def init(_opts) do
    suffix = System.unique_integer([:positive])
    registry = :"#{__MODULE__}.Registry.#{suffix}"
    dynamic = :"#{__MODULE__}.DynamicSupervisor.#{suffix}"

    :persistent_term.put({__MODULE__, self()}, %{registry: registry, dynamic: dynamic})

    children = [
      {Registry, keys: :unique, name: registry},
      {DynamicSupervisor, name: dynamic, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp components(supervisor) do
    :persistent_term.get({__MODULE__, supervisor})
  end
end

defmodule Patterns.RegistryDynamicSupervisor.Worker do
  @moduledoc """
  A GenServer worker that registers itself in a `Registry` on startup.

  Used to demonstrate keyed process lookup with dynamic supervision.
  """

  use GenServer

  @type worker_key :: term()

  @spec child_spec({worker_key(), atom(), atom()}) :: Supervisor.child_spec()
  def child_spec({key, registry, dynamic_supervisor}) do
    %{
      id: key,
      start: {__MODULE__, :start_link, [key, registry, dynamic_supervisor]},
      restart: :transient,
      type: :worker
    }
  end

  @spec start_link(worker_key(), atom(), atom()) :: GenServer.on_start()
  def start_link(key, registry, dynamic_supervisor) do
    GenServer.start_link(__MODULE__, {key, registry, dynamic_supervisor})
  end

  @spec crash(pid()) :: :ok
  def crash(pid) do
    GenServer.cast(pid, :crash)
  end

  @impl GenServer
  def init({key, registry, _dynamic_supervisor}) do
    metadata = %{started_at: System.monotonic_time(:millisecond)}
    Registry.register(registry, key, metadata)
    {:ok, %{key: key, registry: registry, calls: 0, started_at: metadata.started_at}}
  end

  @impl GenServer
  def handle_call(:ping, _from, state) do
    {:reply, :pong, increment_calls(state)}
  end

  @impl GenServer
  def handle_call(:info, _from, state) do
    {:reply, worker_info(state), state}
  end

  @impl GenServer
  def handle_call({:set, value}, _from, state) do
    {:reply, :ok, Map.put(state, :value, value)}
  end

  @impl GenServer
  def handle_call(:get, _from, %{value: value} = state) do
    {:reply, {:ok, value}, state}
  end

  @impl GenServer
  def handle_call(:get, _from, state) do
    {:reply, {:error, :no_value}, state}
  end

  @impl GenServer
  def handle_cast({:set, value}, state) do
    {:noreply, Map.put(state, :value, value)}
  end

  @impl GenServer
  def handle_cast(:crash, state) do
    raise "Worker #{inspect(state.key)} crashed intentionally for testing"
  end

  defp increment_calls(%{calls: calls} = state) do
    %{state | calls: calls + 1}
  end

  defp worker_info(%{key: key, calls: calls, started_at: started_at}) do
    now = System.monotonic_time(:millisecond)

    %{
      key: key,
      calls: calls,
      uptime_ms: now - started_at
    }
  end
end
