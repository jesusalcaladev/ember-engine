## 📊 ESTADO ACTUAL: QUÉ FUNCIONA BIEN (M0-M7)

### ✅ CORE ENGINE (M0-M3) - SÓLIDO
- [x] **ECS Archetype-based** - SOA, archetypes, queries tipadas, signals, hierarchy
- [x] **VTable Renderer** - Dawn (WebGPU) + Null backend, spec §3.6 (no alloc en frame)
- [x] **Sprite Batcher** - Ordenado por atlas + draw-call agrupado, 1 draw call por (atlas, blend)
- [x] **Atlas Packer** - Shelf packing, multi-page, padding, trim, decontaminación alfa.
- [x] **LuaJIT Bindings** - Actor API, Math, Vec2, Spatial, Input, Time, Signals
- [x] **Physics** - Box2D wrapper, collision layers simétricas, raycast, signals
- [x] **Camera2D** - Follow, zoom, shake, shake decay, deadzone, lerp
- [x] **Timer System** - Fixed-step, one-shot, repeating, signals
- [x] **ZSON** - Serialización binaria + texto, prefabs con overrides
- [x] **Signals** - Typed, stable order by spawn, drain once/frame

### ✅ M4-M5 GAMEPLAY - FUNCIONAL
- [x] **Behavior System** - LuaJIT, hot-reload, lifecycle (init/update/destroy), signals
- [x] **Steering** - Seek, flee, arrive, pursue, evade, wander, flock, obstacle avoidance
- [x] **Pathfinding** - A* grid, navigation mesh (básico), dynamic obstacles
- [x] **Input System** - Keyboard, mouse, gamepad, action mapping, action buffer
- [x] **UI System (Básico)** - Layout, widgets, focus, navegación, temas

### ✅ M7 ILUMINACIÓN 2D - COMPLETO
- [x] **4 Tipos Luz** - Point, Spot, Directional, Ambient (LightBase compartido)
- [x] **Shadow Maps 1D** - Barrido angular, penumbra real, 4 canales priorizados
- [x] **Spot Lights** - Cono + penumbra suave (1 dot product)
- [x] **Radiance Cascades GI** - CPU ref + GPU compute (f64 puro, coarse-to-fine)
- [x] **Blend Modes** - Add / Subtract / Mix (3 pipelines)
- [x] **Layer Masking** - per-pixel en light shader
- [x] **Auto-SDF Oclusores** - Cobertura α → máscara → EDT → Radiance Cascades (⚠️ la cobertura α estaba escrita pero **no cableada** — ya corregido, ver abajo)
- [x] **GI ajustable por config** - `gi_resolution`, `shadow_resolution`, `gi_backend`, `bounce_iterations`, `bounce_albedo`; defaults puestos por medición
- [x] **3 modelos de GI** - `sky` (exteriores), `bounce` (interiores, más barato y el único que ilumina una sala sellada), `off` (iluminación a mano, coste cero y sin alias). Elegible por proyecto y por `Environment`
- [x] **Editor Bindings** - 167 bindings con metadata docs
- [x] **Tests** - 86/86 passing (`zig build test-light`), 6 shaders validados

### ⚠️ M7 MEDIDO — LO QUE LA SUITE NO ESTABA MIRANDO

`zig build test-light` reportaba **1 test pasado** durante meses, y ese único test
era el `test { }` del propio root. Los 85 tests del renderer y de la iluminación
se COMPILABAN y nunca se EJECUTABAN. Dos errores apilados:

1. `std.testing.refAllDecls` no recursiona. Los tests son campos de `Lighting`,
   `Radiance`, `CoverageStore`; tomar la dirección de una referencia de módulo y
   parar deja todo lo anidado sin analizar.
2. `src/engine/render/` pasó a ser un MÓDULO Zig propio, y Zig solo recolecta
   tests de los archivos del módulo ROOT. Ninguna recursión desde fuera lo
   alcanza.

El arreglo fue de ubicación, no de ingenio: el root de tests ahora es
`src/engine/render/test_root.zig`, dentro del módulo que prueba. 86 tests corren.

Con la suite corriendo de verdad, el demo de aceptación encontró **cuatro
defectos reales** — todos invisibles desde las estadísticas, que se veían
perfectas mientras el motor hacía lo contrario:

| Defecto | Síntoma | Arreglo |
|---|---|---|
| La huella del occlusor se cancelaba a sí misma | 40 muros idénticos → XOR = 0 = el centinela de un resize, así que la máscara **nunca** se construía. Toda sombra la proyectaba una rejilla vacía. | FNV-1a sobre posición, extensión, radio, círculo, umbral, cobertura, rectángulo, layer mask **y los puntos del polígono** |
| El barrido de sombras no podía ver un cambio de máscara | `rasterize` limpia `mask_changed` antes de que `buildShadowMaps` lo lea, así que la sombra solo se recalculaba si se movía una LUZ. Mueve una pared pasado un foco quieto y la sombra se queda. | `sweep_stale`, lo fija `rasterize`/`resize`, lo consume el barrido |
| La pirámide GI se reconstruía cada frame | Bajo un comentario que decía "solo cuando el campo se mueve". | `updateSdf` devuelve si reconstruyó, y la pirámide sigue esa respuesta |
| El coste de GI escalaba con el área de pantalla | 1,048,576 sondas × 16 rayos = 16.7M trazas a 2048². | Presupuesto de sondas por eje (128 medium, 256 high) |

### ✅ GI A 1080p — RESUELTO, Y AHORA ES UN DIAL DE CONFIGURACIÓN

Presupuesto del ROADMAP: **GI ≤ 1.5 ms/frame amortizado**. Estaba **100× por
encima**: el campo GI vivía a la resolución de la máscara (2048²), así que el
transformado de distancia exacto corría sobre 4.2M celdas.

Ahora el campo GI tiene **resolución propia**, ajustable por el developer desde
`project.config`:

```
lighting {
  gi_resolution 128        # lado mayor del campo GI, en celdas. 0 = una celda GI por celda de máscara
  shadow_resolution 1024   # lado mayor de la máscara de sombras, en celdas
}
```

El default (**128**) está puesto por medición, no por gusto. `zig build bench-light`
imprime el barrido completo, con coste **y** diferencia contra el campo a
resolución completa (MAE sobre 4096 muestras — medido, porque en un bench sin
ventana no se puede "mirar"):

| `gi_resolution` | resample | transform | **total** | MAE | subida |
|---|---|---|---|---|---|
| 0 (antes) | 1.4 ms | 259.5 ms | **260.9 ms** | ref | 16 MiB |
| 64 | 1.6 ms | 0.2 ms | 1.7 ms | 0.109 | 16 KiB |
| **128** | 2.0 ms | 0.7 ms | **2.7 ms** | 0.040 | 64 KiB |
| 256 | 3.1 ms | 3.0 ms | 6.1 ms | 0.025 | 256 KiB |
| 512 | 9.1 ms | 13.2 ms | 22.3 ms | 0.008 | 1 MiB |

**Por qué 128 y no 256**: la rodilla está ahí. 64→128 cuesta 1 ms más y reduce el
error a la mitad. 128→256 cuesta 3.4 ms más y mejora el error en 0.015 — sobre un
término que se envía ponderado por `gi_contribution` (0.3 en la escena de
aceptación) es menos del 1% de un término de iluminación que nadie nota.
256→512 cuesta 16 ms por 0.017, y de ahí en adelante es una recta al coste
anterior.

**Efecto en el frame real** (`zig build bench-light`, medium, 21 luces,
40 oclusores, máscara 2048²):

| | Antes | Ahora |
|---|---|---|
| Frame en movimiento | 392 ms | **14.2 ms** |
| Costo medio de frame | 125.9 ms | **4.7 ms** |
| Subida de GI | 16 MiB | **64 KiB** |

Un frame en movimiento a 1080p bajó de 23× el presupuesto a 14.2 ms.

> **CORREGIDO MÁS ABAJO — esta afirmación estaba mal.** "14.2 ms cabe en un frame
> de 60 Hz"merce las 2.4 ms restantes a un sprite, la física, Lua, el audio, la UI
> y el propio driver del batch, y no caben. La medición posterior (`sweepBudgetGrid`)
>拉克orta que el coste estaba mal atribuido y que el default era 2.8× más caro de
> lo que estas cifras sugerían. Se conserva el texto porque el error está
> registrado, no borrado.

**Lo que sigue sin cumplirse**: el presupuesto de 1.5 ms amortizados. El
`resample` es lineal en la MÁSCARA y ninguna resolución lo reduce, así que 2.7 ms
es el piso con este diseño. Está registrado como tal, no maquillado.

Nota: el bench tiene ~20% de dispersión entre corridas; las cifras de EDT y
pirámide son rangos.


### ✅ EL DEFAULT DE `shadow_resolution`: 2048 → 1024, POR MEDICIÓN

La pregunta era "un juego 2D de mundo abierto puede ir a 60 fps con GI", y la
respuesta corta resultó ser: **no, con los defaults que había**. El coste de un
frame de iluminación con oclusores moviéndose era de **26.6 ms** — 1.6× un frame
entero de 60 Hz — y la mitad erarasterizado de máscara y barrido angular, que son
lineales en área.

#### El hallazgo que cambió la recomendación

Medí `shadow_resolution` primero, porque era la hipótesis evidente. **No era el
dial**, y el sweep lo dice de forma inequívoca: la pirámide se mantiene en
22–27 ms en **todas** las resoluciones de 256 a 4096, porque no lee la máscara de
sombras — lee `gi_resolution`, que es un presupuesto aparte. Bajar la resolución
de sombras no toca la pirámide.

Lo que sí baja es la máscara y el barrido, que corren **cada frame** en que se
mueve un oclusor. El coste por reconstrucción (µs, GI activo, 21 luces, 40
oclusores, vista 1920×1080):

| `shadow_resolution` | máscara | pasos de rayo | máscara | barrido | campo GI | pirámide | total |
|---|---|---|---|---|---|---|---|
| 256/512 | 512² | 49 918 | 612–863 | 1131–1401 | 1485–2523 | 21618–22124 | **24.8–26.9 ms** |
| 1024 | 1024² | 98 341 | 1775 | 3427 | 2316 | 23391 | **30.9 ms** |
| 2048 | 2048² | 195 965 | 10 067 | 5226 | 3624 | 22544 | **41.5 ms** |
| 4096 | 4096² | 391 110 | 40 291 | 11 025 | 11 053 | 21 853 | **84.2 ms** |

2048 era una costumbre, no una medición: es el tamaño de un mapa de sombras en
un motor 3D donde una texel cubre una superficie entera. Aquí una texel cubre una
celda 2D, y 1024 sobre una vista de 1920 ya es una texel por ~2×2 píxeles de
pantalla — bajo un término de GI que es 128×128, nadie lo ve.

#### La tabla que decide

µs por frame **amortizado**, con la forma real de un frame con oclusores en
movimiento: máscara + barrido **cada frame**, campo + pirámide repartidos en 6
frames (`gi_interval_ns` = 100 ms). El intervalo gobierna el campo y la pirámide,
**no** la máscara ni el barrido, y dividir el frame entero entre 6 subestima
justo en la dirección que hace parecer que el dial barato es el bueno.

| `shadow_res` ↓ / `gi_res` → | 32 | 64 | 128 |
|---|---|---|---|
| **512** | **1612** | 3640 | 7565 |
| **1024** | 5634 | 6358 | 9507 |
| **2048** (antes) | 21089 | 15045 | **26597** ⚠️ |

⚠️ = se pasa un frame entero. La celda elegida es **1024 × 128**, que entrega
**9.5 ms** — un 2.8× de mejora sobre el default anterior.

La calidad de `gi_res` ya estaba medida (MAE contra el campo a resolución
completa): 0.199 en 32, 0.109 en 64, **0.041 en 128**, 0.025 en 256. El error cae
como ~1/res, así que 128 es el codo de la curva — y también cuatro veces el coste
del de abajo.

**Resultado medido con los defaults que se envían**
(`zig build bench-light`, "M7 ACCEPTANCE"):

| | antes (2048) | ahora (1024) |
|---|---|---|
| Máscara | 2048² | **1024²** |
| Frame en movimiento | 14 891 µs | **5285 µs** |
| Costo medio de frame | 4972 µs | **1770 µs** |
| % del presupuesto de 60 Hz | 49.2% | **10.6%** |
| Frame en reposo | 12 µs | 12 µs |

### 🐛 LA SECCIÓN `lighting` DEL CONFIG **NUNCA LLEGÓ AL DRIVER**

Encontrado al intentar hacer que el acceptance midiera el default que se envía, y
es la clase de defecto que este motor ha ido acumulando:

- `Driver.applyLightingConfig` **no tenía ningún caller** en el árbol entero.
- Leía un campo llamado **`backend`**, que `project.config.Lighting` nunca ha
  tenido: se llama `gi_backend`, y es un enum, no el `u8` que la función esperaba.
- Era genérica sobre `anytype` + `@field`, así que un genérico sólo se comprueba
  contra lo que se le pasa, y no se le pasaba nada.

Consecuencia: **`gi_backend`, `gi_resolution`, `shadow_resolution`,
`bounce_iterations` y `bounce_albedo` eran inertes.** Se parseaban, se
documentaban en el esquema con tooltips, seEGF They'd appear in an editor
dropdown, y no se usaban. Un proyecto podía poner `shadow_resolution 512` y el
render seguiría con la suposición del constructor.

Tres arreglos:

1. **`applyLightingConfig` ahora toma `project.config.Lighting` concreto.** El
   parámetro se escribe explícito a propósito: volverlo genérico reintroduce la
   misma clase de error y además elimina la única comprobación que lo detectó.
2. **Un callback `applyLighting` en `project.runtime.apply`.** Es un callback de
   config y no una línea de arranque, así que editar el fichero lo re-aplica. Los
   dos dials que más cuestan son exactamente los que uno ajusta mirando el frame
   time, y un ajuste que exige relanzar se ajusta una vez y se olvida.
3. **`Driver` recuerda `shadow_resolution`.** `setShadowResolution` calcula una
   *escala* a partir de una vista, y `resize` divide por ella, así que el driver
   conservaba la escala de la vista ANTERIOR: la máscara se movía exactamente en
   la proporción en que se movía la ventana. Una resolución que no se puede
   conservar no es una resolución. `resize` vuelve a derivar la escala a partir de
   la vista que recibe.

Con (3) desaparece también una trampa de orden: `applyLighting` **no** redimensiona.
En tiempo de config el driver todavía no tiene vista (`lighting.rect` está vacío),
y redimensionar ahí pide una máscara de 1×1 contra una escala pensada para 1920.
Se probó, y entra en pánico en `allocMask` en el primer frame.

Dos tests nuevos, en `lighting_driver.zig`, que fallan contra el código anterior:
la sección del config llega al driver (backend, dials **y** el tamaño real de la
máscara), y la resolución configurada sobrevive a un `resize`.

### ✅ GI: TRES MODELOS, UN ENUM, TODO PARAMETRIZADO

```
lighting {
  gi_resolution 128          # lado mayor del campo GI (0 = 1 celda GI por celda de máscara)
  shadow_resolution 1024     # lado mayor de la máscara de sombras (medido: 2048 costaba 26.6 ms/frame)
  gi_backend "sky"           # off | sky | bounce
  bounce_iterations 8        # pases de difusión por frame (modelo bounce)
  bounce_albedo 0.6          # fracción de luz que conserva una pared por rebote
}
```

**`gi_backend` es un enum y no un número a propósito**: los tres son afirmaciones
distintas sobre de dónde viene la luz, así que un número sería mentira de
construcción.

| | qué modela | para qué |
|---|---|---|
| `sky` | traza hacia el cielo y propaga lo que encontró | exteriores: un patio a mediodía |
| `bounce` | lleva las luces **de la propia escena** por el espacio libre y las rebota en las paredes | interiores: un pasillo con antorchas |
| `off` | nada | proyecto que ilumina a mano — **libera** cada buffer, no salta el trabajo |

Medido, mismas escenas, mismos ajustes (`zig build bench-light`, "GI BACKENDS"):

| escena | GI con `sky` | GI con `bounce` | luz que llega a la sala |
|---|---|---|---|
| abierta | 17.8 ms | **10.8 ms** | — |
| **sala sellada** | 7.3 ms | **6.4 ms** | `sky`: **0.000** / `bounce`: **2.739** |

La última columna es la que decide. **El modelo de cascadas produce exactamente
nada en una habitación sin cielo** — y eso no era un bug, era la pregunta
equivocada: la luz que debería estar en una mazmorra viene de las antorchas que
están en la mazmorra, y las antorchas no están en el campo que la cascada traza.
Un RPG 2D de mundo abierto es las dos cosas en el mismo fichero, por eso
`gi_backend` está **también en `Environment`**, no solo en el config.

Y el rebote es **más barato**, no más caro: un número fijo de pasadas sobre la
rejilla contra `sondas × rayos` que crece con cada cascada.

### ✅ GI OFF — como el de Unreal, y no es un castigo

Tres afirmaciones distintas porque apagar un subsistema tiene tres maneras
distintas de salir mal, y todas verificadas por test:

1. **No cuesta nada.** Sin campo, sin transformada de distancia, sin buffer de
   subida, sin rejilla de propagación. Todo a longitud cero, no "no leído".
2. **No se lleva nada más.** Las sombras siguen, los oclusores manuales siguen, y
   los **oclusores automáticos siguen** — un proyecto iluminado a mano quiere
   sombras, y un sprite que proyecta su propia silueta también.
3. **El término se lee como ausente, no como cero.** `sampleGi` devuelve 1.0, que
   significa "no hay término" y no "el cielo es negro". Un cero oscurecería cada
   sala del juego y `encodeGi` se niega a escribir una textura válida llena de
   ceros, porque eso es una escena que se oscurece sin forma de preguntar por qué.

### ✅ EARLY-OUT PARA SONDAS ENCERRADAS — MEDIDO ANTES DE DECIDIR

| escena | apagado | encendido |
|---|---|---|
| abierta | 15.56 ms | 14.68 ms (**5.7%**) |
| **sala sellada** | 7.07 ms | **4.82 ms (31.8%)** |

Gana justo donde el motor se va a usar. Se queda **encendido**, y la bandera
existe porque la respuesta depende de la escena, no porque la idea sea obviamente
buena.

### 🔒 LA SUITE NO PUEDE DESAPARECER EN SILENCIO

Un guard en `build.zig` (el sitio donde estaba el error, y al que un test dentro
del módulo no puede alcanzar: se desarma justo cuando hace falta) y otro en
`test_root.zig` que detecta un subsistema alcanzado como MÓDULO. Los dos
verificados reintroduciendo el bug.

### ⚠️ LO QUE ESTABA ESCRITO Y NO EXISTÍA

`registerAtlasCoverage` — la función que convierte "cobertura α del sprite" en
sombra de silueta — estaba escrita, testeada, benchmarkeada, documentada como
"la acción cero de desarrollo que promete el ROADMAP"… y **no la llamaba nadie**.
Ni el loader, ni `uploadAtlas`, ni `main`. En toda build real, todo
`LightOccluder2D` automático proyectaba el **rectángulo** de su sprite, y
`coverage_used` se quedaba en un cero permanente que nadie señalaba.

La costura es un puntero a función, no una dependencia, porque `uploadAtlas` es
el único momento en que los píxeles de una página son definitivos y ese archivo
no sabe qué es un sprite:

```zig
atlas_mgr.onPageUploaded(driver, lighting_driver.Driver.registerCoverageForPage);
```

**Eso destapó tres bugs latentes en `atlas_bridge.zig`**, cuyos tests tampoco se
recolectaban nunca (el mismo fallo, en pequeño):

| Bug | Efecto |
|---|---|
| `AtlasPacker.init(..., allow_growth = true)` | `insert` nunca devolvía null → `nextPage` **nunca se llamaba** → `pages` tenía siempre 1 entrada. Y el packer repartía rects **pasando** `width`/`height` mientras `uploadAtlas` sube cada página con el `width`/`height` ORIGINALES. **La cola del atlas se escribía fuera de la textura enviada a la GPU.** Esos sprites no sampling nada. |
| `pageCount` devolvía `usize` desde una firma `u32` | No compilaba (nunca se había compilado). |
| `std.fmt.bufPrint` con la forma de 2 argumentos | Pre-0.16. No compilaba. |

---

## ✅ M6 ASSETS PIPELINE - COMPLETO (Recién terminado)

### ✅ Virtual Filesystem (VFS)
- [x] **VFS abstraction** - .pak + filesystem, byte-budgeted, no blocking I/O in frame
- [x] **Pak format** - Magic header, entry table, multi-page, random access
- [x] **Pak compression** - zstd per-entry (~60-70% size reduction)
- [x] **Pak index** - Fast lookup at load time

### ✅ Asset Registry
- [x] **Stable GUIDs** - Content-addressable (FNV-1a), deterministic across sessions
- [x] **Asset types** - image, audio, script, shader, font, collection
- [x] **Dependency graph** - Forward (deps) + reverse (dependents) edges
- [x] **Topological sort** - Load order (dependencies before dependents)
- [x] **Cascade reload** - Get all transitively dependent assets for hot reload

### ✅ Asset Manager
- [x] **LRU cache** - Byte-budgeted with eviction (spec §3.15)
- [x] **Cache hits** - Same slot returned for same path
- [x] **Stats** - Memory report integration

### ✅ Hot Reload
- [x] **File watching** - Poll-based with debounce (100ms default)
- [x] **Change detection** - Content hash comparison (not just timestamp)
- [x] **Callbacks** - Image/audio/script reload events
- [x] **< 250ms target** - Poll once per frame

### ✅ Import Pipeline
- [x] **Batch import** - PNG/OGG/Lua batch processing
- [x] **Image decode** - stb_image via C shim (RGBA8, load-time only)
- [x] **Audio decode** - WAV PCM → audio.Bank bridge
- [x] **Script validate** - LuaJIT syntax check → script_id
- [x] **GuidFromPath** - Deterministic FNV-1a

### ✅ Atlas Integration
- [x] **Multi-page atlas** - Shelf packing, auto page growth
- [x] **UV generation** - Correct [0,1] UVs per entry
- [x] **Blit verification** - Pixel-perfect copy tests

### ✅ Tests (15 integration tests)
- [x] VFS read/write round-trip
- [x] AssetManager LRU eviction
- [x] AssetRegistry GUID stability
- [x] Atlas multi-page + UVs + blit
- [x] Hot reload detection
- [x] Import batch → .pak
- [x] Audio WAV decode
- [x] Script Lua validation
- [x] Complete pipeline VFS → Manager → Atlas → Registry

---

## ✅ M3/M4.5 LUA BINDINGS OPTIMIZATION - COMPLETO

### ✅ Batch APIs
- [x] **actor.set_transform** - Position + rotation + scale in 1 call (was 3)
- [x] **actor.get_all** - All components as one table (was N calls)
- [x] **actor.move_by** - Already existed (read-modify-write in 1 call)

### ✅ Batch Driver
- [x] **Group by script_id** - Single C loop instead of N Lua→C transitions
- [x] **Visitor accumulator** - nearby terms batch in C (flock: 1 call vs 3)

### ✅ Data-Driven Config
- [x] **batch_config.zson** - Designer-controlled batch enabling

### 📊 Benchmark Results
| Métrica | Antes | Después | Mejora |
|---|---|---|---|
| Bindings/agent | 3 | 1 | -67% |
| 10k agents | 4.35 ms | 1.45 ms | -2.9 ms |
| % Budget (2.0ms) | 217% | 72% | Dentro budget |
| Framework floor | 0.65 ms | 0.65 ms | Sin cambios |

---

## ✅ M4.5 NOISE MODULE - OPTIMIZADO
- [x] **Comptime constants** - skew/unskew precomputed
- [x] **GlobalNoise** - World/terrain/weather/animal seeds
- [x] **ChunkCache** - Precomputed noise per chunk
- [x] **Deterministic** - Pure (seed, x, y) → value

---

## 🟡 M8 AUDIO - PARCIAL
- [x] **Audio System** - miniaudio backend implemented
- [x] **Lua Bindings** - sound.play, sound.stop, sound.set_volume
- [x] **Atlas System** - Multi-page atlases, sprite atlases
- [ ] **Audio Streaming** - OGG streaming for long files (music)
- [ ] **OGG decode** - Full miniaudio decode integration

---

## ❌ M9 FX / PARTÍCULAS - NO INICIADO
- [ ] **GPU Particles** - Compute shader, 100k particles ≤ 1ms GPU
- [ ] **Soft Bloom** - For lights
- [ ] **Scene Transitions** - Fades

---

## 🟡 M10 EXPORT - PARCIAL
- [x] **Windows/Linux** - Single binary + .pak
- [x] **WebGPU** - Dawn backend
- [ ] **WASM + WebGPU** - emcc/Zig-wasm linking
- [ ] **Lua 5.4 backend** - Web scripting (LuaJIT no WASM)

---

## ❌ M11 PERFORMANCE CI - INFRA LISTO
- [x] **Bench suite** - M1/M2/M3/M4 benchmarks
- [x] **CI gate** - >5% regression = red CI
- [x] **ember-profile** - Baseline comparison
- [ ] **8h soak test** - Automated memory drift check

---

## ❌ M12.1 PIN-PON DEMO - DISEÑADO
- [ ] **Platformer demo** - Ball + paddles + sensors + score
- [ ] **Full surface exercise** - Physics + Lighting + GI + Audio + Input + Script + Serialize + Editor + Export

---

## ❌ M13 ANIMATION - NO INICIADO (Gap más grande)
- [ ] **AnimationClip** - Tracks: value, sprite, method
- [ ] **AnimationPlayer** - play/stop/pause/seek/speed/queue
- [ ] **AnimationTree** - BlendSpace1D, OneShot, StateMachine, BlendTree
- [ ] **Root Motion** - Per-clip transform drive

---

## ❌ M14 TEXT + UI - NO INICIADO
- [ ] **Font Atlas** - TTF → SDF/bitmap, glyph metrics
- [ ] **Text Pipeline** - Batch on sprite renderer
- [ ] **UI Scene Graph** - Canvas, Control, Label, Button, ProgressBar
- [ ] **HUD** - Bars, counters, anchored to screen size

---

## ❌ M15 TILEMAP - NO INICIADO
- [ ] **TileSet** - Atlas regions, physics layers, autotiling (16/47-blob/Wang)
- [ ] **TileMapLayer** - Chunked storage, dirty-chunk upload, viewport culling
- [ ] **Tile Collision** - Per-tile collision, nav cost, triggers

---

## ❌ M16 TIMELINE + DIALOGUE - NO INICIADO
- [ ] **Timeline** - Animation/audio/method/camera/signal tracks
- [ ] **Dialogue** - Speaker, portrait, choices, branching, l10n keys

---

## ❌ M17 LOCALIZATION - NO INICIADO
- [ ] **l10n.t()** - Plural forms, placeholders, fallback to key
- [ ] **Translation tables** - CSV/JSON assets
- [ ] **Font fallback** - Per-locale, missing glyph reporting

---

## 📋 BACKLOG — Gaps detectados
| Gap | Nota | Home propuesto |
|---|---|---|
| **Shaders / Material System** | M2 dice "simple materials"; no user shader path | M18 |
| **Navmesh** | M4.5 grid A* done; navmesh baking unplaced | M18 |
| **Skeletal Animation / IK** | M13 is sprite/transform only; 2D rig unplaced | M18/M19 |
| **Save slots & settings** | Bit-exact serialize exists; no user-facing slots | M19 |
| **Input remapping** | Action mapping in M3; rebinding at runtime unplaced | M19 |
| **Rich text / markup** | M14 plain Label; bold/color spans unplaced | Post-M14 |
| **Modding / scripting sandbox** | Not promised anywhere | Post-1.0 |

---

## 🚀 POST-1.0 (Explícitamente fuera de foco)
- macOS, mobile, **consolas** (Switch/PS/Xbox) - Dawn/WebGPU + platform layer keep viable
- LSP server + VS Code extension con go-to-def real (v1 ships LuaLS stubs only)

---

## ⚠️ RIESGOS Y MITIGACIONES

| Riesgo | Mitigación |
|---|---|
| Dawn's API changes | Pinned commits + our own wrapper (`render/`) |
| **LuaJIT no soporta WASM** | `script/` layer abstracta VM: LuaJIT (native) + Lua 5.4 (Web) |
| Radiance Cascades pesado en iGPU | Half-res cascades + amortized update; shadows-only fallback |
| Play-in-editor complejidad | Bit-exact snapshot es M1 req, no deferred |
| Frágil emcc/Zig-wasm linking | CI builds Web target from M0 even if unused |
| In-engine code editor crece | Scope limitado a Lua + metadata; full LSP post-1.0 |

---

*Actualizado tras completar: M6 Assets Pipeline completo, M3/M4.5 Lua batch optimization, M4.5 Noise optimization.*