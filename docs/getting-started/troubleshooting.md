# Troubleshooting

Common problems and how to fix them.

## Build Problems

### `zig build` fails with "unable to find Zig"

Zig 0.16 is required. Check your version:

```bash
zig version
```

If you have an older version, download the latest from [ziglang.org](https://ziglang.org/).

### `zig build` fails with "cmake not found"

Run the bootstrap script first:

```bash
libs/bootstrap.sh
```

This downloads CMake, Ninja, and other build tools into `.tools/`.

### `zig build` fails with "Dawn not found"

The bootstrap script clones and builds Dawn. Make sure you ran it:

```bash
libs/bootstrap.sh
```

This can take 10–20 minutes on first run.

### Link errors about `liblua` or `luajit`

LuaJIT must be installed on your system. On Ubuntu/Debian:

```bash
sudo apt install libluajit-5.1-dev
```

On Fedora:

```bash
sudo dnf install luajit-devel
```

## Runtime Problems

### The window opens but nothing renders

1. Check that your `.zson` file is valid. The engine logs parse errors to stderr.
2. Check that your entities have both `Transform` and `Sprite` components.
3. Check that `Sprite.visible` is `true`.
4. Check that `Sprite.size` is not `{x: 0, y: 0}`.

### My script does not run

1. Check that the entity has a `Script` component with the correct id.
2. Check that the script file exists and returns a table.
3. Check the engine log for errors. Script errors are logged, not crashed.

### My script errors are not showing

Script errors are logged to stderr with the `[error]` prefix. Make sure you
are capturing stderr:

```bash
zig build run -- myscene.zson 2>&1 | grep error
```

### The game runs too fast or too slow

The engine uses a fixed 60 Hz timestep. If your monitor is 120 Hz or 144 Hz,
the game will still run at 60 Hz simulation rate, but rendering may be faster.
This is by design — the `FrameLimiter` caps the frame rate.

### Hot-reload does not work

Hot-reload is triggered by the editor or by calling the reload function. If you
are running the runtime directly, you need to manually trigger a reload. Check
the [Hot-Reload documentation](../reference/script-hot-reload.md) for details.

## Lua Problems

### `attempt to index a nil value`

You are trying to access a field on a nil value. Common causes:
- `self.some_field` was never set in `start`.
- A function returned nil and you tried to index the result.

### `attempt to call a nil value`

You are trying to call a function that does not exist. Common causes:
- The method name is misspelled.
- The method is defined on the prototype but not on `self`.
- You forgot to define the method in your script.

### `global 'foo' is not allowed (sandboxed)`

You are trying to use a global that is not in the sandbox. See the
[Sandbox section in First Script](first-script.md#the-sandbox) for the list of
allowed globals.

### My script runs but does nothing visible

1. Add `log.info("update called")` to your `update` method to confirm it runs.
2. Check that `dt` is not zero (it should be ~0.0167 at 60 FPS).
3. Check that your movement values are large enough to see (try `actor.move_by(self, 1000 * dt, 0)`).

## Performance Problems

### The game stutters

1. Run `zig build profile` to check for spec violations.
2. Check the `report.json` for frame time spikes.
3. Look for allocations in the frame loop (the engine panics on these in debug builds).

### Memory usage grows over time

1. Check that you are not creating tables in `update` (use scalar forms).
2. Check that you are not leaking Lua references (use `actor.destroy` to remove entities).
3. Run with `EMBER_TRACK=1` to enable the tracked allocator.

## Getting Help

If none of these solve your problem:

1. Check the [Lua API Reference](../reference/script-lua-api.md) for the exact function signature.
2. Check the [Architecture Overview](../architecture/overview.md) to understand how the engine works.
3. Open an issue on [GitHub](https://github.com/jesusalcaladev/ember-engine/issues).
