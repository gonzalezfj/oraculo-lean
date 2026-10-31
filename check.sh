#!/usr/bin/env bash
# Repite la historia sobre una copia de la app:
#   1. el modelo y la app discrepan sobre revertir en una tarjeta vencida;
#   2. después de decidir eso, discrepan sobre revertir dos veces;
#   3. después de arreglarlo, 1000 secuencias aleatorias coinciden.
set -euo pipefail
cd "$(dirname "$0")"

port=${PORT:-8080}
work=$(mktemp -d)
trap 'kill $server 2>/dev/null || true; rm -rf "$work"' EXIT

cp -r app "$work/app"

# Se reinicia después de cada parche, para que ningún caché sirva el código viejo.
start() {
  php -S "localhost:$port" "$work/app/index.php" >/dev/null 2>&1 &
  server=$!
  until curl -s "localhost:$port/reset" >/dev/null; do :; done
}
stop() { kill $server; wait $server 2>/dev/null || true; }
start

lake build lockstep >/dev/null

run() { SUT="http://localhost:$port" lake exe lockstep 2>&1 || true; }

expect() {
  local out
  out=$(run)
  if grep -qF -- "$1" <<<"$out"; then
    echo "ok: $1"
  else
    echo "FALLÓ: se esperaba '$1', pero salió:"
    echo "$out"
    exit 1
  fi
}

expect '[Sell 1,Expire,Reverse]'
stop; patch -s -p1 -d "$work" < fixes/1-expired-cards.diff; start
expect '[Sell 1,Redeem 1,Reverse,Reverse]'
stop; patch -s -p1 -d "$work" < fixes/2-double-reverse.diff; start
expect '+++ OK, passed 1000 tests.'
