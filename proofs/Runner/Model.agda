{-# OPTIONS --safe #-}

-- The vocabulary: this runner as a build system in the sense of Build Systems à
-- la Carte, with a scheduler (a job's steps run in order, as GitHub Actions
-- specifies) and a rebuilder (Dagger reuses an exec whose key it has already
-- seen). Runner.Build is the algorithm and its theorems.
--
-- Every modelling choice below is a claim about the real system, and the code
-- that backs it up is named:
--
--  * A step's key keeps the container it starts from, the script text, and the
--    non-volatile environment; it forgets the mounts and the volatile
--    variables. That is what dagger.zig builds: `withExec` under
--    `loadContainerFromID`, `withVolatileVariable` for the names in
--    `volatile_env`, and `withDirectory` / `withMountedCache` for content,
--    which BuildKit excludes from an exec's cache key.
--
--  * "Always run" is not a flag the engine understands. The runner writes the
--    run's nonce into the step's script, and the script is part of the key
--    (`always_run`, threaded through `containerScript` in dagger.zig).
--    `stamped` models that, so the proofs are about the mechanism that exists
--    rather than one we wish existed.
--
--  * `exec` takes a trial number, so a step need not be a function of its
--    inputs alone. Nothing here forces a step to be deterministic; the
--    properties that need determinism have to ask for it, which is how the
--    flakiness question (docs/RELATED.md) shows up as a hypothesis rather than
--    as an oversight.

module Runner.Model where

open import Prelude

------------------------------------------------------------------------------
-- Atoms
--
-- Variable names, script bodies, container ids and file contents are things the
-- system only ever compares for equality, so numbers stand in for them: a
-- container id is a digest, and this model never looks inside one.

Name : Set
Name = ℕ

Body : Set
Body = ℕ

State : Set
State = ℕ

Content : Set
Content = ℕ

Log : Set
Log = ℕ

Trial : Set
Trial = ℕ

-- A script is its text together with the step's position in the job, or that
-- script with a run nonce written into it.
--
-- The position is in here because it is in the real script: `containerScript`
-- and `stepScriptFc` write `echo '<marker>begin <n>'` and the step's file-command
-- paths, so two steps of a job never have the same script text. That is a log
-- marker doing load-bearing work for the cache, and Runner.Counterexamples
-- shows what goes wrong without it.
--
-- `stamped` is the always-run marker, a constructor rather than a flag because
-- that is how the runner implements it: a run nonce written into the script
-- text, which is part of the key.
data Script : Set where
  body    : Body → ℕ → Script
  stamped : Trial → Script → Script

body-injective₁ : {b b' : Body} {n n' : ℕ} → body b n ≡ body b' n' → b ≡ b'
body-injective₁ refl = refl

body-injective₂ : {b b' : Body} {n n' : ℕ} → body b n ≡ body b' n' → n ≡ n'
body-injective₂ refl = refl

stamped-injective₁ : {t t' : Trial} {s s' : Script} → stamped t s ≡ stamped t' s' → t ≡ t'
stamped-injective₁ refl = refl

stamped-injective₂ : {t t' : Trial} {s s' : Script} → stamped t s ≡ stamped t' s' → s ≡ s'
stamped-injective₂ refl = refl

_≟Script_ : DecEq Script
body b n    ≟Script body b' n'    with b ≟ℕ b' | n ≟ℕ n'
... | yes refl | yes refl = yes refl
... | no  ¬p   | _        = no (λ eq → ¬p (body-injective₁ eq))
... | _        | no ¬q    = no (λ eq → ¬q (body-injective₂ eq))
body b n    ≟Script stamped t s   = no (λ ())
stamped t s ≟Script body b n      = no (λ ())
stamped t s ≟Script stamped t' s' with t ≟ℕ t' | s ≟Script s'
... | yes refl | yes refl = yes refl
... | no  ¬p   | _        = no (λ eq → ¬p (stamped-injective₁ eq))
... | _        | no ¬q    = no (λ eq → ¬q (stamped-injective₂ eq))

-- A script carries no nonce: the step was not marked always-run.
Unstamped : Script → Set
Unstamped (body _ _)    = ⊤
Unstamped (stamped _ _) = ⊥

------------------------------------------------------------------------------
-- Steps, inputs, outputs

Binding : Set
Binding = Name × Content

Env : Set
Env = List Binding

-- A mount is a path and the content mounted there: a checkout, an action's
-- directory, or a cache volume.
Mounts : Set
Mounts = List (Name × Content)

-- A step as the workflow writes it. `reads` is the set of variable names the
-- script really consults; `readsRunSpecific` in dagger.zig is a syntactic
-- over-approximation of it, which is sound only when a script that consults a
-- name also mentions it (see proofs/README.md, "what this does not model").
record Step : Set where
  constructor step
  field
    text   : Body
    num    : ℕ
    env    : Env
    mounts : Mounts
    reads  : List Name

-- Everything a step's result could possibly depend on.
record Input : Set where
  constructor input
  field
    parent : State
    script : Script
    env    : Env
    mounts : Mounts

record Output : Set where
  constructor output
  field
    after : State
    log   : Log

------------------------------------------------------------------------------
-- Keys
--
-- What the engine actually hashes. Modelling the hash as a projection rather
-- than as a function into digests is deliberate: collisions are a separate
-- concern, and assuming them away silently would be exactly the kind of hidden
-- hypothesis this exercise is meant to surface.

record Key : Set where
  constructor key
  field
    kParent : State
    kScript : Script
    kEnv    : Env

_≟Key_ : DecEq Key
key p s e ≟Key key p' s' e' with p ≟ℕ p' | s ≟Script s' | List-dec (×-dec _≟ℕ_ _≟ℕ_) e e'
... | yes refl | yes refl | yes refl = yes refl
... | no  ¬p   | _        | _        = no (λ eq → ¬p (cong Key.kParent eq))
... | _        | no ¬q    | _        = no (λ eq → ¬q (cong Key.kScript eq))
... | _        | _        | no ¬r    = no (λ eq → ¬r (cong Key.kEnv eq))

-- Which names are run-specific: `volatile_env` in dagger.zig.
Volatile : Set
Volatile = Name → Bool

stable : Volatile → Env → Env
stable vol = filter (λ b → not (vol (fst b)))

keyOf : Volatile → Input → Key
keyOf vol i = key (Input.parent i) (Input.script i) (stable vol (Input.env i))

------------------------------------------------------------------------------
-- The cache
--
-- An association list from keys to the outputs recorded for them. The engine's
-- store is a content-addressed graph with garbage collection; what matters to
-- every property below is only that a key maps to at most one output, and that
-- the answer survives between jobs.

Cache : Set
Cache = List (Key × Output)

look : Key → Cache → Maybe Output
look k []      = nothing
look k (e ∷ c) with k ≟Key fst e
... | yes _ = just (snd e)
... | no  _ = look k c

-- A hit names an entry that is really in the cache.
look-sound : (k : Key) (c : Cache) {o : Output} → look k c ≡ just o → (k , o) ∈ c
look-sound k []      eq = ⊥-elim (hit eq)
  where
    hit : {o : Output} → nothing ≡ just o → ⊥
    hit ()
look-sound k (e ∷ c) eq with k ≟Key fst e
look-sound k (e ∷ c) eq | yes refl rewrite sym (just-injective eq) = here
look-sound k (e ∷ c) eq | no  _    = there (look-sound k c eq)

-- A hit on an extended cache is a hit on the new entry or a hit on the old
-- cache. Stated as a lemma because the case split has to happen in the same
-- shape as `look`'s own for the definition to reduce.
look-cons : (k : Key) (e : Key × Output) (c : Cache) {o : Output}
  → look k (e ∷ c) ≡ just o → ((k ≡ fst e) × (o ≡ snd e)) ⊎ (look k c ≡ just o)
look-cons k e c eq with k ≟Key fst e
... | yes p = inl (p , sym (just-injective eq))
... | no  _ = inr eq

-- A key no entry carries cannot be found.
look-miss : (k : Key) (c : Cache) → ((o : Output) → ¬ ((k , o) ∈ c)) → look k c ≡ nothing
look-miss k []      absent = refl
look-miss k (e ∷ c) absent with k ≟Key fst e
look-miss k (e ∷ c) absent | yes refl = ⊥-elim (absent (snd e) here)
look-miss k (e ∷ c) absent | no  _    = look-miss k c (λ o mem → absent o (there mem))
