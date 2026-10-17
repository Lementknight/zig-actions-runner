#!/usr/bin/env python3
"""Compares src/regex.zig against Python's `re` on a corpus of patterns and inputs.

    zig build && python3 tools/regex_diff.py [--random N] [--seed S]

Writing our own matcher is only defensible if something else agrees with it. The corpus is the five
patterns real actions ship, a set covering each supported construct, and optionally N random
patterns generated from the supported grammar paired with inputs likely to interact with them.

`re.ASCII` is used throughout, because `\\d` `\\w` `\\s` are Unicode-aware in Python by default and
ours are bytes. Both search rather than anchor, both are leftmost-first with backtracking, and both
report a group that took no part in the match as absent — so the two are comparable on this subset.

A disagreement is printed with the pattern, the input, and both answers. A pattern our engine
refuses (`Unsupported`) is counted and skipped, not failed: refusing is a documented choice.
"""

import argparse
import json
import random
import re
import subprocess
import sys
from pathlib import Path

# `python3 -I` keeps the script's own directory off sys.path, so say where the grammar lives.
sys.path.insert(0, str(Path(__file__).resolve().parent))
import regex_grammar  # noqa: E402

# The five patterns shipped by actions/setup-go and actions/setup-node, with inputs they are meant
# to match and inputs they are meant to miss.
REAL = [
    (
        r"^\s*(.+\.go):(?:(\d+):(\d+):)? (.*)",
        [
            "  main.go:9:2: undefined: foo",
            "pkg/a.go: build failed",
            "main.go:9:2:no space before message",
            "not-go.txt:1:1: nope",
            "",
        ],
    ),
    (
        r"^(.+):\sline\s(\d+),\scol\s(\d+),\s([Ee]rror|[Ww]arning|[Ii]nfo)\s-\s(.+)\s\((.+)\)$",
        [
            "src/a.js: line 3, col 10, Error - Missing semicolon (semi)",
            "src/a.js: line 3, col 10, warning - Unused var (no-unused-vars)",
            "src/a.js: line x, col 10, Error - bad (rule)",
            "src/a.js: line 3, col 10, Error - no parens",
        ],
    ),
    (r"^\s*([^\s].*)$", ["  src/b.js", "   ", "", "a"]),
    (
        r"^\s+(\d+):(\d+)\s+(error|warning|info)\s+(.*)\s\s+(.*)$",
        [
            "  12:34  error  Unexpected console statement  no-console",
            "  1:2  warning  x  y",
            "12:34  error  no leading space  rule",
        ],
    ),
    (
        r"^([^\s].*)[\(:](\d+)[,:](\d+)(?:\):\s+|\s+-\s+)(error|warning|info)\s+TS(\d+)\s*:\s*(.*)$",
        [
            "src/c.ts(5,9): error TS2304: Cannot find name 'x'.",
            "src/c.ts:5:9 - error TS2304: Cannot find name 'x'.",
            "src/c.ts(5,9): info TS1234:",
            " src/c.ts(5,9): error TS2304: leading space",
        ],
    ),
]

# One per supported construct, including the awkward corners of class parsing.
CONSTRUCTS = [
    (r"abc", ["abc", "xabcx", "ab"]),
    (r"^abc$", ["abc", "xabc", "abcx"]),
    (r"a.c", ["abc", "a\nc", "ac"]),
    (r"a*b", ["b", "aaab", "c"]),
    (r"a+b", ["b", "ab", "aaab"]),
    (r"a?b", ["b", "ab", "aab"]),
    (r"(a|b|c)+", ["abcabc", "d", ""]),
    (r"(?:ab)+", ["ababab", "aba"]),
    (r"(a)(b)?(c)", ["abc", "ac"]),
    (r"a{2}", ["a", "aa", "aaa"]),
    (r"a{2,}", ["a", "aa", "aaaa"]),
    (r"a{2,3}b", ["ab", "aab", "aaab", "aaaab"]),
    (r"<(.+)>", ["<a><b>"]),
    (r"<(.+?)>", ["<a><b>"]),
    (r"(a+?)(a*)", ["aaaa"]),
    (r"[a-f0-9]+", ["zz9afz", "ghi"]),
    (r"[^0-9]+", ["12ab34", "123"]),
    (r"[]x]+", ["a]x]b"]),
    (r"[a-]+", ["-a-"]),
    (r"[\(:]+", ["x(:y"]),
    (r"\s+", [" \t ", "x"]),
    (r"\S+", ["  ab  ", "   "]),
    (r"\d+\.\d+", ["v1.25", "1x2"]),
    (r"\w+", ["a_1-b", "---"]),
    (r"\W+", ["a--b", "abc"]),
    (r"(\d+):(\d+)", ["12:34", "12:", ":34"]),
    (r"^(?:(a)|(b))$", ["a", "b", "c"]),
    (r"x(y|)z", ["xyz", "xz"]),
]

def reference(pattern, text):
    """Python's answer: match flag plus one entry per group, absent groups as None."""
    try:
        compiled = re.compile(pattern, re.ASCII)
    except re.error:
        return None  # Python will not take it either; nothing to compare
    m = compiled.search(text)
    if m is None:
        return {"match": False, "groups": []}
    return {"match": True, "groups": list(m.groups())}


# Perl's engine is an independent implementation, and close to .NET's on this subset — which is the
# family these patterns come from. `/a` keeps the shorthands ASCII, as `re.ASCII` does for Python.
PERL = r"""
use strict; use warnings;
binmode(STDIN, ':raw'); binmode(STDOUT, ':raw');
local $/; my $all = <STDIN>;
for my $line (split /\n/, $all, -1) {
    last unless length $line;
    my ($pat, $txt) = split /\x01/, $line, 2;
    $txt = '' unless defined $txt;
    # \x02 stands for a newline in both directions: the corpus contains an input with one, and a
    # line-oriented protocol cannot carry it. Without this the answers shift by a line and every
    # later case looks like a disagreement.
    $pat =~ s/\x02/\n/g; $txt =~ s/\x02/\n/g;
    my @g;
    my $ok = eval { if ($txt =~ /(?a)$pat/) { @g = map { defined $_ ? "s$_" : 'u' } @{^CAPTURE}; 1 } else { 0 } };
    if (!defined $ok) { print "E\n"; }
    elsif ($ok)       { my $j = join("\x01", @g); $j =~ s/\n/\x02/g; print "M" . $j . "\n"; }
    else              { print "N\n"; }
}
"""


def perl_reference(cases):
    """Perl's answers for every case, or None if perl is unavailable."""
    enc = lambda v: v.replace("\n", "\x02")
    payload = "".join(f"{enc(p)}\x01{enc(t)}\n" for p, t in cases)
    try:
        proc = subprocess.run(["perl", "-e", PERL], input=payload, capture_output=True, text=True)
    except FileNotFoundError:
        return None
    if proc.returncode != 0:
        return None
    out = []
    for line in proc.stdout.split("\n")[: len(cases)]:
        if line.startswith("E") or line == "":
            out.append(None)  # perl refused the pattern; nothing to compare
        elif line.startswith("N"):
            out.append({"match": False, "groups": []})
        else:
            fields = line[1:].split("\x01") if len(line) > 1 else []
            out.append({"match": True, "groups": [None if f == "u" else f[1:].replace("\x02", "\n") for f in fields]})
    while len(out) < len(cases):
        out.append(None)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--random", type=int, default=400, help="how many random patterns to add")
    ap.add_argument("--seed", type=int, default=1, help="recorded, so a disagreement can be reproduced")
    ap.add_argument("--engine", default="zig-out/bin/regex-diff")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    cases = []
    for pattern, inputs in REAL + CONSTRUCTS:
        for text in inputs:
            cases.append((pattern, text))
    # From the grammar in tools/regex_grammar.py, with inputs drawn from each pattern so matches
    # are common rather than accidental, plus near-misses and noise.
    cases.extend(regex_grammar.cases(rng, args.random))

    payload = "".join(json.dumps({"pattern": p, "input": t}) + "\n" for p, t in cases)
    proc = subprocess.run([args.engine], input=payload, capture_output=True, text=True)
    if proc.returncode != 0:
        print(f"engine exited {proc.returncode}\n{proc.stderr}", file=sys.stderr)
        return 2
    lines = [l for l in proc.stdout.splitlines() if l.strip()]
    if len(lines) != len(cases):
        print(f"engine answered {len(lines)} of {len(cases)} cases", file=sys.stderr)
        return 2

    perl = perl_reference(cases)
    if perl is None:
        print("perl unavailable: comparing against Python only", file=sys.stderr)
        perl = [None] * len(cases)

    agree = refused = skipped = 0
    perl_agree = perl_skipped = 0
    perl_disagreements = []
    disagreements = []
    refusals = {}
    for (pattern, text), line, theirs_perl in zip(cases, lines, perl):
        ours = json.loads(line)
        if not ours["ok"]:
            refused += 1
            # Grouped by reason, with an example: a refusal of an *unsupported* construct is a
            # documented choice, while `TooComplex` on an ordinary pattern would mean the step
            # budget is too tight and legitimate matchers would fail.
            refusals.setdefault(ours["error"], []).append((pattern, text))
            continue
        theirs = reference(pattern, text)
        if theirs is None:
            skipped += 1
            continue
        if ours["match"] != theirs["match"] or ours["groups"] != theirs["groups"]:
            disagreements.append((pattern, text, ours, theirs))
        else:
            agree += 1
        # Perl independently, where it has an opinion.
        if theirs_perl is None:
            perl_skipped += 1
        # `@{^CAPTURE}` is sized by the highest group that *matched*, so perl omits trailing unset
        # groups where we and Python report them as absent. Padding is normalising an API
        # difference, not excusing a disagreement: a group perl reports as set must still match.
        elif theirs_perl["match"] and len(theirs_perl["groups"]) < len(ours["groups"]):
            padded = theirs_perl["groups"] + [None] * (len(ours["groups"]) - len(theirs_perl["groups"]))
            if ours["groups"] != padded:
                perl_disagreements.append((pattern, text, ours, {"match": True, "groups": padded}))
            else:
                perl_agree += 1
        elif ours["match"] != theirs_perl["match"] or ours["groups"] != theirs_perl["groups"]:
            perl_disagreements.append((pattern, text, ours, theirs_perl))
        else:
            perl_agree += 1

    print(f"{len(cases)} cases: {agree} agree, {refused} refused by us, {skipped} rejected by Python")
    for reason, examples in sorted(refusals.items()):
        pattern, text = examples[0]
        print(f"  refused {len(examples):4d}x {reason:12s} e.g. {pattern!r} on {text!r}")
    # A difference from perl where *Python* also differs from perl is the two references
    # disagreeing, not our bug. Counting them apart is the difference between "we are wrong 68
    # times" and "perl and python disagree 68 times and we are with python".
    refs_differ = 0
    ours_alone = []
    for pattern, text, ours, theirs_perl in perl_disagreements:
        py = reference(pattern, text)
        if py is not None:
            padded = theirs_perl["groups"] + [None] * max(0, len(py["groups"]) - len(theirs_perl["groups"]))
            if py["match"] != theirs_perl["match"] or py["groups"] != padded:
                refs_differ += 1
                continue
        ours_alone.append((pattern, text, ours, theirs_perl))
    print(f"  vs perl: {perl_agree} agree, {len(perl_disagreements)} differ "
          f"({refs_differ} where python differs from perl too, {len(ours_alone)} ours alone), "
          f"{perl_skipped} no opinion")
    perl_disagreements = ours_alone
    for pattern, text, ours, theirs in perl_disagreements[:10]:
        print(f"\n  [perl] pattern {pattern!r}\n         input   {text!r}\n         ours    {ours}\n         perl    {theirs}")
    for pattern, text, ours, theirs in disagreements[:20]:
        print(f"\n  pattern {pattern!r}\n  input   {text!r}\n  ours    {ours}\n  python  {theirs}")
    if disagreements or perl_disagreements:
        print(f"\n{len(disagreements)} python + {len(perl_disagreements)} perl disagreement(s) (seed {args.seed})")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
