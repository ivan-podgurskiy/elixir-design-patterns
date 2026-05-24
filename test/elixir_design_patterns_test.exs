defmodule ElixirDesignPatternsTest do
  use ExUnit.Case

  test "lists phase 1 patterns" do
    patterns = ElixirDesignPatterns.patterns()

    assert Patterns.GenServerCache in patterns
    assert Patterns.SupervisorTree in patterns
    assert Patterns.AgentState in patterns
    assert Patterns.TaskAsync in patterns
  end
end
