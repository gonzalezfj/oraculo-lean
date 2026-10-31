/-!
El modelo de una gift card. Nunca corre en producción: su único trabajo es
decir qué debería responder el sistema real.
-/

namespace Oraculo

inductive Status where
  | available
  | sold
  | expired
  deriving DecidableEq, Repr

structure Card where
  status   : Status
  balance  : Nat
  /-- Redenciones aún no revertidas, la más reciente primero. -/
  redeemed : List Nat
  deriving DecidableEq, Repr

inductive Command where
  | sell (n : Nat)
  | redeem (n : Nat)
  | reverse
  | expire
  | balance
  deriving DecidableEq, Repr

inductive Response where
  | ok
  | funds (n : Nat)
  | insufficient
  | notSold
  | alreadySold
  | isExpired
  | nothingToReverse
  deriving DecidableEq, Repr

def initial : Card := { status := .available, balance := 0, redeemed := [] }

def step (cmd : Command) (card : Card) : Response × Card :=
  match cmd, card.status with
  | .balance, _ => (.funds card.balance, card)

  | .sell n, .available => (.ok, { card with status := .sold, balance := n })
  | .sell _, _          => (.alreadySold, card)

  | .redeem n, .sold =>
    if n > card.balance then
      (.insufficient, card)
    else
      (.ok, { card with balance := card.balance - n, redeemed := n :: card.redeemed })

  | .reverse, .sold =>
    match card.redeemed with
    | n :: rest => (.ok, { card with balance := card.balance + n, redeemed := rest })
    | []        => (.nothingToReverse, card)

  | .expire, .sold => (.ok, { card with status := .expired })

  | _, .available => (.notSold, card)
  | _, .expired   => (.isExpired, card)

/-- Lo que el modelo responde a una secuencia entera, empezando con una tarjeta nueva. -/
def responses (cmds : List Command) : List Response :=
  go initial cmds
where
  go (card : Card) : List Command → List Response
    | []        => []
    | c :: rest =>
      let (r, card') := step c card
      r :: go card' rest

end Oraculo
