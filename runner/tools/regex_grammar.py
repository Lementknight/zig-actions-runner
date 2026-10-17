#!/usr/bin/env python3
r"""The grammar src/regex.zig accepts, as a generator for the differential test.

The engine's supported subset, written down once:

    alternation := sequence ('|' sequence)*
    sequence    := term*
    term        := atom quantifier?
    quantifier  := ('*' | '+' | '?' | '{' n '}' | '{' n ',' '}' | '{' n ',' m '}') '?'?
    atom        := literal | '.' | class | shorthand | group | anchor
    group       := '(' alternation ')' | '(?:' alternation ')'
    class       := '[' '^'? item+ ']'
    item        := byte | byte '-' byte | shorthand
    shorthand   := '\s' | '\S' | '\d' | '\D' | '\w' | '\W'
    anchor      := '^' | '$'
    literal     := a byte that is not a metacharacter, or '\' metacharacter

Generating from the grammar beats a list of hand-picked atoms: it reaches combinations nobody
thought to write down, which is where the engine's bugs were. It also means the corpus and the
engine can be checked against *the same* statement of what is supported — a pattern this generator
produces and the engine refuses is a disagreement about the grammar, which is itself a finding.

Each generated pattern comes with inputs drawn from itself, so matches are common rather than
accidental: `sample()` walks the tree choosing one way through every alternation and a count for
every quantifier, which yields a string the pattern should match. Mutations of that string and some
random noise cover the near-misses.
"""

import random

META = set(r".^$*+?()[]{}|\\")
SHORTHANDS = ["s", "S", "d", "D", "w", "W"]
# A small alphabet keeps collisions likely, so matches and near-misses both happen often.
ALPHABET = "abx019_- \t."


class Lit:
    def __init__(self, ch):
        self.ch = ch

    def render(self):
        return ("\\" + self.ch) if self.ch in META else self.ch

    def sample(self, rng):
        return self.ch


class Any:
    def render(self):
        return "."

    def sample(self, rng):
        return rng.choice("abx019_- \t")  # not a newline: `.` does not match one


class Short:
    def __init__(self, kind):
        self.kind = kind

    def render(self):
        return "\\" + self.kind

    def sample(self, rng):
        pools = {
            "s": " \t",
            "S": "abx019_-.",
            "d": "0123456789",
            "D": "abx_- \t.",
            "w": "abx019_",
            "W": " \t.-",
        }
        return rng.choice(pools[self.kind])


class Class:
    def __init__(self, negated, items):
        self.negated = negated
        self.items = items  # (lo, hi) ranges, single bytes, or Short

    def render(self):
        out = "["
        if self.negated:
            out += "^"
        for it in self.items:
            if isinstance(it, Short):
                out += it.render()
            elif isinstance(it, tuple):
                out += f"{it[0]}-{it[1]}"
            else:
                out += ("\\" + it) if it in "\\]^-" else it
        return out + "]"

    def members(self):
        """The bytes this class admits, for sampling."""
        inside = set()
        for it in self.items:
            if isinstance(it, Short):
                inside |= {c for c in ALPHABET if _short_has(it.kind, c)}
            elif isinstance(it, tuple):
                inside |= {chr(c) for c in range(ord(it[0]), ord(it[1]) + 1)}
            else:
                inside.add(it)
        if not self.negated:
            return sorted(inside) or ["a"]
        outside = [c for c in ALPHABET if c not in inside]
        return outside or ["a"]

    def sample(self, rng):
        return rng.choice(self.members())


def _short_has(kind, c):
    if kind == "s":
        return c in " \t\n\r\v\f"
    if kind == "S":
        return c not in " \t\n\r\v\f"
    if kind == "d":
        return c.isdigit()
    if kind == "D":
        return not c.isdigit()
    if kind == "w":
        return c.isalnum() or c == "_"
    return not (c.isalnum() or c == "_")


class Group:
    def __init__(self, capturing, alts):
        self.capturing = capturing
        self.alts = alts  # list of sequences (each a list of terms)

    def render(self):
        body = "|".join("".join(t.render() for t in seq) for seq in self.alts)
        return ("(" if self.capturing else "(?:") + body + ")"

    def sample(self, rng):
        seq = rng.choice(self.alts)
        return "".join(t.sample(rng) for t in seq)


class Repeat:
    def __init__(self, node, lo, hi, greedy):
        self.node = node
        self.lo = lo
        self.hi = hi  # None means unbounded
        self.greedy = greedy

    def render(self):
        if (self.lo, self.hi) == (0, None):
            q = "*"
        elif (self.lo, self.hi) == (1, None):
            q = "+"
        elif (self.lo, self.hi) == (0, 1):
            q = "?"
        elif self.hi is None:
            q = "{%d,}" % self.lo
        elif self.lo == self.hi:
            q = "{%d}" % self.lo
        else:
            q = "{%d,%d}" % (self.lo, self.hi)
        return self.node.render() + q + ("" if self.greedy else "?")

    def sample(self, rng):
        hi = self.lo + 2 if self.hi is None else self.hi
        return "".join(self.node.sample(rng) for _ in range(rng.randint(self.lo, max(self.lo, hi))))


class Anchor:
    def __init__(self, which):
        self.which = which

    def render(self):
        return self.which

    def sample(self, rng):
        return ""


def gen_atom(rng, depth):
    choices = ["lit", "any", "short", "class"]
    if depth > 0:
        choices += ["group", "group"]
    kind = rng.choice(choices)
    if kind == "lit":
        return Lit(rng.choice(ALPHABET))
    if kind == "any":
        return Any()
    if kind == "short":
        return Short(rng.choice(SHORTHANDS))
    if kind == "class":
        items = []
        for _ in range(rng.randint(1, 3)):
            r = rng.random()
            if r < 0.3:
                lo = rng.choice("abcx0")
                items.append((lo, chr(ord(lo) + rng.randint(0, 3))))
            elif r < 0.5:
                items.append(Short(rng.choice(SHORTHANDS)))
            else:
                items.append(rng.choice(ALPHABET))
        return Class(rng.random() < 0.35, items)
    return gen_group(rng, depth - 1)


def gen_group(rng, depth):
    alts = [gen_sequence(rng, depth) for _ in range(rng.randint(1, 3))]
    return Group(rng.random() < 0.7, alts)


def gen_term(rng, depth):
    atom = gen_atom(rng, depth)
    if rng.random() < 0.45:
        lo, hi = rng.choice([(0, None), (1, None), (0, 1), (1, 2), (2, 2), (2, None), (0, 2)])
        return Repeat(atom, lo, hi, rng.random() < 0.7)
    return atom


def gen_sequence(rng, depth):
    return [gen_term(rng, depth) for _ in range(rng.randint(1, 3))]


def gen_pattern(rng, depth=2):
    """A pattern from the grammar, with anchors sometimes, as a (text, sampler) pair."""
    seq = gen_sequence(rng, depth)
    pre = [Anchor("^")] if rng.random() < 0.25 else []
    post = [Anchor("$")] if rng.random() < 0.25 else []
    terms = pre + seq + post
    text = "".join(t.render() for t in terms)
    return text, lambda r: "".join(t.sample(r) for t in terms)


def mutate(rng, s):
    """A near-miss: one byte changed, dropped, or inserted."""
    if not s:
        return rng.choice(ALPHABET)
    i = rng.randrange(len(s))
    op = rng.random()
    if op < 0.4:
        return s[:i] + rng.choice(ALPHABET) + s[i + 1 :]
    if op < 0.7:
        return s[:i] + s[i + 1 :]
    return s[:i] + rng.choice(ALPHABET) + s[i:]


def noise(rng):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, 10)))


def cases(rng, count):
    """`count` patterns, each with inputs it should match, near-misses, and noise."""
    out = []
    for _ in range(count):
        pattern, sampler = gen_pattern(rng)
        drawn = sampler(rng)
        out.append((pattern, drawn))
        out.append((pattern, mutate(rng, drawn)))
        out.append((pattern, noise(rng)))
    return out
