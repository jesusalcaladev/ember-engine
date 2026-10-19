# TileMapLayer — PARKED, not registered

**Registry name:** `TileMapLayer` · **not registered** · `src/engine/ecs/components/tilemap.zig`

The type exists (`components/tilemap.zig`) but is **not registered**: the registry entry and the Lua module are both commented out ("M15 PARKED"). The editor's tilemap workspace can still use the type.

| Field | Type | Default | Meaning |
|---|---|---|---|
| `tileset_guid` | `AssetGUID` | `.{ .value = 0 }` | The palette it draws from |
| `layer` | `u16` | `0` | The render layer |
| `z_offset` | `f32` | `0.0` | A parallax offset inside the layer |
| `physics_enabled` | `bool` | `false` | Whether it collides |
| `tile_size_override` | `f32` | `0.0` | 0 = use the TileSet default |
| `default_flip_x` | `bool` | `false` | The default flip for new tiles |
| `default_flip_y` | `bool` | `false` | The default flip for new tiles |
| `_reserved` | `[3]u8` | zeroed | Reserved |

---

← [Component index](README.md) · [Registry mechanics](../ecs-components.md)
