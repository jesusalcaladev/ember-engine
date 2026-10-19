# ShaderMaterial — component id 5

**Registry name:** `ShaderMaterial` · **id:** 5


**What it is:** a hook for a user-authored shader, held on its own entity so many sprites can share one material.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `shader` | `u16` | `0` | Index into the runtime's shader table. 0 is the stock sprite shader |
| `params` | `[4]f32` | `{0,0,0,0}` | Four floats: a colour, a dissolve threshold, a time… |
| `owner_scene` | `SceneId` | `0` | The entity whose material this is, for the inspector |

**Driven by:** **nothing.** No renderer, batcher or shader-selection code reads it.

**Lua:** `material.new(self, shader)`, `material.set_params(self, p0..p3)`, `material.get_params(self)`, `material.get_shader(self)`.

**Connects to:** nothing yet.

**Gotcha:** the component is a **hook with no consumer**. Setting a non-zero shader has no verified effect anywhere.

---

## Behaviour and timing

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md) · [Lua API](../script-lua-api.md)
