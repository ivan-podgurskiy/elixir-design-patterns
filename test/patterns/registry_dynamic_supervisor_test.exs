defmodule Patterns.RegistryDynamicSupervisorTest do
  use ExUnit.Case, async: false

  alias Patterns.RegistryDynamicSupervisor

  setup do
    {:ok, supervisor} = RegistryDynamicSupervisor.start()
    on_exit(fn -> stop_supervisor(supervisor) end)
    {:ok, supervisor: supervisor}
  end

  describe "supervisor initialization" do
    test "starts registry and dynamic supervisor", %{supervisor: supervisor} do
      info = RegistryDynamicSupervisor.info(supervisor)

      assert is_atom(info.registry)
      assert is_atom(info.dynamic_supervisor)
      assert info.worker_count == 0
      assert info.workers == []
    end
  end

  describe "worker lifecycle" do
    test "starts and looks up a worker by key", %{supervisor: supervisor} do
      assert {:ok, worker} = RegistryDynamicSupervisor.start_worker(supervisor, "user:1")
      assert is_pid(worker)
      assert Process.alive?(worker)

      assert {:ok, ^worker} = RegistryDynamicSupervisor.lookup(supervisor, "user:1")
      assert RegistryDynamicSupervisor.worker_count(supervisor) == 1
    end

    test "start_worker is idempotent", %{supervisor: supervisor} do
      {:ok, worker1} = RegistryDynamicSupervisor.start_worker(supervisor, "session:abc")
      {:ok, worker2} = RegistryDynamicSupervisor.start_worker(supervisor, "session:abc")

      assert worker1 == worker2
      assert RegistryDynamicSupervisor.worker_count(supervisor) == 1
    end

    test "stop_worker removes the worker", %{supervisor: supervisor} do
      {:ok, worker} = RegistryDynamicSupervisor.start_worker(supervisor, "room:lobby")
      assert Process.alive?(worker)

      :ok = RegistryDynamicSupervisor.stop_worker(supervisor, "room:lobby")

      assert {:error, :not_found} = RegistryDynamicSupervisor.lookup(supervisor, "room:lobby")
      refute Process.alive?(worker)
      assert RegistryDynamicSupervisor.worker_count(supervisor) == 0
    end

    test "stop_worker returns not_found for missing key", %{supervisor: supervisor} do
      assert {:error, :not_found} =
               RegistryDynamicSupervisor.stop_worker(supervisor, "missing")
    end

    test "manages multiple workers independently", %{supervisor: supervisor} do
      {:ok, worker1} = RegistryDynamicSupervisor.start_worker(supervisor, "shard:1")
      {:ok, worker2} = RegistryDynamicSupervisor.start_worker(supervisor, "shard:2")

      refute worker1 == worker2
      assert RegistryDynamicSupervisor.worker_count(supervisor) == 2

      workers = RegistryDynamicSupervisor.list_workers(supervisor)
      keys = Enum.map(workers, & &1.key)
      assert "shard:1" in keys
      assert "shard:2" in keys
    end
  end

  describe "worker communication" do
    test "call starts worker on demand and returns response", %{supervisor: supervisor} do
      assert :pong = RegistryDynamicSupervisor.call(supervisor, "on-demand", :ping)
      assert {:ok, _pid} = RegistryDynamicSupervisor.lookup(supervisor, "on-demand")
    end

    test "call tracks worker call count", %{supervisor: supervisor} do
      :pong = RegistryDynamicSupervisor.call(supervisor, "counter", :ping)
      :pong = RegistryDynamicSupervisor.call(supervisor, "counter", :ping)

      [worker] = RegistryDynamicSupervisor.list_workers(supervisor)
      assert worker.key == "counter"
      assert worker.calls == 2
    end

    test "cast delivers messages asynchronously", %{supervisor: supervisor} do
      {:ok, _worker} = RegistryDynamicSupervisor.start_worker(supervisor, "cast-target")
      :ok = RegistryDynamicSupervisor.cast(supervisor, "cast-target", {:set, "hello"})
      assert {:ok, "hello"} = RegistryDynamicSupervisor.call(supervisor, "cast-target", :get)
    end
  end

  describe "fault tolerance" do
    test "crashed worker is restarted and re-registered", %{supervisor: supervisor} do
      {:ok, worker} = RegistryDynamicSupervisor.start_worker(supervisor, "fragile")
      ref = Process.monitor(worker)

      :ok = RegistryDynamicSupervisor.crash_worker(supervisor, "fragile")

      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1000

      assert_eventually(fn ->
        case RegistryDynamicSupervisor.lookup(supervisor, "fragile") do
          {:ok, new_worker} when new_worker != worker -> :ok
          _ -> {:error, :not_restarted}
        end
      end)

      assert :pong = RegistryDynamicSupervisor.call(supervisor, "fragile", :ping)
    end
  end

  defp stop_supervisor(supervisor) do
    if Process.alive?(supervisor) do
      Supervisor.stop(supervisor, :normal, 5000)
    end
  end

  defp assert_eventually(fun, attempts \\ 20) do
    case fun.() do
      :ok ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(50)
        assert_eventually(fun, attempts - 1)

      result ->
        flunk("condition not met: #{inspect(result)}")
    end
  end
end
