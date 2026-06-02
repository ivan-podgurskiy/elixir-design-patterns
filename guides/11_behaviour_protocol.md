# Behaviour & Protocol Systems

## Overview

Elixir has two complementary mechanisms for polymorphism, and the most common
source of confusion is choosing between them. They answer different questions:

- A **behaviour** is a compile-time contract *between modules*. It declares a set
  of `@callback`s that an implementing module promises to provide. Dispatch is by
  **module** — the *caller* decides which implementation to use.
- A **protocol** is runtime polymorphism dispatched on the **data type** of its
  first argument. Dispatch is by **value** — the *data* decides which
  implementation runs.

```
Behaviour  ── dispatch by MODULE ── the caller picks the implementation
Protocol   ── dispatch by VALUE  ── the data picks the implementation
```

This guide builds a tiny notification system that uses **both**, so the contrast
is concrete:

- `Patterns.BehaviourProtocol.Notification` (a **protocol**) turns an event value
  into a message string. The event's type selects the implementation.
- `Patterns.BehaviourProtocol.Channel` (a **behaviour**) describes how a message
  is delivered. The caller selects the channel module.
- `notify/3` wires them together: render with the protocol, deliver with the
  behaviour.

## Problem it Solves

- **Open extension without touching callers**: Add a new event type by writing one
  `defimpl`; add a new delivery channel by writing one module. Existing code is
  untouched in both cases.
- **Explicit contracts**: `@behaviour` + `@callback` let the compiler warn when an
  implementation is missing or mistyped, instead of failing at runtime.
- **Type-driven formatting**: Protocols dispatch on the value, so you never write
  a sprawling `case`/`cond` on the shape of the data.

## When to Use Which

✅ **Reach for a behaviour when:**

- Multiple modules should be interchangeable through a known set of functions
  (strategies, adapters, plug-ins, clients).
- The *caller* chooses the implementation, often from config or at runtime.
- You want compile-time guarantees that an implementation is complete.

✅ **Reach for a protocol when:**

- The right code to run depends on the *type of a value*, not on a caller's
  choice.
- You want to extend behaviour to types you don't own (built-ins, third-party
  structs) without editing them.
- Examples in the standard library: `Enumerable`, `Collectable`,
  `String.Chars`, `Inspect`.

❌ **Avoid when:**

- There is only ever one implementation — a plain function is simpler than either.
- You'd use a protocol purely to branch on a tag you control; a multi-clause
  function pattern-matching on the tag is clearer.

## The Two Mechanisms Side by Side

| | Behaviour | Protocol |
|---|---|---|
| **Defined with** | `@callback` in a module | `defprotocol` |
| **Implemented with** | `@behaviour` + functions | `defimpl ... for: Type` |
| **Dispatch on** | the module the caller names | the type of the first argument |
| **Who chooses** | the caller | the data |
| **Resolved** | compile time (with checks) | runtime (consolidated in builds) |
| **Catch-all** | `@optional_callbacks` | `@fallback_to_any` + `Any` impl |
| **Stdlib examples** | `GenServer`, `Application`, `Plug` | `Enumerable`, `Inspect` |

## The Protocol: dispatch by value

```elixir
defprotocol Patterns.BehaviourProtocol.Notification do
  @fallback_to_any true
  @spec to_message(t()) :: String.t()
  def to_message(event)
end
```

Each type gets its own implementation. The *value you pass* selects which one
runs:

```elixir
defimpl Notification, for: Alert do
  def to_message(%{service: s, level: l, message: nil}),
    do: "[#{l |> Atom.to_string() |> String.upcase()}] #{s}"

  def to_message(%{service: s, level: l, message: m}),
    do: "[#{l |> Atom.to_string() |> String.upcase()}] #{s}: #{m}"
end

defimpl Notification, for: BitString do
  def to_message(string), do: string
end

defimpl Notification, for: Any do
  def to_message(term), do: inspect(term)
end
```

```elixir
alias Patterns.BehaviourProtocol, as: BP
alias Patterns.BehaviourProtocol.{Alert, Deploy}

BP.render(%Alert{service: "api", level: :critical})            # => "[CRITICAL] api"
BP.render(%Deploy{app: "web", version: "1.4.0", status: :ok})  # => "Deploy of web 1.4.0 ..."
BP.render("raw string")                                        # => "raw string"
BP.render(%{anything: true})                                   # => "%{anything: true}"
```

`@fallback_to_any true` plus a `for: Any` implementation means an unknown type
never raises `Protocol.UndefinedError` — it falls back to `inspect/1`.

## The Behaviour: dispatch by module

```elixir
defmodule Patterns.BehaviourProtocol.Channel do
  @callback deliver(message :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback name() :: String.t()
  @optional_callbacks name: 0
end
```

Implementing modules declare `@behaviour` and provide the callbacks. The compiler
checks that the required callbacks exist; `@impl` documents intent and catches
typos:

```elixir
defmodule Patterns.BehaviourProtocol.CollectorChannel do
  @behaviour Patterns.BehaviourProtocol.Channel

  @impl true
  def deliver(message, opts) do
    send(Keyword.get(opts, :pid, self()), {:delivered, __MODULE__, message})
    {:ok, message}
  end

  @impl true
  def name, do: "collector"
end
```

The *caller* chooses the module:

```elixir
BP.notify(alert, CollectorChannel)   # delivers via the collector
BP.notify(alert, ConsoleChannel)     # same event, different module
```

### Optional callbacks

`@optional_callbacks name: 0` makes `name/0` optional. `FailingChannel` omits it,
and the caller falls back gracefully:

```elixir
def channel_name(channel) do
  if function_exported?(channel, :name, 0) do
    channel.name()
  else
    channel |> Module.split() |> List.last()
  end
end
```

### Runtime checking

When a channel is picked dynamically, verify it really implements the contract:

```elixir
def delivery_channel?(module) do
  Code.ensure_loaded?(module) and function_exported?(module, :deliver, 2)
end
```

## Putting It Together

`notify/3` shows the division of labour clearly — the protocol renders, the
behaviour delivers:

```elixir
def notify(event, channel, opts \\ []) when is_atom(channel) do
  event
  |> render()             # protocol: the data picks how it's rendered
  |> channel.deliver(opts) # behaviour: the caller picked the channel module
end
```

```elixir
alert = %Alert{service: "api", level: :warning, message: "high latency"}

BP.notify(alert, CollectorChannel)
# => {:ok, "[WARNING] api: high latency"}

BP.notify(alert, FailingChannel, reason: :down)
# => {:error, :down}
```

## Real-World Applications

- **Behaviours**: `GenServer`, `Supervisor`, `Application`, `Plug`, Ecto adapters,
  Phoenix `LiveView` — pluggable modules selected by the caller or config.
- **Protocols**: `Enumerable` (drives `Enum`/`Stream`), `Collectable`,
  `String.Chars` (string interpolation), `Inspect`, `Jason.Encoder` — behaviour
  selected by the value's type.
- **Both together**: a serializer behaviour (`encode/2` per format module) fed by
  an encoding protocol (per data type) is the same shape as the example here.

## Design Notes

- **Use `@impl`.** Annotating every callback implementation turns "I forgot a
  callback" and "I typo'd a name" into compile-time warnings.
- **Prefer `@fallback_to_any` deliberately.** It's convenient, but a too-broad
  `Any` implementation can hide missing implementations. Only add it when a
  sensible default truly exists.
- **Consolidate protocols in releases.** Mix consolidates protocols at build time
  so dispatch is fast; avoid defining `defimpl`s dynamically at runtime.
- **Don't reach for a protocol to branch on your own tag.** If you control the
  data and it carries a tag, a multi-clause function is simpler and faster to read.
- **Behaviours document intent.** Even a single implementation benefits from a
  `@callback` contract when you expect others (or future you) to add more.

## Testing Tips

1. Test protocol implementations directly per type, including the `Any` fallback.
2. Prove dispatch is by value: give two different structs and assert each routes
   to its own implementation.
3. For behaviours, use a test-only channel that records deliveries (send to a pid,
   then `assert_received`) so you don't need real I/O.
4. Cover the error track — a channel that returns `{:error, _}` — and assert the
   caller propagates it.
5. Test the optional-callback fallback: a module without `name/0` should still
   produce a derived name.

## Key Takeaways

1. **Behaviour = caller picks the module; protocol = data picks the
   implementation.** This is the whole distinction.
2. **Behaviours are compile-time contracts** — `@callback` + `@behaviour` +
   `@impl` give you checks and clear intent.
3. **Protocols extend behaviour to any type** — including types you don't own,
   without editing them.
4. **`@optional_callbacks` and `@fallback_to_any`** are the escape hatches for
   "this part is optional" on each side.
5. **They compose** — render with a protocol, deliver with a behaviour.

## Phase 3 Progress

Third pattern in **Phase 3 — Functional Patterns**:

- ✅ Pipeline with `with` chains
- ✅ Railway-oriented programming
- ✅ Behaviour & Protocol systems
- ⏳ ETS-backed stores
