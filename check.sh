#!/usr/bin/env bash
# Repite la historia sobre una copia de la app:
#   1. el modelo y la app discrepan sobre revertir en una tarjeta vencida;
#   2. después de decidir eso, discrepan sobre revertir dos veces;
#   3. después de arreglarlo, 1000 secuencias aleatorias coinciden... una a la vez;
#   4. con pedidos simultáneos, el sistema deja de ser linealizable;
#   5. después de hacer atómico cada pedido, los escenarios concurrentes pasan.
set -euo pipefail
cd "$(dirname "$0")"

port=${PORT:-8080}
work=$(mktemp -d)
trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT

cp -r app "$work/app"

# Se reinicia después de cada parche, para que ningún caché sirva el código viejo.
# Con varios workers el servidor de PHP atiende pedidos en paralelo (Linux/macOS).
start() {
  PHP_CLI_SERVER_WORKERS=${WORKERS:-4} php -S "localhost:$port" "$work/app/index.php" >/dev/null 2>&1 &
  server=$!
  until curl -s "localhost:$port/reset" >/dev/null; do :; done
}
stop() { kill $server; wait $server 2>/dev/null || true; }
start

lake build lockstep linearizable >/dev/null

run() { SUT="http://localhost:$port" lake exe "$1" 2>&1 || true; }

expect() {
  local exe=$1 out
  out=$(run "$exe")
  if grep -qF -- "$2" <<<"$out"; then
    echo "ok: $2"
  else
    echo "FALLÓ: se esperaba '$2', pero salió:"
    echo "$out"
    exit 1
  fi
}

expect lockstep '[Sell 1,Expire,Reverse]'
stop; patch -s -p1 -d "$work" < fixes/1-expired-cards.diff; start
expect lockstep '[Sell 1,Redeem 1,Reverse,Reverse]'
stop; patch -s -p1 -d "$work" < fixes/2-double-reverse.diff; start
expect lockstep '+++ OK, passed 1000 tests.'

# Secuencialmente todo coincide; con pedidos simultáneos, no.
expect linearizable '*** Failed! No linearization'
stop; patch -s -p1 -d "$work" < fixes/3-atomic-requests.diff; start
expect linearizable '+++ OK, passed'
