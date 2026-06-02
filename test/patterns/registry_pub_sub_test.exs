defmodule Patterns.RegistryPubSubTest do
  use ExUnit.Case, async: false

  alias Patterns.RegistryPubSub
  alias Patterns.RegistryPubSub.Subscriber

  setup do
    {:ok, supervisor} = RegistryPubSub.start()
    on_exit(fn -> stop_supervisor(supervisor) end)
    {:ok, supervisor: supervisor}
  end

  describe "supervisor initialization" do
    test "starts with an empty duplicate-key registry", %{supervisor: supervisor} do
      info = RegistryPubSub.info(supervisor)

      assert is_atom(info.registry)
      assert info.topic_count == 0
      assert info.subscriber_count == 0
      assert info.topics == []
    end
  end

  describe "subscribe and publish" do
    test "delivers messages to the calling process", %{supervisor: supervisor} do
      :ok = RegistryPubSub.subscribe(supervisor, "orders.created")

      assert {:ok, 1} = RegistryPubSub.publish(supervisor, "orders.created", %{id: 1})
      assert_receive {:pubsub, "orders.created", %{id: 1}}

      :ok = RegistryPubSub.unsubscribe(supervisor, "orders.created")
    end

    test "subscribe is idempotent for the same process", %{supervisor: supervisor} do
      :ok = RegistryPubSub.subscribe(supervisor, "events")
      :ok = RegistryPubSub.subscribe(supervisor, "events")

      assert RegistryPubSub.subscriber_count(supervisor, "events") == 1
      :ok = RegistryPubSub.unsubscribe(supervisor, "events")
    end

    test "fan-out delivers to multiple subscribers", %{supervisor: supervisor} do
      parent = self()

      subscriber_pids =
        for index <- 1..3 do
          spawn(fn ->
            RegistryPubSub.subscribe(supervisor, "notifications")
            send(parent, {:ready, self(), index})

            receive do
              {:pubsub, "notifications", :broadcast} -> send(parent, {:received, index})
            end
          end)
        end

      for _ <- subscriber_pids, do: assert_receive({:ready, _, _})

      assert {:ok, 3} = RegistryPubSub.publish(supervisor, "notifications", :broadcast)

      for index <- 1..3, do: assert_receive({:received, ^index})

      Enum.each(subscriber_pids, &RegistryPubSub.unsubscribe(supervisor, "notifications", &1))
    end

    test "publish returns zero when no subscribers exist", %{supervisor: supervisor} do
      assert {:ok, 0} = RegistryPubSub.publish(supervisor, "empty.topic", :hello)
    end

    test "unsubscribe stops delivery", %{supervisor: supervisor} do
      :ok = RegistryPubSub.subscribe(supervisor, "updates")
      :ok = RegistryPubSub.unsubscribe(supervisor, "updates")

      assert {:ok, 0} = RegistryPubSub.publish(supervisor, "updates", :missed)
      refute_receive {:pubsub, "updates", :missed}, 50
    end
  end

  describe "introspection" do
    test "lists subscribers and topics", %{supervisor: supervisor} do
      {:ok, sub1} = Subscriber.start_link(supervisor, "metrics")
      {:ok, sub2} = Subscriber.start_link(supervisor, "metrics")
      {:ok, _sub3} = Subscriber.start_link(supervisor, "alerts")

      assert RegistryPubSub.subscriber_count(supervisor, "metrics") == 2
      assert RegistryPubSub.subscriber_count(supervisor, "alerts") == 1
      assert RegistryPubSub.topics(supervisor) == ["alerts", "metrics"]

      subscribers = RegistryPubSub.subscribers(supervisor, "metrics")
      assert length(subscribers) == 2
      assert Enum.all?(subscribers, &(&1.topic == "metrics"))

      info = RegistryPubSub.info(supervisor)
      assert info.topic_count == 2
      assert info.subscriber_count == 3
      assert {"alerts", 1} in info.topics
      assert {"metrics", 2} in info.topics

      GenServer.stop(sub1)
      GenServer.stop(sub2)
    end
  end

  describe "Subscriber helper" do
    test "collects published messages", %{supervisor: supervisor} do
      {:ok, subscriber} = Subscriber.start_link(supervisor, "inventory")

      assert {:ok, 1} = RegistryPubSub.publish(supervisor, "inventory", %{sku: "ABC"})
      assert {:ok, 1} = RegistryPubSub.publish(supervisor, "inventory", %{sku: "XYZ"})

      assert Subscriber.messages(subscriber) == [
               {"inventory", %{sku: "ABC"}},
               {"inventory", %{sku: "XYZ"}}
             ]

      :ok = Subscriber.flush(subscriber)
      assert Subscriber.messages(subscriber) == []

      GenServer.stop(subscriber)
    end
  end

  describe "fault tolerance" do
    test "crashed subscribers are automatically unregistered", %{supervisor: supervisor} do
      {:ok, subscriber} = Subscriber.start(supervisor, "volatile")
      ref = Process.monitor(subscriber)

      assert RegistryPubSub.subscriber_count(supervisor, "volatile") == 1

      Process.exit(subscriber, :kill)
      assert_receive {:DOWN, ^ref, :process, ^subscriber, :killed}

      # Registry unregistration is asynchronous after process exit.
      assert_eventually(fn ->
        if RegistryPubSub.subscriber_count(supervisor, "volatile") == 0 and
             RegistryPubSub.topics(supervisor) == [] do
          :ok
        else
          {:error, :not_unregistered}
        end
      end)
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
