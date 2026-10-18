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
| `matcher-frompath.yml` | a matcher's `fromPath` (SPEC §6) | the annotations' **paths** |

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

## What the `fromPath` comparison found

`fromPath` is the one matcher property no action this runner would meet ships — .NET's matcher is its
canonical user, and .NET is a non-goal — so it was implemented from GitHub's documentation rather
than from its observed behaviour. That makes it the comparison most worth running, not the least:
everything else here checks a feature that was written by watching GitHub, while this one checks
whether a specification was read correctly.

It was read correctly. One run, both arms:

```
hosted       failure  probe/shared/Util.cs:7:2              dot-dot, resolves to probe/shared/Util.cs
             warning  probe/app/sub/Other.cs:3:1            resolves to probe/app/sub/Other.cs
             failure  probe/app/Program.cs:12:5             resolves to probe/app/Program.cs
selfhosted   failure  probe/shared/Util.cs:7:2    [PP0003]  dot-dot, resolves to probe/shared/Util.cs
             warning  probe/app/sub/Other.cs:3:1  [PP0002]  resolves to probe/app/sub/Other.cs
             failure  probe/app/Program.cs:12:5   [PP0001]  resolves to probe/app/Program.cs
```

Same path, line and column on all three, including the one reached with `..`. The only difference is
the one the other matcher comparison also shows: ours keeps the matcher's `code` as the annotation
title, where GitHub drops it.

**The first attempt failed, and that was worth more than a pass.** The matcher JSON contained `\.`
where JSON requires `\\.`, and the two runners disagreed about what to do: GitHub's **failed the
step** ("Bad JSON escape sequence"), while this one warned and carried on with no matcher. That is
the documented divergence in SPEC §9, seen live rather than asserted — and a reminder that a matcher
which silently does nothing is easy to miss, which is what the warning is for.

The probe files are committed rather than written by the job because GitHub's annotation payload
falls back to the workflow file for a path that is not in the commit. That is why `matcher-check.yml`
shows `.github` on the hosted side, and without real files this comparison would have shown two
fallbacks and proved nothing.
