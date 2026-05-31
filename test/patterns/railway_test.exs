defmodule Patterns.RailwayTest do
  use ExUnit.Case, async: true

  doctest Patterns.Railway

  alias Patterns.Railway

  describe "ok/1 and error/1" do
    test "wrap values on the right track" do
      assert Railway.ok(1) == {:ok, 1}
      assert Railway.error(:boom) == {:error, :boom}
    end
  end

  describe "bind/2" do
    test "runs the step on the success track" do
      assert {:ok, 6} = Railway.bind({:ok, 5}, fn n -> {:ok, n + 1} end)
    end

    test "can divert to the failure track" do
      assert {:error, :nope} = Railway.bind({:ok, 5}, fn _ -> {:error, :nope} end)
    end

    test "skips the step on the failure track" do
      assert {:error, :prior} =
               Railway.bind({:error, :prior}, fn _ -> flunk("should not run") end)
    end
  end

  describe "map/2" do
    test "transforms the success value and re-wraps it" do
      assert {:ok, 30} = Railway.map({:ok, 3}, &(&1 * 10))
    end

    test "passes errors through untouched" do
      assert {:error, :boom} = Railway.map({:error, :boom}, fn _ -> flunk("nope") end)
    end
  end

  describe "map_error/2" do
    test "transforms the reason on the failure track" do
      assert {:error, {:upstream, :timeout}} =
               Railway.map_error({:error, :timeout}, &{:upstream, &1})
    end

    test "leaves success values untouched" do
      assert {:ok, 1} = Railway.map_error({:ok, 1}, fn _ -> flunk("nope") end)
    end
  end

  describe "tee/2" do
    test "runs the side effect and passes the value through" do
      assert {:ok, 7} = Railway.tee({:ok, 7}, fn n -> send(self(), {:saw, n}) end)
      assert_received {:saw, 7}
    end

    test "does not run on the failure track" do
      assert {:error, :boom} = Railway.tee({:error, :boom}, fn _ -> flunk("nope") end)
    end
  end

  describe "tap_error/2" do
    test "runs the side effect only on the failure track" do
      assert {:error, :boom} =
               Railway.tap_error({:error, :boom}, fn r -> send(self(), {:err, r}) end)

      assert_received {:err, :boom}
    end

    test "does not run on the success track" do
      assert {:ok, 1} = Railway.tap_error({:ok, 1}, fn _ -> flunk("nope") end)
    end
  end

  describe "try_catch/2" do
    test "wraps a normal return in ok" do
      assert {:ok, 42} = Railway.try_catch({:ok, "42"}, &String.to_integer/1)
    end

    test "captures a raised exception as an error" do
      assert {:error, {:exception, %ArgumentError{}}} =
               Railway.try_catch({:ok, "nope"}, &String.to_integer/1)
    end

    test "skips on the failure track" do
      assert {:error, :prior} =
               Railway.try_catch({:error, :prior}, fn _ -> flunk("nope") end)
    end
  end

  describe "recover/2" do
    test "switches a failure back to success" do
      assert {:ok, :default} = Railway.recover({:error, :not_found}, fn _ -> {:ok, :default} end)
    end

    test "can stay on the failure track" do
      assert {:error, :still_bad} =
               Railway.recover({:error, :x}, fn _ -> {:error, :still_bad} end)
    end

    test "leaves success values untouched" do
      assert {:ok, 1} = Railway.recover({:ok, 1}, fn _ -> flunk("nope") end)
    end
  end

  describe "unwrap/2 and unwrap_with/2" do
    test "unwrap returns the value or the default" do
      assert Railway.unwrap({:ok, 99}, 0) == 99
      assert Railway.unwrap({:error, :boom}, 0) == 0
    end

    test "unwrap_with computes a fallback from the reason" do
      assert Railway.unwrap_with({:ok, 99}, fn _ -> 0 end) == 99
      assert Railway.unwrap_with({:error, :boom}, &{:failed, &1}) == {:failed, :boom}
    end
  end

  describe "composed pipelines" do
    test "threads a value through a full success pipeline" do
      result =
        "  10 "
        |> Railway.ok()
        |> Railway.map(&String.trim/1)
        |> Railway.try_catch(&String.to_integer/1)
        |> Railway.bind(fn n -> if n > 0, do: {:ok, n}, else: {:error, :non_positive} end)
        |> Railway.map(&(&1 * 2))

      assert result == {:ok, 20}
    end

    test "short-circuits at the first failing step and recovers" do
      log = self()

      result =
        "0"
        |> Railway.ok()
        |> Railway.try_catch(&String.to_integer/1)
        |> Railway.bind(fn n -> if n > 0, do: {:ok, n}, else: {:error, :non_positive} end)
        |> Railway.map(fn _ -> flunk("should have short-circuited") end)
        |> Railway.tap_error(fn reason -> send(log, {:logged, reason}) end)
        |> Railway.recover(fn _ -> {:ok, :fallback} end)

      assert result == {:ok, :fallback}
      assert_received {:logged, :non_positive}
    end

    test "an early exception flows down the failure track" do
      result =
        "not-a-number"
        |> Railway.ok()
        |> Railway.try_catch(&String.to_integer/1)
        |> Railway.map(fn _ -> flunk("should not run") end)
        |> Railway.map_error(fn {:exception, _} -> :parse_failed end)
        |> Railway.unwrap(:never)

      assert result == :never
    end
  end
end
