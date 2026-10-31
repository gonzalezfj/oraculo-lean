import Oraculo.Model

/-!
Lockstep: la misma secuencia aleatoria va al modelo y al sistema real por HTTP,
y las respuestas tienen que coincidir una por una.

Sin librerías: generador, adaptador y shrinker a mano, para que se lea en una pantalla.
-/

open Oraculo

/-! ## Cómo se ve un comando y una respuesta -/

def Oraculo.Command.show : Command → String
  | .sell n   => s!"Sell {n}"
  | .redeem n => s!"Redeem {n}"
  | .reverse  => "Reverse"
  | .expire   => "Expire"
  | .balance  => "Balance"

def Oraculo.Response.show : Response → String
  | .ok               => "Ok"
  | .funds n          => s!"Funds {n}"
  | .insufficient     => "Insufficient"
  | .notSold          => "NotSold"
  | .alreadySold      => "AlreadySold"
  | .isExpired        => "IsExpired"
  | .nothingToReverse => "NothingToReverse"

def showList (cmds : List Command) : String :=
  "[" ++ ",".intercalate (cmds.map Command.show) ++ "]"

/-! ## Generador -/

def genCommand : IO Command := do
  match ← IO.rand 0 4 with
  | 0 => return .sell (← IO.rand 1 100)
  | 1 => return .redeem (← IO.rand 1 100)
  | 2 => return .reverse
  | 3 => return .expire
  | _ => return .balance

/-- Las secuencias crecen con el número de test, como el `size` de QuickCheck. -/
def genSeq (size : Nat) : IO (List Command) := do
  let len ← IO.rand 0 size
  (List.range len).mapM fun _ => genCommand

/-! ## Adaptador: un comando, un pedido HTTP -/

def path : Command → String
  | .sell n   => s!"/sell?amount={n}"
  | .redeem n => s!"/redeem?amount={n}"
  | .reverse  => "/reverse"
  | .expire   => "/expire"
  | .balance  => "/balance"

/-- Manda `/reset` y después los comandos, en orden, con un solo `curl`
(que ejecuta los pedidos de a uno y reusa la conexión). Devuelve el cuerpo de
cada respuesta de los comandos, sin la del reset. -/
def runSystem (base : String) (cmds : List Command) : IO (List String) := do
  let urls := (base ++ "/reset") :: cmds.map (base ++ path ·)
  let out ← IO.Process.output
    { cmd := "curl"
      args := #["-s", "--globoff", "--max-time", "10", "-w", "\\n"] ++ urls.toArray }
  if out.exitCode != 0 then
    throw <| IO.userError s!"curl falló (código {out.exitCode}); ¿está andando el sistema en {base}?"
  let lines := (out.stdout.splitOn "\n").dropLast  -- el último elemento es el vacío tras el último \n
  match lines with
  | "Ok" :: rest => return rest
  | other => throw <| IO.userError s!"/reset no respondió Ok: {other.take 1}"

/-- Lo que respondió el sistema, con relleno si le faltaron respuestas. -/
def actualFor (base : String) (cmds : List Command) : IO (List String) := do
  let got ← runSystem base cmds
  return (List.range cmds.length).map fun i => got.getD i "<sin respuesta>"

def expectedFor (cmds : List Command) : List String :=
  (responses cmds).map Response.show

def disagrees (base : String) (cmds : List Command) : IO Bool := do
  return (← actualFor base cmds) != expectedFor cmds

/-! ## Shrinking: de una secuencia que falla a una mínima que falla -/

def shrinkNat (n : Nat) : List Nat :=
  ([1, n / 2, n - 1].filter fun m => 0 < m && m < n).eraseDups

def shrinkCommand : Command → List Command
  | .sell n   => (shrinkNat n).map .sell
  | .redeem n => (shrinkNat n).map .redeem
  | _         => []

/-- Candidatas más chicas: primero sacar tramos grandes, después tramos de a uno,
después achicar los montos. -/
def candidates (cmds : List Command) : List (List Command) := Id.run do
  let len := cmds.length
  let mut out : List (List Command) := []
  let mut k := len
  while k ≥ 1 do
    for s in List.range len do
      if s + k ≤ len then
        out := out ++ [cmds.take s ++ cmds.drop (s + k)]
    k := k / 2
  for i in List.range len do
    for c' in shrinkCommand (cmds.getD i .balance) do
      out := out ++ [cmds.set i c']
  return out

partial def shrink (base : String) (cmds : List Command) (steps : Nat) :
    IO (List Command × Nat) := do
  for cand in candidates cmds do
    if ← disagrees base cand then
      return (← shrink base cand (steps + 1))
  return (cmds, steps)

/-! ## Reporte -/

def pad (n : Nat) (s : String) : String := s.pushn ' ' (n - s.length)

def report (base : String) (cmds : List Command) : IO Unit := do
  let expected := expectedFor cmds
  let actual ← actualFor base cmds
  IO.println (pad 14 "command" ++ pad 20 "model" ++ "system")
  for ((c, e), a) in (cmds.zip expected).zip actual do
    IO.println (pad 14 c.show ++ pad 20 e ++ a ++ (if e == a then "" else "   <--"))

/-! ## La propiedad: "el sistema responde lo que responde el modelo" -/

def main : IO UInt32 := do
  let base := (← IO.getEnv "SUT").getD "http://localhost:8080"
  let tests := ((← IO.getEnv "TESTS").bind String.toNat?).getD 1000
  let seed ← match (← IO.getEnv "SEED").bind String.toNat? with
    | some s => pure s
    | none   => IO.monoMsNow
  IO.setRandSeed seed
  for i in List.range tests do
    let cmds ← genSeq (2 + i / 20)
    if ← disagrees base cmds then
      let (small, steps) ← shrink base cmds 0
      IO.println s!"*** Failed! Falsified (after {i + 1} tests and {steps} shrinks, seed {seed}):"
      IO.println (showList small)
      report base small
      return 1
  IO.println s!"+++ OK, passed {tests} tests."
  return 0
