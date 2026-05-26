defmodule Patterns.RegistryPubSub do
  @moduledoc """
  Demonstrates publish/subscribe event distribution using a duplicate-key `Registry`.

  This pattern showcases:
  - Topic-based subscriptions with multiple subscribers per topic
  - Fan-out message delivery via `Registry.dispatch/3`
  - Automatic cleanup when subscribers exit
  - Topic introspection and subscriber counts

  ## Examples

      iex> {:ok, sup} = Patterns.RegistryPubSub.start()
      iex> :ok = Patterns.RegistryPubSub.subscribe(sup, "orders.created")
      iex> {:ok, 1} = Patterns.RegistryPubSub.publish(sup, "orders.created", %{id: 1})

  """

  use Supervisor

  @type topic :: term()
  @type message :: term()
  @type subscriber_info :: %{
          pid: pid(),
          topic: topic(),
          metadata: term()
        }

  @doc """
  Starts the pub/sub supervisor with a duplicate-key registry.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts)
  end

  @doc """
  Starts an unlinked pub/sub supervisor for testing or embedding.
  """
  @spec start(keyword()) :: Supervisor.on_start()
  def start(opts \\ []) do
    case Supervisor.start_link(__MODULE__, opts) do
      {:ok, pid} = result ->
        Process.unlink(pid)
        result

      error ->
        error
    end
  end

  @doc """
  Subscribes the calling process to a topic.

  Subscribers receive messages as `{:pubsub, topic, payload}`.
  """
  @spec subscribe(Supervisor.supervisor(), topic()) :: :ok
  def subscribe(supervisor, topic) do
    %{registry: registry} = components(supervisor)

    if subscribed?(registry, topic, self()) do
      :ok
    else
      metadata = %{subscribed_at: System.monotonic_time(:millisecond)}
      {:ok, _} = Registry.register(registry, topic, metadata)
      :ok
    end
  end

  @doc """
  Unsubscribes a process from a topic.
  """
  @spec unsubscribe(Supervisor.supervisor(), topic(), pid()) :: :ok
  def unsubscribe(supervisor, topic, subscriber \\ self()) do
    %{registry: registry} = components(supervisor)

    if subscriber == self() do
      Registry.unregister(registry, topic)
    else
      Registry.unregister_match(registry, topic, subscriber)
    end

    :ok
  end

  @doc """
  Publishes a message to all subscribers of a topic.

  Returns `{:ok, delivery_count}`.
  """
  @spec publish(Supervisor.supervisor(), topic(), message()) ::
          {:ok, non_neg_integer()}
  def publish(supervisor, topic, message) do
    %{registry: registry} = components(supervisor)
    count = dispatch(registry, topic, message)
    {:ok, count}
  end

  @doc """
  Returns all subscribers for a topic.
  """
  @spec subscribers(Supervisor.supervisor(), topic()) :: [subscriber_info()]
  def subscribers(supervisor, topic) do
    %{registry: registry} = components(supervisor)

    registry
    |> Registry.lookup(topic)
    |> Enum.map(fn {pid, metadata} ->
      %{pid: pid, topic: topic, metadata: metadata}
    end)
    |> Enum.sort_by(& &1.pid)
  end

  @doc """
  Returns the number of subscribers for a topic.
  """
  @spec subscriber_count(Supervisor.supervisor(), topic()) :: non_neg_integer()
  def subscriber_count(supervisor, topic) do
    supervisor
    |> subscribers(topic)
    |> length()
  end

  @doc """
  Returns all topics that currently have at least one subscriber.
  """
  @spec topics(Supervisor.supervisor()) :: [topic()]
  def topics(supervisor) do
    %{registry: registry} = components(supervisor)

    registry
    |> Registry.select([{{:"$1", :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc """
  Returns pub/sub system information.
  """
  @spec info(Supervisor.supervisor()) :: %{
          registry: atom(),
          topic_count: non_neg_integer(),
          subscriber_count: non_neg_integer(),
          topics: [{topic(), non_neg_integer()}]
        }
  def info(supervisor) do
    %{registry: registry} = components(supervisor)
    topic_list = topics(supervisor)

    topic_counts =
      Enum.map(topic_list, fn topic ->
        {topic, subscriber_count(supervisor, topic)}
      end)

    total_subscribers =
      Registry.select(registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      |> length()

    %{
      registry: registry,
      topic_count: length(topic_list),
      subscriber_count: total_subscribers,
      topics: topic_counts
    }
  end

  @impl Supervisor
  def init(_opts) do
    suffix = System.unique_integer([:positive])
    registry = :"#{__MODULE__}.Registry.#{suffix}"

    :persistent_term.put({__MODULE__, self()}, %{registry: registry})

    children = [
      {Registry, keys: :duplicate, name: registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp components(supervisor) do
    :persistent_term.get({__MODULE__, supervisor})
  end

  defp dispatch(registry, topic, message) do
    count =
      registry
      |> Registry.lookup(topic)
      |> length()

    Registry.dispatch(registry, topic, fn entries ->
      Enum.each(entries, fn {pid, _metadata} ->
        send(pid, {:pubsub, topic, message})
      end)
    end)

    count
  end

  defp subscribed?(registry, topic, pid) do
    Enum.any?(Registry.lookup(registry, topic), fn
      {^pid, _} -> true
      _ -> false
    end)
  end
end

defmodule Patterns.RegistryPubSub.Subscriber do
  @moduledoc """
  A GenServer subscriber that collects published messages for demos and tests.
  """

  use GenServer

  alias Patterns.RegistryPubSub

  @type t :: pid()

  @doc """
  Starts a subscriber process for the given topic.
  """
  @spec start_link(Supervisor.supervisor(), RegistryPubSub.topic()) :: GenServer.on_start()
  def start_link(supervisor, topic) do
    GenServer.start_link(__MODULE__, {supervisor, topic})
  end

  @doc """
  Starts an unlinked subscriber process.
  """
  @spec start(Supervisor.supervisor(), RegistryPubSub.topic()) :: GenServer.on_start()
  def start(supervisor, topic) do
    GenServer.start(__MODULE__, {supervisor, topic})
  end

  @doc """
  Returns messages received by the subscriber.
  """
  @spec messages(t()) :: [{RegistryPubSub.topic(), RegistryPubSub.message()}]
  def messages(subscriber) do
    GenServer.call(subscriber, :messages)
  end

  @doc """
  Clears the collected message buffer.
  """
  @spec flush(t()) :: :ok
  def flush(subscriber) do
    GenServer.call(subscriber, :flush)
  end

  @impl GenServer
  def init({supervisor, topic}) do
    :ok = RegistryPubSub.subscribe(supervisor, topic)
    {:ok, %{topic: topic, messages: []}}
  end

  @impl GenServer
  def handle_call(:messages, _from, state) do
    {:reply, Enum.reverse(state.messages), state}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    {:reply, :ok, %{state | messages: []}}
  end

  @impl GenServer
  def handle_info({:pubsub, topic, message}, state) do
    {:noreply, %{state | messages: [{topic, message} | state.messages]}}
  end
end
