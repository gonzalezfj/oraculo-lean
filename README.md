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
| `Oraculo/Harness.lean` | Lo que comparten los dos tests: generador, adaptador HTTP (vía `curl`) y shrinkers. |
| `test/Lockstep.lean` | La comparación secuencial: la propiedad "el sistema responde lo que responde el modelo". |
| `test/Linearizable.lean` | **Nuevo:** la fase concurrente. Manda comandos a la vez y chequea que algún orden los explique. |
| `app/`, `fixes/` | El "sistema real" (PHP + SQLite, con **dos bugs a propósito**) y los arreglos 1 y 2, del repo original. El `3-atomic-requests.diff` es de esta versión. |
| `check.sh` | Repite toda la historia sobre una copia de la app. |

## Qué cambia respecto del original

**Los teoremas.** Antes de usar el modelo como oráculo, se demuestra que se comporta como uno espera:

- `total_conserved`: ningún comando (salvo `sell`) crea ni destruye plata. Un `reverse` que devuelve dos veces la misma redención rompería exactamente esto.
- `redeem_then_reverse`: redimir y revertir enseguida deja la tarjeta idéntica.
- `expired_absorbing`: una tarjeta vencida no cambia nunca.

Dependen solo de `propext` y `Quot.sound`; no hay `sorry`. Así el oráculo deja de ser "lo que alguien escribió" y pasa a ser una especificación verificada. Eso no reemplaza el lockstep: los teoremas hablan del modelo, y el lockstep es el que lo compara con el sistema.

**Sin librerías de testing.** El original usa QuickCheck. Acá el generador (`IO.rand`), el shrinker y el bucle son del proyecto, porque la propiedad corre en `IO` (le pega a un servidor) y las librerías de property testing de Lean están pensadas para propiedades puras. El shrinker es más simple que el de QuickCheck: saca tramos de la secuencia y achica montos, pero no es tan fino.

**Un `curl` por secuencia.** El adaptador manda `/reset` y todos los comandos en un solo proceso `curl`, que hace los pedidos de a uno y en orden. Sigue siendo un pedido HTTP por comando; solo evita lanzar un proceso por cada uno.

**Una fase concurrente.** Ver más abajo.

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

**Tercera corrida.** `+++ OK, passed 1000 tests.`

Las secuencias son aleatorias. La semilla se imprime al fallar, y con `SEED=42` se repite la misma corrida.

## La fase concurrente

Hasta acá todo es de a un pedido por vez, y la app pasa. `lake exe linearizable` hace lo que el
lockstep secuencial no puede. Cada escenario tiene tres partes: un prefijo secuencial que arma el
estado, una **ráfaga** de 2 a 4 comandos mandados todos a la vez (`curl --parallel-immediate`, una
conexión por pedido) y un sufijo secuencial que mira lo que quedó.

El criterio: el sistema es linealizable respecto del modelo si **existe algún orden** de los
comandos de la ráfaga tal que el modelo, corrido en ese orden, responda lo mismo que el sistema,
tanto en la ráfaga como en el sufijo. Se prueban todas las permutaciones (a lo sumo 24).

**Cuarta corrida.** Con los arreglos 1 y 2 puestos, el servidor con varios workers
(`PHP_CLI_SERVER_WORKERS`) y la misma app que acaba de pasar 1000 tests, aparece una carrera:

```
*** Failed! No linearization (after 41 scenarios and 6 shrinks, seed 1):
prefix:     [Sell 1]
concurrent: [Expire,Expire]
then:       []

phase       command       system
prefix      Sell 1        Ok
concurrent  Expire        Ok
concurrent  Expire        Ok

Ningún orden de los comandos concurrentes da eso. El modelo acepta solo:
  Expire → Ok, Expire → IsExpired
```

Dos `Expire` simultáneos ven la tarjeta `sold` y los dos contestan `Ok`. En las dos semillas que
probé (1 y 2) fue esta la primera carrera que apareció. El patrón se repite en todos los handlers
de la app: leer el estado, decidir y escribir son pasos separados. Por ejemplo, dos `Reverse`
simultáneos después de una redención pueden devolver la plata dos veces: probado a mano con `curl`,
pasó en 7 de 20 intentos. `fixes/3-atomic-requests.diff` mete cada pedido en una transacción
`BEGIN IMMEDIATE`, que toma el lock de escritura de entrada.

**Quinta corrida.** `+++ OK, passed 200 scenarios (600 runs).` En una corrida más larga, de 600
escenarios con 5 repeticiones cada uno (3000 corridas), tampoco apareció nada.

Con `check.sh` toda la historia (cinco corridas) tarda un poco más de un minuto.

**Qué garantiza y qué no.** La ráfaga se manda a la vez, pero no medimos cuándo empezó y terminó
cada pedido, así que el chequeo da por superpuestos a todos los de la ráfaga. Eso solo debilita la
condición: nunca da un falso fallo, pero puede dejar pasar una carrera. Y una carrera es cuestión
de suerte, no de lógica: por eso cada escenario se repite varias veces (`REPS`, por defecto 3) y,
al achicar, se repite hasta `SHRINK_REPS` veces antes de descartar un candidato. Que pase no
demuestra que no haya carreras; que falle sí demuestra que las hay.

## Cómo correrlo

Con Lean 4.35 (`elan` lo toma de `lean-toolchain`), `curl` y PHP 8 con `pdo_sqlite`:

```sh
./check.sh                       # toda la historia, sobre una copia temporal de la app

php -S localhost:8080 app/index.php   # o a mano: levantar la app...
lake exe lockstep                     # ...y correr el lockstep contra ella
```

Para la fase concurrente, el servidor tiene que atender en paralelo (Linux o macOS):

```sh
PHP_CLI_SERVER_WORKERS=4 php -S localhost:8080 app/index.php
lake exe linearizable
```

Variables: `SUT` (URL base, por defecto `http://localhost:8080`), `TESTS` (cantidad; 1000 en `lockstep`, 200 en `linearizable`), `SEED`; y solo para `linearizable`, `REPS` (repeticiones por escenario, 3) y `SHRINK_REPS` (15).

Para chequear los teoremas: `lake build Oraculo`.

## Lo que esta prueba de concepto no cubre

Es un juguete, a propósito.

- **Una sola tarjeta.** Todo pasa sobre la tarjeta 1. Con varias tarjetas, las carreras entre tarjetas distintas (que no deberían interferir) no se prueban.
- **La concurrencia es probabilística y de una sola ráfaga.** Ver arriba: no hay chequeo general de linealizabilidad con tiempos de inicio y fin, ni ráfagas con secuencias por cliente. Para eso hay herramientas hechas, como [Jepsen](https://jepsen.io)/Knossos, o el chequeo de linealizabilidad de [quickcheck-state-machine](https://hackage.haskell.org/package/quickcheck-state-machine) en Haskell.
- **Los teoremas son sobre el modelo, no sobre el PHP.** Que el modelo sea correcto no dice que el sistema lo sea; para eso está el lockstep.
- **Los bugs fueron plantados.** Son de los que aparecen en sistemas reales, pero acá se sabe dónde están.

## Créditos y licencia

La idea, el modelo original en Haskell, la app PHP (`app/`) y los arreglos (`fixes/`) son de
[Federico Sawady](https://github.com/Ragnagrok) ([repo original](https://github.com/Ragnagrok/un-oraculo-que-nunca-se-deploya),
artículo [*Un oráculo que nunca se deploya*](https://blog.ragnagrok.com/es/2026-10-30-un-oraculo-que-nunca-se-deploya)).
Esta versión en Lean es una adaptación y conserva la licencia MIT del original (ver `LICENSE`).
