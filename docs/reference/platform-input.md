# Platform Layer — Input

**Sources:** `src/engine/platform/platform.zig`, `src/engine/script/input.zig`

The engine has two layers of input:

1. **Platform `Input`** (`platform.zig`) — raw key state, filled by GLFW callbacks. Gameplay never touches this directly.
2. **Action `Input`** (`script/input.zig`) — a named-action snapshot that Lua reads. This is the gameplay-facing API.

## Platform Input (raw key state)

The platform `Input` is a flat, fixed-size array of key states. It is filled by GLFW key callbacks and read by the action layer.

```zig
pub const Input = struct {
    keys: [352]u8 = [_]u8{0} ** 352,
    presses: [352]u8 = [_]u8{0} ** 352,

    const max_key: usize = 352;
    // ...
};
```

### Key handling

`handleKey` is called from the GLFW key callback. It distinguishes three actions:

- `PRESS` — sets both `keys[k]` (held) and `presses[k]` (edge).
- `RELEASE` — clears `keys[k]` only.
- `REPEAT` — ignored: the key stays down, `pressed` does not re-fire.

```zig
fn handleKey(self: *Input, key: c_int, action: c_int) void {
    if (key < 0 or @as(usize, @intCast(key)) >= max_key) return;
    const k: usize = @intCast(key);
    if (action == glfw.PRESS) {
        self.keys[k] = 1;
        self.presses[k] = 1;
    } else if (action == glfw.RELEASE) {
        self.keys[k] = 0;
    }
    // REPEAT: key stays down, pressed does not re-fire.
}
```

### Query methods

```zig
pub fn down(self: *const Input, key: c_int) bool      // held this frame
pub fn pressed(self: *const Input, key: c_int) bool   // edge: pressed this frame only
pub fn endFrame(self: *Input) void                    // clears all pressed flags
```

`endFrame()` must be called once at the end of each frame to reset the edge-triggered `presses` array:

```zig
pub fn endFrame(self: *Input) void {
    @memset(&self.presses, 0);
}
```

## Action-based Input (gameplay API)

Gameplay code never reads a physical key. It reads a named **action** ("move_left", "jump"). The mapping from action to key lives in the engine (and later in a remappable project file), so rebinding a control never touches a line of Lua.

### Design

Actions are interned by name into a fixed pool at setup. The frame path (`pressed`/`down`) is O(actions) with an early length check — for the handful of actions a 2D game has, this is cheaper than any hash map and needs no per-frame allocation.

```zig
pub const max_actions = 64;
pub const max_name_len = 24;

const Action = struct {
    name_buf: [max_name_len]u8 = [_]u8{0} ** max_name_len,
    name_len: u8 = 0,
    down: bool = false,
    pressed: bool = false,

    fn name(self: *const Action) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};
```

### The Input snapshot

```zig
pub const Input = struct {
    actions: [max_actions]Action = [_]Action{Action{}} ** max_actions,
    count: u8 = 0,
    // ...
};
```

### Defining actions

`define` interns an action name. It is idempotent — interning the same name twice does not duplicate it. Names longer than `max_name_len` are truncated:

```zig
pub fn define(self: *Input, name: []const u8) void {
    if (self.find(name) != null) return;
    if (self.count >= max_actions) return;
    var a = &self.actions[self.count];
    const n = @min(name.len, max_name_len);
    @memcpy(a.name_buf[0..n], name[0..n]);
    a.name_len = @intCast(n);
    a.down = false;
    a.pressed = false;
    self.count += 1;
}
```

### Per-frame lifecycle

1. **`beginFrame()`** — clears all `pressed` flags (edges are recomputed from the platform edge each frame).
2. **`set(name, is_down, just_pressed)`** — drives an action's state from the platform layer.
3. Lua queries `down(name)` / `pressed(name)` / `axis(negative, positive)`.

```zig
pub fn beginFrame(self: *Input) void {
    for (self.actions[0..self.count]) |*a| a.pressed = false;
}

pub fn set(self: *Input, name: []const u8, is_down: bool, just_pressed: bool) void {
    const a = self.findMut(name) orelse return;
    a.down = is_down;
    if (just_pressed) a.pressed = true;
}
```

### Query methods

```zig
pub fn down(self: *const Input, name: []const u8) bool
pub fn pressed(self: *const Input, name: []const u8) bool
```

Both return `false` for unknown actions (define first).

### Axis helper

`axis` produces a signed value from two opposing actions: -1 when `negative` is held, +1 when `positive` is held, 0 when neither or both:

```zig
pub fn axis(self: *const Input, negative: []const u8, positive: []const u8) f32 {
    const neg = self.down(negative);
    const pos = self.down(positive);
    if (neg == pos) return 0; // neither, or the contradictory both
    return if (pos) 1 else -1;
}
```

### Internal lookup

Actions are stored in a flat array and looked up by linear scan with early length check:

```zig
fn find(self: *const Input, name: []const u8) ?*const Action {
    for (self.actions[0..self.count]) |*a| {
        if (a.name_len == name.len and std.mem.eql(u8, a.name(), name)) return a;
    }
    return null;
}
```

## Typical usage from Lua bindings

```zig
// At setup:
input.define("move_left");
input.define("move_right");
input.define("jump");

// Each frame, after platform.poll():
input.beginFrame();
input.set("move_left",  platform.input.down(glfw.KEY_A),  platform.input.pressed(glfw.KEY_A));
input.set("move_right", platform.input.down(glfw.KEY_D), platform.input.pressed(glfw.KEY_D));
input.set("jump",      platform.input.down(glfw.KEY_SPACE), platform.input.pressed(glfw.KEY_SPACE));

// Lua reads:
//   input.down("move_left")     -- held
//   input.pressed("jump")       -- edge
//   input.axis("move_left", "move_right")  -- -1, 0, or +1
```
