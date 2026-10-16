{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model

-- The algorithm, and what it does and does not guarantee.
--
-- Parameters: which variable names are run-specific (`volatile_env` in
-- dagger.zig), and what a step does. `exec` takes the trial as well as the
-- input, so a step is not forced to be a function of its inputs: a flaky test
-- is a perfectly good inhabitant of this type, and the properties that need it
-- not to be have to say so.
module Runner.Build (vol : Volatile) (exec : Input → Trial → Output) where

K : Input → Key
K = keyOf vol

------------------------------------------------------------------------------
-- The scheduler and the rebuilder

-- Whether the runner must not let this step be replayed: it consults a name
-- whose value differs between runs while the key does not. `readsRunSpecific`
-- in dagger.zig, which also marks steps that use secrets or can mint OIDC
-- tokens; those are the same case, since what they produce depends on something
-- no key holds.
data Mark : Set where
  plain    : Mark
  everyRun : Mark

mark : Step → Mark
mark st with any vol (Step.reads st)
... | true  = everyRun
... | false = plain

-- The input a step is run on. Marking it costs a script that no other job can
-- have produced, because the job's nonce is written into the script text and
-- the script text is part of the key.
inputFor : Trial → State → Step → Mark → Input
inputFor t s st plain    = input s (body (Step.text st) (Step.num st)) (Step.env st) (Step.mounts st)
inputFor t s st everyRun = input s (stamped t (body (Step.text st) (Step.num st))) (Step.env st) (Step.mounts st)

-- `RUNNER_OUTPUT_KEYS`.
data Keys : Set where
  off : Keys
  on  : Keys

-- The container the next step starts from.
--
-- Normally it is the one this exec left, whose identity is this exec's recipe —
-- nonce and all, which is why a marked step makes every step after it new. With
-- output keys on, a marked step instead hands on the container it started from
-- with what it produced copied in by digest (`outputKeyed`), so what the next
-- step starts from says what was produced and not who produced it.
nextState : Keys → Trial → State → Step → Mark → Output → State
nextState off t s st m        o = stateOf (K (inputFor t s st m))
nextState on  t s st plain    o = stateOf (K (inputFor t s st plain))
nextState on  t s st everyRun o = afterCopy s (Output.digest o)

record Progress : Set where
  constructor progress
  field
    state : State
    cache : Cache
    ran   : ℕ
    outs  : List Output

-- What the step contributes: the recorded output on a hit, a run on a miss.
produced : Trial → Progress → Step → Mark → Maybe Output → Output
produced t p st m (just o) = o
produced t p st m nothing  = exec (inputFor t (Progress.state p) st m) t

-- A miss records what it ran, under the key it ran with.
addEntry : Trial → Progress → Step → Mark → Maybe Output → Cache
addEntry t p st m (just o) = Progress.cache p
addEntry t p st m nothing  =
  (K (inputFor t (Progress.state p) st m) , exec (inputFor t (Progress.state p) st m) t) ∷ Progress.cache p

ranAfter : Progress → Maybe Output → ℕ
ranAfter p (just o) = Progress.ran p
ranAfter p nothing  = suc (Progress.ran p)

-- The rebuilder, in Build Systems à la Carte's sense: a verifying trace. A hit
-- replays the recorded output; a miss runs the step and records it. Everything
-- the rest of the job sees of this step — the container it hands on and the
-- output it contributes — goes through `produced`, which is what makes replay
-- transparent when `produced` is right.
advance : Keys → Trial → Progress → Step → Mark → Maybe Output → Progress
advance ks t p st m r =
  progress (nextState ks t (Progress.state p) st m (produced t p st m r))
           (addEntry t p st m r)
           (ranAfter p r)
           (produced t p st m r ∷ Progress.outs p)

stepOnce : Keys → Trial → Progress → Step → Progress
stepOnce ks t p st =
  advance ks t p st (mark st)
    (look (K (inputFor t (Progress.state p) st (mark st))) (Progress.cache p))

-- The scheduler: a job's steps, in order. GitHub Actions gives no choice here,
-- which is why the interesting questions are all about the rebuilder.
build : Keys → Trial → Progress → List Step → Progress
build ks t p []         = p
build ks t p (st ∷ sts) = build ks t (stepOnce ks t p st) sts

-- The same job with the step cache off: every step runs. The outputs come back
-- in reverse, as `Progress.outs` collects them.
uncached : Keys → Trial → State → List Output → List Step → List Output
uncached ks t s acc []         = acc
uncached ks t s acc (st ∷ sts) =
  uncached ks t (nextState ks t s st (mark st) (exec (inputFor t s st (mark st)) t))
              (exec (inputFor t s st (mark st)) t ∷ acc) sts

uncached-cong : (ks : Keys) (t : Trial) {s s' : State} {acc acc' : List Output} (sts : List Step)
  → s ≡ s' → acc ≡ acc' → uncached ks t s acc sts ≡ uncached ks t s' acc' sts
uncached-cong ks t sts refl refl = refl

------------------------------------------------------------------------------
-- P2 and P3: what the key keeps, and what it forgets
--
-- MEASURE.md asks for one generated case per input kind. Here they are as
-- theorems instead: for the inputs the key keeps, a change makes a different
-- key; for the ones it forgets, no change can.

-- P2, script text.
text-matters : {s : State} {e : Env} {m : Mounts} {b b' : Body} {n : ℕ}
  → ¬ (b ≡ b') → ¬ (K (input s (body b n) e m) ≡ K (input s (body b' n) e m))
text-matters ¬eq k = ¬eq (body-injective₁ (cong Key.kScript k))

-- And the step's position, which the script text carries whether the workflow
-- author wanted it to or not.
position-matters : {s : State} {e : Env} {m : Mounts} {b : Body} {n n' : ℕ}
  → ¬ (n ≡ n') → ¬ (K (input s (body b n) e m) ≡ K (input s (body b n') e m))
position-matters ¬eq k = ¬eq (body-injective₂ (cong Key.kScript k))

-- P2, the container the step starts from. This is the one that carries the
-- checkout: a new commit gives a new workspace, so every step after the
-- checkout has a new parent, which is why the commit itself can be volatile.
parent-matters : {s s' : State} {sc : Script} {e : Env} {m : Mounts}
  → ¬ (s ≡ s') → ¬ (K (input s sc e m) ≡ K (input s' sc e m))
parent-matters ¬eq k = ¬eq (cong Key.kParent k)

-- P2, a binding the key keeps.
stable-env-matters : {s : State} {sc : Script} {e e' : Env} {m : Mounts}
  → ¬ (stable vol e ≡ stable vol e') → ¬ (K (input s sc e m) ≡ K (input s sc e' m))
stable-env-matters ¬eq k = ¬eq (cong Key.kEnv k)

-- P3, mounted cache volumes. Nothing about a mount reaches the key: this is
-- BuildKit excluding mounts from an exec's cache key, and it is the reason the
-- package caches can be shared without making every step miss.
mounts-invisible : {s : State} {sc : Script} {e : Env} {m m' : Mounts}
  → K (input s sc e m) ≡ K (input s sc e m')
mounts-invisible = refl

-- P3, a volatile binding. Changing the run id or the actor leaves the key
-- untouched, so steps that do not consult them are replayed.
volatile-invisible : (n : Name) (c c' : Content) {e : Env} {s : State} {sc : Script} {m m' : Mounts}
  → vol n ≡ true
  → K (input s sc ((n , c) ∷ e) m) ≡ K (input s sc ((n , c') ∷ e) m')
volatile-invisible n c c' v rewrite v = refl

------------------------------------------------------------------------------
-- Why two steps of one job never collide
--
-- Not because of the step number in the script, though that is in the key too
-- (`position-matters`). Because each step starts from the container the last one
-- left, so the chain only grows, and the parent is in the key.

depth : State → ℕ
depth (base _)          = 0
depth (afterExec s _ _) = suc (depth s)
depth (afterCopy s _)   = suc (depth s)

depth-advances : (ks : Keys) (t : Trial) (s : State) (st : Step) (m : Mark) (o : Output)
  → depth (nextState ks t s st m o) ≡ suc (depth s)
depth-advances off t s st plain    o = refl
depth-advances off t s st everyRun o = refl
depth-advances on  t s st plain    o = refl
depth-advances on  t s st everyRun o = refl

-- So a key asked from a deeper container is a different key, whatever the
-- script, the environment or the mounts.
deeper-keys-differ : {i j : Input}
  → ¬ (depth (Input.parent i) ≡ depth (Input.parent j)) → ¬ (K i ≡ K j)
deeper-keys-differ ¬d eq = ¬d (cong (λ k → depth (Key.kParent k)) eq)

------------------------------------------------------------------------------
-- What a cache has to be for a replay to stand in for a run

-- An entry is honest when some run of some input with that key really produced
-- it. This is all the engine can promise: it recorded what it saw.
Honest : Key → Output → Set
Honest k o = Σ Input (λ i → Σ Trial (λ t → (K i ≡ k) × (exec i t ≡ o)))

Coherent : Cache → Set
Coherent c = {k : Key} {o : Output} → (k , o) ∈ c → Honest k o

coherent-cons : {k : Key} {o : Output} {c : Cache} → Honest k o → Coherent c → Coherent ((k , o) ∷ c)
coherent-cons h co here      = h
coherent-cons h co (there m) = co m

-- Nothing in the cache was recorded by this job for a step numbered n or later.
--
-- Two mechanisms keep this true, and the model needs both. Across jobs it is
-- the nonce: a marked step's key names the job (`run_nonce` is the run, the
-- attempt and the job), so no other job can have left an entry under it. Within
-- a job it is the step's position, which the script text carries, so the entry a
-- step leaves cannot be found by any later step.
Ahead : Trial → ℕ → Cache → Set
Ahead t n c = {k : Key} {o : Output} → (k , o) ∈ c
  → (b : Body) (i : ℕ) → Key.kScript k ≡ stamped t (body b i) → ¬ (n ≤ i)

ahead-loosen : {t : Trial} {n : ℕ} {c : Cache} → Ahead t n c → Ahead t (suc n) c
ahead-loosen ah mem b i eq le = ah mem b i eq (≤-loosen le)

ahead-cons : {t : Trial} {n : ℕ} {k : Key} {o : Output} {c : Cache}
  → ((b : Body) (i : ℕ) → Key.kScript k ≡ stamped t (body b i) → ¬ (suc n ≤ i))
  → Ahead t (suc n) c → Ahead t (suc n) ((k , o) ∷ c)
ahead-cons new ah here        = new
ahead-cons new ah (there mem) = ah mem

-- The hypothesis the step cache rests on, for the steps that are not marked:
-- inputs that agree on everything the key keeps give the same result, whatever
-- job they are part of. It bundles three separate obligations — the step is
-- deterministic, it does not consult a volatile variable, and it does not
-- depend on the content of a mounted cache volume — and the runner enforces
-- none of them. Runner.Counterexamples breaks each one.
Disciplined : Set
Disciplined = (i j : Input) (t t' : Trial)
  → K i ≡ K j → Unstamped (Input.script i) → exec i t ≡ exec j t'

-- Determinism is not a separate assumption: it is part of Disciplined, which is
-- the honest way to record that the step cache cannot be sound for a flaky step
-- that is not marked always-run.
disciplined⇒deterministic : Disciplined
  → (i : Input) (t t' : Trial) → Unstamped (Input.script i) → exec i t ≡ exec i t'
disciplined⇒deterministic d i t t' u = d i i t t' refl u

------------------------------------------------------------------------------
-- What a hit must hand back

-- A hit on this step holds what running the step now would produce. This is P1
-- for one step, and it is the thing that has to hold every time a step is
-- replayed.
Replays : Trial → Cache → State → Step → Mark → Set
Replays t c s st m = (o : Output)
  → look (K (inputFor t s st m)) c ≡ just o → exec (inputFor t s st m) t ≡ o

-- A marked step cannot hit at all: its key names this job and its own position.
marked-misses : {t : Trial} {c : Cache} (s : State) (st : Step)
  → Ahead t (Step.num st) c → look (K (inputFor t s st everyRun)) c ≡ nothing
marked-misses s st ah = look-miss _ _ (λ o mem → ah mem (Step.text st) (Step.num st) refl ≤-refl)

-- An unmarked step's hit is honest, and honest is enough once the step is
-- disciplined. The two cases are the whole design: either the result depends
-- only on what the key keeps, or the step is marked and does not get replayed.
unmarked-replays : Disciplined → {t : Trial} {c : Cache} (s : State) (st : Step)
  → Coherent c → Replays t c s st plain
unmarked-replays d s st co o eq with co (look-sound _ _ eq)
... | ⟨ j , ⟨ t' , (kj , ej) ⟩ ⟩ = trans (d _ j _ t' (sym kj) tt) ej

------------------------------------------------------------------------------
-- P1: replay equals run

-- One step. Whether it hit or missed, what it contributes is what running it
-- contributes; the cache stays coherent, and still holds nothing for the steps
-- that come after.
step-ok : Disciplined → (t : Trial) (p : Progress) (st : Step) (m : Mark) (r : Maybe Output)
  → look (K (inputFor t (Progress.state p) st m)) (Progress.cache p) ≡ r
  → Coherent (Progress.cache p) → Ahead t (Step.num st) (Progress.cache p)
  → (produced t p st m r ≡ exec (inputFor t (Progress.state p) st m) t)
    × (Coherent (addEntry t p st m r) × Ahead t (suc (Step.num st)) (addEntry t p st m r))
step-ok d t p st plain (just o) eq co ah =
  sym (unmarked-replays d (Progress.state p) st co o eq) , (co , ahead-loosen ah)
step-ok d t p st everyRun (just o) eq co ah =
  ⊥-elim (impossible (trans (sym (marked-misses (Progress.state p) st ah)) eq))
  where
    impossible : {o' : Output} → ¬ (nothing ≡ just o')
    impossible ()
step-ok d t p st plain nothing eq co ah =
  refl , (coherent-cons ⟨ _ , ⟨ t , (refl , refl) ⟩ ⟩ co , ahead-cons new (ahead-loosen ah))
  where
    new : (b : Body) (i : ℕ)
      → Key.kScript (K (inputFor t (Progress.state p) st plain)) ≡ stamped t (body b i)
      → ¬ (suc (Step.num st) ≤ i)
    new b i ()
step-ok d t p st everyRun nothing eq co ah =
  refl , (coherent-cons ⟨ _ , ⟨ t , (refl , refl) ⟩ ⟩ co , ahead-cons new (ahead-loosen ah))
  where
    new : (b : Body) (i : ℕ)
      → Key.kScript (K (inputFor t (Progress.state p) st everyRun)) ≡ stamped t (body b i)
      → ¬ (suc (Step.num st) ≤ i)
    new b i eq' le =
      suc≰ (Step.num st)
        (subst (λ x → suc (Step.num st) ≤ x) (sym (body-injective₂ (stamped-injective₂ eq'))) le)

-- The job's steps are numbered from n upwards, as the runner numbers them and
-- as `containerScript` writes into each script.
Numbered : ℕ → List Step → Set
Numbered n []         = ⊤
Numbered n (st ∷ sts) = (Step.num st ≡ n) × Numbered (suc n) sts

-- P1, replay equals run. A job run against a cache from other jobs produces
-- what the same job produces with the step cache off — every step of it —
-- provided the steps the runner does not mark are disciplined. It holds with
-- output keys on or off, since what the rest of the job sees of a step goes
-- through `produced` either way.
--
-- What the proof needs beyond Disciplined is only bookkeeping the
-- implementation already does: entries are honest, and the job's steps are
-- numbered. There is no hypothesis left over about mounted content, because the
-- numbering discharges it inside a job and Disciplined covers it across jobs.
replay≡run : Disciplined → (ks : Keys) (t : Trial) (n : ℕ) (p : Progress) (job : List Step)
  → Numbered n job
  → Coherent (Progress.cache p) → Ahead t n (Progress.cache p)
  → Progress.outs (build ks t p job) ≡ uncached ks t (Progress.state p) (Progress.outs p) job
replay≡run d ks t n p []         _            co ah = refl
replay≡run d ks t n p (st ∷ sts) (num , nums) co ah
  with step-ok d t p st (mark st) _ refl co (subst (λ x → Ahead t x (Progress.cache p)) (sym num) ah)
... | (out-eq , (co' , ah')) =
      trans (replay≡run d ks t (suc n) (stepOnce ks t p st) sts nums co'
              (subst (λ x → Ahead t (suc x)
                       (addEntry t p st (mark st)
                         (look (K (inputFor t (Progress.state p) st (mark st))) (Progress.cache p))))
                     num ah'))
            (uncached-cong ks t sts
              (cong (nextState ks t (Progress.state p) st (mark st)) out-eq)
              (cong (λ x → x ∷ Progress.outs p) out-eq))

------------------------------------------------------------------------------
-- P6: minimality

-- Every step of the job hits.
Warm : Keys → Trial → Progress → List Step → Set
Warm ks t p []         = ⊤
Warm ks t p (st ∷ sts) =
  Σ Output (λ o → (look (K (inputFor t (Progress.state p) st (mark st))) (Progress.cache p) ≡ just o)
                  × Warm ks t (stepOnce ks t p st) sts)

hit-keeps-ran : (ks : Keys) (t : Trial) (p : Progress) (st : Step) {o : Output}
  → look (K (inputFor t (Progress.state p) st (mark st))) (Progress.cache p) ≡ just o
  → Progress.ran (stepOnce ks t p st) ≡ Progress.ran p
hit-keeps-ran ks t p st eq rewrite eq = refl

-- P6, the half that matters for the claim "N of M steps replayed from the
-- cache": a job whose every step hits runs nothing at all.
warm-runs-nothing : (ks : Keys) (t : Trial) (p : Progress) (job : List Step)
  → Warm ks t p job → Progress.ran (build ks t p job) ≡ Progress.ran p
warm-runs-nothing ks t p []         w = refl
warm-runs-nothing ks t p (st ∷ sts) ⟨ o , (hit , w) ⟩ =
  trans (warm-runs-nothing ks t (stepOnce ks t p st) sts w) (hit-keeps-ran ks t p st hit)
