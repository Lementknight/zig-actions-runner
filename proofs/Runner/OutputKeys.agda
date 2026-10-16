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
nonced-misses : {t : Trial} {c : Cache} (s : State) (st : Step) (m : Mark)
  → Nonced t s → Clean t c → look (K (inputFor t s st m)) c ≡ nothing
nonced-misses s st plain    nc cl = look-miss _ _ (λ o mem → cl mem nc)
nonced-misses s st everyRun nc cl = look-miss _ _ (λ o mem → cl mem nc)

------------------------------------------------------------------------------
-- Without output keys, a marked step is a wall

-- The container a marked step hands on names the job.
marked-is-nonced : (t : Trial) (s : State) (st : Step) (o : Output)
  → Nonced t (nextState off t s st everyRun o)
marked-is-nonced t s st o = marked

-- And nothing downstream shakes it off, in either mode. Output keys do not
-- clean a container that is already named by the job; they stop a marked step
-- from naming one in the first place.
nonced-stays : (ks : Keys) (t : Trial) (s : State) (st : Step) (m : Mark) (o : Output)
  → Nonced t s → Nonced t (nextState ks t s st m o)
nonced-stays off t s st plain    o nc = below nc
nonced-stays off t s st everyRun o nc = below nc
nonced-stays on  t s st plain    o nc = below nc
nonced-stays on  t s st everyRun o nc = copied nc

-- The keys a job asks for, in order, from a given container.
keysFrom : Keys → Trial → State → List Step → List Key
keysFrom ks t s []         = []
keysFrom ks t s (st ∷ sts) =
  K (inputFor t s st (mark st))
    ∷ keysFrom ks t (nextState ks t s st (mark st) (exec (inputFor t s st (mark st)) t)) sts

-- Every key asked from a container that names the job starts from one too.
keys-stay-nonced : (ks : Keys) (t : Trial) (s : State) (job : List Step)
  → Nonced t s → All (λ k → Nonced t (Key.kParent k)) (keysFrom ks t s job)
keys-stay-nonced ks t s []         nc = all[]
keys-stay-nonced ks t s (st ∷ sts) nc =
  all∷ (parent-nonced (mark st))
    (keys-stay-nonced ks t (nextState ks t s st (mark st) (exec (inputFor t s st (mark st)) t)) sts
        (nonced-stays ks t s st (mark st) (exec (inputFor t s st (mark st)) t) nc))
  where
    parent-nonced : (m : Mark) → Nonced t (Key.kParent (K (inputFor t s st m)))
    parent-nonced plain    = nc
    parent-nonced everyRun = nc

-- E1. With output keys off, a marked step makes every step after it run: each
-- one asks a key that no other job's cache can hold, whatever the marked step
-- produced and whatever the later steps are. This is the cost output keys were
-- built to remove, and the reason SPEC.md §6 says "every step after them then
-- runs too".
no-cutoff-without-keys : (t : Trial) (c : Cache) (s : State) (st : Step) (rest : List Step)
  → Clean t c
  → All (λ k → look k c ≡ nothing)
        (keysFrom off t (nextState off t s st everyRun (exec (inputFor t s st everyRun) t)) rest)
no-cutoff-without-keys t c s st rest cl =
  misses (keys-stay-nonced off t
            (nextState off t s st everyRun (exec (inputFor t s st everyRun) t)) rest
            (marked-is-nonced t s st (exec (inputFor t s st everyRun) t)))
  where
    misses : {ks : List Key} → All (λ k → Nonced t (Key.kParent k)) ks
      → All (λ k → look k c ≡ nothing) ks
    misses all[]          = all[]
    misses (all∷ nc ncs) = all∷ (look-miss _ _ (λ o mem → cl mem nc)) (misses ncs)

------------------------------------------------------------------------------
-- With output keys, the same bytes mean the same keys

-- Which steps the runner will not mark.
AllPlain : List Step → Set
AllPlain = All (λ st → mark st ≡ plain)

-- An unmarked step's key and the container it hands on say nothing about which
-- job is running: the nonce is the only job-specific thing in either, and an
-- unmarked step has none.
keys-job-independent : (t t' : Trial) (s : State) (sts : List Step)
  → AllPlain sts → keysFrom on t s sts ≡ keysFrom on t' s sts
keys-job-independent t t' s []         all[]        = refl
keys-job-independent t t' s (st ∷ sts) (all∷ pl pls) rewrite pl =
  cong (λ x → K (input s (body (Step.text st) (Step.num st)) (Step.env st) (Step.mounts st)) ∷ x)
       (keys-job-independent t t' _ sts pls)

-- E2. Early cutoff. Two jobs that run the same steps from the same container,
-- whose marked step produced the same bytes, ask exactly the same keys for
-- every step after it — so whatever the first job recorded, the second finds,
-- and the marked step having run again does not cost anything downstream.
--
-- Soundness of those replays is not a new question: replay≡run is proved for
-- output keys on as well as off, with no extra hypothesis.
cutoff : (t t' : Trial) (s : State) (st : Step) (rest : List Step)
  → AllPlain rest
  → Output.digest (exec (inputFor t s st everyRun) t)
    ≡ Output.digest (exec (inputFor t' s st everyRun) t')
  → keysFrom on t  (nextState on t  s st everyRun (exec (inputFor t  s st everyRun) t))  rest
  ≡ keysFrom on t' (nextState on t' s st everyRun (exec (inputFor t' s st everyRun) t')) rest
cutoff t t' s st rest plains dig =
  trans (cong (λ x → keysFrom on t (afterCopy s x) rest) dig)
        (keys-job-independent t t' (afterCopy s _) rest plains)

-- And it is not a blanket excuse. Different bytes are a different container, so
-- a marked step whose output changed still forces the steps after it: output
-- keys buy early cutoff, not unconditional reuse.
different-bytes-different-container : (s : State) (d d' : Content)
  → ¬ (d ≡ d') → ¬ (afterCopy s d ≡ afterCopy s d')
different-bytes-different-container s d d' ¬eq eq = ¬eq (afterCopy-injective₂ eq)
