defmodule Patterns.Pipeline do
  @moduledoc """
  Demonstrates pipeline processing built on `with` chains for happy-path code
  with first-class error handling.

  A pipeline threads a value through a series of steps. Each step either succeeds
  with `{:ok, value}` and hands the value to the next step, or fails with
  `{:error, reason}` and short-circuits the rest of the pipeline. The `with`
  special form expresses exactly this flow without nested `case` statements.

  This pattern showcases:

  - `with` chains that keep the happy path linear and readable
  - Short-circuiting on the first `{:error, _}` without losing the reason
  - The `else` clause for normalizing or tagging failures
  - A generic, data-driven runner (`run/2`) that composes step functions
  - Tagging which step failed so errors stay debuggable (`run_tagged/2`)

  ## Two flavours

  The module shows the same idea at two levels of abstraction:

  - `register_user/1` is a concrete, hand-written `with` chain — the form you
    reach for inside a single function.
  - `run/2` and `run_tagged/2` are generic runners that fold a list of step
    functions, useful when steps are configured at runtime or shared.

  ## Examples

      iex> Patterns.Pipeline.register_user(%{email: "a@b.io", password: "secret12", age: 30})
      {:ok, %{age: 30, email: "a@b.io", status: :active}}

      iex> Patterns.Pipeline.register_user(%{email: "nope", password: "secret12", age: 30})
      {:error, :invalid_email}

      iex> Patterns.Pipeline.run(2, [&{:ok, &1 * 3}, &{:ok, &1 + 1}])
      {:ok, 7}

  """

  @type reason :: term()
  @type step(input, output) :: (input -> {:ok, output} | {:error, reason()})
  @type result(value) :: {:ok, value} | {:error, reason()}

  @doc """
  Runs `input` through `steps`, threading the value with `with`-style semantics.

  Each step is a one-argument function returning `{:ok, value}` or
  `{:error, reason}`. The first error short-circuits the pipeline and is returned
  as-is. An empty step list returns `{:ok, input}`.

  ## Examples

      iex> Patterns.Pipeline.run("  Hi  ", [
      ...>   &{:ok, String.trim(&1)},
      ...>   &{:ok, String.downcase(&1)}
      ...> ])
      {:ok, "hi"}

      iex> Patterns.Pipeline.run(0, [fn _ -> {:error, :nope} end, &{:ok, &1}])
      {:error, :nope}

  """
  @spec run(input, [step(term(), term())]) :: result(term()) when input: term()
  def run(input, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, input}, fn step, {:ok, value} ->
      case step.(value) do
        {:ok, _next} = ok -> {:cont, ok}
        {:error, _reason} = error -> {:halt, error}
        other -> {:halt, {:error, {:bad_step_return, other}}}
      end
    end)
  end

  @doc """
  Like `run/2`, but each step is a `{tag, fun}` pair and failures are wrapped as
  `{:error, {tag, reason}}` so you can see which step failed.

  ## Examples

      iex> Patterns.Pipeline.run_tagged(10, [
      ...>   {:halve, fn n -> {:ok, div(n, 2)} end},
      ...>   {:check, fn n -> if n > 0, do: {:ok, n}, else: {:error, :non_positive} end}
      ...> ])
      {:ok, 5}

      iex> Patterns.Pipeline.run_tagged(0, [
      ...>   {:check, fn n -> if n > 0, do: {:ok, n}, else: {:error, :non_positive} end}
      ...> ])
      {:error, {:check, :non_positive}}

  """
  @spec run_tagged(input, [{atom(), step(term(), term())}]) ::
          result(term()) | {:error, {atom(), reason()}}
        when input: term()
  def run_tagged(input, steps) when is_list(steps) do
    Enum.reduce_while(steps, {:ok, input}, fn {tag, step}, {:ok, value} ->
      case step.(value) do
        {:ok, _next} = ok -> {:cont, ok}
        {:error, reason} -> {:halt, {:error, {tag, reason}}}
        other -> {:halt, {:error, {tag, {:bad_step_return, other}}}}
      end
    end)
  end

  @doc """
  A concrete `with` chain that validates and normalizes user registration params.

  Returns `{:ok, user}` when every step succeeds, or the first step's
  `{:error, reason}` otherwise. This is the idiomatic shape of an in-function
  pipeline: a linear happy path with each clause guarding the next.

  ## Examples

      iex> Patterns.Pipeline.register_user(%{email: "JANE@EXAMPLE.COM", password: "hunter2!", age: 42})
      {:ok, %{age: 42, email: "jane@example.com", status: :active}}

      iex> Patterns.Pipeline.register_user(%{email: "x@y.io", password: "short", age: 42})
      {:error, :password_too_short}

  """
  @spec register_user(map()) :: result(%{email: String.t(), age: pos_integer(), status: :active})
  def register_user(params) do
    with {:ok, params} <- require_keys(params, [:email, :password, :age]),
         {:ok, email} <- validate_email(params.email),
         :ok <- validate_password(params.password),
         {:ok, age} <- validate_age(params.age) do
      {:ok, %{email: email, age: age, status: :active}}
    end
  end

  @doc """
  Same chain as `register_user/1`, but uses an `else` clause to normalize every
  failure into a uniform `{:error, %{field: field, message: message}}` shape.

  The `else` clause runs only when one of the `<-` patterns fails to match,
  letting you translate internal reasons into a consistent external contract.

  ## Examples

      iex> Patterns.Pipeline.register_user_normalized(%{email: "bad", password: "hunter2!", age: 42})
      {:error, %{field: :email, message: "must be a valid email address"}}

  """
  @spec register_user_normalized(map()) ::
          result(%{email: String.t(), age: pos_integer(), status: :active})
  def register_user_normalized(params) do
    with {:ok, params} <- require_keys(params, [:email, :password, :age]),
         {:ok, email} <- validate_email(params.email),
         :ok <- validate_password(params.password),
         {:ok, age} <- validate_age(params.age) do
      {:ok, %{email: email, age: age, status: :active}}
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  # Steps — each returns {:ok, value} | {:error, reason} so they compose.

  defp require_keys(params, keys) when is_map(params) do
    case Enum.find(keys, fn key -> not Map.has_key?(params, key) end) do
      nil -> {:ok, params}
      missing -> {:error, {:missing_key, missing}}
    end
  end

  defp require_keys(_params, _keys), do: {:error, :not_a_map}

  defp validate_email(email) when is_binary(email) do
    normalized = email |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/, normalized) do
      {:ok, normalized}
    else
      {:error, :invalid_email}
    end
  end

  defp validate_email(_email), do: {:error, :invalid_email}

  defp validate_password(password) when is_binary(password) do
    if String.length(password) >= 8, do: :ok, else: {:error, :password_too_short}
  end

  defp validate_password(_password), do: {:error, :password_too_short}

  defp validate_age(age) when is_integer(age) and age >= 18, do: {:ok, age}
  defp validate_age(age) when is_integer(age), do: {:error, :under_age}
  defp validate_age(_age), do: {:error, :invalid_age}

  # Translate internal reasons into a stable external error contract.

  defp describe({:missing_key, key}),
    do: %{field: key, message: "is required"}

  defp describe(:not_a_map),
    do: %{field: :params, message: "must be a map"}

  defp describe(:invalid_email),
    do: %{field: :email, message: "must be a valid email address"}

  defp describe(:password_too_short),
    do: %{field: :password, message: "must be at least 8 characters"}

  defp describe(:under_age),
    do: %{field: :age, message: "must be 18 or older"}

  defp describe(:invalid_age),
    do: %{field: :age, message: "must be an integer"}
end
