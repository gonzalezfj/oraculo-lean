import Oraculo.Model

/-!
Propiedades demostradas sobre el modelo. Es la parte que un oráculo en
Haskell no tiene: acá el oráculo mismo está verificado, no solo escrito.
-/

namespace Oraculo

/-- Plata total que la tarjeta "conoce": saldo más lo redimido y no revertido. -/
def total (c : Card) : Nat := c.balance + c.redeemed.sum

/-- Conservación: ningún comando, salvo `sell`, crea ni destruye plata.
Un `reverse` que devolviera dos veces la misma redención rompería esto. -/
theorem total_conserved (cmd : Command) (card : Card)
    (h : ∀ n, cmd ≠ .sell n) :
    total (step cmd card).2 = total card := by
  cases cmd with
  | sell n => exact absurd rfl (h n)
  | redeem n =>
    rcases card with ⟨s, b, r⟩
    cases s <;> simp only [step, total] <;> try rfl
    split
    · rfl
    · rename_i hn
      simp only [List.sum_cons]
      omega
  | reverse =>
    rcases card with ⟨s, b, r⟩
    cases s <;> simp only [step, total] <;> try rfl
    cases r with
    | nil => rfl
    | cons n rest => simp only [List.sum_cons]; omega
  | expire =>
    rcases card with ⟨s, b, r⟩
    cases s <;> simp only [step, total] <;> rfl
  | balance =>
    rcases card with ⟨s, b, r⟩
    cases s <;> simp only [step, total] <;> rfl

/-- Una tarjeta vencida no cambia nunca, con ningún comando. -/
theorem expired_absorbing (cmd : Command) (card : Card)
    (h : card.status = .expired) :
    (step cmd card).2 = card := by
  rcases card with ⟨s, b, r⟩
  simp only at h
  subst h
  cases cmd <;> rfl

/-- Redimir y revertir enseguida devuelve la tarjeta exactamente al estado anterior. -/
theorem redeem_then_reverse (n : Nat) (card c' : Card)
    (h : step (.redeem n) card = (.ok, c')) :
    step .reverse c' = (.ok, card) := by
  rcases card with ⟨s, b, r⟩
  cases s <;> simp only [step] at h
  · cases h
  · split at h
    · cases h
    · rename_i hn
      simp only [Prod.mk.injEq, true_and] at h
      subst h
      simp only [step]
      have e : b - n + n = b := by omega
      rw [e]
  · cases h

/-- Revertir dos veces seguidas lo mismo no puede dar `ok` las dos veces si
solo hubo una redención: el bug de la segunda corrida. -/
example : responses [.sell 1, .redeem 1, .reverse, .reverse]
    = [.ok, .ok, .ok, .nothingToReverse] := by decide

/-- La decisión que el modelo tuvo que tomar: revertir en una tarjeta vencida. -/
example : responses [.sell 1, .expire, .reverse]
    = [.ok, .ok, .isExpired] := by decide

end Oraculo
