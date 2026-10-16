{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model
import Runner.Build as B

-- Output keys (`RUNNER_OUTPUT_KEYS`), and the property they exist for.
--
-- A marked step cannot be replayed — that is the point of marking it — and
-- without help neither can anything after it, because the container it hands on
-- is identified by its own recipe, nonce and all. `outputKeyed` replaces that
-- container with the one before the step plus what the step produced, copied in
-- by content digest. So what the next step starts from records *what was
-- produced* rather than *who produced it*.
--
-- In Build Systems à la Carte's taxonomy the step cache is a verifying trace
-- and this is a constructive one, and what it buys is early cutoff: a step
-- whose result is unchanged stops forcing its dependents to run.
module Runner.OutputKeys (vol : Volatile) (exec : Input → Trial → Output) where

module Core = B vol exec
open Core

------------------------------------------------------------------------------
-- Containers that name a job

-- The container's identity mentions this job's nonce, so no other job can have
-- built it: either a marked step's exec left it, or something that did is
-- somewhere below it in the chain.
data Nonced (t : Trial) : State → Set where
  marked : {s : State} {b : Body} {n : ℕ} {e : Env} → Nonced t (afterExec s (stamped t (body b n)) e)
  below  : {s : State} {sc : Script} {e : Env} → Nonced t s → Nonced t (afterExec s sc e)
  copied : {s : State} {c : Content} → Nonced t s → Nonced t (afterCopy s c)

-- A cache written by other jobs: no entry's key starts from a container that
-- mentions this job's nonce. Such a container is one no other job could have
-- built, so no other job could have recorded a key starting from it.
Clean : Trial → Cache → Set
Clean t c = {k : Key} {o : Output} → (k , o) ∈ c → ¬ Nonced t (Key.kParent k)

-- A step that starts from such a container misses, marked or not.
nonced-misses : {t : Trial} {c : Cache} (s : State) (e : Env) (st : Step) (m : Mark)
  → Nonced t s → Clean t c → look (K (inputFor t s e st m)) c ≡ nothing
nonced-misses s e st plain    nc cl = look-miss _ _ (λ o mem → cl mem nc)
nonced-misses s e st everyRun nc cl = look-miss _ _ (λ o mem → cl mem nc)

------------------------------------------------------------------------------
-- Without output keys, a marked step is a wall

-- The container a marked step hands on names the job. This is equally what a
-- *fallback* costs: `outputKeyed` returning null for one step is the `off`
-- behaviour for that step, and this is the price of it.
marked-is-nonced : (t : Trial) (s : State) (e : Env) (st : Step) (o : Output)
  → Nonced t (nextState off t s e st everyRun o)
marked-is-nonced t s e st o = marked

-- And nothing downstream shakes it off, in either mode. Output keys do not
-- clean a container that is already named by the job; they stop a marked step
-- from naming one in the first place.
nonced-stays : (ks : Keys) (t : Trial) (s : State) (e : Env) (st : Step) (m : Mark) (o : Output)
  → Nonced t s → Nonced t (nextState ks t s e st m o)
nonced-stays off t s e st plain    o nc = below nc
nonced-stays off t s e st everyRun o nc = below nc
nonced-stays on  t s e st plain    o nc = below nc
nonced-stays on  t s e st everyRun o nc = copied nc

-- The keys a job asks for, in order, from a given container and environment.
keysFrom : Mode → Trial → State → Env → List Step → List Key
keysFrom md t s e []         = []
keysFrom md t s e (st ∷ sts) =
  K (inputFor t s e st (mark st)) ∷
    keysFrom md t (nextState (md (Step.num st)) t s e st (mark st) (exec (inputFor t s e st (mark st)) t))
                  (nextEnv e (exec (inputFor t s e st (mark st)) t)) sts

-- Every key asked from a container that names the job starts from one too.
keys-stay-nonced : (md : Mode) (t : Trial) (s : State) (e : Env) (job : List Step)
  → Nonced t s → All (λ k → Nonced t (Key.kParent k)) (keysFrom md t s e job)
keys-stay-nonced md t s e []         nc = all[]
keys-stay-nonced md t s e (st ∷ sts) nc =
  all∷ (parent-nonced (mark st))
    (keys-stay-nonced md t
      (nextState (md (Step.num st)) t s e st (mark st) (exec (inputFor t s e st (mark st)) t))
      (nextEnv e (exec (inputFor t s e st (mark st)) t)) sts
      (nonced-stays (md (Step.num st)) t s e st (mark st) (exec (inputFor t s e st (mark st)) t) nc))
  where
    parent-nonced : (m : Mark) → Nonced t (Key.kParent (K (inputFor t s e st m)))
    parent-nonced plain    = nc
    parent-nonced everyRun = nc

-- E1. With output keys off — or falling back on this one step — a marked step
-- makes every step after it run: each one asks a key that no other job's cache
-- can hold, whatever the marked step produced and whatever the later steps are.
-- This is the cost output keys were built to remove, and the reason SPEC.md §6
-- says "every step after them then runs too".
no-cutoff-without-keys : (md : Mode) (t : Trial) (c : Cache) (s : State) (e : Env)
  (st : Step) (rest : List Step)
  → Clean t c
  → All (λ k → look k c ≡ nothing)
        (keysFrom md t (nextState off t s e st everyRun (exec (inputFor t s e st everyRun) t))
                       (nextEnv e (exec (inputFor t s e st everyRun) t)) rest)
no-cutoff-without-keys md t c s e st rest cl =
  misses (keys-stay-nonced md t
            (nextState off t s e st everyRun (exec (inputFor t s e st everyRun) t))
            (nextEnv e (exec (inputFor t s e st everyRun) t)) rest
            (marked-is-nonced t s e st (exec (inputFor t s e st everyRun) t)))
  where
    misses : {ks : List Key} → All (λ k → Nonced t (Key.kParent k)) ks
      → All (λ k → look k c ≡ nothing) ks
    misses all[]         = all[]
    misses (all∷ nc ncs) = all∷ (look-miss _ _ (λ o mem → cl mem nc)) (misses ncs)

------------------------------------------------------------------------------
-- With output keys, the same bytes mean the same keys

-- Which steps the runner will not mark.
AllPlain : List Step → Set
AllPlain = All (λ st → mark st ≡ plain)

-- An unmarked step's key says nothing about which job is running: the nonce is
-- the only job-specific thing in one, and an unmarked step has none.
--
-- It needs `Disciplined` all the same, and that is new: what a step exports
-- through `$GITHUB_ENV` is in the next step's container, so if an unmarked step
-- produced different variables in two jobs, the keys after it would part
-- company. Early cutoff therefore rests on the same hypothesis P1 does.
keys-job-independent : Disciplined → (t t' : Trial) (s : State) (e : Env) (sts : List Step)
  → AllPlain sts
  → keysFrom (always on) t s e sts ≡ keysFrom (always on) t' s e sts
keys-job-independent d t t' s e []         all[]        = refl
keys-job-independent d t t' s e (st ∷ sts) (all∷ pl pls) rewrite pl =
  cong (λ ks → K (input s (body (Step.text st) (Step.num st)) e (Step.mounts st)) ∷ ks)
    (trans (cong (λ o → keysFrom (always on) t
                          (stateOf (K (input s (body (Step.text st) (Step.num st)) e (Step.mounts st))))
                          (nextEnv e o) sts)
                 (d (input s (body (Step.text st) (Step.num st)) e (Step.mounts st))
                    (input s (body (Step.text st) (Step.num st)) e (Step.mounts st)) t t' refl tt))
           (keys-job-independent d t t' _ _ sts pls))

-- E2. Early cutoff. Two jobs that run the same steps from the same container,
-- whose marked step produced the same bytes, ask exactly the same keys for
-- every step after it — so whatever the first job recorded, the second finds,
-- and the marked step having run again costs nothing downstream.
--
-- Soundness of those replays is not a new question: replay≡run is proved for
-- every mode, with no extra hypothesis.
cutoff : Disciplined → (t t' : Trial) (s : State) (e : Env) (st : Step) (rest : List Step)
  → AllPlain rest
  → exec (inputFor t s e st everyRun) t ≡ exec (inputFor t' s e st everyRun) t'
  → keysFrom (always on) t
      (nextState on t s e st everyRun (exec (inputFor t s e st everyRun) t))
      (nextEnv e (exec (inputFor t s e st everyRun) t)) rest
  ≡ keysFrom (always on) t'
      (nextState on t' s e st everyRun (exec (inputFor t' s e st everyRun) t'))
      (nextEnv e (exec (inputFor t' s e st everyRun) t')) rest
cutoff d t t' s e st rest plains same =
  trans (cong (λ o → keysFrom (always on) t (afterCopy s (Output.digest o)) (nextEnv e o) rest) same)
        (keys-job-independent d t t' (afterCopy s (Output.digest (exec (inputFor t' s e st everyRun) t')))
          (nextEnv e (exec (inputFor t' s e st everyRun) t')) rest plains)

-- The digest is what the next container is keyed on, so equal *bytes* are
-- enough even when the step's log and exported variables differ — which is the
-- point: a deploy that prints a new timestamp still leaves the same files.
cutoff-needs-only-the-digest : (t t' : Trial) (s : State) (e : Env) (st : Step)
  → Output.digest (exec (inputFor t s e st everyRun) t)
    ≡ Output.digest (exec (inputFor t' s e st everyRun) t')
  → nextState on t s e st everyRun (exec (inputFor t s e st everyRun) t)
    ≡ nextState on t' s e st everyRun (exec (inputFor t' s e st everyRun) t')
cutoff-needs-only-the-digest t t' s e st dig = cong (afterCopy s) dig

-- And it is not a blanket excuse. Different bytes are a different container, so
-- a marked step whose output changed still forces the steps after it: output
-- keys buy early cutoff, not unconditional reuse.
different-bytes-different-container : (s : State) (d d' : Content)
  → ¬ (d ≡ d') → ¬ (afterCopy s d ≡ afterCopy s d')
different-bytes-different-container s d d' ¬eq eq = ¬eq (afterCopy-injective₂ eq)
