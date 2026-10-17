{-# OPTIONS --safe #-}

-- Why the regex matcher terminates, and what it costs to leave the reason out.
--
-- `runner/src/regex.zig` is a backtracking matcher, and backtracking does not terminate for free: a
-- loop whose body matches the empty string repeats at the same position for ever. The engine stops
-- that with two instructions — `mark` records where an iteration began, `progress` leaves the loop
-- when the iteration consumed nothing — and this module is the argument that those two are enough.
--
-- The theorem is a bound, not just finiteness: **the iterations a loop takes, plus the position it
-- started from, cannot exceed the input** (`iterations r + pos ≤ n`), because every iteration that
-- continues strictly advances. Starting at zero that is `iterations r ≤ n`. The `stall` construction at the bottom is the other half: drop the strict advance and
-- chains of every length exist, which is the bug the differential test found twice.
--
-- The arithmetic it needs — `_+_`, `+-suc`, `+-zero`, `≤-trans`, `+-mono` — lives in Prelude, with
-- the fixity for `_≤_` that its absence made necessary. A shared base that cannot add two numbers
-- is not a base; every proof here should be able to reach for the same lemmas.

module Runner.Regex where

open import Prelude

------------------------------------------------------------------------------
-- A run of the loop
--
-- One value of `Run n pos` is one complete execution of a loop over an input of `n` bytes, starting
-- at `pos`. `stop` is `progress` leaving the loop (or the body failing); `step` is an iteration that
-- continued, and it carries the two facts the engine's instructions establish:
--
--   * `suc pos ≤ pos'` — the iteration consumed at least one byte. This is exactly what `progress`
--     checks against the position `mark` recorded: equal means stop, so continuing means greater.
--   * `pos' ≤ n` — a position stays inside the input, since every instruction that advances it
--     first checks `pos < input.len`.

data Run (n : ℕ) : ℕ → Set where
  stop : {pos : ℕ} → Run n pos
  step : {pos pos' : ℕ} → suc pos ≤ pos' → pos' ≤ n → Run n pos' → Run n pos

iterations : {n pos : ℕ} → Run n pos → ℕ
iterations stop           = zero
iterations (step _ _ rest) = suc (iterations rest)

------------------------------------------------------------------------------
-- The bound
--
-- `iterations r + pos ≤ n`: the iterations already taken, plus where they started, cannot exceed
-- the input. So a loop starting at 0 runs at most `n` times, and the engine's step budget is a
-- safety net rather than the thing that makes it stop.

bounded : {n pos : ℕ} → pos ≤ n → (r : Run n pos) → (iterations r + pos) ≤ n
bounded p stop = p
bounded {n} {pos} _ (step {pos' = pos'} adv inside rest) =
  -- The tail's bound is about `pos'`; `pos' ≥ suc pos` carries it back to `pos`.
  let tail : iterations rest + pos' ≤ n
      tail = bounded inside rest
      shift : (iterations rest + suc pos) ≤ (iterations rest + pos')
      shift = +-mono (iterations rest) adv
      -- `iterations rest + suc pos` is `suc (iterations rest + pos)`, which is the goal's shape.
      goal : (suc (iterations rest + pos)) ≤ n
      goal = ≤-trans (subst (λ x → x ≤ (iterations rest + pos')) (+-suc (iterations rest) pos) shift) tail
  in goal

-- A loop over the whole input runs at most `n` times.
bounded-from-zero : {n : ℕ} → (r : Run n zero) → (iterations r) ≤ n
bounded-from-zero {n} r = subst (λ x → x ≤ n) (+-zero (iterations r)) (bounded z≤n r)

------------------------------------------------------------------------------
-- Why the guard is load-bearing
--
-- The same chain without the strict advance — an iteration allowed to consume nothing — has values
-- of every length at a single position. `stall n pos k` is `k` iterations that never move, so no
-- bound like `bounded` can hold for it: the iteration count is free of both `n` and `pos`.
--
-- This is not hypothetical. `runner/src/regex.zig` shipped twice without this guard in one of its
-- two places, and the differential test against Python and Perl found both:
--
--   * no guard on a star: `(x*?)+` reached the step budget on 38 inputs Python answers.
--   * no guard on a *bounded* repeat: `(\s{0,2}|…){0,2}` ran an empty iteration and then a
--     non-empty one, capturing the wrong text, because the references stop at the empty iteration.
--
-- So `Stalling` is the shape of the bug and `Run` is the shape of the fix.

data Stalling (n : ℕ) : ℕ → Set where
  stop : {pos : ℕ} → Stalling n pos
  step : {pos pos' : ℕ} → pos ≤ pos' → pos' ≤ n → Stalling n pos' → Stalling n pos

stallIterations : {n pos : ℕ} → Stalling n pos → ℕ
stallIterations stop            = zero
stallIterations (step _ _ rest) = suc (stallIterations rest)

-- `k` iterations, none of which moves: a loop at one position, as long as you like.
stall : {n : ℕ} → (pos : ℕ) → pos ≤ n → (k : ℕ) → Stalling n pos
stall pos _     zero    = stop
stall pos p (suc k) = step ≤-refl p (stall pos p k)

stall-length : {n : ℕ} → (pos : ℕ) → (p : pos ≤ n) → (k : ℕ) → stallIterations (stall pos p k) ≡ k
stall-length pos p zero    = refl
stall-length pos p (suc k) = cong suc (stall-length pos p k)

-- So no function of `n` bounds a stalling loop: for any candidate bound `b`, there is a run longer
-- than it. Instantiated at `pos = zero`, where `Run` gives `iterations r ≤ n`.
unbounded : {n : ℕ} → (b : ℕ) → Σ (Stalling n zero) (λ s → stallIterations s ≡ suc b)
unbounded {n} b = ⟨ stall zero z≤n (suc b) , stall-length zero z≤n (suc b) ⟩
