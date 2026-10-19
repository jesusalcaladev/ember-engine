# UiCanvas — component id 23

**Registry name:** `UiCanvas` · **id:** 23


**What it is:** the screen root of the game's UI: the virtual resolution the interface is authored in, and how it maps onto the framebuffer.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `virtual_w` | `f32` | `1280` | The virtual (logical) width |
| `virtual_h` | `f32` | `720` | The virtual (logical) height |
| `scale_mode` | `UiScaleMode` | `.fit` | `pixel` (1:1), `fit` (uniform + letterbox), `stretch` (fills and distorts) |
| `layer_base` | `u16` | `255` | The layer the UI draws on. 255 is the "every light" wildcard, so an unlit HUD never goes dark |

**Driven by:** `ecs/ui_system.zig` — `resolveCanvas` **per frame**, taking the **first** canvas in slot order.

**Lua:** **not settable** (there is no binding for the fields).

**Connects to:** every widget's layout, and `render/ui_draw.zig`.

**Gotchas:** only the first canvas wins. `layer_base` is a `u16` but only the low byte reaches the GPU.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
