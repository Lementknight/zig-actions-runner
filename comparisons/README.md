# Parity, against GitHub's own runner

Audience: whoever adds a feature GitHub already has · Divergences: [docs/SPEC.md](../docs/SPEC.md)
§9

```sh
./comparisons/gen-workflows.sh /tmp/cmp    # the workloads, for installing in a test repository
gh workflow run shell-python.yml -R "$repo" -f "token=$(date +%s)"
```

A comparison workflow defines the same job twice, once on `ubuntu-latest` and once on
`[self-hosted, zig]`, and is dispatched once. Both arms then answer the same input in the same run,
and the question "does ours behave like GitHub's?" is settled by reading two logs rather than by
reading our log against a memory of GitHub's.

These are generated, not hand-installed, for one reason: a comparison is only evidence if the two
arms are *identical*, and two files that were edited separately are not. One `emit` function
guarantees it. The same argument applies to [properties/](../properties/README.md), which generates
its workloads for the same reason.

## What each one is for

| workflow | the feature | what to read |
|---|---|---|
| `shell-python.yml` | `shell: python` (SPEC §6) | the group header's `shell:` line, the interpreter version, and `sys.argv[0]` |
| `matcher-check.yml` | problem matchers (SPEC §6) | the run's **annotations**, not the log |

`shell: python` is a case where reading GitHub's output changed the implementation three times: it
expands a bare `python` to a full path, it writes the script to a `.py` file — `sys.argv[0]` reaches
a traceback, so the extension is not cosmetic — and it invokes `python`, not `python3`.

`matcher-check.yml` registers the matcher in one step and emits diagnostics in a later one. That is
the realistic shape (`setup-node` registers tsc's matcher; the compiler runs after it) and also the
only shape the two runners agree on, because ours applies a matcher from the *next* step. A version
that emitted diagnostics in the registering step would be demonstrating that divergence rather than
testing anything, and SPEC §9 already records it.

Expect the same levels, lines, columns and messages from both arms, and two differences in ours: it
reports the path the matcher captured where GitHub falls back to the workflow file (those source
files are not in the checked-out repository), and it keeps the matcher's `code` as the annotation
title, which GitHub drops. The third diagnostic line matches nothing and must produce no annotation
on either.

## Running them

Install the output in the test repository and start a runner scoped to it
([docs/DEPLOY.md](../docs/DEPLOY.md)). The `token` input exists so that no step is replayed from the
cache between trials: pass something new every time, or a second trial measures the cache rather
than the feature.

Nothing here is kept installed. A parity check is run when the behaviour it covers changes, and a
test repository with a workflow per past experiment is a repository nobody can read — so these are
generated, dispatched, and removed again.
