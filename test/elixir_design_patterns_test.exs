defmodule ElixirDesignPatternsTest do
  use ExUnit.Case
  doctest ElixirDesignPatterns

  test "greets the world" do
    assert ElixirDesignPatterns.hello() == :world
  end
end
