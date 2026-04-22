# Contributing

Early days. PRs welcome but expect churn.

## Dev

```sh
zig build test
zig build run
```

## Git hooks

Activate once per clone so bad formatting and failing tests can't land:

```sh
git config core.hooksPath .githooks
```

- `pre-commit` blocks if `zig fmt --check` fails
- `pre-push` blocks if `zig build test --summary all` fails

## Conventions

- Zig `0.16.0` stable
- Conventional commits (`feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`)
- Small, focused PRs
- Commit messages describe the engineering change — no tracker IDs, sequence numbers, or workflow metadata

## License

By contributing you agree your contributions are licensed under MIT.
