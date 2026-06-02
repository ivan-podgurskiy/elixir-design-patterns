defprotocol Patterns.BehaviourProtocol.Notification do
  @moduledoc """
  Protocol that renders an arbitrary event value into a human-readable message.

  This is **runtime polymorphism dispatched on the data type** of the argument:
  the value you pass in decides which implementation runs. Add support for a new
  event type by writing a `defimpl` for it — no existing code changes.

  `@fallback_to_any true` provides a catch-all `Any` implementation so the
  protocol never raises `Protocol.UndefinedError` for an unknown type.
  """

  @fallback_to_any true

  @typedoc "Any value that can be rendered into a notification message."
  @type t :: term()

  @doc """
  Returns the message string for `event`.
  """
  @spec to_message(t()) :: String.t()
  def to_message(event)
end

defmodule Patterns.BehaviourProtocol.Alert do
  @moduledoc """
  An operational alert about a service. Used to demonstrate protocol dispatch on
  a custom struct.
  """

  @enforce_keys [:service]
  defstruct service: nil, level: :info, message: nil

  @type level :: :info | :warning | :critical

  @type t :: %__MODULE__{
          service: String.t(),
          level: level(),
          message: String.t() | nil
        }
end

defmodule Patterns.BehaviourProtocol.Deploy do
  @moduledoc """
  A deployment event. A second struct so the protocol has more than one custom
  implementation to dispatch between.
  """

  @enforce_keys [:app, :version]
  defstruct app: nil, version: nil, status: :started

  @type status :: :started | :succeeded | :failed

  @type t :: %__MODULE__{
          app: String.t(),
          version: String.t(),
          status: status()
        }
end

defimpl Patterns.BehaviourProtocol.Notification, for: Patterns.BehaviourProtocol.Alert do
  def to_message(%{service: service, level: level, message: nil}) do
    "[#{format_level(level)}] #{service}"
  end

  def to_message(%{service: service, level: level, message: message}) do
    "[#{format_level(level)}] #{service}: #{message}"
  end

  defp format_level(level), do: level |> Atom.to_string() |> String.upcase()
end

defimpl Patterns.BehaviourProtocol.Notification, for: Patterns.BehaviourProtocol.Deploy do
  def to_message(%{app: app, version: version, status: status}) do
    "Deploy of #{app} #{version} #{status_phrase(status)}"
  end

  defp status_phrase(:started), do: "started"
  defp status_phrase(:succeeded), do: "succeeded"
  defp status_phrase(:failed), do: "failed"
end

defimpl Patterns.BehaviourProtocol.Notification, for: BitString do
  def to_message(string), do: string
end

defimpl Patterns.BehaviourProtocol.Notification, for: Any do
  def to_message(term), do: inspect(term)
end

defmodule Patterns.BehaviourProtocol.Channel do
  @moduledoc """
  Behaviour describing how a rendered message is delivered.

  This is **compile-time polymorphism dispatched on the module**: the caller
  decides which channel module to use. Any module that implements `deliver/2`
  can be plugged in. `@behaviour Patterns.BehaviourProtocol.Channel` makes the
  contract explicit and lets the compiler warn about missing or mistyped
  callbacks.

  `name/0` is an *optional* callback: channels may provide a friendly label, and
  callers fall back to a derived name when it is absent (see
  `Patterns.BehaviourProtocol.channel_name/1`).
  """

  @doc """
  Delivers `message`, returning `{:ok, term}` on success or `{:error, reason}`.

  `opts` is a keyword list of channel-specific options.
  """
  @callback deliver(message :: String.t(), opts :: keyword()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Optional friendly name for the channel.
  """
  @callback name() :: String.t()

  @optional_callbacks name: 0
end

defmodule Patterns.BehaviourProtocol.ConsoleChannel do
  @moduledoc """
  Channel that writes the message to an IO device (`:stdio` by default).

  Pass `device:` in `opts` to redirect output, e.g. a `StringIO` device in tests.
  """

  @behaviour Patterns.BehaviourProtocol.Channel

  @impl Patterns.BehaviourProtocol.Channel
  def deliver(message, opts) when is_binary(message) do
    device = Keyword.get(opts, :device, :stdio)
    IO.puts(device, message)
    {:ok, message}
  end

  @impl Patterns.BehaviourProtocol.Channel
  def name, do: "console"
end

defmodule Patterns.BehaviourProtocol.CollectorChannel do
  @moduledoc """
  Channel that sends `{:delivered, channel, message}` to a pid instead of doing
  real I/O, which makes deliveries easy to assert on in tests.

  Pass `pid:` in `opts` to choose the recipient; it defaults to the caller.
  """

  @behaviour Patterns.BehaviourProtocol.Channel

  @impl Patterns.BehaviourProtocol.Channel
  def deliver(message, opts) when is_binary(message) do
    pid = Keyword.get(opts, :pid, self())
    send(pid, {:delivered, __MODULE__, message})
    {:ok, message}
  end

  @impl Patterns.BehaviourProtocol.Channel
  def name, do: "collector"
end

defmodule Patterns.BehaviourProtocol.FailingChannel do
  @moduledoc """
  Channel that always fails. Used to exercise the error path, and deliberately
  omits the optional `name/0` callback to show the fallback in
  `Patterns.BehaviourProtocol.channel_name/1`.

  Pass `reason:` in `opts` to control the returned error reason.
  """

  @behaviour Patterns.BehaviourProtocol.Channel

  @impl Patterns.BehaviourProtocol.Channel
  def deliver(message, opts) when is_binary(message) do
    {:error, Keyword.get(opts, :reason, :unavailable)}
  end
end

defmodule Patterns.BehaviourProtocol do
  @moduledoc """
  Demonstrates the two complementary forms of polymorphism in Elixir —
  **behaviours** and **protocols** — and the crucial difference between them.

  - A **behaviour** is a compile-time contract *between modules*: it lists the
    callbacks a module promises to implement. Dispatch is by **module** — the
    *caller* picks the implementation. See `Patterns.BehaviourProtocol.Channel`.
  - A **protocol** is runtime polymorphism dispatched on the **data type** of its
    first argument. Dispatch is by **value** — the *data* picks the
    implementation. See `Patterns.BehaviourProtocol.Notification`.

  This module models a tiny notification system that uses both:

  - The `Notification` protocol turns an arbitrary event value into a message.
    The event's *type* selects the implementation.
  - The `Channel` behaviour describes how a message is delivered (console,
    collector, ...). The *caller* selects the channel module.

  `notify/3` wires them together: render the event with the protocol, then
  deliver the message through the chosen behaviour module.

      Behaviour  ── dispatch by MODULE ── caller picks the implementation
      Protocol   ── dispatch by VALUE  ── data picks the implementation

  ## Examples

      iex> alias Patterns.BehaviourProtocol
      iex> alias Patterns.BehaviourProtocol.Alert
      iex> BehaviourProtocol.render(%Alert{service: "api", level: :critical})
      "[CRITICAL] api"

      iex> alias Patterns.BehaviourProtocol
      iex> alias Patterns.BehaviourProtocol.{Alert, CollectorChannel}
      iex> alert = %Alert{service: "api", level: :warning, message: "high latency"}
      iex> BehaviourProtocol.notify(alert, CollectorChannel)
      {:ok, "[WARNING] api: high latency"}
      iex> receive do
      ...>   {:delivered, CollectorChannel, message} -> message
      ...> end
      "[WARNING] api: high latency"

  """

  alias Patterns.BehaviourProtocol.Notification

  @doc """
  Renders `event` into a message string via the `Notification` protocol.

  Dispatch is by the *type* of `event`: structs, strings, and any other term all
  resolve to their matching implementation.

  ## Examples

      iex> alias Patterns.BehaviourProtocol
      iex> alias Patterns.BehaviourProtocol.Deploy
      iex> BehaviourProtocol.render(%Deploy{app: "web", version: "1.4.0", status: :succeeded})
      "Deploy of web 1.4.0 succeeded"

      iex> Patterns.BehaviourProtocol.render("raw message")
      "raw message"

      iex> Patterns.BehaviourProtocol.render(%{unexpected: true})
      "%{unexpected: true}"

  """
  @spec render(Notification.t()) :: String.t()
  def render(event), do: Notification.to_message(event)

  @doc """
  Renders `event` and delivers it through `channel` (a module implementing the
  `Patterns.BehaviourProtocol.Channel` behaviour).

  Returns whatever the channel's `deliver/2` returns — `{:ok, term}` or
  `{:error, reason}`.

  ## Examples

      iex> alias Patterns.BehaviourProtocol
      iex> alias Patterns.BehaviourProtocol.FailingChannel
      iex> BehaviourProtocol.notify("ping", FailingChannel, reason: :down)
      {:error, :down}

  """
  @spec notify(Notification.t(), module(), keyword()) :: {:ok, term()} | {:error, term()}
  def notify(event, channel, opts \\ []) when is_atom(channel) do
    event
    |> render()
    |> channel.deliver(opts)
  end

  @doc """
  Returns `true` when `module` implements the `Channel` behaviour (i.e. exports
  the required `deliver/2` callback).

  This is the runtime counterpart to the compile-time `@behaviour` check — useful
  when a channel module is chosen dynamically.

  ## Examples

      iex> Patterns.BehaviourProtocol.delivery_channel?(Patterns.BehaviourProtocol.ConsoleChannel)
      true

      iex> Patterns.BehaviourProtocol.delivery_channel?(Enum)
      false

  """
  @spec delivery_channel?(module()) :: boolean()
  def delivery_channel?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :deliver, 2)
  end

  @doc """
  Returns a friendly name for `channel`.

  Calls the optional `name/0` callback when the channel implements it; otherwise
  derives a name from the module's last segment.

  ## Examples

      iex> Patterns.BehaviourProtocol.channel_name(Patterns.BehaviourProtocol.ConsoleChannel)
      "console"

      iex> Patterns.BehaviourProtocol.channel_name(Patterns.BehaviourProtocol.FailingChannel)
      "FailingChannel"

  """
  @spec channel_name(module()) :: String.t()
  def channel_name(channel) when is_atom(channel) do
    if Code.ensure_loaded?(channel) and function_exported?(channel, :name, 0) do
      channel.name()
    else
      channel |> Module.split() |> List.last()
    end
  end
end
