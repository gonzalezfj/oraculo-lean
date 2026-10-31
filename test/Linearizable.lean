import Oraculo.Harness

/-!
Fase concurrente. Un escenario tiene tres partes:

1. `pre`: comandos secuenciales (arman el estado);
2. `burst`: comandos que se mandan **todos a la vez**, cada uno en su conexión;
3. `post`: comandos secuenciales (miran el estado que quedó).

El sistema es *linealizable* respecto del modelo si existe **algún orden** de los comandos
concurrentes tal que el modelo, corrido en ese orden, responda lo mismo que el sistema, tanto en
la ráfaga como en `post`.

Es un chequeo a medida y no un chequeo general de linealizabilidad: no medimos cuándo empezó y
terminó cada pedido, así que damos por superpuestos a todos los de la ráfaga. Eso solo debilita la
condición: no puede dar un falso fallo, pero puede dejar pasar una carrera. Por eso cada escenario
se repite varias veces: una carrera es cuestión de suerte, no de lógica.
-/

open Oraculo

structure Scenario where
  pre   : List Command
  burst : List Command
  post  : List Command

structure Observed where
  pre   : List String
  burst : List String
  post  : List String

def runScenario (base : String) (s : Scenario) : IO Observed := do
  let pre ← runSystem base s.pre                       -- /reset y después `pre`
  let burst ← runBurst base s.burst
  let post ← runSystem base s.post (reset := false)
  return ⟨pre, burst, post⟩

/-! ## El chequeo -/

/-- Todos los órdenes posibles de una lista. -/
def perms : List α → List (List α)
  | []      => [[]]
  | x :: xs => (perms xs).flatMap fun p =>
      (List.range (p.length + 1)).map fun i => p.take i ++ x :: p.drop i

/-- El modelo corre la ráfaga en `order`. Devuelve su respuesta a cada comando (indexada por
posición en la ráfaga, no por orden de ejecución) y la tarjeta que queda. -/
def simulate (card : Card) (burst : Array Command) (order : List Nat) : Array String × Card := Id.run do
  let mut out := Array.replicate burst.size ""
  let mut c := card
  for i in order do
    let (r, c') := step (burst.getD i .balance) c
    out := out.set! i r.show
    c := c'
  return (out, c)

def linearizable (s : Scenario) (o : Observed) : Bool :=
  let (preR, c1) := runFrom initial s.pre
  preR.map Response.show == o.pre &&
  (perms (List.range s.burst.length)).any fun order =>
    let (out, c2) := simulate c1 s.burst.toArray order
    out.toList == o.burst && (runFrom c2 s.post).1.map Response.show == o.post

/-- Corre el escenario hasta `reps` veces; devuelve lo observado la primera vez que no hay
ningún orden que lo explique. -/
def findFailure (base : String) (s : Scenario) (reps : Nat) : IO (Option Observed) := do
  for _ in List.range reps do
    let o ← runScenario base s
    if !linearizable s o then return some o
  return none

/-! ## Generador y shrinking -/

def genScenario (size : Nat) : IO Scenario := do
  let sell := Command.sell (← IO.rand 1 100)
  let start := if (← IO.rand 0 4) == 0 then [] else [sell]   -- a veces, ni vendida
  let pre := start ++ (← genSeq (← IO.rand 0 size))
  let burst ← genSeq (← IO.rand 2 4)
  let post := (← genSeq (← IO.rand 0 2)) ++ [.balance]
  return ⟨pre, burst, post⟩

def scenarioCandidates (s : Scenario) : List Scenario :=
  (candidates s.burst).map ({ s with burst := · }) ++
  (candidates s.pre).map ({ s with pre := · }) ++
  (candidates s.post).map ({ s with post := · })

partial def shrink (base : String) (s : Scenario) (o : Observed) (reps steps : Nat) :
    IO (Scenario × Observed × Nat) := do
  for cand in scenarioCandidates s do
    match ← findFailure base cand reps with
    | some o' => return (← shrink base cand o' reps (steps + 1))
    | none    => pure ()
  return (s, o, steps)

/-! ## Reporte -/

def report (s : Scenario) (o : Observed) : IO Unit := do
  IO.println s!"prefix:     {showList s.pre}"
  IO.println s!"concurrent: {showList s.burst}"
  IO.println s!"then:       {showList s.post}"
  IO.println ""
  IO.println (pad 12 "phase" ++ pad 14 "command" ++ "system")
  for (c, r) in s.pre.zip o.pre do
    IO.println (pad 12 "prefix" ++ pad 14 c.show ++ r)
  for (c, r) in s.burst.zip o.burst do
    IO.println (pad 12 "concurrent" ++ pad 14 c.show ++ r)
  for (c, r) in s.post.zip o.post do
    IO.println (pad 12 "then" ++ pad 14 c.show ++ r)
  IO.println ""
  IO.println "Ningún orden de los comandos concurrentes da eso. El modelo acepta solo:"
  let (_, c1) := runFrom initial s.pre
  let lines := (perms (List.range s.burst.length)).map fun order =>
    let (out, c2) := simulate c1 s.burst.toArray order
    let burst := order.map fun i => (s.burst.getD i .balance).show ++ " → " ++ out.getD i ""
    let post := (s.post.zip (runFrom c2 s.post).1).map fun (p : Command × Response) =>
      p.1.show ++ " → " ++ p.2.show
    let after := if post.isEmpty then "" else s!"; después {", ".intercalate post}"
    s!"  {", ".intercalate burst}{after}"
  for l in lines.eraseDups do
    IO.println l

def main : IO UInt32 := do
  let base := (← IO.getEnv "SUT").getD "http://localhost:8080"
  let tests := ((← IO.getEnv "TESTS").bind String.toNat?).getD 200
  let reps := ((← IO.getEnv "REPS").bind String.toNat?).getD 3
  let shrinkReps := ((← IO.getEnv "SHRINK_REPS").bind String.toNat?).getD 15
  let seed ← match (← IO.getEnv "SEED").bind String.toNat? with
    | some s => pure s
    | none   => IO.monoMsNow
  IO.setRandSeed seed
  for i in List.range tests do
    let s ← genScenario (2 + i / 20)
    match ← findFailure base s reps with
    | none => pure ()
    | some o =>
      let (small, o', steps) ← shrink base s o shrinkReps 0
      IO.println s!"*** Failed! No linearization (after {i + 1} scenarios and {steps} shrinks, seed {seed}):"
      report small o'
      return 1
  IO.println s!"+++ OK, passed {tests} scenarios ({tests * reps} runs)."
  return 0
