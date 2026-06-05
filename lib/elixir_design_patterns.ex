defmodule ElixirDesignPatterns do
  @moduledoc """
  Practical, runnable examples of OTP and functional design patterns in Elixir.

  See the pattern modules under `Patterns.*` and the guides in `guides/`.
  """

  @doc """
  Returns the pattern modules included in this library.
  """
  def patterns do
    [
      Patterns.GenServerCache,
      Patterns.SupervisorTree,
      Patterns.AgentState,
      Patterns.TaskAsync,
      Patterns.RegistryDynamicSupervisor,
      Patterns.RegistryPubSub,
      Patterns.ProcessPool,
      Patterns.CircuitBreaker,
      Patterns.Pipeline,
      Patterns.Railway,
      Patterns.BehaviourProtocol,
      Patterns.EtsStore,
      Patterns.RateLimiter
    ]
  end
end
