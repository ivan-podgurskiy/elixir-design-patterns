# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2024-11-15

### Added - Phase 1: Core OTP Patterns

#### GenServer Cache Pattern
- In-memory key-value cache with TTL expiration
- Hit/miss statistics tracking
- Automatic cleanup of expired entries
- Comprehensive test suite with 100% coverage
- Detailed guide with real-world examples

#### Supervisor Tree Pattern
- One-for-one, one-for-all, and rest-for-one supervision strategies
- Dynamic child management (add/remove at runtime)
- Worker process demonstrations with fault tolerance testing
- Child process introspection and monitoring
- Comprehensive supervision strategy comparisons

#### Agent State Pattern
- Counter implementation with atomic operations
- Configuration store with hot-reloading capabilities
- Statistics collector with timing functionality
- Thread-safe concurrent access patterns
- Integration examples for real-world applications

#### Task.async Pattern
- Parallel HTTP fetching with timeout handling
- Concurrent data processing with controlled concurrency
- Task racing for fastest-wins scenarios
- Retry mechanisms with exponential backoff
- Pipeline processing patterns

### Infrastructure
- GitHub Actions CI/CD pipeline
- Code quality tools: Credo, Dialyzer, ExCoveralls
- Comprehensive test coverage across all patterns
- ExDoc documentation generation
- Code formatting with consistent style

### Documentation
- Pattern-specific guides with when/why/how explanations
- Real-world usage examples and scenarios
- IEx demonstrations for hands-on learning
- Architecture principles and best practices
- Performance characteristics and trade-offs

## [Unreleased]

### Added - Phase 2: Process Patterns (Part 1)

#### Registry & Dynamic Supervisors Pattern
- Registry-backed unique key to pid lookup
- DynamicSupervisor for on-demand worker lifecycle
- Idempotent `start_worker/2` and keyed `call/4` / `cast/3` APIs
- Worker crash recovery with automatic re-registration
- Introspection via `info/1` and `list_workers/1`
- Comprehensive test suite and detailed guide

### Added - Phase 2: Process Patterns (Part 2)

#### Pub/Sub with Registry Pattern
- Duplicate-key Registry for multi-subscriber topics
- Topic subscribe/unsubscribe and fan-out publish via `Registry.dispatch/3`
- Subscriber helper GenServer for demos and testing
- Topic and subscriber introspection via `info/1` and `topics/1`
- Automatic unregistration when subscribers exit
- Comprehensive test suite and detailed guide

### Added - Phase 2: Process Patterns (Part 3)

#### Process Pooling Pattern
- Fixed-size pre-warmed worker pool with FIFO waiting queue
- Checkout/checkin and transaction APIs with timeout support
- Interchangeable worker job processing
- Automatic worker replacement on crash
- Pool utilization introspection via `info/1`
- Comprehensive test suite and detailed guide

### Added - Phase 2: Process Patterns (Part 4)

#### Circuit Breaker Pattern
- Three-state machine: closed, open, and half-open
- Failure-threshold tripping and fail-fast rejection when open
- Probationary half-open recovery with configurable success threshold
- Isolated call execution capturing exceptions, exits, and timeouts as failures
- Configurable failure predicate, reset timeout, and call timeout
- Manual `trip/1` and `reset/1` controls plus `state/1` and `stats/1` introspection
- Comprehensive test suite and detailed guide

### Planned - Phase 3: Functional Patterns
- Pipeline processing with `with` statement chains
- Railway-oriented programming for error handling
- Behaviour and Protocol system demonstrations
- ETS-backed storage patterns with performance comparisons

### Planned - Phase 4: Real-World Patterns
- Rate limiter using token bucket algorithm
- Retry patterns with jitter and backoff strategies
- Graceful shutdown handling for production systems
- Event sourcing fundamentals with projections

---

## Version History Summary

- **v1.0.0** (Phase 1): Core OTP patterns - GenServer, Supervisor, Agent, Task
- **v1.1.0** (Phase 2): Advanced process management patterns
- **v1.2.0** (Phase 3): Functional programming and data transformation patterns
- **v1.3.0** (Phase 4): Production-ready reliability and scaling patterns

## Development Timeline

- **March 2023**: Project initialization and foundation
- **April-August 2023**: Phase 1 core patterns development
- **September-December 2023**: Testing and documentation improvements
- **January-June 2024**: Continuous refinement and optimization
- **July-November 2024**: Final polish and comprehensive documentation

---

For detailed information about each pattern, see the individual guides in the `guides/` directory.