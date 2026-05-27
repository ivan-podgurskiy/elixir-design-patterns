defmodule Patterns.ProcessPoolTest do
  use ExUnit.Case, async: false

  alias Patterns.ProcessPool
  alias Patterns.ProcessPool.Worker

  setup do
    {:ok, pool} = ProcessPool.start(size: 2)
    on_exit(fn -> stop_pool(pool) end)
    {:ok, pool: pool}
  end

  describe "pool initialization" do
    test "starts with configured workers", %{pool: pool} do
      info = ProcessPool.info(pool)

      assert info.size == 2
      assert info.available_count == 2
      assert info.in_use_count == 0
      assert info.waiting_count == 0
      assert length(info.workers) == 2
      assert Enum.all?(info.workers, & &1.alive?)
    end
  end

  describe "checkout and checkin" do
    test "checks out and returns workers", %{pool: pool} do
      assert {:ok, worker} = ProcessPool.checkout(pool)
      assert Process.alive?(worker)

      info = ProcessPool.info(pool)
      assert info.available_count == 1
      assert info.in_use_count == 1

      :ok = ProcessPool.checkin(pool, worker)

      info_after = ProcessPool.info(pool)
      assert info_after.available_count == 2
      assert info_after.in_use_count == 0
    end

    test "checkin rejects unknown workers", %{pool: pool} do
      assert {:error, :unknown_worker} = ProcessPool.checkin(pool, self())
    end

    test "exhausted pool blocks until checkin", %{pool: pool} do
      assert {:ok, worker1} = ProcessPool.checkout(pool)
      assert {:ok, worker2} = ProcessPool.checkout(pool)

      parent = self()

      waiter =
        spawn(fn ->
          result = ProcessPool.checkout(pool, 500)
          send(parent, {:checkout_result, result})
        end)

      refute_receive {:checkout_result, _}, 100
      :ok = ProcessPool.checkin(pool, worker1)
      assert_receive {:checkout_result, {:ok, worker3}}, 500
      assert Process.alive?(worker3)

      :ok = ProcessPool.checkin(pool, worker2)
      :ok = ProcessPool.checkin(pool, worker3)

      Process.exit(waiter, :kill)
    end

    test "checkout times out when pool stays exhausted", %{pool: pool} do
      assert {:ok, worker1} = ProcessPool.checkout(pool)
      assert {:ok, worker2} = ProcessPool.checkout(pool)

      assert {:error, :timeout} = ProcessPool.checkout(pool, 50)

      :ok = ProcessPool.checkin(pool, worker1)
      :ok = ProcessPool.checkin(pool, worker2)
    end
  end

  describe "transaction and process" do
    test "transaction runs work and returns worker to pool", %{pool: pool} do
      assert {:ok, "hello"} =
               ProcessPool.transaction(pool, fn worker ->
                 Worker.process(worker, {:echo, "hello"})
               end)

      info = ProcessPool.info(pool)
      assert info.available_count == 2
      assert info.in_use_count == 0
    end

    test "process helper delegates to workers", %{pool: pool} do
      assert {:ok, 5} = ProcessPool.process(pool, {:add, 2, 3})
    end

    test "transaction returns worker after raised errors", %{pool: pool} do
      assert_raise RuntimeError, "boom", fn ->
        ProcessPool.transaction(pool, fn _worker ->
          raise "boom"
        end)
      end

      info = ProcessPool.info(pool)
      assert info.available_count == 2
    end
  end

  describe "concurrency" do
    test "handles parallel transactions up to pool size", %{pool: pool} do
      parent = self()

      tasks =
        for index <- 1..2 do
          Task.async(fn ->
            result = ProcessPool.process(pool, {:echo, index})
            send(parent, {:done, index})
            result
          end)
        end

      assert_receive {:done, 1}, 1000
      assert_receive {:done, 2}, 1000

      results = Enum.map(tasks, &Task.await/1)
      assert Enum.sort(results) == [{:ok, 1}, {:ok, 2}]

      info = ProcessPool.info(pool)
      assert info.available_count == 2
    end
  end

  describe "fault tolerance" do
    test "replaces crashed workers and restores pool capacity", %{pool: pool} do
      assert {:ok, worker} = ProcessPool.checkout(pool)
      Worker.crash(worker)

      assert_eventually(fn ->
        info = ProcessPool.info(pool)

        if info.available_count == 2 and info.in_use_count == 0 and
             Enum.count(info.workers, & &1.alive?) == 2 do
          :ok
        else
          {:error, info}
        end
      end)
    end

    test "transaction propagates error when checked-out worker crashes", %{pool: pool} do
      assert catch_exit(
               ProcessPool.transaction(pool, fn worker ->
                 Worker.crash(worker)
                 Process.sleep(10)
                 Worker.process(worker, {:echo, "late"})
               end)
             )

      assert_eventually(fn ->
        info = ProcessPool.info(pool)
        if info.available_count == 2, do: :ok, else: {:error, info}
      end)
    end
  end

  defp stop_pool(pool) do
    case Process.info(pool, :parent) do
      {:parent, parent} when is_pid(parent) ->
        if Process.alive?(parent), do: Supervisor.stop(parent, :normal, 5000)

      _ ->
        if Process.alive?(pool), do: GenServer.stop(pool)
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
