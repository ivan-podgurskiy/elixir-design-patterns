defmodule Patterns.SupervisorTreeTest do
  use ExUnit.Case, async: false
  alias Patterns.SupervisorTree

  describe "supervisor initialization" do
    test "starts with one_for_one strategy" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)

      info = SupervisorTree.info(sup)
      assert info.strategy == :one_for_one
      assert info.running_count == 3
      assert info.specs_count == 3

      # Clean up
      Supervisor.stop(sup)
    end

    test "starts with one_for_all strategy" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_all)

      info = SupervisorTree.info(sup)
      assert info.strategy == :one_for_all
      assert info.running_count == 3

      Supervisor.stop(sup)
    end

    test "starts with rest_for_one strategy" do
      {:ok, sup} = SupervisorTree.start_link(:rest_for_one)

      info = SupervisorTree.info(sup)
      assert info.strategy == :rest_for_one
      assert info.running_count == 3

      Supervisor.stop(sup)
    end
  end

  describe "child management" do
    setup do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)
      on_exit(fn -> Supervisor.stop(sup) end)
      {:ok, supervisor: sup}
    end

    test "adds dynamic children", %{supervisor: sup} do
      initial_info = SupervisorTree.info(sup)
      assert initial_info.running_count == 3

      {:ok, _pid} = SupervisorTree.add_child(sup, :worker, :dynamic_worker_1)

      updated_info = SupervisorTree.info(sup)
      assert updated_info.running_count == 4
      assert updated_info.specs_count == 4

      # Verify the child exists
      dynamic_child = Enum.find(updated_info.children, &(&1.id == :dynamic_worker_1))
      assert dynamic_child
      assert dynamic_child.alive?
    end

    test "removes children", %{supervisor: sup} do
      {:ok, _pid} = SupervisorTree.add_child(sup, :worker, :removable_worker)

      # Verify child was added
      info_after_add = SupervisorTree.info(sup)
      assert info_after_add.running_count == 4

      # Remove the child
      :ok = SupervisorTree.remove_child(sup, :removable_worker)

      # Verify child was removed
      info_after_remove = SupervisorTree.info(sup)
      assert info_after_remove.running_count == 3
      assert info_after_remove.specs_count == 3

      removable_child = Enum.find(info_after_remove.children, &(&1.id == :removable_worker))
      refute removable_child
    end

    test "handles removing non-existent children", %{supervisor: sup} do
      result = SupervisorTree.remove_child(sup, :non_existent)
      assert {:error, :not_found} = result
    end
  end

  describe "worker interaction" do
    setup do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)
      on_exit(fn -> Supervisor.stop(sup) end)
      {:ok, supervisor: sup}
    end

    test "can communicate with workers", %{supervisor: sup} do
      info = SupervisorTree.info(sup)
      worker_pid = get_worker_pid(info.children, :worker_1)

      status = DemoWorker.get_status(worker_pid)
      assert %{id: :worker_1, uptime: uptime} = status
      assert uptime >= 0

      :pong = DemoWorker.ping(worker_pid)
    end
  end

  describe "supervision strategies" do
    test "one_for_one: only crashed child restarts" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)
      on_exit(fn -> Supervisor.stop(sup) end)

      # Get initial PIDs
      initial_info = SupervisorTree.info(sup)
      worker_1_pid = get_worker_pid(initial_info.children, :worker_1)
      worker_2_pid = get_worker_pid(initial_info.children, :worker_2)

      # Crash worker_1
      :ok = SupervisorTree.crash_child(sup, :worker_1)

      # Give time for restart
      Process.sleep(50)

      # Check that only worker_1 has a new PID
      updated_info = SupervisorTree.info(sup)
      new_worker_1_pid = get_worker_pid(updated_info.children, :worker_1)
      new_worker_2_pid = get_worker_pid(updated_info.children, :worker_2)

      # worker_1 restarted
      assert worker_1_pid != new_worker_1_pid
      # worker_2 unchanged
      assert worker_2_pid == new_worker_2_pid

      # All children should still be running
      assert updated_info.running_count == 3
    end

    test "one_for_all: all children restart when one fails" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_all)
      on_exit(fn -> Supervisor.stop(sup) end)

      # Get initial PIDs
      initial_info = SupervisorTree.info(sup)
      worker_1_pid = get_worker_pid(initial_info.children, :worker_1)
      worker_2_pid = get_worker_pid(initial_info.children, :worker_2)

      # Crash worker_1
      :ok = SupervisorTree.crash_child(sup, :worker_1)

      # Give time for restart
      Process.sleep(50)

      # Check that all workers have new PIDs
      updated_info = SupervisorTree.info(sup)
      new_worker_1_pid = get_worker_pid(updated_info.children, :worker_1)
      new_worker_2_pid = get_worker_pid(updated_info.children, :worker_2)

      # worker_1 restarted
      assert worker_1_pid != new_worker_1_pid
      # worker_2 also restarted
      assert worker_2_pid != new_worker_2_pid

      # All children should still be running
      assert updated_info.running_count == 3
    end

    test "temporary worker is not restarted" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)
      on_exit(fn -> Supervisor.stop(sup) end)

      # Get initial info - temp_worker should be running
      initial_info = SupervisorTree.info(sup)
      assert initial_info.running_count == 3

      temp_worker_pid = get_worker_pid(initial_info.children, :temp_worker)
      assert temp_worker_pid

      # Crash the temporary worker
      :ok = SupervisorTree.crash_child(sup, :temp_worker)

      # Give time for supervisor to handle the crash
      Process.sleep(50)

      # Temporary worker should not be restarted
      updated_info = SupervisorTree.info(sup)
      assert updated_info.running_count == 2

      temp_worker_after = Enum.find(updated_info.children, &(&1.id == :temp_worker))
      refute temp_worker_after || temp_worker_after.alive?
    end
  end

  describe "supervisor introspection" do
    test "provides detailed information about children" do
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)
      on_exit(fn -> Supervisor.stop(sup) end)

      info = SupervisorTree.info(sup)

      assert %{
               strategy: :one_for_one,
               children: children,
               running_count: 3,
               specs_count: 3
             } = info

      assert length(children) == 3

      # Check that all expected children are present
      child_ids = Enum.map(children, & &1.id)
      assert :worker_1 in child_ids
      assert :worker_2 in child_ids
      assert :temp_worker in child_ids

      # Check that all children have expected properties
      for child <- children do
        assert Map.has_key?(child, :id)
        assert Map.has_key?(child, :pid)
        assert Map.has_key?(child, :type)
        assert Map.has_key?(child, :modules)
        assert Map.has_key?(child, :alive?)
        assert child.alive?
        assert child.type == :worker
      end
    end
  end

  describe "restart limits" do
    test "supervisor shuts down after exceeding restart limits" do
      # This test demonstrates that the supervisor will shut down if
      # restart limits are exceeded. We use a FailingWorker for this.
      {:ok, sup} = SupervisorTree.start_link(:one_for_one)

      # Add a failing worker that will continuously crash
      {:ok, _pid} = SupervisorTree.add_child(sup, :failing_worker, :failing_1)

      # The supervisor should eventually shut down due to restart limits
      # We'll monitor the supervisor process
      ref = Process.monitor(sup)

      # Wait for supervisor shutdown (this might take a few seconds)
      receive do
        {:DOWN, ^ref, :process, ^sup, reason} ->
          assert reason == :shutdown
      after
        10_000 ->
          # Clean up if test times out
          Supervisor.stop(sup)
          flunk("Supervisor did not shut down within expected time")
      end
    end
  end

  # Helper functions

  defp get_worker_pid(children, worker_id) do
    case Enum.find(children, &(&1.id == worker_id)) do
      %{pid: pid} when is_pid(pid) -> pid
      _ -> nil
    end
  end
end
