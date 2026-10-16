# Zig Actions Runner

A lightweight, self-hosted GitHub Actions runner in Zig. One small process runs many runners, each job's steps run in a Dagger engine that caches them, and workflows written for GitHub's hosted runners run unchanged, with their logs in GitHub's UI. A Raspberry Pi is the reference machine.

- [Design](docs/DESIGN.md): goals, architecture and the decisions behind them
- [Spec sheet](docs/SPEC.md): configuration, the GitHub protocol, what workflows can use
- [Deploying the runner](docs/DEPLOY.md): Docker Compose, systemd, or a plain binary, and sizing
- Optional: run state and logs in Postgres ([`db/`](db/README.md)), a read API ([`api/`](api/README.md)) and a frontend ([`web/`](web/README.md))

Quick start, on a Linux machine with Docker:

```sh
cp deploy/runner.env.example deploy/runner.env   # fill in GH_TOKEN and GH_SCOPE
docker compose -f deploy/compose.yaml up -d --build
```

Then select the runners in a workflow with `runs-on: [self-hosted, zig]`.

## License

[MIT](LICENSE). Where third-party code and protocols come from is in [THIRD_PARTY.md](THIRD_PARTY.md).

## Git hooks

`.githooks/` has hooks that catch Zig problems before CI does. Enable them once per clone:

```sh
git config core.hooksPath .githooks
```

- **pre-commit** (fast) checks the staged `.zig` and `.zon` files: `zig fmt` formatting, and the errors `zig ast-check` finds without compiling (syntax, unused locals and parameters, shadowing). It checks what is staged, not the working tree.
- **check-workflows** (`cd runner && zig build check-workflows`) checks this repository's workflow YAML with the parser the runner uses for `action.yml`, plus the one rule that parser is laxer about than YAML: a plain scalar cannot contain `": "`. pre-commit runs it on staged workflow files and CI on all of them. Give it other paths after `--`.
- **pre-push** runs what CI's "Zig unit tests" job runs, plus a build: `zig fmt --check`, `zig build` and `zig build test` in `runner/`, on the commit being pushed. It runs only when the commits the remote does not have yet change `runner/`, and uses a temporary worktree when the working tree differs from that commit.

Both do nothing when no Zig code changed, need `zig` on `PATH` when it did, and warn when its version differs from CI's (`ZIG_VERSION` in `.github/workflows/ci.yml`). To skip them once: `git commit --no-verify` / `git push --no-verify`, or `SKIP_ZIG_HOOKS=1`.
