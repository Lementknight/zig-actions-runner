# Zig Actions Runner

A lightweight, Zig-based alternative to the official GitHub Actions runner. Jobs run as Dagger pipelines, and logs are stored in Tiger Data and shown in a custom frontend.

- [Design document](docs/DESIGN.md)
- [Spec sheet](docs/SPEC.md)

Status: design phase.

## Git hooks

`.githooks/` has hooks that catch Zig problems before CI does. Enable them once per clone:

```sh
git config core.hooksPath .githooks
```

- **pre-commit** (fast) checks the staged `.zig` and `.zon` files: `zig fmt` formatting, and the errors `zig ast-check` finds without compiling (syntax, unused locals and parameters, shadowing). It checks what is staged, not the working tree.
- **pre-push** runs what CI's "Zig unit tests" job runs, plus a build: `zig fmt --check`, `zig build` and `zig build test` in `runner/`, on the commit being pushed. It runs only when the commits the remote does not have yet change `runner/`, and uses a temporary worktree when the working tree differs from that commit.

Both do nothing when no Zig code changed, need `zig` on `PATH` when it did, and warn when its version differs from CI's (`ZIG_VERSION` in `.github/workflows/ci.yml`). To skip them once: `git commit --no-verify` / `git push --no-verify`, or `SKIP_ZIG_HOOKS=1`.
