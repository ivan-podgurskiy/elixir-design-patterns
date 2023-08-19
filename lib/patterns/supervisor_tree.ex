defmodule Patterns.SupervisorTree do
  @moduledoc """
  Demonstrates different supervision strategies and child specifications in OTP.

  This pattern showcases:
  - One-for-one supervision strategy
  - One-for-all supervision strategy
  - Rest-for-one supervision strategy
  - Dynamic child specifications
  - Supervision tree introspection

  ## Supervision Strategies

  - **One-for-one**: Only the failed child is restarted
  - **One-for-all**: All children are restarted when any child fails
  - **Rest-for-one**: The failed child and all children started after it are restarted

  ## Examples

      iex> {:ok, pid} = Patterns.SupervisorTree.start_link(:one_for_one)
      iex> children = Supervisor.which_children(pid)
      iex> length(children) == 3

  """

  use Supervisor

  @type strategy :: :one_for_one | :one_for_all | :rest_for_one
  @type child_type :: :worker | :temporary_worker | :failing_worker

  @doc """
  Starts the supervisor with the specified strategy.
  """
  @spec start_link(strategy()) :: Supervisor.on_start()
  def start_link(strategy) do
    Supervisor.start_link(__MODULE__, strategy)
  end

  @doc """
  Adds a dynamic child to the running supervisor.
  """
  @spec add_child(pid(), child_type(), term()) :: Supervisor.on_start_child()
  def add_child(supervisor, type, id) do
    child_spec = build_child_spec(type, id)
    Supervisor.start_child(supervisor, child_spec)
  end

  @doc """
  Removes a child from the supervisor.
  """
  @spec remove_child(pid(), term()) :: :ok | {:error, :not_found}
  def remove_child(supervisor, id) do
    case Supervisor.terminate_child(supervisor, id) do
      :ok -> Supervisor.delete_child(supervisor, id)
      error -> error
    end
  end

  @doc """
  Restarts a specific child.
  """
  @spec restart_child(pid(), term()) :: {:ok, pid()} | {:error, term()}
  def restart_child(supervisor, id) do
    Supervisor.restart_child(supervisor, id)
  end

  @doc """
  Gets information about the supervisor and its children.
  """
  @spec info(pid()) :: %{
          strategy: atom(),
          children: [map()],
          running_count: non_neg_integer(),
          specs_count: non_neg_integer()
        }
  def info(supervisor) do
    children = Supervisor.which_children(supervisor)
    running_count = Supervisor.count_children(supervisor)

    child_info =
      Enum.map(children, fn {id, pid, type, modules} ->
        %{
          id: id,
          pid: pid,
          type: type,
          modules: modules,
          alive?: is_pid(pid) and Process.alive?(pid)
        }
      end)

    %{
      strategy: get_strategy(supervisor),
      children: child_info,
      running_count: running_count[:active],
      specs_count: running_count[:specs]
    }
  end

  @doc """
  Causes a specific worker to crash for testing supervision behavior.
  """
  @spec crash_child(pid(), term()) :: :ok | {:error, :not_found}
  def crash_child(supervisor, child_id) do
    children = Supervisor.which_children(supervisor)

    case List.keyfind(children, child_id, 0) do
      {^child_id, pid, :worker, _} when is_pid(pid) ->
        DemoWorker.crash(pid)
        :ok

      _ ->
        {:error, :not_found}
    end
  end

  # Supervisor Callbacks

  @impl Supervisor
  def init(strategy) do
    children = [
      build_child_spec(:worker, :worker_1),
      build_child_spec(:worker, :worker_2),
      build_child_spec(:temporary_worker, :temp_worker)
    ]

    opts = [
      strategy: strategy,
      max_restarts: 3,
      max_seconds: 5
    ]

    Supervisor.init(children, opts)
  end

  # Private Functions

  @spec build_child_spec(child_type(), term()) :: Supervisor.child_spec()
  defp build_child_spec(:worker, id) do
    %{
      id: id,
      start: {DemoWorker, :start_link, [id]},
      restart: :permanent,
      type: :worker
    }
  end

  defp build_child_spec(:temporary_worker, id) do
    %{
      id: id,
      start: {DemoWorker, :start_link, [id]},
      restart: :temporary,
      type: :worker
    }
  end

  defp build_child_spec(:failing_worker, id) do
    %{
      id: id,
      start: {FailingWorker, :start_link, [id]},
      restart: :permanent,
      type: :worker
    }
  end

  defp get_strategy(supervisor) do
    case :supervisor.get_childspec(supervisor, :supervisor) do
      {:ok, {_, {_, _, _, opts}}} -> Keyword.get(opts, :strategy, :one_for_one)
      _ -> :unknown
    end
  catch
    :exit, _ -> :one_for_one
  end
end

defmodule DemoWorker do
  @moduledoc """
  A simple GenServer worker for demonstration purposes.
  """

  use GenServer

  @type worker_id :: term()

  @spec start_link(worker_id()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  @spec get_status(pid()) :: %{id: worker_id(), uptime: non_neg_integer()}
  def get_status(pid) do
    GenServer.call(pid, :get_status)
  end

  @spec crash(pid()) :: :ok
  def crash(pid) do
    GenServer.cast(pid, :crash)
  end

  @spec ping(pid()) :: :pong
  def ping(pid) do
    GenServer.call(pid, :ping)
  end

  # GenServer Callbacks

  @impl GenServer
  def init(id) do
    state = %{id: id, start_time: System.monotonic_time(:second)}
    {:ok, state}
  end

  @impl GenServer
  def handle_call(:get_status, _from, %{id: id, start_time: start_time} = state) do
    uptime = System.monotonic_time(:second) - start_time
    status = %{id: id, uptime: uptime}
    {:reply, status, state}
  end

  @impl GenServer
  def handle_call(:ping, _from, state) do
    {:reply, :pong, state}
  end

  @impl GenServer
  def handle_cast(:crash, state) do
    raise "Worker #{state.id} crashed intentionally for testing"
  end
end

defmodule FailingWorker do
  @moduledoc """
  A worker that fails immediately on startup for testing supervision strategies.
  """

  use GenServer

  @type worker_id :: term()

  @spec start_link(worker_id()) :: GenServer.on_start()
  def start_link(id) do
    GenServer.start_link(__MODULE__, id)
  end

  @impl GenServer
  def init(id) do
    Process.send_after(self(), :fail, 100)
    {:ok, %{id: id}}
  end

  @impl GenServer
  def handle_info(:fail, state) do
    raise "FailingWorker #{state.id} failed as expected"
  end
end
