# Un oráculo que nunca se deploya, en Lean

Versión en Lean 4 de [`un-oraculo-que-nunca-se-deploya`](https://github.com/Ragnagrok/un-oraculo-que-nunca-se-deploya)
(Federico Sawady): un modelo chico de una gift card, usado **solo** como oráculo de tests
para un sistema escrito en PHP. El modelo nunca corre en producción.

La idea en una línea: generar una secuencia aleatoria de comandos, mandársela al modelo y al
sistema real por HTTP, y comparar las respuestas una por una (*lockstep testing*).

## Qué hay acá

| Archivo | Qué es |
|---|---|
| `Oraculo/Model.lean` | El modelo: una tarjeta es `available`, `sold` o `expired`, y `step` dice qué responde cada comando. |
| `Oraculo/Proofs.lean` | **Lo que el original no tiene:** teoremas demostrados sobre el modelo. |
| `test/Lockstep.lean` | La comparación: generador, adaptador HTTP (vía `curl`), shrinker y la propiedad "el sistema responde lo que responde el modelo". |
| `app/`, `fixes/` | El "sistema real" (PHP + SQLite, con **dos bugs a propósito**) y los dos arreglos. Son del repo original, ver abajo. |
| `check.sh` | Repite toda la historia sobre una copia de la app. |

## Qué cambia respecto del original

**Los teoremas.** Antes de usar el modelo como oráculo, se demuestra que se comporta como uno espera:

- `total_conserved`: ningún comando (salvo `sell`) crea ni destruye plata. Un `reverse` que devuelve dos veces la misma redención rompería exactamente esto.
- `redeem_then_reverse`: redimir y revertir enseguida deja la tarjeta idéntica.
- `expired_absorbing`: una tarjeta vencida no cambia nunca.

Dependen solo de `propext` y `Quot.sound`; no hay `sorry`. Así el oráculo deja de ser "lo que alguien escribió" y pasa a ser una especificación verificada. Eso no reemplaza el lockstep: los teoremas hablan del modelo, y el lockstep es el que lo compara con el sistema.

**Sin librerías de testing.** El original usa QuickCheck. Acá el generador (`IO.rand`), el shrinker y el bucle son del proyecto, unas 150 líneas, porque la propiedad corre en `IO` (le pega a un servidor) y las librerías de property testing de Lean están pensadas para propiedades puras. El shrinker es más simple que el de QuickCheck: saca tramos de la secuencia y achica montos, pero no es tan fino.

**Un `curl` por secuencia.** El adaptador manda `/reset` y todos los comandos en un solo proceso `curl`, que hace los pedidos de a uno y en orden. Sigue siendo un pedido HTTP por comando; solo evita lanzar un proceso por cada uno.

## La historia que repite `check.sh`

**Primera corrida.** Encuentra un desacuerdo y lo reduce a tres comandos:

```
[Sell 1,Expire,Reverse]
command       model               system
Sell 1        Ok                  Ok
Expire        Ok                  Ok
Reverse       IsExpired           NothingToReverse   <--
```

Esto no es un bug propiamente dicho: nadie había decidido qué significa revertir en una tarjeta
vencida. El modelo tuvo que decir algo (dice: una tarjeta vencida no se toca); el PHP decía otra
cosa sin que nadie lo notara. `fixes/1-expired-cards.diff` hace que la app siga al modelo.

**Segunda corrida.** Ahora sí es un bug real, reducido a cuatro comandos:

```
[Sell 1,Redeem 1,Reverse,Reverse]
command       model               system
Sell 1        Ok                  Ok
Redeem 1      Ok                  Ok
Reverse       Ok                  Ok
Reverse       NothingToReverse    Ok   <--
```

La app revierte la última redención sin chequear si ya estaba revertida: la misma plata vuelve
dos veces. `fixes/2-double-reverse.diff` lo arregla.

**Tercera corrida.** `+++ OK, passed 1000 tests.` Unos 45 segundos en total, incluyendo las tres corridas.

Las secuencias son aleatorias. La semilla se imprime al fallar, y con `SEED=42` se repite la misma corrida.

## Cómo correrlo

Con Lean 4.35 (`elan` lo toma de `lean-toolchain`), `curl` y PHP 8 con `pdo_sqlite`:

```sh
./check.sh                       # toda la historia, sobre una copia temporal de la app

php -S localhost:8080 app/index.php   # o a mano: levantar la app...
lake exe lockstep                     # ...y correr el lockstep contra ella
```

Variables: `SUT` (URL base, por defecto `http://localhost:8080`), `TESTS` (cantidad, por defecto 1000), `SEED`.

Para chequear los teoremas: `lake build Oraculo`.

## Lo que esta prueba de concepto no cubre

Es un juguete, a propósito.

- **Una tarjeta, un cliente, un pedido a la vez.** El lockstep secuencial no ve condiciones de carrera: dos sucursales redimiendo el mismo código a la vez necesitan una fase paralela con chequeo de linealizabilidad.
- **Los teoremas son sobre el modelo, no sobre el PHP.** Que el modelo sea correcto no dice que el sistema lo sea; para eso está el lockstep.
- **Los bugs fueron plantados.** Son de los que aparecen en sistemas reales, pero acá se sabe dónde están.

## Créditos y licencia

La idea, el modelo original en Haskell, la app PHP (`app/`) y los arreglos (`fixes/`) son de
[Federico Sawady](https://github.com/Ragnagrok) ([repo original](https://github.com/Ragnagrok/un-oraculo-que-nunca-se-deploya),
artículo [*Un oráculo que nunca se deploya*](https://blog.ragnagrok.com/es/2026-10-30-un-oraculo-que-nunca-se-deploya)).
Esta versión en Lean es una adaptación y conserva la licencia MIT del original (ver `LICENSE`).
