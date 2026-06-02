defmodule Patterns.BehaviourProtocolTest do
  use ExUnit.Case, async: true

  doctest Patterns.BehaviourProtocol

  alias Patterns.BehaviourProtocol

  alias Patterns.BehaviourProtocol.{
    Alert,
    CollectorChannel,
    ConsoleChannel,
    Deploy,
    FailingChannel,
    Notification
  }

  describe "Notification protocol (dispatch by data type)" do
    test "renders an Alert without a message" do
      assert Notification.to_message(%Alert{service: "api", level: :critical}) ==
               "[CRITICAL] api"
    end

    test "renders an Alert with a message" do
      alert = %Alert{service: "api", level: :warning, message: "high latency"}
      assert Notification.to_message(alert) == "[WARNING] api: high latency"
    end

    test "renders a Deploy for each status" do
      base = %Deploy{app: "web", version: "1.4.0"}

      assert Notification.to_message(%{base | status: :started}) ==
               "Deploy of web 1.4.0 started"

      assert Notification.to_message(%{base | status: :succeeded}) ==
               "Deploy of web 1.4.0 succeeded"

      assert Notification.to_message(%{base | status: :failed}) ==
               "Deploy of web 1.4.0 failed"
    end

    test "renders a bare string as itself" do
      assert Notification.to_message("plain text") == "plain text"
    end

    test "falls back to inspect for any other type" do
      assert Notification.to_message(%{a: 1}) == "%{a: 1}"
      assert Notification.to_message(42) == "42"
      assert Notification.to_message([:a, :b]) == "[:a, :b]"
    end

    test "the data picks the implementation, not the caller" do
      alert = %Alert{service: "db", level: :info}
      deploy = %Deploy{app: "db", version: "2.0.0"}

      assert Notification.to_message(alert) =~ "[INFO]"
      assert Notification.to_message(deploy) =~ "Deploy of"
    end
  end

  describe "Channel behaviour (dispatch by module)" do
    test "CollectorChannel delivers to the calling process by default" do
      assert {:ok, "hello"} = CollectorChannel.deliver("hello", [])
      assert_received {:delivered, CollectorChannel, "hello"}
    end

    test "CollectorChannel delivers to a configured pid" do
      parent = self()

      task =
        Task.async(fn ->
          CollectorChannel.deliver("from task", pid: parent)
        end)

      assert {:ok, "from task"} = Task.await(task)
      assert_received {:delivered, CollectorChannel, "from task"}
    end

    test "ConsoleChannel writes to a configurable device" do
      {:ok, device} = StringIO.open("")
      assert {:ok, "logged"} = ConsoleChannel.deliver("logged", device: device)
      assert {_input, "logged\n"} = StringIO.contents(device)
    end

    test "FailingChannel returns the configured error reason" do
      assert {:error, :unavailable} = FailingChannel.deliver("x", [])
      assert {:error, :boom} = FailingChannel.deliver("x", reason: :boom)
    end
  end

  describe "notify/3 (protocol + behaviour wired together)" do
    test "renders the event then delivers through the chosen channel" do
      alert = %Alert{service: "api", level: :critical, message: "down"}

      assert {:ok, "[CRITICAL] api: down"} = BehaviourProtocol.notify(alert, CollectorChannel)
      assert_received {:delivered, CollectorChannel, "[CRITICAL] api: down"}
    end

    test "the same event can be sent through different channels" do
      deploy = %Deploy{app: "web", version: "3.1.0", status: :failed}
      expected = "Deploy of web 3.1.0 failed"

      assert {:ok, ^expected} = BehaviourProtocol.notify(deploy, CollectorChannel)
      assert_received {:delivered, CollectorChannel, ^expected}

      assert {:error, :unavailable} = BehaviourProtocol.notify(deploy, FailingChannel)
    end

    test "propagates the channel's error result" do
      assert {:error, :timeout} =
               BehaviourProtocol.notify("ping", FailingChannel, reason: :timeout)
    end
  end

  describe "render/1" do
    test "delegates to the Notification protocol" do
      assert BehaviourProtocol.render(%Alert{service: "api", level: :info}) == "[INFO] api"
      assert BehaviourProtocol.render("x") == "x"
    end
  end

  describe "delivery_channel?/1" do
    test "true for modules implementing the Channel behaviour" do
      assert BehaviourProtocol.delivery_channel?(ConsoleChannel)
      assert BehaviourProtocol.delivery_channel?(CollectorChannel)
      assert BehaviourProtocol.delivery_channel?(FailingChannel)
    end

    test "false for unrelated or unknown modules" do
      refute BehaviourProtocol.delivery_channel?(Enum)
      refute BehaviourProtocol.delivery_channel?(NoSuchModule)
    end
  end

  describe "channel_name/1" do
    test "uses the optional name/0 callback when implemented" do
      assert BehaviourProtocol.channel_name(ConsoleChannel) == "console"
      assert BehaviourProtocol.channel_name(CollectorChannel) == "collector"
    end

    test "falls back to the module's last segment when name/0 is absent" do
      assert BehaviourProtocol.channel_name(FailingChannel) == "FailingChannel"
    end
  end
end
