defmodule Patterns.PipelineTest do
  use ExUnit.Case, async: true

  doctest Patterns.Pipeline

  alias Patterns.Pipeline

  describe "run/2" do
    test "threads the value through every step" do
      steps = [
        &{:ok, &1 * 2},
        &{:ok, &1 + 1},
        &{:ok, Integer.to_string(&1)}
      ]

      assert {:ok, "7"} = Pipeline.run(3, steps)
    end

    test "returns the input unchanged for an empty pipeline" do
      assert {:ok, :unchanged} = Pipeline.run(:unchanged, [])
    end

    test "short-circuits on the first error and returns it as-is" do
      steps = [
        &{:ok, &1 + 1},
        fn _ -> {:error, :stop_here} end,
        fn _ -> flunk("should not run after an error") end
      ]

      assert {:error, :stop_here} = Pipeline.run(0, steps)
    end

    test "wraps a malformed step return value" do
      assert {:error, {:bad_step_return, :oops}} =
               Pipeline.run(1, [fn _ -> :oops end])
    end
  end

  describe "run_tagged/2" do
    test "threads the value through tagged steps" do
      steps = [
        {:double, fn n -> {:ok, n * 2} end},
        {:inc, fn n -> {:ok, n + 1} end}
      ]

      assert {:ok, 9} = Pipeline.run_tagged(4, steps)
    end

    test "tags the failing step in the error" do
      steps = [
        {:double, fn n -> {:ok, n * 2} end},
        {:guard, fn _ -> {:error, :rejected} end}
      ]

      assert {:error, {:guard, :rejected}} = Pipeline.run_tagged(1, steps)
    end

    test "tags malformed step returns too" do
      assert {:error, {:weird, {:bad_step_return, nil}}} =
               Pipeline.run_tagged(1, [{:weird, fn _ -> nil end}])
    end
  end

  describe "register_user/1" do
    test "succeeds and normalizes the email for valid params" do
      params = %{email: "  Jane@Example.COM ", password: "hunter2!", age: 30}

      assert {:ok, user} = Pipeline.register_user(params)
      assert user == %{email: "jane@example.com", age: 30, status: :active}
    end

    test "fails when a required key is missing" do
      assert {:error, {:missing_key, :age}} =
               Pipeline.register_user(%{email: "a@b.io", password: "hunter2!"})
    end

    test "fails on an invalid email" do
      params = %{email: "not-an-email", password: "hunter2!", age: 30}
      assert {:error, :invalid_email} = Pipeline.register_user(params)
    end

    test "fails on a short password" do
      params = %{email: "a@b.io", password: "short", age: 30}
      assert {:error, :password_too_short} = Pipeline.register_user(params)
    end

    test "fails when under age" do
      params = %{email: "a@b.io", password: "hunter2!", age: 17}
      assert {:error, :under_age} = Pipeline.register_user(params)
    end

    test "fails when age is not an integer" do
      params = %{email: "a@b.io", password: "hunter2!", age: "30"}
      assert {:error, :invalid_age} = Pipeline.register_user(params)
    end

    test "short-circuits at the first failing step" do
      params = %{email: "bad", password: "short", age: 5}
      assert {:error, :invalid_email} = Pipeline.register_user(params)
    end

    test "rejects non-map input" do
      assert {:error, :not_a_map} = Pipeline.register_user("nope")
    end
  end

  describe "register_user_normalized/1" do
    test "returns a uniform error shape" do
      params = %{email: "bad", password: "hunter2!", age: 30}

      assert {:error, %{field: :email, message: message}} =
               Pipeline.register_user_normalized(params)

      assert message =~ "valid email"
    end

    test "normalizes a missing-key failure" do
      assert {:error, %{field: :age, message: "is required"}} =
               Pipeline.register_user_normalized(%{email: "a@b.io", password: "hunter2!"})
    end

    test "still succeeds on the happy path" do
      params = %{email: "a@b.io", password: "hunter2!", age: 21}

      assert {:ok, %{email: "a@b.io", age: 21, status: :active}} =
               Pipeline.register_user_normalized(params)
    end
  end
end
