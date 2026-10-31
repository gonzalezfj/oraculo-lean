import Oraculo.Model

/-!
Lo que comparten los dos tests (`lockstep` y `linearizable`): cómo se muestran los
comandos y respuestas, el generador, el adaptador HTTP y los shrinkers.
Sin librerías de testing: se lee de corrido.
-/

namespace Oraculo

/-! ## Cómo se ve un comando y una respuesta -/

def Command.show : Command → String
  | .sell n   => s!"Sell {n}"
  | .redeem n => s!"Redeem {n}"
  | .reverse  => "Reverse"
  | .expire   => "Expire"
  | .balance  => "Balance"

def Response.show : Response → String
  | .ok               => "Ok"
  | .funds n          => s!"Funds {n}"
  | .insufficient     => "Insufficient"
  | .notSold          => "NotSold"
  | .alreadySold      => "AlreadySold"
  | .isExpired        => "IsExpired"
  | .nothingToReverse => "NothingToReverse"

def showList (cmds : List Command) : String :=
  "[" ++ ",".intercalate (cmds.map Command.show) ++ "]"

def pad (n : Nat) (s : String) : String := s.pushn ' ' (n - s.length)

/-! ## El modelo, corrido desde un estado cualquiera -/

/-- Corre comandos desde `card`; devuelve las respuestas y la tarjeta final. -/
def runFrom (card : Card) : List Command → List Response × Card
  | []        => ([], card)
  | c :: rest =>
    let (r, card') := step c card
    let (rs, final) := runFrom card' rest
    (r :: rs, final)

def expectedFor (cmds : List Command) : List String :=
  (responses cmds).map Response.show

/-! ## Generador -/

def genCommand : IO Command := do
  match ← IO.rand 0 4 with
  | 0 => return .sell (← IO.rand 1 100)
  | 1 => return .redeem (← IO.rand 1 100)
  | 2 => return .reverse
  | 3 => return .expire
  | _ => return .balance

def genSeq (len : Nat) : IO (List Command) :=
  (List.range len).mapM fun _ => genCommand

/-! ## Adaptador: un comando, un pedido HTTP -/

def path : Command → String
  | .sell n   => s!"/sell?amount={n}"
  | .redeem n => s!"/redeem?amount={n}"
  | .reverse  => "/reverse"
  | .expire   => "/expire"
  | .balance  => "/balance"

def sinRespuesta : String := "<sin respuesta>"

def curl (args : Array String) : IO IO.Process.Output :=
  IO.Process.output { cmd := "curl", args := #["-s", "--globoff", "--max-time", "10"] ++ args }

/-- Los comandos, en orden y con un solo `curl` (que hace los pedidos de a uno y reusa la
conexión). Si `reset`, antes manda `/reset` y exige que conteste `Ok`. -/
def runSystem (base : String) (cmds : List Command) (reset : Bool := true) : IO (List String) := do
  let urls := (if reset then [base ++ "/reset"] else []) ++ cmds.map (base ++ path ·)
  if urls.isEmpty then return []
  let out ← curl (#["-w", "\\n"] ++ urls.toArray)
  if out.exitCode != 0 then
    throw <| IO.userError s!"curl falló (código {out.exitCode}); ¿está andando el sistema en {base}?"
  let lines := (out.stdout.splitOn "\n").dropLast  -- el último elemento es el vacío tras el último \n
  let lines ← match reset, lines with
    | false, ls => pure ls
    | true, "Ok" :: rest => pure rest
    | true, other => throw <| IO.userError s!"/reset no respondió Ok: {other.take 1}"
  return (List.range cmds.length).map fun i => lines.getD i sinRespuesta

/-- Todos los comandos **a la vez** (`curl --parallel-immediate`), una conexión por pedido.
Devuelve el cuerpo de cada respuesta, en el orden de los comandos. -/
def runBurst (base : String) (cmds : List Command) : IO (List String) := do
  if cmds.isEmpty then return []
  let dir ← IO.FS.createTempDir
  let files := (List.range cmds.length).map fun i => (dir / s!"{i}").toString
  let mut args : Array String :=
    #["--parallel", "--parallel-immediate", "--parallel-max", toString cmds.length]
  for (c, f) in cmds.zip files do
    args := args ++ #["-o", f, base ++ path c]
  let out ← curl args
  let mut bodies := []
  for f in files do
    bodies := bodies ++ [(← (IO.FS.readFile f).toBaseIO).toOption.getD sinRespuesta]
  IO.FS.removeDirAll dir
  if out.exitCode != 0 then
    throw <| IO.userError s!"curl falló (código {out.exitCode}); ¿está andando el sistema en {base}?"
  return bodies

/-! ## Shrinking: de algo que falla a algo mínimo que falla -/

def shrinkNat (n : Nat) : List Nat :=
  ([1, n / 2, n - 1].filter fun m => 0 < m && m < n).eraseDups

def shrinkCommand : Command → List Command
  | .sell n   => (shrinkNat n).map .sell
  | .redeem n => (shrinkNat n).map .redeem
  | _         => []

/-- Secuencias más chicas: primero sacar tramos grandes, después de a uno,
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

end Oraculo
