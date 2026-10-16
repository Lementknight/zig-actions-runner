{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model
import Runner.Build as B

-- Runner.Build proves that replay equals run, and what it needs is
-- `Disciplined`: for a step the runner does not mark always-run, inputs that
-- agree on everything the key keeps give the same result. That one hypothesis
-- bundles three obligations — the step is deterministic, it reads no volatile
-- variable, and it does not depend on the content of a mounted cache volume —
-- and the runner enforces none of them. Here is a job that breaks each.
--
-- Everything computes: each `refl` is the model running, and each `()` is Agda
-- checking that two concrete answers differ.
module Runner.Counterexamples where

-- Name 0 stands for GITHUB_RUN_ID: its value differs between runs, and the key
-- deliberately leaves it out.
runId : Name
runId = 0

vol : Volatile
vol n with n ≟ℕ runId
... | yes _ = true
... | no  _ = false

-- Looking a name up in an environment, or a path up in the mounts; absent is 0.
valueOf : Name → List (Name × Content) → Content
valueOf n []       = 0
valueOf n (b ∷ bs) with n ≟ℕ fst b
... | yes _ = snd b
... | no  _ = valueOf n bs

-- The job's base container.
start : State
start = base 0

------------------------------------------------------------------------------
-- 1. A volatile read the runner did not notice
--
-- `readsRunSpecific` looks for the variable's name in the script text. A script
-- that gets the value another way — sourcing a file, calling a program that
-- reads the environment, `env | grep` — consults it without naming it, so the
-- step is not marked. This is that step.

module VolatileRead where

  -- The step logs what it read from the run id.
  execV : Input → Trial → Output
  execV i t = output (valueOf runId (Input.env i)) 0

  module V = B vol execV
  open V

  -- One step, in two jobs: the first has GITHUB_RUN_ID=7, the second 9.
  -- `reads` is empty, so the runner marks neither.
  first  : Step
  first  = step 1 0 ((runId , 7) ∷ []) [] []
  second : Step
  second = step 1 0 ((runId , 9) ∷ []) [] []

  warm : Cache
  warm = Progress.cache (build off 1 (progress start [] 0 []) (first ∷ []))

  replayed : List Output
  replayed = Progress.outs (build off 2 (progress start warm 0 []) (second ∷ []))

  ran : List Output
  ran = uncached off 2 start [] (second ∷ [])

  -- The second job is handed the first's answer, and never runs the step.
  replayed-logs-7 : replayed ≡ (output 7 0 ∷ [])
  replayed-logs-7 = refl

  ran-logs-9 : ran ≡ (output 9 0 ∷ [])
  ran-logs-9 = refl

  nothing-ran : Progress.ran (build off 2 (progress start warm 0 []) (second ∷ [])) ≡ 0
  nothing-ran = refl

  -- So P1 fails, and nothing in the engine is at fault: the key kept everything
  -- it promised to keep. The obligation is the runner's, and it is the
  -- obligation to decide `Step.reads` correctly.
  unsound : ¬ (replayed ≡ ran)
  unsound ()

------------------------------------------------------------------------------
-- 2. The same step, marked
--
-- With the read declared, `mark` gives `everyRun`, the job's nonce goes into
-- the script, the key is one no other job can have recorded, and the step runs.

module Marked where

  execV : Input → Trial → Output
  execV i t = output (valueOf runId (Input.env i)) 0

  module V = B vol execV
  open V

  first  : Step
  first  = step 1 0 ((runId , 7) ∷ []) [] (runId ∷ [])
  second : Step
  second = step 1 0 ((runId , 9) ∷ []) [] (runId ∷ [])

  warm : Cache
  warm = Progress.cache (build off 1 (progress start [] 0 []) (first ∷ []))

  -- It runs, and it gives what running gives.
  it-ran : Progress.ran (build off 2 (progress start warm 0 []) (second ∷ [])) ≡ 1
  it-ran = refl

  sound : Progress.outs (build off 2 (progress start warm 0 []) (second ∷ []))
          ≡ uncached off 2 start [] (second ∷ [])
  sound = refl

------------------------------------------------------------------------------
-- 3. A flaky step
--
-- A step that is not marked and is not a function of its inputs. The runner has
-- no way to tell, and the cache has no reason to doubt it.

module Flaky where

  -- The result differs between jobs although every input the key keeps is the
  -- same: a test that passes once and fails once.
  execF : Input → Trial → Output
  execF i t = output t 0

  module F = B vol execF
  open F

  test : Step
  test = step 1 0 [] [] []

  warm : Cache
  warm = Progress.cache (build off 1 (progress start [] 0 []) (test ∷ []))

  -- Job 1 passed, so job 2 "passes" too, without running the test. A runner
  -- that replays steps cannot observe flakiness in the steps it replays: it is
  -- not that we have not measured it (docs/RELATED.md), it is that this design
  -- hides it by construction, and `Disciplined` is where it hides.
  replay-hides-it : Progress.outs (build off 2 (progress start warm 0 []) (test ∷ []))
                    ≡ (output 1 0 ∷ [])
  replay-hides-it = refl

  running-shows-it : uncached off 2 start [] (test ∷ []) ≡ (output 2 0 ∷ [])
  running-shows-it = refl

  unsound : ¬ (Progress.outs (build off 2 (progress start warm 0 []) (test ∷ []))
               ≡ uncached off 2 start [] (test ∷ []))
  unsound ()

------------------------------------------------------------------------------
-- 4. A step that reads a cache volume
--
-- Mounts are excluded from an exec's key by design, which is what lets the
-- package caches be shared without making every step miss (experiment 6). The
-- price is that a step whose result depends on what it found in one is not
-- disciplined, and gets replayed when the volume has changed.

module MountedCache where

  -- The step logs what it found at path 3, a cache volume.
  execM : Input → Trial → Output
  execM i t = output (valueOf 3 (Input.mounts i)) 0

  module M = B vol execM
  open M

  -- The same step in two jobs. Between them something else filled the volume:
  -- another job's `uv sync`, a `go mod download`, a pruning pass.
  first  : Step
  first  = step 1 0 [] ((3 , 5) ∷ []) []
  second : Step
  second = step 1 0 [] ((3 , 9) ∷ []) []

  warm : Cache
  warm = Progress.cache (build off 1 (progress start [] 0 []) (first ∷ []))

  -- The key is the same, so the step is replayed with the old volume's answer.
  unsound : ¬ (Progress.outs (build off 2 (progress start warm 0 []) (second ∷ []))
               ≡ uncached off 2 start [] (second ∷ []))
  unsound ()

------------------------------------------------------------------------------
-- 5. The same step twice in one job
--
-- This is the case an earlier version of this model got wrong, and it is worth
-- keeping as the correction. The job's nonce is per job, not per step, so two
-- marked steps in one job carry the *same* marker; it looked as though only the
-- step number in the script text kept them apart. It is not: each step starts
-- from the container the previous one left, so the second occurrence asks a key
-- with a deeper parent, and the first's entry cannot answer it.

module SameStepTwice where

  execM : Input → Trial → Output
  execM i t = output (valueOf 3 (Input.mounts i)) 0

  module M = B vol execM
  open M

  -- Identical but for the volume's content, and numbered the same, which the
  -- runner never emits — so the script text cannot be what separates them.
  readsFive : Step
  readsFive = step 1 0 [] ((3 , 5) ∷ []) (runId ∷ [])
  readsSix  : Step
  readsSix  = step 1 0 [] ((3 , 6) ∷ []) (runId ∷ [])

  afterFirst : Progress
  afterFirst = build off 1 (progress start [] 0 []) (readsFive ∷ [])

  -- The second occurrence does not find the first's entry.
  misses : look (K (inputFor 1 (Progress.state afterFirst) readsSix (mark readsSix)))
                (Progress.cache afterFirst)
           ≡ nothing
  misses = refl

  -- Because the chain grew: it is one deeper than where the first step started.
  deeper : depth (Progress.state afterFirst) ≡ suc (depth start)
  deeper = refl

  -- So both run, and the job reports what running reports.
  both-ran : Progress.ran (build off 1 (progress start [] 0 []) (readsFive ∷ readsSix ∷ [])) ≡ 2
  both-ran = refl

  sound : Progress.outs (build off 1 (progress start [] 0 []) (readsFive ∷ readsSix ∷ []))
          ≡ uncached off 1 start [] (readsFive ∷ readsSix ∷ [])
  sound = refl

------------------------------------------------------------------------------
-- 6. Output keys, and what makes them fall flat
--
-- A marked step is a wall: nothing after it can be replayed, because what it
-- hands on is identified by its own recipe. Output keys replace that with the
-- container before it plus what it produced, by digest — so the wall comes down
-- exactly when the step produces the same bytes as last time. These four
-- numbers are experiment 7.6 in miniature.

module OutputKeys where

  -- A deploy (text 1) that leaves the same bytes behind every job; a deploy
  -- (text 2) whose output carries something new every time, which is what a
  -- timestamp or a random delimiter in a file command does; and everything
  -- else, which is stable.
  execD : Input → Trial → Output
  execD i t with Input.script i
  ... | stamped _ (body 2 _) = output 0 t
  ... | _                    = output 0 42

  module D = B vol execD
  open D

  deploy : Step
  deploy = step 1 0 [] [] (runId ∷ [])

  noisyDeploy : Step
  noisyDeploy = step 2 0 [] [] (runId ∷ [])

  check : Step
  check = step 5 1 [] [] []

  -- Job 1 runs both steps and records them.
  warm : Cache
  warm = Progress.cache (build on 1 (progress start [] 0 []) (deploy ∷ check ∷ []))

  cold-job-runs-both : Progress.ran (build on 1 (progress start [] 0 []) (deploy ∷ check ∷ [])) ≡ 2
  cold-job-runs-both = refl

  -- Job 2, with output keys: the deploy runs again, as it must, and the check
  -- after it is replayed anyway. That is early cutoff.
  cutoff-replays-the-check : Progress.ran (build on 2 (progress start warm 0 []) (deploy ∷ check ∷ [])) ≡ 1
  cutoff-replays-the-check = refl

  -- Without output keys, the same job runs both: the deploy's new key is a new
  -- container, and the check cannot be found under it.
  without-keys-runs-both : Progress.ran (build off 2 (progress start warm 0 []) (deploy ∷ check ∷ [])) ≡ 2
  without-keys-runs-both = refl

  -- And output keys buy nothing when the always-run step's output is never the
  -- same twice: the digest is the key, so a new digest is a new container.
  -- `outputs_ignored` in dagger.zig exists for exactly this reason.
  noisy : Cache
  noisy = Progress.cache (build on 1 (progress start [] 0 []) (noisyDeploy ∷ check ∷ []))

  noise-defeats-cutoff : Progress.ran (build on 2 (progress start noisy 0 []) (noisyDeploy ∷ check ∷ [])) ≡ 2
  noise-defeats-cutoff = refl
