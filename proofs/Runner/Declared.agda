{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model

-- P5, enforcement over guessing: the property behind declared inputs
-- (`ZIG_RUNNER_INPUTS`, experiment 5, shelved on `feat/declared-inputs-v2`).
--
-- The mechanism is not in the shipped runner, so this module does not extend
-- Runner.Build; it models the shape of the choice instead, which is the part
-- worth keeping. A step can be given a narrower key in two ways:
--
--   * **enforced** — build its container from the declared files only, so what
--     it was not given, it cannot read;
--   * **guessed** — hand it the whole workspace and key it on the guess, which
--     is what inferring a step's inputs without tracing them amounts to.
--
-- The two are not variations on a theme. Enforcement discharges the obligation
-- by construction: a declared step's result *is* a function of its declaration,
-- with no hypothesis about the step at all, which is more than `Disciplined` can
-- say for an ordinary step. Guessing is unsound, and `Guessing` below is a job
-- where it hands back an answer running would not have given.
--
-- What that costs is not modelled here, and it is what sank the mechanism:
-- experiment 5 measured +28% on flask and +85% on go-task. Riker and Rattle
-- (docs/RELATED.md) take the third way, tracing what a command actually read.
module Runner.Declared where

------------------------------------------------------------------------------
-- Workspaces and declarations

Path : Set
Path = ℕ

Ws : Set
Ws = List (Path × Content)

_∈?_ : Path → List Path → Bool
p ∈? []       = false
p ∈? (q ∷ qs) with p ≟ℕ q
... | yes _ = true
... | no  _ = p ∈? qs

∈?-cong : {p q : Path} (decl : List Path) → p ≡ q → (p ∈? decl) ≡ (q ∈? decl)
∈?-cong decl refl = refl

true≢false : ¬ (true ≡ false)
true≢false ()

-- The workspace a declared step is given: its declaration, and nothing else.
-- In the prototype this was a filter of the git tree, which Dagger keys on
-- content (experiment 5, §9.2), so an unchanged declaration is an unchanged key.
view : List Path → Ws → Ws
view decl = filter (λ e → fst e ∈? decl)

find : Path → Ws → Maybe Content
find p []       = nothing
find p (e ∷ ws) with p ≟ℕ fst e
... | yes _ = just (snd e)
... | no  _ = find p ws

------------------------------------------------------------------------------
-- Enforcement

-- **P5.** A path the step did not declare is not in what it is given. So a step
-- that needs it fails — a missing file, not a stale one — instead of replaying
-- a result computed from something it could not see. Experiment 5 hit this
-- twice: flit reads `LICENSE.txt` and the version out of `src`, and both
-- declarations failed loudly.
undeclared-absent : (p : Path) (decl : List Path) (ws : Ws)
  → (p ∈? decl) ≡ false → find p (view decl ws) ≡ nothing
undeclared-absent p decl []       absent = refl
undeclared-absent p decl (e ∷ ws) absent = go (fst e ∈? decl) refl
  where
    go : (b : Bool) → (fst e ∈? decl) ≡ b → find p (view decl (e ∷ ws)) ≡ nothing
    go false eq rewrite eq = undeclared-absent p decl ws absent
    go true  eq rewrite eq with p ≟ℕ fst e
    ... | no  _   = undeclared-absent p decl ws absent
    ... | yes eq' =
          -- The step did not declare p, and this entry is declared, so they are
          -- different files. Otherwise p would be declared after all.
          ⊥-elim (true≢false (trans (sym eq) (trans (sym (∈?-cong decl eq')) absent)))

-- A change to a file the step did not declare leaves what it is given alone, so
-- its key is unchanged and it is replayed. This is P3 for a declared step, and
-- unlike P3 for an ordinary one it holds for *every* file outside the
-- declaration rather than for a fixed list of excluded variables.
undeclared-change-invisible : (decl : List Path) (p : Path) (c : Content) (ws : Ws)
  → (p ∈? decl) ≡ false → view decl ((p , c) ∷ ws) ≡ view decl ws
undeclared-change-invisible decl p c ws absent rewrite absent = refl

-- And a change to one it did declare is visible, so the step runs. P2.
declared-change-visible : (decl : List Path) (p : Path) (c c' : Content) (ws : Ws)
  → (p ∈? decl) ≡ true → ¬ (c ≡ c')
  → ¬ (view decl ((p , c) ∷ ws) ≡ view decl ((p , c') ∷ ws))
declared-change-visible decl p c c' ws present ¬eq eq
  rewrite present = ¬eq (cong snd (∷-injective₁ eq))

-- The positive half of P5: a declared step's result is a function of its
-- declaration. Nothing is assumed about the step — it may read whatever it
-- likes, in whatever order, and it still cannot depend on a file it was not
-- given, because the dependence goes through `view`.
--
-- `behaviour` here is any function from a workspace to a result: what the step
-- does, unconstrained.
enforced-depends-only-on-the-declaration :
  {R : Set} (behaviour : Ws → R) (decl : List Path) (ws ws' : Ws)
  → view decl ws ≡ view decl ws'
  → behaviour (view decl ws) ≡ behaviour (view decl ws')
enforced-depends-only-on-the-declaration behaviour decl ws ws' same = cong behaviour same

------------------------------------------------------------------------------
-- Guessing

-- The other way: key the step on a guessed set of inputs, but run it in the
-- whole workspace. Then the key cannot tell two workspaces apart while the step
-- can, and a missed input is a wrong replay rather than a failure.

module Guessing where

  -- The guess: the step is assumed to read only path 1.
  guess : List Path
  guess = 1 ∷ []

  -- What it really reads: path 9, a file nobody listed. (`uv sync` reading
  -- `src`, a script sourcing another script, a test reading a fixture.)
  run : Ws → Content
  run ws with find 9 ws
  ... | just c  = c
  ... | nothing = 0

  before : Ws
  before = (1 , 5) ∷ (9 , 7) ∷ []

  after : Ws
  after = (1 , 5) ∷ (9 , 8) ∷ []

  -- The guessed key is the same in both...
  same-key : view guess before ≡ view guess after
  same-key = refl

  -- ...so the second job is replayed from the first, and gets 7 where running
  -- would have given 8.
  replayed : Content
  replayed = run before

  ran : Content
  ran = run after

  unsound : ¬ (replayed ≡ ran)
  unsound ()

  -- Enforced instead, the same step sees no path 9 at all, so it fails rather
  -- than answering from a file it was not given.
  enforced-sees-nothing : find 9 (view guess after) ≡ nothing
  enforced-sees-nothing = refl
