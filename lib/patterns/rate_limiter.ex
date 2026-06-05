defmodule Patterns.RateLimiter do
  @moduledoc """
  Demonstrates the token bucket rate limiter for controlling request throughput.

  A token bucket holds a configurable number of tokens that refill continuously at
  a fixed rate. Each allowed request spends one or more tokens; when the bucket is
  empty, requests are rejected with an estimated retry delay.

  This pattern showcases:
  - Continuous token refill using monotonic time
  - Global and per-key rate limiting
  - `{:error, :rate_limited, retry_after_ms}` for client-friendly backoff hints
  - GenServer-serialized bucket state with O(1) checks

  ## Examples

      iex> {:ok, limiter} = Patterns.RateLimiter.start_link(capacity: 2, refill_rate: 0)
      iex> {:ok, 1} = Patterns.RateLimiter.allow(limiter)
      iex> {:ok, 0} = Patterns.RateLimiter.allow(limiter)
      iex> {:error, :rate_limited, _} = Patterns.RateLimiter.allow(limiter)

  """

  use GenServer

  @default_capacity 10
  @default_refill_rate 1.0

  @type key :: term()
  @type cost :: pos_integer()
  @type allow_result ::
          {:ok, non_neg_integer()}
          | {:error, :rate_limited, pos_integer()}
          | {:error, :key_required | :key_not_allowed}
  @type stats :: %{
          total_allowed: non_neg_integer(),
          total_rejected: non_neg_integer(),
          capacity: pos_integer(),
          refill_rate: float(),
          tokens: float(),
          keys: non_neg_integer() | nil
        }

  defmodule Bucket do
    @moduledoc false

    defstruct [:tokens, :last_refill_ms, :capacity, :refill_rate]

    @type t :: %__MODULE__{
            tokens: float(),
            last_refill_ms: non_neg_integer(),
            capacity: pos_integer(),
            refill_rate: float()
          }

    @spec new(pos_integer(), float()) :: t()
    def new(capacity, refill_rate) do
      now = monotonic_now()

      %__MODULE__{
        tokens: capacity * 1.0,
        last_refill_ms: now,
        capacity: capacity,
        refill_rate: refill_rate
      }
    end

    @spec refill(t()) :: t()
    def refill(%__MODULE__{} = bucket) do
      now = monotonic_now()
      elapsed_ms = max(0, now - bucket.last_refill_ms)

      tokens_to_add = elapsed_ms * bucket.refill_rate / 1000.0

      %{
        bucket
        | tokens: min(bucket.capacity * 1.0, bucket.tokens + tokens_to_add),
          last_refill_ms: now
      }
    end

    @spec try_consume(t(), pos_integer()) ::
            {:ok, t(), float()} | {:error, :rate_limited, pos_integer(), t()}
    def try_consume(%__MODULE__{} = bucket, cost) do
      bucket = refill(bucket)

      if bucket.tokens >= cost do
        remaining = bucket.tokens - cost
        {:ok, %{bucket | tokens: remaining}, remaining}
      else
        deficit = cost - bucket.tokens
        retry_after_ms = retry_after_ms(deficit, bucket.refill_rate)
        {:error, :rate_limited, retry_after_ms, bucket}
      end
    end

    @spec retry_after_ms(float(), float()) :: pos_integer()
    defp retry_after_ms(deficit, refill_rate) when refill_rate > 0 do
      deficit
      |> Kernel./(refill_rate)
      |> Kernel.*(1000.0)
      |> ceil()
      |> max(1)
    end

    defp retry_after_ms(_deficit, _refill_rate), do: 1

    @spec monotonic_now() :: non_neg_integer()
    defp monotonic_now, do: System.monotonic_time(:millisecond)
  end

  @doc """
  Starts a rate limiter.

  ## Options

  - `:capacity` — maximum tokens in the bucket (default: #{@default_capacity})
  - `:refill_rate` — tokens added per second (default: #{@default_refill_rate})
  - `:per_key` — when `true`, maintain a separate bucket per key (default: `false`)
  - `:name` — optional registered name
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Attempts to consume one token from the global bucket.

  Returns `{:ok, remaining}` when allowed, or `{:error, :rate_limited, retry_after_ms}`
  when the bucket is empty.
  """
  @spec allow(GenServer.server()) :: allow_result()
  def allow(server) do
    consume(server, 1)
  end

  @doc """
  Attempts to consume one token from the bucket for `key`.

  Requires `per_key: true` at startup.
  """
  @spec allow(GenServer.server(), key()) :: allow_result()
  def allow(server, key) do
    consume(server, key, 1)
  end

  @doc """
  Attempts to consume `cost` tokens from the global bucket.
  """
  @spec consume(GenServer.server(), cost()) :: allow_result()
  def consume(server, cost) when is_integer(cost) and cost > 0 do
    GenServer.call(server, {:consume, nil, cost})
  end

  @doc """
  Attempts to consume `cost` tokens from the bucket for `key`.
  """
  @spec consume(GenServer.server(), key(), cost()) :: allow_result()
  def consume(server, key, cost) when is_integer(cost) and cost > 0 do
    GenServer.call(server, {:consume, key, cost})
  end

  @doc """
  Returns limiter statistics and the current token count.
  """
  @spec stats(GenServer.server()) :: stats()
  def stats(server) do
    GenServer.call(server, :stats)
  end

  @doc """
  Resets the global bucket to full capacity.
  """
  @spec reset(GenServer.server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  @doc """
  Resets the bucket for `key` to full capacity.
  """
  @spec reset(GenServer.server(), key()) :: :ok
  def reset(server, key) do
    GenServer.call(server, {:reset, key})
  end

  @impl GenServer
  def init(opts) do
    capacity = Keyword.get(opts, :capacity, @default_capacity)
    refill_rate = Keyword.get(opts, :refill_rate, @default_refill_rate) * 1.0
    per_key = Keyword.get(opts, :per_key, false)

    state = %{
      per_key: per_key,
      capacity: capacity,
      refill_rate: refill_rate,
      bucket: unless(per_key, do: Bucket.new(capacity, refill_rate)),
      buckets: if(per_key, do: %{}, else: nil),
      total_allowed: 0,
      total_rejected: 0
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:consume, key, cost}, _from, state) do
    case consume_from_state(state, key, cost) do
      {:ok, new_state, remaining} ->
        new_state = %{new_state | total_allowed: new_state.total_allowed + 1}
        {:reply, {:ok, trunc(remaining)}, new_state}

      {:error, :rate_limited, retry_after_ms, new_state} ->
        new_state = %{new_state | total_rejected: new_state.total_rejected + 1}
        {:reply, {:error, :rate_limited, retry_after_ms}, new_state}

      {:error, reason, new_state} when reason in [:key_required, :key_not_allowed] ->
        {:reply, {:error, reason}, new_state}
    end
  end

  @impl GenServer
  def handle_call(:stats, _from, state) do
    {:reply, build_stats(state), state}
  end

  @impl GenServer
  def handle_call(:reset, _from, %{per_key: false} = state) do
    {:reply, :ok, put_bucket(state, Bucket.new(state.capacity, state.refill_rate))}
  end

  @impl GenServer
  def handle_call({:reset, key}, _from, %{per_key: true} = state) do
    buckets = Map.put(state.buckets, key, Bucket.new(state.capacity, state.refill_rate))
    {:reply, :ok, %{state | buckets: buckets}}
  end

  defp consume_from_state(%{per_key: false} = state, key, _cost) when not is_nil(key) do
    {:error, :key_not_allowed, state}
  end

  defp consume_from_state(%{per_key: false} = state, nil, cost) do
    case Bucket.try_consume(state.bucket, cost) do
      {:ok, bucket, remaining} ->
        {:ok, put_bucket(state, bucket), remaining}

      {:error, :rate_limited, retry_after_ms, bucket} ->
        {:error, :rate_limited, retry_after_ms, put_bucket(state, bucket)}
    end
  end

  defp consume_from_state(%{per_key: true} = state, key, cost) when not is_nil(key) do
    bucket = Map.get(state.buckets, key, Bucket.new(state.capacity, state.refill_rate))

    case Bucket.try_consume(bucket, cost) do
      {:ok, bucket, remaining} ->
        buckets = Map.put(state.buckets, key, bucket)
        {:ok, %{state | buckets: buckets}, remaining}

      {:error, :rate_limited, retry_after_ms, bucket} ->
        buckets = Map.put(state.buckets, key, bucket)
        {:error, :rate_limited, retry_after_ms, %{state | buckets: buckets}}
    end
  end

  defp consume_from_state(state, nil, _cost) when state.per_key do
    {:error, :key_required, state}
  end

  defp put_bucket(state, bucket), do: %{state | bucket: bucket}

  defp build_stats(%{per_key: false} = state) do
    bucket = Bucket.refill(state.bucket)

    %{
      total_allowed: state.total_allowed,
      total_rejected: state.total_rejected,
      capacity: state.capacity,
      refill_rate: state.refill_rate,
      tokens: bucket.tokens,
      keys: nil
    }
  end

  defp build_stats(%{per_key: true, buckets: buckets} = state) do
    %{
      total_allowed: state.total_allowed,
      total_rejected: state.total_rejected,
      capacity: state.capacity,
      refill_rate: state.refill_rate,
      tokens: nil,
      keys: map_size(buckets)
    }
  end
end
