defmodule Patterns.Railway do
  @moduledoc """
  Demonstrates railway-oriented programming (ROP) — composing fallible
  operations as a pipeline of pipe-friendly combinators.

  Picture a two-track railway. The **success track** carries `{:ok, value}` and
  the **failure track** carries `{:error, reason}`. Each step is a switch: while
  on the success track a step runs and may divert the train to the failure track;
  once on the failure track every remaining step is skipped and the error is
  carried straight to the end.

  Where `Patterns.Pipeline` expresses this with the `with` special form, this
  module provides combinators that thread a result through the pipe operator
  (`|>`), so you can build the railway from small, reusable functions.

  This pattern showcases:

  - Result constructors (`ok/1`, `error/1`) and combinators for the `|>` operator
  - `bind/2` for steps that themselves return a result (success track switch)
  - `map/2` / `map_error/2` for transforming the value or the reason
  - `tee/2` / `tap_error/2` for side effects that don't change the result
  - `try_catch/2` to bring raising code onto the railway
  - `recover/2` to switch back to the success track, and `unwrap/2` to leave it

  ## The two tracks

      {:ok, value}     ──▶ step runs, may divert to error
      {:error, reason} ──▶ step skipped, error flows through

  ## Examples

      iex> alias Patterns.Railway
      iex> 4
      ...> |> Railway.ok()
      ...> |> Railway.map(&(&1 * 2))
      ...> |> Railway.bind(fn n -> if n > 0, do: {:ok, n}, else: {:error, :non_positive} end)
      {:ok, 8}

      iex> alias Patterns.Railway
      iex> {:error, :boom}
      ...> |> Railway.map(&(&1 * 2))
      ...> |> Railway.unwrap(:default)
      :default

  """

  @type reason :: term()
  @type result(value) :: {:ok, value} | {:error, reason()}
  @type result :: result(term())

  @doc """
  Wraps a value on the success track.

  ## Examples

      iex> Patterns.Railway.ok(42)
      {:ok, 42}

  """
  @spec ok(value) :: {:ok, value} when value: term()
  def ok(value), do: {:ok, value}

  @doc """
  Wraps a reason on the failure track.

  ## Examples

      iex> Patterns.Railway.error(:not_found)
      {:error, :not_found}

  """
  @spec error(reason()) :: {:error, reason()}
  def error(reason), do: {:error, reason}

  @doc """
  Chains a step that returns a result (also known as `and_then` or `flat_map`).

  Runs `fun` only when on the success track; `fun` receives the unwrapped value
  and must return a `{:ok, _}` / `{:error, _}` result. On the failure track the
  error passes through untouched.

  ## Examples

      iex> Patterns.Railway.bind({:ok, 5}, fn n -> {:ok, n + 1} end)
      {:ok, 6}

      iex> Patterns.Railway.bind({:ok, 5}, fn _ -> {:error, :nope} end)
      {:error, :nope}

      iex> Patterns.Railway.bind({:error, :prior}, fn n -> {:ok, n + 1} end)
      {:error, :prior}

  """
  @spec bind(result(), (term() -> result())) :: result()
  def bind({:ok, value}, fun) when is_function(fun, 1), do: fun.(value)
  def bind({:error, _reason} = error, _fun), do: error

  @doc """
  Transforms the success value with a plain function, staying on the same track.

  Unlike `bind/2`, `fun` returns a bare value (not a result); it is automatically
  re-wrapped in `{:ok, _}`. Errors pass through untouched.

  ## Examples

      iex> Patterns.Railway.map({:ok, 3}, &(&1 * 10))
      {:ok, 30}

      iex> Patterns.Railway.map({:error, :boom}, &(&1 * 10))
      {:error, :boom}

  """
  @spec map(result(), (term() -> term())) :: result()
  def map({:ok, value}, fun) when is_function(fun, 1), do: {:ok, fun.(value)}
  def map({:error, _reason} = error, _fun), do: error

  @doc """
  Transforms the failure reason, leaving success values untouched.

  Useful for normalizing or tagging errors as they travel down the failure track.

  ## Examples

      iex> Patterns.Railway.map_error({:error, :timeout}, fn r -> {:upstream, r} end)
      {:error, {:upstream, :timeout}}

      iex> Patterns.Railway.map_error({:ok, 1}, fn r -> {:upstream, r} end)
      {:ok, 1}

  """
  @spec map_error(result(), (reason() -> reason())) :: result()
  def map_error({:error, reason}, fun) when is_function(fun, 1), do: {:error, fun.(reason)}
  def map_error({:ok, _value} = ok, _fun), do: ok

  @doc """
  Runs a side-effecting function on the success value and passes the result
  through unchanged (a "tee" in the track).

  Handy for logging, metrics, or notifications without breaking the chain. The
  return value of `fun` is ignored.

  ## Examples

      iex> Patterns.Railway.tee({:ok, 7}, fn n -> send(self(), {:saw, n}) end)
      {:ok, 7}

      iex> Patterns.Railway.tee({:error, :boom}, fn _ -> raise "never runs" end)
      {:error, :boom}

  """
  @spec tee(result(), (term() -> any())) :: result()
  def tee({:ok, value} = ok, fun) when is_function(fun, 1) do
    _ = fun.(value)
    ok
  end

  def tee({:error, _reason} = error, _fun), do: error

  @doc """
  Like `tee/2`, but runs the side effect only on the failure track.

  ## Examples

      iex> Patterns.Railway.tap_error({:error, :boom}, fn r -> send(self(), {:err, r}) end)
      {:error, :boom}

      iex> Patterns.Railway.tap_error({:ok, 1}, fn _ -> raise "never runs" end)
      {:ok, 1}

  """
  @spec tap_error(result(), (reason() -> any())) :: result()
  def tap_error({:error, reason} = error, fun) when is_function(fun, 1) do
    _ = fun.(reason)
    error
  end

  def tap_error({:ok, _value} = ok, _fun), do: ok

  @doc """
  Runs a function that may raise and brings the outcome onto the railway.

  When on the success track, `fun` is called with the value. A normal return is
  wrapped in `{:ok, _}`; a raised exception becomes `{:error, {:exception, e}}`.
  Errors already on the failure track pass through untouched.

  ## Examples

      iex> Patterns.Railway.try_catch({:ok, "42"}, &String.to_integer/1)
      {:ok, 42}

      iex> {:error, {:exception, %ArgumentError{}}} =
      ...>   Patterns.Railway.try_catch({:ok, "nope"}, &String.to_integer/1)
      iex> :ok
      :ok

  """
  @spec try_catch(result(), (term() -> term())) :: result()
  def try_catch({:ok, value}, fun) when is_function(fun, 1) do
    {:ok, fun.(value)}
  rescue
    exception -> {:error, {:exception, exception}}
  end

  def try_catch({:error, _reason} = error, _fun), do: error

  @doc """
  Attempts to switch a failure back onto the success track.

  When on the failure track, `fun` receives the reason and returns a new result —
  use it for fallbacks and recovery. Success values pass through untouched.

  ## Examples

      iex> Patterns.Railway.recover({:error, :not_found}, fn _ -> {:ok, :default} end)
      {:ok, :default}

      iex> Patterns.Railway.recover({:ok, 1}, fn _ -> {:ok, :default} end)
      {:ok, 1}

  """
  @spec recover(result(), (reason() -> result())) :: result()
  def recover({:error, reason}, fun) when is_function(fun, 1), do: fun.(reason)
  def recover({:ok, _value} = ok, _fun), do: ok

  @doc """
  Leaves the railway, returning the success value or `default` on failure.

  ## Examples

      iex> Patterns.Railway.unwrap({:ok, 99}, 0)
      99

      iex> Patterns.Railway.unwrap({:error, :boom}, 0)
      0

  """
  @spec unwrap(result(value), default) :: value | default when value: term(), default: term()
  def unwrap({:ok, value}, _default), do: value
  def unwrap({:error, _reason}, default), do: default

  @doc """
  Leaves the railway, returning the success value or calling `fun` with the
  reason to compute a fallback.

  ## Examples

      iex> Patterns.Railway.unwrap_with({:ok, 99}, fn _ -> 0 end)
      99

      iex> Patterns.Railway.unwrap_with({:error, :boom}, fn reason -> {:failed, reason} end)
      {:failed, :boom}

  """
  @spec unwrap_with(result(value), (reason() -> term())) :: value | term() when value: term()
  def unwrap_with({:ok, value}, _fun), do: value
  def unwrap_with({:error, reason}, fun) when is_function(fun, 1), do: fun.(reason)
end
