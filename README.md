# Elixir Design Patterns

> Practical, runnable examples of OTP and functional design patterns in Elixir.
> Each pattern is a self-contained module with tests, docs, and a real-world use case.

[![CI](https://github.com/yourusername/elixir-design-patterns/workflows/CI/badge.svg)](https://github.com/yourusername/elixir-design-patterns/actions)
[![Elixir Version](https://img.shields.io/badge/elixir-1.14+-blue.svg)](https://elixir-lang.org/)
[![OTP Version](https://img.shields.io/badge/otp-25+-blue.svg)](https://www.erlang.org/)

## Overview

This repository demonstrates deep Elixir/OTP expertise through comprehensive, runnable examples of common patterns. Each pattern includes:

- **Clean, documented code** with full typespecs
- **Comprehensive tests** covering happy path, edge cases, and error scenarios
- **Detailed guides** explaining when and how to use each pattern
- **Real-world examples** from production experience
- **IEx demonstrations** you can try immediately

## Quick Start

```bash
git clone https://github.com/yourusername/elixir-design-patterns.git
cd elixir-design-patterns
mix deps.get
mix test
```

Try a pattern in IEx:
```bash
iex -S mix
```

```elixir
# Start a cache with TTL
{:ok, cache} = Patterns.GenServerCache.start_link()
:ok = Patterns.GenServerCache.put(cache, "user:123", %{name: "John"}, 5000)
{:ok, user} = Patterns.GenServerCache.get(cache, "user:123")
```

## Pattern Index

### Phase 1 — Core OTP Patterns

| Pattern | Module | Description | Guide |
|---------|--------|-------------|--------|
| **GenServer Cache** | [`Patterns.GenServerCache`](lib/patterns/genserver_cache.ex) | In-memory key-value cache with TTL expiration and statistics | [📖 Guide](guides/01_genserver_cache.md) |
| **Supervisor Tree** | [`Patterns.SupervisorTree`](lib/patterns/supervisor_tree.ex) | Fault-tolerant supervision with different restart strategies | [📖 Guide](guides/02_supervisor_tree.md) |
| **Agent State** | [`Patterns.AgentState`](lib/patterns/agent_state.ex) | Simple shared state for counters, config, and statistics | [📖 Guide](guides/03_agent_state.md) |
| **Task.async** | [`Patterns.TaskAsync`](lib/patterns/task_async.ex) | Parallel execution, timeout handling, and result aggregation | [📖 Guide](guides/04_task_async.md) |

### Coming Soon — Additional Phases

**Phase 2 — Process Patterns**
- Registry & Dynamic Supervisors
- Pub/Sub with Registry
- Process Pooling
- Circuit Breaker

**Phase 3 — Functional Patterns**
- Pipeline with `with` chains
- Railway-oriented programming
- Behaviour & Protocol systems
- ETS-backed stores

**Phase 4 — Real-World Patterns**
- Rate Limiter with token bucket
- Retry with exponential backoff
- Graceful shutdown handling
- Event Sourcing fundamentals

## Pattern Categories

### 🔧 **State Management**
- **GenServer Cache**: Production-ready caching with expiration
- **Agent State**: Lightweight shared state for simple scenarios

### 🚦 **Process Supervision**
- **Supervisor Tree**: Fault tolerance with configurable restart strategies
- **Task.async**: Concurrent execution with proper error handling

### ⚡ **Concurrency & Performance**
- **Task.async**: Parallel I/O and CPU-bound operations
- **Agent State**: Thread-safe atomic operations

### 🛡️ **Fault Tolerance**
- **Supervisor Tree**: "Let it crash" philosophy in practice
- **GenServer Cache**: Graceful degradation and recovery

## Code Quality

This project maintains high code quality standards:

```bash
# Run all quality checks
mix test                    # Full test suite
mix credo --strict         # Code analysis
mix dialyzer              # Static type checking
mix format --check-formatted  # Code formatting
mix docs                   # Generate documentation
```

### Quality Metrics
- **100% Test Coverage**: Every pattern has comprehensive tests
- **Full Type Coverage**: All functions have `@spec` annotations
- **Zero Credo Issues**: Strict code quality enforcement
- **Zero Dialyzer Warnings**: Static analysis passing
- **Comprehensive Docs**: Every module has detailed documentation

## Usage Examples

### GenServer Cache
```elixir
{:ok, cache} = Patterns.GenServerCache.start_link()

# Store with TTL
:ok = Patterns.GenServerCache.put(cache, "session:abc", "active", 300_000)

# Retrieve
{:ok, "active"} = Patterns.GenServerCache.get(cache, "session:abc")

# Statistics
%{hits: 1, misses: 0, total_keys: 1} = Patterns.GenServerCache.stats(cache)
```

### Supervision Strategies
```elixir
# Test different supervision strategies
{:ok, sup} = Patterns.SupervisorTree.start_link(:one_for_one)

# Inspect running processes
info = Patterns.SupervisorTree.info(sup)
# %{strategy: :one_for_one, running_count: 3, children: [...]}

# Test fault tolerance
:ok = Patterns.SupervisorTree.crash_child(sup, :worker_1)
# Worker automatically restarts
```

### Parallel Processing
```elixir
# Fetch multiple URLs concurrently
urls = ["https://api.github.com/users/octocat", "https://httpbin.org/ip"]
{:ok, responses} = Patterns.TaskAsync.parallel_fetch(urls, timeout: 5000)

# Process data in parallel
results = Patterns.TaskAsync.parallel_map(1..1000, fn x ->
  expensive_computation(x)
end, max_concurrency: 8)
```

### Statistics Collection
```elixir
{:ok, stats} = Patterns.AgentState.Statistics.start_link()

# Time operations
result = Patterns.AgentState.Statistics.time(stats, :api_call, fn ->
  HTTPoison.get("https://api.example.com/data")
end)

# Get metrics
avg_time = Patterns.AgentState.Statistics.average_time(stats, :api_call)
```

## Real-World Applications

These patterns are used in production for:

- **API Gateways**: Parallel service aggregation with fault tolerance
- **Caching Layers**: High-performance in-memory caches with TTL
- **Background Processing**: Job queues with supervised workers
- **Microservices**: Service coordination and health monitoring
- **Data Pipelines**: ETL processing with error recovery

## Learning Path

1. **Start with Agent State** — Simplest pattern for shared state
2. **Move to GenServer Cache** — More complex state with business logic
3. **Explore Supervision** — Understand fault tolerance fundamentals
4. **Master Task.async** — Concurrent programming patterns

Each pattern builds on concepts from the previous ones.

## Architecture Principles

### The Elixir Way
- **Let It Crash**: Use supervision for fault tolerance
- **Immutable Data**: Functional programming principles
- **Actor Model**: Isolated processes communicating via messages
- **OTP Design**: Battle-tested concurrency patterns

### Code Organization
- **Single Responsibility**: Each pattern solves one problem well
- **Composability**: Patterns can be combined for complex systems
- **Testability**: Every pattern is thoroughly tested
- **Documentation**: Self-documenting code with comprehensive guides

## Development

### Prerequisites
- Elixir 1.14+ with OTP 25+
- Understanding of basic Elixir/OTP concepts

### Running Tests
```bash
# All tests
mix test

# Specific pattern
mix test test/patterns/genserver_cache_test.exs

# With coverage
mix test --cover
```

### Code Quality
```bash
# Format code
mix format

# Static analysis
mix credo --strict

# Type checking
mix dialyzer

# Generate docs
mix docs && open doc/index.html
```

## Contributing

This is primarily a demonstration repository, but improvements are welcome:

1. **Bug Reports**: Open an issue with reproduction steps
2. **Documentation**: Clarifications and corrections
3. **Performance**: Benchmarks and optimizations
4. **Examples**: Additional real-world usage scenarios

## Project Status

- ✅ **Phase 1 Complete**: Core OTP patterns with full documentation
- 🚧 **Phase 2 In Progress**: Advanced process patterns
- 📋 **Phase 3 Planned**: Functional programming patterns
- 📋 **Phase 4 Planned**: Real-world production patterns

## Resources

### Learning More
- [Elixir School](https://elixirschool.com/) — Comprehensive Elixir tutorial
- [Programming Elixir](https://pragprog.com/titles/elixir16/) — Dave Thomas book
- [Designing Elixir Systems](https://pragprog.com/titles/jgotp/) — OTP patterns

### Pattern Guides
- [GenServer Cache Guide](guides/01_genserver_cache.md)
- [Supervisor Tree Guide](guides/02_supervisor_tree.md)
- [Agent State Guide](guides/03_agent_state.md)
- [Task.async Guide](guides/04_task_async.md)

---

**Built with ❤️ for the Elixir community**

Demonstrating production-ready patterns that power reliable, concurrent systems.

