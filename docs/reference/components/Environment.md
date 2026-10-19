# Environment — component id 13

**Registry name:** `Environment` · **id:** 13


**What it is:** the world's own light level: what "dark" means here, and the post-process mood. It is **one per world, not per actor**.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `ambient_color` | `[4]f32` | `{0.09,0.10,0.14,1}` | The colour the ambient term tints everything by |
| `ambient_energy` | `f32` | `1.0` | Global light level, a multiplier on the colour |
| `clear_color` | `[4]f32` | `{0.02,0.02,0.03,1}` | What a pixel with no light resolves to |
| `bloom_intensity` | `f32` | `0.0` | How much bloom is added. **Zero disables the whole chain** |
| `bloom_threshold` | `f32` | `1.0` | Luminance above which a pixel contributes to the bloom |
| `tonemap` | `bool` | `false` | Screen-space tonemap |
| `fog` | `[2]f32` | `{0,0}` | Fog near and far in world units. 0 disables it |
| `fog_color` | `[4]f32` | `{0.5,0.5,0.55,1}` | The fog colour |

**Driven by:** `render/lighting_driver.zig` — the **first** `Environment` in the world, read **every frame** (a script can change it mid-run).

**Lua:** `environment.new(self)`, `environment.set_ambient(self, r, g, b, energy)`, `environment.set_clear`, `environment.set_bloom(self, intensity, threshold)`, `environment.set_tonemap`, `environment.set_fog(self, near, far)`, plus the getters.

**Connects to:** the lighting driver (ambient) and the post chain (bloom, tonemap, fog).

**Gotcha:** only `ambient` is mapped into the renderer's `SceneEnvironment` by `toScene`; the rest are read by the post pass.

---

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
