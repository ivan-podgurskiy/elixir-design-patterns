# Contributing

Thank you for improving this repository. Bug reports, documentation fixes, and well-tested examples are welcome.

## Conventional Commits

This project uses [Conventional Commits](https://www.conventionalcommits.org/) for changelog generation (release-please) and consistent dependency update messages (Renovate `semanticCommits`).

Use these prefixes in commit titles:

| Prefix | When to use |
|--------|-------------|
| `feat:` | New pattern, module, or user-facing capability |
| `fix:` | Bug fix or corrected behavior |
| `docs:` | Documentation or guide changes only |
| `test:` | Test additions or fixes without behavior changes |
| `refactor:` | Code restructuring without behavior change |
| `chore:` | Maintenance, tooling, CI, formatting |
| `deps:` | Dependency updates (Renovate may use this automatically) |
| `perf:` | Performance improvements |
| `ci:` | CI/CD workflow changes |

Examples:

```text
feat: add rate limiter pattern
fix: handle timeout in process pool checkout
docs: clarify supervisor restart strategies in guide
chore: update credo configuration
deps: update excoveralls to 0.18.5
```

Breaking changes: append `!` after the type/scope or add a `BREAKING CHANGE:` footer:

```text
feat!: rename Patterns.Cache to Patterns.GenServerCache
```

## Pull Requests

1. Open a PR against `main`.
2. Ensure CI passes (tests, Credo, Dialyzer, coverage).
3. Wait for review and approval — all merges require explicit approval; Mergify only executes the merge after approval.

See [README.md](README.md) for local setup and quality checks.
