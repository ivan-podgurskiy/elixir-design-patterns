# ETS-Backed Stores

## Overview

**ETS** (Erlang Term Storage) is an in-memory key-value store built into the BEAM. Tables live
outside any single process heap, so large values can be read by many processes without copying
through messages.

The production pattern used throughout OTP is:

```
┌─────────────┐     writes (insert/delete)      ┌──────────────┐
│   Client    │ ──────────────────────────────▶ │   GenServer  │
│  processes  │                                 │   (owner)    │
└─────────────┘                                 └──────┬───────┘
       │                                               │ creates
       │         reads (:ets.lookup on :public table)  ▼
       └──────────────────────────────────────▶ ┌──────────────┐
                                                │  ETS table   │
                                                └──────────────┘
```

[`Patterns.EtsStore`](../lib/patterns/ets_store.ex) implements this layout: a GenServer owns a
`:public, :protected` table, exposes write operations through calls, and documents how callers
can **`fetch/2`** for read-heavy paths.

## Problem it Solves

- **Shared hot reads** — many processes need the same configuration, session, or cache entry.
- **Large values** — copying a big map on every `GenServer.call/3` is expensive; ETS reads stay
  in the shared table.
- **Predictable ownership** — the GenServer still controls lifecycle, cleanup, and write
  serialization.

## When to Use ETS

✅ **Good fit:**

- Read-heavy caches with occasional writes
- Per-node shared indexes (ETS is local to the node, not cluster-wide)
- Storing counters, rate-limit windows, or feature flags accessed by many processes

❌ **Reach for something else when:**

- You need **durability** or **replication** — use a database or `:mnesia`
- State is **only used inside one process** — a plain map in GenServer state is simpler
  ([GenServer Cache guide](01_genserver_cache.md) demonstrates that approach)
- You need **TTL and rich cache policies** — GenServer-owned maps with explicit cleanup are
  easier to reason about for small datasets

## Table Types

| Type | Keys | Values per key | Typical use |
|------|------|----------------|-------------|
| `:set` | unique | one | general KV store (default) |
| `:ordered_set` | unique, sorted | one | range-friendly key ordering |
| `:bag` | unique | many | tags, multi-valued attributes |
| `:duplicate_bag` | non-unique | many | event logs per key |

Start a bag table when you need multiple values under one key:

```elixir
{:ok, pid} = Patterns.EtsStore.start_link(table_type: :bag)
:ok = Patterns.EtsStore.put(pid, :tag, "elixir")
:ok = Patterns.EtsStore.put(pid, :tag, "otp")
{:ok, ["elixir", "otp"]} = Patterns.EtsStore.get(pid, :tag)  # order not guaranteed
```

## Concurrency Options

ETS tables accept:

- **`read_concurrency: true`** — optimizes many concurrent readers (default here).
- **`write_concurrency: true`** — stripes writes for `:set` tables on OTP 22+ (default here).

Tuning depends on your workload; start with both enabled for typical caches, then profile.

## GenServer Path vs Direct Read

| Path | API | Cost |
|------|-----|------|
| Through owner | `get/2` | one `call` + lookup in owner |
| Direct | `fetch/2` | `:ets.lookup/2` only |

```elixir
{:ok, pid} = Patterns.EtsStore.start_link([])
table = Patterns.EtsStore.table(pid)
:ok = Patterns.EtsStore.put(pid, :session, %{user_id: 42})

# Hot path — no GenServer message
{:ok, %{user_id: 42}} = Patterns.EtsStore.fetch(table, :session)
```

Run the built-in comparison from `iex`:

```elixir
result = Patterns.EtsStore.compare_reads(pid, 10_000)
# => %{iterations: 10000, genserver_microseconds: ..., ets_direct_microseconds: ..., speedup: ...}
```

Direct reads should show a measurable `speedup` over `> 1.0` on a typical machine because they
skip message passing.

## Compared to GenServer Map Storage

| | ETS-backed (`EtsStore`) | Map in GenServer (`GenServerCache`) |
|---|---|---|
| **Reads** | can bypass owner with `:public` | always serialized through owner |
| **Writes** | owner + `:ets.insert` | owner updates map |
| **Memory** | table on heap shared by VM | term lives in process state |
| **Complexity** | table options, ownership rules | simpler mental model |
| **Best for** | many readers, larger payloads | moderate size, TTL, stats in one place |

## Access Control Reminder

Tables created here use `:public, :protected`:

- **Any process** may read (`fetch/2`, `:ets.lookup`)
- **Only the owner** may write (`put/2`, `delete/2`)

Never expose a `:public` table id to untrusted code without considering what keys can be read.

## Key Takeaways

1. **GenServer owns, ETS stores** — lifecycle and writes stay in one process; data lives in the table.
2. **`:public` enables read fan-out** — hot paths use `fetch/2`, not `get/2`.
3. **Pick the table type deliberately** — `:set` for KV, `:bag` for multi-valued keys.
4. **Tune `read_concurrency` / `write_concurrency`** when profiling shows contention.
5. **ETS is node-local** — not a distributed cache; pair with replication layers when needed.

## Phase 3 Complete

Fourth and final pattern in **Phase 3 — Functional Patterns**:

- ✅ Pipeline with `with` chains
- ✅ Railway-oriented programming
- ✅ Behaviour & Protocol systems
- ✅ ETS-backed stores

**Phase 4 — Real-World Patterns** has started with the [Rate Limiter](13_rate_limiter.md). Still planned: retries, graceful shutdown, and event sourcing fundamentals.
