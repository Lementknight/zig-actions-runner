{-# OPTIONS --safe #-}

-- A small prelude, so these proofs check with nothing but `agda`: no standard
-- library to install, pin, or keep in step with a compiler release. Everything
-- here is the usual definition, kept to what the model actually uses.

module Prelude where

------------------------------------------------------------------------------
-- Equality

infix 4 _≡_

data _≡_ {A : Set} (x : A) : A → Set where
  refl : x ≡ x

{-# BUILTIN EQUALITY _≡_ #-}

sym : {A : Set} {x y : A} → x ≡ y → y ≡ x
sym refl = refl

trans : {A : Set} {x y z : A} → x ≡ y → y ≡ z → x ≡ z
trans refl refl = refl

cong : {A B : Set} (f : A → B) {x y : A} → x ≡ y → f x ≡ f y
cong f refl = refl

cong₂ : {A B C : Set} (f : A → B → C) {x y : A} {u v : B} → x ≡ y → u ≡ v → f x u ≡ f y v
cong₂ f refl refl = refl

subst : {A : Set} (P : A → Set) {x y : A} → x ≡ y → P x → P y
subst P refl p = p

------------------------------------------------------------------------------
-- Logic

data ⊥ : Set where

⊥-elim : {A : Set} → ⊥ → A
⊥-elim ()

infix 3 ¬_

¬_ : Set → Set
¬ A = A → ⊥

record ⊤ : Set where
  constructor tt

------------------------------------------------------------------------------
-- Booleans

data Bool : Set where
  true  : Bool
  false : Bool

{-# BUILTIN BOOL  Bool  #-}
{-# BUILTIN TRUE  true  #-}
{-# BUILTIN FALSE false #-}

not : Bool → Bool
not true  = false
not false = true

infixr 5 _∨_
_∨_ : Bool → Bool → Bool
true  ∨ _ = true
false ∨ b = b

if_then_else_ : {A : Set} → Bool → A → A → A
if true  then t else f = t
if false then t else f = f

------------------------------------------------------------------------------
-- Naturals

data ℕ : Set where
  zero : ℕ
  suc  : ℕ → ℕ

{-# BUILTIN NATURAL ℕ #-}

suc-injective : {m n : ℕ} → suc m ≡ suc n → m ≡ n
suc-injective refl = refl

data _≤_ : ℕ → ℕ → Set where
  z≤n : {n : ℕ} → zero ≤ n
  s≤s : {m n : ℕ} → m ≤ n → suc m ≤ suc n

≤-refl : {n : ℕ} → n ≤ n
≤-refl {zero}  = z≤n
≤-refl {suc n} = s≤s ≤-refl

≤-suc : {m n : ℕ} → m ≤ n → m ≤ suc n
≤-suc z≤n     = z≤n
≤-suc (s≤s p) = s≤s (≤-suc p)

-- A bound one step weaker.
≤-loosen : {m n : ℕ} → suc m ≤ n → m ≤ n
≤-loosen (s≤s p) = ≤-suc p

suc≰ : (n : ℕ) → ¬ (suc n ≤ n)
suc≰ zero    ()
suc≰ (suc n) (s≤s p) = suc≰ n p

------------------------------------------------------------------------------
-- Decidability

data Dec (A : Set) : Set where
  yes : A → Dec A
  no  : ¬ A → Dec A

DecEq : Set → Set
DecEq A = (x y : A) → Dec (x ≡ y)

_≟ℕ_ : DecEq ℕ
zero  ≟ℕ zero  = yes refl
zero  ≟ℕ suc n = no (λ ())
suc m ≟ℕ zero  = no (λ ())
suc m ≟ℕ suc n with m ≟ℕ n
... | yes refl = yes refl
... | no  ¬p   = no (λ eq → ¬p (suc-injective eq))

------------------------------------------------------------------------------
-- Pairs and existentials

infixr 4 _,_

record _×_ (A B : Set) : Set where
  constructor _,_
  field
    fst : A
    snd : B

open _×_ public

record Σ (A : Set) (B : A → Set) : Set where
  constructor ⟨_,_⟩
  field
    wit : A
    prf : B wit

open Σ public

data _⊎_ (A B : Set) : Set where
  inl : A → A ⊎ B
  inr : B → A ⊎ B

------------------------------------------------------------------------------
-- Maybe

data Maybe (A : Set) : Set where
  nothing : Maybe A
  just    : A → Maybe A

just-injective : {A : Set} {x y : A} → just x ≡ just y → x ≡ y
just-injective refl = refl

------------------------------------------------------------------------------
-- Lists

infixr 5 _∷_

data List (A : Set) : Set where
  []  : List A
  _∷_ : A → List A → List A

data _∈_ {A : Set} (x : A) : List A → Set where
  here  : {xs : List A} → x ∈ (x ∷ xs)
  there : {y : A} {xs : List A} → x ∈ xs → x ∈ (y ∷ xs)

-- Constructors named apart from the list's: overloading them compiles on some
-- Agda versions and not others, which is not a thing to find out in CI.
data All {A : Set} (P : A → Set) : List A → Set where
  all[] : All P []
  all∷  : {x : A} {xs : List A} → P x → All P xs → All P (x ∷ xs)

infixr 5 _++_
_++_ : {A : Set} → List A → List A → List A
[]       ++ ys = ys
(x ∷ xs) ++ ys = x ∷ (xs ++ ys)

any : {A : Set} → (A → Bool) → List A → Bool
any p []       = false
any p (x ∷ xs) = p x ∨ any p xs

filter : {A : Set} → (A → Bool) → List A → List A
filter p []       = []
filter p (x ∷ xs) = if p x then x ∷ filter p xs else filter p xs

-- Filtering twice by the same predicate is filtering once: what is kept is already kept.
filter-idempotent : {A : Set} (p : A → Bool) (xs : List A) → filter p (filter p xs) ≡ filter p xs
filter-idempotent p []       = refl
filter-idempotent p (x ∷ xs) with p x in eq
... | false = filter-idempotent p xs
... | true  rewrite eq = cong (λ ys → x ∷ ys) (filter-idempotent p xs)

∷-injective₁ : {A : Set} {x y : A} {xs ys : List A} → (x ∷ xs) ≡ (y ∷ ys) → x ≡ y
∷-injective₁ refl = refl

∷-injective₂ : {A : Set} {x y : A} {xs ys : List A} → (x ∷ xs) ≡ (y ∷ ys) → xs ≡ ys
∷-injective₂ refl = refl

------------------------------------------------------------------------------
-- Decidable equality, lifted

×-dec : {A B : Set} → DecEq A → DecEq B → DecEq (A × B)
×-dec da db (a , b) (a' , b') with da a a' | db b b'
... | yes refl | yes refl = yes refl
... | no  ¬p   | _        = no (λ eq → ¬p (cong fst eq))
... | _        | no ¬q    = no (λ eq → ¬q (cong snd eq))

List-dec : {A : Set} → DecEq A → DecEq (List A)
List-dec d []       []       = yes refl
List-dec d []       (y ∷ ys) = no (λ ())
List-dec d (x ∷ xs) []       = no (λ ())
List-dec d (x ∷ xs) (y ∷ ys) with d x y | List-dec d xs ys
... | yes refl | yes refl = yes refl
... | no  ¬p   | _        = no (λ eq → ¬p (∷-injective₁ eq))
... | _        | no ¬q    = no (λ eq → ¬q (∷-injective₂ eq))
