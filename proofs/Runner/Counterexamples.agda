{-# OPTIONS --safe #-}

open import Prelude
open import Runner.Model
import Runner.Build as B

-- Runner.Build proves that replay equals run, and it needs exactly two things:
-- `Disciplined` for the steps the runner does not mark always-run, and a job
-- whose steps are numbered. This file shows that neither is decoration. For
-- each one there is a step, a cache and a job where it fails and the cache
-- hands back an answer that running would not have given.
--
-- Everything here computes: each `refl` below is the model running, and each
-- `()` is Agda checking that two concrete answers differ.
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

------------------------------------------------------------------------------
-- 1. A volatile read the runner did not notice
--
-- `readsRunSpecific` looks for the variable's name in the script text. A script
-- that gets the value another way — sourcing a file, calling a program that
-- reads the environment, `env | grep` — consults it without naming it, so the
-- step is not marked. This is that step.

module VolatileRead where

  -- The step leaves behind what it read from the run id.
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
  warm = Progress.cache (build 1 (progress 0 [] 0) (first ∷ []))

  replayed : State
  replayed = Progress.state (build 2 (progress 0 warm 0) (second ∷ []))

  ran : State
  ran = uncached 2 0 (second ∷ [])

  -- The second job is handed the first's answer, and never runs the step.
  replayed≡7 : replayed ≡ 7
  replayed≡7 = refl

  ran≡9 : ran ≡ 9
  ran≡9 = refl

  nothing-ran : Progress.ran (build 2 (progress 0 warm 0) (second ∷ [])) ≡ 0
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
  warm = Progress.cache (build 1 (progress 0 [] 0) (first ∷ []))

  -- It runs, and it gives what running gives.
  it-ran : Progress.ran (build 2 (progress 0 warm 0) (second ∷ [])) ≡ 1
  it-ran = refl

  sound : Progress.state (build 2 (progress 0 warm 0) (second ∷ [])) ≡ uncached 2 0 (second ∷ [])
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
  warm = Progress.cache (build 1 (progress 0 [] 0) (test ∷ []))

  -- Job 1 passed, so job 2 passes too, without running the test. A runner that
  -- replays steps cannot observe flakiness in the steps it replays: it is not
  -- that we have not measured it (docs/RELATED.md), it is that this design
  -- hides it by construction, and `Disciplined` is where it hides.
  replay-hides-it : Progress.state (build 2 (progress 0 warm 0) (test ∷ [])) ≡ 1
  replay-hides-it = refl

  running-shows-it : uncached 2 0 (test ∷ []) ≡ 2
  running-shows-it = refl

  unsound : ¬ (Progress.state (build 2 (progress 0 warm 0) (test ∷ [])) ≡ uncached 2 0 (test ∷ []))
  unsound ()

------------------------------------------------------------------------------
-- 4. A step that reads a cache volume
--
-- Mounts are excluded from an exec's key by design, which is what lets the
-- package caches be shared without making every step miss (experiment 6). The
-- price is that a step whose result depends on what it found in one is not
-- disciplined, and gets replayed when the volume has changed.

module MountedCache where

  -- The step leaves behind what it found at path 3, a cache volume.
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
  warm = Progress.cache (build 1 (progress 0 [] 0) (first ∷ []))

  -- The key is the same, so the step is replayed with the old volume's answer.
  unsound : ¬ (Progress.state (build 2 (progress 0 warm 0) (second ∷ []))
               ≡ uncached 2 0 (second ∷ []))
  unsound ()

------------------------------------------------------------------------------
-- 5. Two steps that share a number
--
-- The job's nonce is per job, not per step, so two marked steps in one job
-- carry the same marker. What keeps them apart is the step's position, which
-- `containerScript` writes into the script text as a log marker. Take it away —
-- give two steps the same number — and the second is replayed from the first,
-- marked or not.

module SharedNumber where

  -- The step reports what it found at path 3 and leaves the container alone: a
  -- check that reads a cache volume, a `uv sync` that only writes to one.
  execM : Input → Trial → Output
  execM i t = output (Input.parent i) (valueOf 3 (Input.mounts i))

  module M = B vol execM
  open M

  readsFive : Step
  readsFive = step 1 0 [] ((3 , 5) ∷ []) (runId ∷ [])

  -- Numbered 0 as well, which the runner never emits.
  readsSix : Step
  readsSix = step 1 0 [] ((3 , 6) ∷ []) (runId ∷ [])

  afterFirst : Cache
  afterFirst = Progress.cache (build 1 (progress 0 [] 0) (readsFive ∷ []))

  -- Same job, same marker, same everything the key keeps: a hit.
  hits : look (K (inputFor 1 0 readsSix (mark readsSix))) afterFirst ≡ just (output 0 5)
  hits = refl

  -- And the hit is wrong: it reports 5 where running reports 6.
  unsound : ¬ (Replays 1 afterFirst 0 readsSix (mark readsSix))
  unsound r = differs (cong Output.log (r (output 0 5) hits))
    where
      differs : ¬ (6 ≡ 5)
      differs ()

  -- Numbered as the runner numbers them, the same step cannot find the entry.
  numberedSix : Step
  numberedSix = step 1 1 [] ((3 , 6) ∷ []) (runId ∷ [])

  numbering-saves-it : look (K (inputFor 1 0 numberedSix (mark numberedSix))) afterFirst ≡ nothing
  numbering-saves-it = refl
