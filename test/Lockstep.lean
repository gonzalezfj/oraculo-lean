import Oraculo.Harness

/-!
Lockstep: la misma secuencia aleatoria va al modelo y al sistema real por HTTP,
y las respuestas tienen que coincidir una por una.
-/

open Oraculo

def disagrees (base : String) (cmds : List Command) : IO Bool := do
  return (← runSystem base cmds) != expectedFor cmds

partial def shrink (base : String) (cmds : List Command) (steps : Nat) :
    IO (List Command × Nat) := do
  for cand in candidates cmds do
    if ← disagrees base cand then
      return (← shrink base cand (steps + 1))
  return (cmds, steps)

def report (base : String) (cmds : List Command) : IO Unit := do
  let expected := expectedFor cmds
  let actual ← runSystem base cmds
  IO.println (pad 14 "command" ++ pad 20 "model" ++ "system")
  for ((c, e), a) in (cmds.zip expected).zip actual do
    IO.println (pad 14 c.show ++ pad 20 e ++ a ++ (if e == a then "" else "   <--"))

/-- La propiedad: "el sistema responde lo que responde el modelo". -/
def main : IO UInt32 := do
  let base := (← IO.getEnv "SUT").getD "http://localhost:8080"
  let tests := ((← IO.getEnv "TESTS").bind String.toNat?).getD 1000
  let seed ← match (← IO.getEnv "SEED").bind String.toNat? with
    | some s => pure s
    | none   => IO.monoMsNow
  IO.setRandSeed seed
  for i in List.range tests do
    -- las secuencias crecen con el número de test, como el `size` de QuickCheck
    let cmds ← genSeq (← IO.rand 0 (2 + i / 20))
    if ← disagrees base cmds then
      let (small, steps) ← shrink base cmds 0
      IO.println s!"*** Failed! Falsified (after {i + 1} tests and {steps} shrinks, seed {seed}):"
      IO.println (showList small)
      report base small
      return 1
  IO.println s!"+++ OK, passed {tests} tests."
  return 0
