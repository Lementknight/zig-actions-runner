# E8.3: did testmon miss the edit, or does no test cover it?

Audience: whoever re-checks this · Register: [CLAIMS.md](../../docs/CLAIMS.md) E8.3 · Rules:
[MEASURE.md](../../docs/MEASURE.md) §3.2

The study's row: changing a leaf module (`util/langhelpers.py`) made testmon select **62 of 9,380**
tests — the same 62 as changing nothing at all. [STUDY.md](../../docs/STUDY.md) §12 marked it
inconclusive in writing:

> either testmon missed it or the function the edit landed in is covered by no test. Without
> checking which, it cannot be read as evidence that testmon is wrong, so it is not.

## Not a measurement, so not measured

This is the one claim in the register that a timing series cannot settle. It asks **which of two
mechanisms** produced an observation, and the answer is a selection count — which is a function of
the code and the tests, not of the machine. So `reproduce.sh` runs locally in about four minutes
rather than on the Pi, and the protocol's apparatus (interleaving, bootstrap intervals, a negative
control) would answer nothing here. What stands in for a negative control is that the experiment has
**two arms with known answers in opposite directions**: edit something the suite calls, and edit
something it never executes.

## The answer

The study's row reproduces exactly, and the ambiguity resolves in favour of testmon.

| | Tests selected | Tests actually run |
|---|---|---|
| first run, building the database | 9,325 | 9,325 |
| again, nothing changed | **62** | **0** |
| after editing `find_matching_paren` — a function `test/base/test_utils.py` calls directly | **25** | **25** |
| after editing `asbool` — same file, never executed by this suite | **62** | **0** |

**testmon did not miss anything.** Edit a covered function in that leaf module and it selects 25
tests, precisely the ones touching it, and runs them in 2.7 s. Edit an uncovered function in the
same file and it selects the same 62 as no change at all. So the study's leaf-module edit landed in
code the suite does not cover, which is the second of its two explanations.

That was a likely place to land: of the 141 functions in `langhelpers.py`, **29 are never executed**
by `test/base test/sql` — 21% of the file. The suite is large (9,325 tests) but it is not a coverage
suite for the utility module.

E8.3 therefore **holds as stated and is no longer ambiguous**: the row is real, and it says something
about sqlalchemy's coverage rather than about testmon's tracing. It is still not evidence that
testmon is wrong, which is what §12 refused to read into it — correctly.

## The 62 never run, which the row does not say

`62 selected` is followed by `6097 deselected in 1.09s` and **no pass count**, with pytest exiting 0.
Those 62 are selected at collection and then nothing executes. The study's column header is "Tests
chosen", which is accurate, but the natural reading of "62 of 9,380" is that 62 tests ran, and none
did.

This sharpens §12's conclusion rather than disturbing it. The unchanged case is not "7.5 s to run 62
tests", it is 7.5 s to collect 9,380 and run none — so tool-level selection's best case is even more
clearly a no-op than the table suggests, and the step cache already replays that case for nothing.
The finding that selection is a bad trade here rested on the *changed* case (261.8 s for 79% of the
suite), which this does not touch.

## What this ran on, and the one thing that differs from the study

Python 3.12.14 on arm64 macOS, pytest 9.1.1, pytest-testmon 2.2.0, sqlalchemy at
`7b95e267c867f9e35ee0aba7e637f373522b0e1d` — 9,325 tests against the study's 9,300, so the same
suite. The study ran on the Pi at Python 3.12.3. Selection counts do not depend on the machine, and
the timings here are not offered as comparable with the study's.

One loose end, recorded rather than chased: testmon reports `changed files: 20` when `git status`
shows one modified file. It still selected only the floor, which is consistent with selection being
driven by covered code blocks rather than by file count — but nothing here explains the 20.

```sh
./reproduce.sh /tmp/e83        # needs a native python3.12+, about four minutes
```

A native interpreter matters: an x86_64 python under Rosetta cannot load the arm64 extensions an
editable install builds, which is how the first attempt failed. Note also that a local editable
install *does* compile sqlalchemy's Cython extensions, where the install measured in
[w5/](../w5/README.md) on the CI runners did not — the build dependency is present here and absent
there.
