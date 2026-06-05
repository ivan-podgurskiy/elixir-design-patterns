# Rate Limiter (Token Bucket) Pattern

## Overview

The token bucket rate limiter controls how many requests a client or endpoint can make in a given period. Tokens refill continuously at a configured rate; each allowed request spends tokens. When the bucket is empty, requests are rejected immediately with an estimated retry delay.

Unlike a circuit breaker (which protects *you* from a failing dependency), a rate limiter protects *your service* from being overwhelmed — by external clients, noisy neighbours, or your own runaway jobs.

## Problem it Solves

- **API abuse**: Cap requests per user, IP, or API key
- **Resource protection**: Prevent one tenant from exhausting shared capacity
- **Fairness**: Spread load across clients with per-key buckets
- **Predictable degradation**: Reject early with `retry_after` instead of timing out under load

## When to Use

✅ **Good for:**

- Public HTTP APIs with per-client quotas
- Outbound calls to third-party APIs with strict rate caps
- Background job enqueue limits per tenant
- Protecting expensive endpoints (reports, exports, ML inference)

❌ **Avoid when:**

- You need hard sliding-window counts (use a fixed window counter instead)
- The limit is global concurrency, not request rate (use a [Process Pool](07_process_pool.md))
- The downstream service is failing and you should stop calling it (use a [Circuit Breaker](08_circuit_breaker.md))

## How the Token Bucket Works

```mermaid
graph LR
    Request[Incoming request] --> Check{tokens >= cost?}
    Check -->|yes| Deduct[Deduct tokens]
    Deduct --> Allow[{:ok, remaining}]
    Check -->|no| Reject["{:error, :rate_limited, retry_after_ms}"]
    Refill[Continuous refill] --> Bucket[(Token bucket)]
    Bucket --> Check
```

| Parameter | Meaning |
|-----------|---------|
| `capacity` | Maximum tokens the bucket can hold (burst size) |
| `refill_rate` | Tokens added per second (sustained throughput) |

Refill is computed lazily on each check using monotonic time — no background timer required.

## Implementation

### Lazy Refill

```elixir
def refill(bucket) do
  elapsed_ms = monotonic_now() - bucket.last_refill_ms
  tokens_to_add = elapsed_ms * bucket.refill_rate / 1000.0

  %{bucket |
    tokens: min(bucket.capacity, bucket.tokens + tokens_to_add),
    last_refill_ms: monotonic_now()
  }
end
```

### Allow or Reject

```elixir
case try_consume(bucket, cost) do
  {:ok, bucket, remaining} ->
    {:ok, trunc(remaining)}

  {:error, :rate_limited, retry_after_ms, _bucket} ->
    {:error, :rate_limited, retry_after_ms}
end
```

## Usage Examples

### Global Limit

```elixir
{:ok, limiter} = Patterns.RateLimiter.start_link(capacity: 100, refill_rate: 10)

case Patterns.RateLimiter.allow(limiter) do
  {:ok, remaining} ->
    handle_request(remaining)

  {:error, :rate_limited, retry_after_ms} ->
    # HTTP 429 with Retry-After header
    send_rate_limited(retry_after_ms)
end
```

### Per-Key Limits

```elixir
{:ok, limiter} =
  Patterns.RateLimiter.start_link(
    capacity: 20,
    refill_rate: 2,
    per_key: true,
    name: MyApp.ApiRateLimiter
  )

user_id = conn.assigns.current_user.id

case Patterns.RateLimiter.allow(limiter, user_id) do
  {:ok, _} -> proceed(conn)
  {:error, :rate_limited, ms} -> too_many_requests(conn, ms)
end
```

### Variable Cost

Charge more tokens for expensive operations:

```elixir
Patterns.RateLimiter.consume(limiter, "tenant:42", 5)
```

### Human-Friendly Retry Messages

Pair with the [`humanizer`](https://hexdocs.pm/humanizer) package to format retry hints for logs or API responses:

```elixir
{:error, :rate_limited, retry_after_ms} ->
  message = "Try again in #{Humanizer.duration(div(retry_after_ms, 1000))}"
  {:error, :rate_limited, message, retry_after_ms: retry_after_ms}
```

### Introspection

```elixir
Patterns.RateLimiter.stats(limiter)
# %{
#   total_allowed: 842,
#   total_rejected: 17,
#   capacity: 100,
#   refill_rate: 10.0,
#   tokens: 73.4,
#   keys: nil
# }
```

## Real-World Applications

### API Gateway

Place a per-key limiter in front of route handlers. Cheap reads cost 1 token; heavy writes cost more.

### Third-Party API Client

Wrap outbound HTTP calls:

```elixir
with {:ok, _} <- Patterns.RateLimiter.allow(stripe_limiter),
     {:ok, result} <- StripeClient.charge(params) do
  {:ok, result}
else
  {:error, :rate_limited, ms} ->
    Process.sleep(ms)
    retry_charge(params)
end
```

For retry delays after rate limiting, combine with [`jitter`](https://hexdocs.pm/jitter) when backing off across many clients.

### Multi-Tenant SaaS

Each tenant gets an isolated bucket (`per_key: true`) so one customer's spike does not starve others.

## Comparison with Related Patterns

| Pattern | Purpose |
|---------|---------|
| **Rate Limiter** | Cap request rate / throughput |
| **Circuit Breaker** | Stop calling a failing service |
| **Process Pool** | Cap concurrent workers |
| **GenServer Cache** | Store data with TTL (can track counters, but not ideal for rate limiting) |

Rate limiters and circuit breakers complement each other: limit inbound load, then protect outbound calls.

## Tuning Guidance

| Parameter | Lower value | Higher value |
|-----------|-------------|--------------|
| `capacity` | Smaller bursts allowed | Larger short spikes tolerated |
| `refill_rate` | Stricter sustained rate | Higher average throughput |

**Rule of thumb**: set `refill_rate` to your target sustained RPS and `capacity` to the burst you can absorb without degrading (often 2–10× the sustained rate).

## Supervision Considerations

- One limiter GenServer per protected surface (API, outbound client, job queue)
- Use the `:name` option for application-wide access
- State is in-memory — limits reset on restart (acceptable for soft limits; use Redis for distributed limits)
- Cheap to run: O(1) per check, no periodic timers

## Testing Tips

1. Use `refill_rate: 0` to disable refill and test exhaustion deterministically
2. Use small `refill_rate` values (e.g. `10`) with short `Process.sleep/1` for refill tests
3. Test per-key isolation: exhausting one key must not affect another
4. Test concurrent `Task.async` callers to verify serialization
5. For time-sensitive *caller-side* expiry logic, [`frozen_clock`](https://hexdocs.pm/frozen_clock) works in the same process; the GenServer bucket uses monotonic time internally

## Key Takeaways

1. **Token bucket = burst + sustained rate** — `capacity` and `refill_rate` control both dimensions
2. **Lazy refill on each check** — no timer process, accurate under variable load
3. **Return retry hints** — `retry_after_ms` enables HTTP 429 / client backoff
4. **Per-key for fairness** — isolate tenants, users, or API keys
5. **Not a circuit breaker** — rate limiting throttles; circuit breaking cuts off failing dependencies

## Phase 4 Started

First pattern in **Phase 4 — Real-World Patterns**:

- ✅ Rate Limiter (token bucket)
- Retry with exponential backoff (standalone module)
- Graceful shutdown handling
- Event sourcing fundamentals
