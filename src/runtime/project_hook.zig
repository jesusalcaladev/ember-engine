//! `runtime.project_hook` — the glue that can see BOTH sides of the boundary.
//!
//! `project` is deliberately dependency-free (spec §7): it describes sections,
//! validates them and hands each one to a callback, and it never names an engine
//! type. This file is where those callbacks live for real, because it is the one
//! that may import `project` AND `audio` at the same time.
//!
//! Two pieces, and the same shape every other subsystem's settings will take:
//!
//! 1. **`AudioHook.apply`** is a `project.runtime.Targets` callback: it stores
//!    the validated section. Nothing is built here, because the engine objects
//!    come later (and because `apply` must stay cheap and reversible).
//! 2. **`AudioHook.create`** turns that section into a running system: the
//!    backend, the device description, the pool size, the PCM budget, the master
//!    gain and the bus map.
//!
//! Validation happens BEFORE either of them: `project.runtime.apply` calls
//! `schema.validate` first, so a half-applied section is not a state this file
//! ever has to handle. That is also why `create` can trust every number.
//!
//! It lives in `src/runtime/` rather than inside `main.zig` so the translation is
//! testable: the tests at the bottom boot the real `Audio` system on the null
//! backend and check the section actually landed.

const std = @import("std");
const core = @import("core");
const project = @import("project");
const audio_mod = @import("audio");

const config = project.config;
const log = core.log.scoped("runtime");

// Two modules say "sixteen" about the bus map (the config's ceiling and the
// mixer's `u4`-shaped registry). `project` cannot import `audio` — that is the
// whole reason this file exists — so the mirror is pinned HERE, where both are
// visible, and a change to either stops compiling.
comptime {
    if (config.max_audio_buses != audio_mod.bus.bus_count) {
        @compileError("project.config allows a different number of audio buses than the mixer has");
    }
}

/// The scalar settings a live system was built from. The bus names are NOT
/// copied here: they are compared against the system's own registry, which owns
/// copies of them — a copy in this struct would dangle the moment a hot-reload
/// frees the config arena it pointed into.
const Built = struct {
    enabled: bool = true,
    backend: config.AudioBackend = .miniaudio,
    sample_rate: config.SampleRate = .@"48000",
    period_frames: i32 = 480,
    voices: i32 = 256,
    budget_bytes: i64 = 32 << 20,
    master_volume: f64 = 1.0,
    bus_count: usize = 0,
};

/// The `audio` section, and the system built from it.
pub const AudioHook = struct {
    /// The last section handed over by `apply`. Defaults are a working mixer, so
    /// a hook that was never applied (a headless run, a test) still creates.
    section: config.Audio = .{},

    /// The live system, or null: because `enabled` is false, or because `create`
    /// has not run yet. Null is the answer the Lua `audio.*` bindings report on
    /// (they never dereference it), so a game with audio off is quiet, not broken.
    system: ?*audio_mod.Audio = null,

    /// What the live system was built from (see `Built`).
    built: Built = .{},

    /// `project.runtime.Targets.audio`: store the validated section. Called with
    /// the hook itself as the context, and with every other section's callback
    /// sharing that context.
    pub fn apply(ctx: *anyopaque, section: *const config.Audio) void {
        const self: *AudioHook = @ptrCast(@alignCast(ctx));
        self.section = section.*;
    }

    /// Builds and starts the system from the stored section. Returns null when
    /// audio is disabled.
    ///
    /// Rebuilding is an editor action (the section is boot-time only: the device,
    /// the pool and the budget cannot be resized in place), so an existing system
    /// is destroyed first. Missing audio after an edit is worse than a rebuilt
    /// mixer.
    pub fn create(self: *AudioHook, allocator: std.mem.Allocator) !?*audio_mod.Audio {
        self.destroy();
        if (!self.section.enabled) return null;

        const section = &self.section;
        const backend: audio_mod.Backend = switch (section.backend) {
            .@"null" => .null,
            .miniaudio => .miniaudio,
        };

        const sys = try audio_mod.Audio.create(allocator, backend, .{
            .desc = .{
                // The enum's VALUES are the rates (`SampleRate` spells them out),
                // so this is the number and not a mapping table that could drift.
                .sample_rate = @intFromEnum(section.sample_rate),
                .period_frames = @intCast(section.period_frames),
                // Stereo: panning a 2D emitter is the reason the mixer has a pan
                // law at all, and the config has no field for it on purpose.
                .channels = 2,
            },
            .voices = @intCast(section.voices),
            .budget_bytes = @intCast(section.budget_bytes),
            .master_gain = @floatCast(section.master_volume),
        });
        errdefer sys.destroy();

        // The bus map is a load-time call, and it COPIES the names, so the config
        // arena may die on the next hot-reload without taking the mixer's ids
        // with it.
        sys.defineBuses(section.buses) catch |err| {
            log.warn("audio: bus map refused ({s}); running with master only", .{@errorName(err)});
        };

        self.system = sys;
        self.built = .{
            .enabled = section.enabled,
            .backend = section.backend,
            .sample_rate = section.sample_rate,
            .period_frames = section.period_frames,
            .voices = section.voices,
            .budget_bytes = section.budget_bytes,
            .master_volume = section.master_volume,
            .bus_count = section.buses.len,
        };
        return sys;
    }

    /// True when the running system already IS this section. Scalars are compared
    /// against what the system was built from, and bus names against the system's
    /// registry (which owns copies of them), because the section's own strings
    /// belong to a config arena that a reload is free to free.
    ///
    /// Index 0 is skipped: it is the master bus's conventional entry, and
    /// `defineBuses` ignores it because bus 0 cannot be renamed.
    pub fn matches(self: *const AudioHook, section: *const config.Audio) bool {
        const sys = self.system orelse return false;
        const b = self.built;
        if (b.enabled != section.enabled) return false;
        if (b.backend != section.backend) return false;
        if (b.sample_rate != section.sample_rate) return false;
        if (b.period_frames != section.period_frames) return false;
        if (b.voices != section.voices) return false;
        if (b.budget_bytes != section.budget_bytes) return false;
        if (b.master_volume != section.master_volume) return false;
        if (b.bus_count != section.buses.len) return false;
        for (section.buses[1..], 1..) |name, i| {
            if (!std.mem.eql(u8, name, sys.busName(@intCast(i)))) return false;
        }
        return true;
    }

    /// The call the runtime makes when a config change is applied: builds the
    /// system if the audio section actually changed, and returns the running one
    /// untouched if it did not. Editing `display.width` must not restart the
    /// mixer, drop every voice and glitch the device.
    pub fn sync(self: *AudioHook, allocator: std.mem.Allocator) !?*audio_mod.Audio {
        if (self.matches(&self.section)) return self.system;
        return self.create(allocator);
    }

    /// Stops and frees the system, if any. The Play/Stop hook (M5) calls this;
    /// so does the runtime on the way out.
    pub fn destroy(self: *AudioHook) void {
        if (self.system) |sys| {
            sys.destroy();
            self.system = null;
        }
        self.built = .{};
    }
};

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a default section boots the mixer with the config's pool, budget and buses" {
    var hook = AudioHook{};
    defer hook.destroy();

    // The null backend: this test must pass on a machine with no sound card,
    // and it drives the REAL mixer through `pump`.
    hook.section.backend = .@"null";
    const sys = (try hook.create(testing.allocator)) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(usize, 256), sys.pool.slotCount());
    try testing.expectEqual(@as(usize, 32 << 20), sys.bank.stats().budget_bytes);
    // The bus map is the section's, copied: id 1 is "music" because the list
    // says so, and 0 is master no matter what the list says.
    try testing.expectEqualStrings("master", sys.busName(0));
    try testing.expectEqualStrings("music", sys.busName(1));
    try testing.expectEqualStrings("ui", sys.busName(3));
    try testing.expectEqual(@as(u8, 2), sys.buses.idOfName("sfx").?);
}

test "audio off means no system at all, and null is what the bindings report" {
    var hook = AudioHook{};
    defer hook.destroy();
    hook.section.enabled = false;
    try testing.expect((try hook.create(testing.allocator)) == null);
    try testing.expect(hook.system == null);
}

test "an edited section rebuilds the mixer rather than being half-applied" {
    var hook = AudioHook{};
    defer hook.destroy();
    hook.section.backend = .@"null";

    const first = (try hook.create(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 256), first.pool.slotCount());

    // A second create with a smaller pool and a different bus map: the old
    // system is gone (its memory freed) and the new one is the section.
    hook.section.voices = 8;
    hook.section.buses = &.{ "master", "voice" };
    const second = (try hook.create(testing.allocator)).?;
    try testing.expectEqual(@as(usize, 8), second.pool.slotCount());
    try testing.expectEqualStrings("voice", second.busName(1));
    try testing.expect(second.buses.idOfName("music") == null);
    try testing.expect(hook.system.? == second);
}

test "apply is reached through the real Targets table, and a bad section never gets there" {
    const ref = struct {
        // The minimal shape `apply` needs: one place for the section to land.
        var seen_voices: i32 = 0;
        fn audio(ctx: *anyopaque, section: *const config.Audio) void {
            const hook: *AudioHook = @ptrCast(@alignCast(ctx));
            AudioHook.apply(ctx, section);
            seen_voices = hook.section.voices;
        }
    };
    ref.seen_voices = 0;

    var hook = AudioHook{};
    defer hook.destroy();

    var cfg = config.Config{};
    defer cfg.deinit();
    cfg.audio.voices = 64;
    try project.runtime.apply(&cfg, .{ .ctx = &hook, .audio = ref.audio });
    try testing.expectEqual(@as(i32, 64), ref.seen_voices);

    // Out of range: validation runs first, so the hook is untouched and no
    // system was ever built from a number the engine would not accept.
    cfg.audio.voices = 0;
    try testing.expectError(
        project.schema.ValidationError.OutOfRange,
        project.runtime.apply(&cfg, .{ .ctx = &hook, .audio = ref.audio }),
    );
    try testing.expectEqual(@as(i32, 64), ref.seen_voices);
    try testing.expect(hook.system == null);
}

test "sync rebuilds only when the audio section actually changed" {
    var hook = AudioHook{};
    defer hook.destroy();
    hook.section.backend = .@"null";
    hook.section.buses = &.{ "master", "music" };

    // First sync builds; a second one with the same section hands back the SAME
    // system, which is what keeps an unrelated edit from restarting the mixer.
    const first = (try hook.sync(testing.allocator)).?;
    try testing.expect((try hook.sync(testing.allocator)).? == first);

    // A different device setting rebuilds...
    hook.section.period_frames = 256;
    const second = (try hook.sync(testing.allocator)).?;
    try testing.expect(second != first);

    // ...and so does a bus map whose NAMES changed, even at the same length: the
    // comparison is by name, not by the section's slice identity (the strings
    // come from an arena that a reload frees).
    var same = [_][]const u8{ "master", "music" };
    hook.section.buses = &same;
    const third = (try hook.sync(testing.allocator)).?;
    try testing.expect(third == second);
    same[1] = "sfx";
    hook.section.buses = &same;
    const fourth = (try hook.sync(testing.allocator)).?;
    try testing.expect(fourth != third);
    try testing.expectEqualStrings("sfx", fourth.busName(1));
}

test "the pinned bus ceiling is the mixer's, both ways" {
    // The comptime check above is the real pin; this is the same fact as a
    // runtime assertion so a reader of the test list sees it.
    try testing.expectEqual(@as(usize, 16), config.max_audio_buses);
    try testing.expectEqual(@as(usize, 16), audio_mod.bus.bus_count);
}
