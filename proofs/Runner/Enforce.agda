{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model

-- Closing the enforcement gap for volatile variables.
--
-- P1 (`replay≡run` in Runner.Build) holds under one hypothesis, `Disciplined`, which bundles three
-- obligations on a step the runner does not mark always-run: it is deterministic, it does not
-- consult a volatile variable, and it does not depend on the content of a mounted cache volume. The
-- runner enforces none of them. It *detects* the second, syntactically, by looking for the
-- variable's name in the script text — and counterexample 1 is a step that reads the value without
-- ever spelling the name, which the live suite confirms is replayed with a stale answer.
--
-- Detection cannot be made sound: a script can reach the value through a file it sources, a program
-- that reads the environment, or a name it builds from pieces. So do what P5 does for files and
-- Runner.Declared proves about them — **give the step only what its key keeps**. An unmarked step is
-- handed the stable environment and nothing else. Then its input is a function of its key, and the
-- volatile clause of `Disciplined` is not an assumption any more.
--
-- The implementation will set a constant, visible sentinel rather than unset the variables: a
-- constant satisfies every theorem here (what matters is that it does not vary between runs), it
-- keeps `$GITHUB_SHA` non-empty for a script under `set -u`, and a step whose output contains it has
-- announced that it read a value it did not declare — which turns a silent blind spot into a line in
-- a log.
module Runner.Enforce (vol : Volatile) where

-- What an unmarked step is given: the bindings its key keeps.
withheld : Env → Env
withheld = stable vol

-- The input of an unmarked step under enforcement. The marked ones are unchanged: they get the real
-- values, and their keys carry the job's nonce, so they are never replayed.
inputPlain : State → Env → Step → Input
inputPlain s e st = input s (body (Step.text st) (Step.num st)) (withheld e) (Step.mounts st)

keyPlain : State → Env → Step → Key
keyPlain s e st = keyOf vol (inputPlain s e st)

------------------------------------------------------------------------------
-- What enforcement establishes

-- The environment an unmarked step is given is already filtered, so filtering it again — which is
-- what the key does — changes nothing.
key-keeps-everything : (s : State) (e : Env) (st : Step)
  → Key.kEnv (keyPlain s e st) ≡ Input.env (inputPlain s e st)
key-keeps-everything s e st = filter-idempotent (λ b → not (vol (fst b))) e

-- **The input is a function of the key.** Two jobs whose unmarked step has the same key gave it the
-- same input — the same container, the same script, the same environment, the same mounts. Nothing
-- about the run is left for the step to notice.
input-determined-by-key : (s : State) (e e' : Env) (st : Step)
  → keyPlain s e st ≡ keyPlain s e' st
  → inputPlain s e st ≡ inputPlain s e' st
input-determined-by-key s e e' st k =
  cong (λ x → input s (body (Step.text st) (Step.num st)) x (Step.mounts st))
    (trans (sym (key-keeps-everything s e st))
      (trans (cong Key.kEnv k) (key-keeps-everything s e' st)))

-- So the volatile clause of `Disciplined` is discharged: for an unmarked step, equal keys give equal
-- results as soon as the step is deterministic. Nothing has to be assumed about what it reads from
-- the environment, because there is nothing in the environment that varies.
--
-- What remains to assume is determinism, and that a step does not depend on the content of a mounted
-- cache volume — which is the same `Step.mounts` on both sides here, and so is counterexample 4's
-- territory rather than this one's.
volatile-clause-discharged : (exec : Input → Trial → Output)
  → ((i : Input) (t t' : Trial) → exec i t ≡ exec i t')
  → (s : State) (e e' : Env) (st : Step) (t t' : Trial)
  → keyPlain s e st ≡ keyPlain s e' st
  → exec (inputPlain s e st) t ≡ exec (inputPlain s e' st) t'
volatile-clause-discharged exec deterministic s e e' st t t' k
  rewrite input-determined-by-key s e e' st k = deterministic (inputPlain s e' st) t t'

-- And the hole is closed at its source: a step that reads a volatile value is handed the same thing
-- in every run, whatever it reads and however it reaches it. This is the statement counterexample 1
-- violates today.
nothing-volatile-survives : (n : Name) (c : Content) (e : Env) (s : State) (st : Step)
  → vol n ≡ true
  → inputPlain s ((n , c) ∷ e) st ≡ inputPlain s e st
nothing-volatile-survives n c e s st v rewrite v = refl
