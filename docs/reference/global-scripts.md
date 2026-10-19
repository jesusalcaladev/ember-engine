# Scripts Globales

Un **script global** es un script Lua montado **sin actor**: el game manager, la puntuación, el director de spawns, el flujo de partida. Mismo lenguaje, mismos bindings, mismo ciclo de vida que un behavior — pero no le pertenece a ninguna entidad, y cualquiera puede reacharlo con `globals.get`, el patrón singleton de Lua.

## Declaración en `project.config`

```ini
scripts {
  global "scripts/globals/game.lua" "scripts/globals/flow.lua"
}
```

- Cada ruta es relativa a la raíz del proyecto (las mismas rutas que `audio.play_file`).
- El orden del fichero **es el orden de arranque**: lista el manager antes de los scripts que lo leen.
- Se montan bajo el **basename** del fichero: `scripts/globals/game.lua` es accesible como `globals.get("game")` desde cualquier script — la superficie Lua nunca ve rutas.
- La sección es opcional: un proyecto sin ella arranca igual, con cero globals.
- El editor y el runtime los montan con la misma política: un fichero que falla (no existe, no compila) es una línea de aviso y se salta ese manager — nunca un arranque muerto.

## Ciclo de vida

Un global acepta los mismos hooks que un behavior:

| Hook | Cuándo corre | Firma |
|---|---|---|
| `start` | Una vez, al montar (idempotente) | `function M:start()` |
| `update(dt)` | Cada frame — **antes** que los actors | `function M:update(dt)` |
| `fixed_update(dt)` | Cada tick fijo de 60 Hz — antes que los actors | `function M:fixed_update(dt)` |
| `on_signal(name, payload)` | Cuando la señal drena — antes que los actors | `function M:on_signal(name, payload)` |
| `on_destroy` | Una vez, al desmontarlo con `detachGlobal` | `function M:on_destroy()` |

Dos diferencias importantes frente a un behavior:

1. **Nunca muere por sweep.** No hay entidad que vigilar, así que no existe el barrido de fin de frame. Un global vive hasta que alguien lo desmonta, y `on_destroy` corre ahí, con la tabla aún alcanzable por completo.
2. **Su `self` no lleva `__entity`.** Es la diferencia entera: `actor.*` sobre el `self` de un global falla por el mismo camino que un self sin handle (error contado y logueado). Un global debe hablar con el mundo, no con un actor que no es suyo: `world.*`, `input.*`, `scene.*`, `audio.*`, `timer.*`.

```lua
-- scripts/globals/game.lua
local M = {}
M.score = 0
M.phase = "menu"

function M:start()
  self.score = 0
end

function M:update(dt)
  -- lógica de alto nivel: budget de spawns, fase, score
end

function M:on_signal(name, payload)
  if name == "enemy_died" then
    self.score = self.score + (payload and payload.points or 1)
  end
end

return M
```

## La regla singleton: un global por script

- `attachGlobal` de un script **ya montado falla** (`error.GlobalAlreadyMounted`) — no se crea una segunda instancia oculta cuyo `update` correría dos veces.
- Un segundo `loadGlobal` del mismo nombre **no** es un segundo global: es el hot-reload de siempre (el caché es compartido, y un `.lua` puede servir actors Y un global a la vez).
- El hot-reload conserva el estado del `self` y re-resuelve los métodos, exactamente igual que para los actors.

## Acceso cruzado desde Lua: `globals.*`

| Binding | Qué hace |
|---|---|
| `globals.get(name)` | Devuelve la tabla `self` del global montado, o `nil` si no existe. Llama métodos (`game:pause()`), lee y escribe campos directamente. |
| `globals.exists(name)` | `true` solo si hay un global montado con ese nombre ("¿puedo llamarlo?", no "¿existe el fichero?"). |

```lua
-- desde cualquier behavior:
local game = globals.get("game")
if game then
  self.target_score = game.score
end

if globals.exists("flow") then
  globals.get("flow"):resume()
end
```

Un nombre desconocido devuelve `nil`/`false`, no un error: el tiempo ("aún no se ha montado el manager") es una respuesta perfectamente válida que un script puede gestionar una vez en el arranque.

## Orden del frame

Los globals corren **antes** que los actors en cada pasada, deliberadamente:

1. Tick de máquinas de estado (igual que siempre)
2. Rebuild de la grid espacial (si steering está activo)
3. **`update` de los globals**
4. `update` de los actors
5. Drenaje de señales: globals primero, actors después
6. `fixedUpdate`: globals primero, actors después
7. Sweep (solo actors; los globals nunca se barren)

La regla que esto compra: el manager prepara el estado compartido (score, fase, budget) y un behavior lo ve **ese mismo frame**, sin el retardo de un frame que tendría "globals después".

El `start` respeta lo mismo: `startAll` corre los globals primero, así un behavior puede leer `globals.get("game")` dentro de su propio `start`.

## Qué no es un global

- No es sustituto de componentes: estado que pertenece a un actor vive en el actor.
- No es un service locator: una instancia por script, resuelta por nombre. No hay API de reflexión a propósito.
- No se puede desmontar desde Lua: `detachGlobal` es una llamada Zig (la usa el flujo de cambio de escena / parada de simulación del editor), no un binding.
