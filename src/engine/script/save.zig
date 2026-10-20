//! Saving and loading a game.
//!
//! ## What the developer saves
//!
//! Not "the world" — **what THEY want**. A save is a set of ACTORS, chosen by
//! name, serialized with the same bit-exact format the editor uses. A game
//! saves the player, the coins and the score; it does not save the camera, the
//! lights or the tilemap, because those are rebuilt from the scene.
//!
//! ```lua
//! save.save("slot1")                                  -- everything
//! save.save("slot1", { only = { "player", "coin3" } })  -- just these
//! save.save("slot1", { exclude = { "camera" } })
//! ```
//!
//! ## The encryption
//!
//! Optional, and a PASSWORD rather than a key: the developer types a password
//! and the engine derives the key from it. A save encrypted with a key stored
//! NEXT to it is not encrypted.
//!
//! The scheme is **AES-256-GCM** with the key derived by **PBKDF2-HMAC-SHA256**
//! (100 000 rounds) from the password and a random per-file salt. GCM is
//! authenticated, so a tampered save is REFUSED rather than decrypted into
//! garbage — and the salt and the slot name are authenticated as the
//! associated data, so a file cannot be moved from one slot to another.
//!
//! A save with no password is written in the clear, and the file says so in
//! its header: a developer who forgets the password gets a clear error
//! instead of a decryption failure.

const std = @import("std");
const ecs = @import("ecs");
const core = @import("core");
const platform = @import("platform");

const components = ecs.components;

/// The magic at the head of every save file. A file that does not start with
/// it is not a save.
const magic = "EMBSAVE1";
const magic_len = magic.len;
const salt_len = 16;
const nonce_len = 12;
const tag_len = 16;
/// The key length AES-256-GCM wants.
const key_len = 32;
/// The PBKDF2 rounds. High enough to make an offline attack expensive, low
/// enough that a load does not stall the frame.
const kdf_rounds = 100_000;

/// The flags byte in the header.
const flag_encrypted: u8 = 1;

pub const Error = error{
    /// The slot name is empty, or has a path in it.
    BadSlot,
    /// The file is not a save (the magic does not match).
    NotASave,
    /// The save is encrypted and no password was given.
    PasswordRequired,
    /// The save is encrypted and the password is wrong.
    WrongPassword,
    /// The save is plain and a password was given.
    NotEncrypted,
    /// The save was tampered with.
    Corrupted,
};

/// What to save and how.
pub const Options = struct {
    /// The actors to save, by name. Null = every actor.
    only: ?[]const []const u8 = null,
    /// The actors to LEAVE OUT, by name.
    exclude: ?[]const []const u8 = null,
    /// The password. Null = the save is written in the clear.
    password: ?[]const u8 = null,
};

/// One slot on disk.
pub const Slot = struct {
    name: []const u8,
    /// Whether the save is encrypted.
    encrypted: bool,
    /// The size on disk, in bytes.
    size: u64,
};

/// Fills a buffer with bytes from the kernel's random source.
fn randomBytes(buf: []u8) void {
    // The kernel's pool. A failure here is not recoverable — a save whose
    // nonce is predictable is not encrypted — so it panics rather than
    // continuing with a weak value.
    const rc = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    if (rc != buf.len) std.debug.panic("save: the kernel gave {d} of {d} random bytes", .{ rc, buf.len });
}

/// The save manager: the directory the saves live in, and the file format.
pub const Manager = struct {
    allocator: std.mem.Allocator,
    /// The directory the saves live in, relative to the project root.
    dir: []const u8,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) Manager {
        return .{ .allocator = allocator, .io = io, .dir = dir };
    }

    /// The manager owns nothing but the directory name, so there is nothing to
    /// release: the file system is not a resource this holds.
    pub fn deinit(self: *Manager) void {
        self.* = undefined;
    }

    /// The path of a slot's file.
    fn pathFor(self: *const Manager, slot: []const u8, buf: []u8) ![]const u8 {
        if (slot.len == 0) return Error.BadSlot;
        // A slot is a NAME, not a path: a slot called "../../etc/passwd" must
        // not be able to write outside the saves directory.
        for (slot) |c| {
            if (c == '/' or c == '\\' or c == ':') return Error.BadSlot;
        }
        const written = try std.fmt.bufPrint(buf, "{s}/{s}.ember-save", .{ self.dir, slot });
        return written;
    }

    /// Whether a slot exists.
    pub fn exists(self: *const Manager, slot: []const u8) bool {
        var buf: [512]u8 = undefined;
        const path = self.pathFor(slot, &buf) catch return false;
        const file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch return false;
        file.close(self.io);
        return true;
    }

    /// Saves the world.
    ///
    /// `opts.only` names the actors to save; `opts.exclude` names the ones to
    /// leave out. With neither, EVERY actor is saved.
    pub fn save(self: *const Manager, world: *ecs.World, slot: []const u8, opts: Options) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.pathFor(slot, &path_buf);

        // The actors, filtered.
        var entities = std.ArrayList(ecs.Entity).empty;
        defer entities.deinit(self.allocator);
        {
            var q = world.query(.{components.Transform});
            while (q.next()) |r| {
                const e = r.entity();
                if (!self.wanted(world, e, opts)) continue;
                try entities.append(self.allocator, e);
            }
        }

        const text = try ecs.zson.encodeToStringEntities(world, entities.items, self.allocator);
        defer self.allocator.free(text);

        // The file: the header, then the payload.
        const payload = try self.encrypt(text, slot, opts);
        defer self.allocator.free(payload);

        std.Io.Dir.cwd().createDirPath(self.io, self.dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        var file = try std.Io.Dir.cwd().createFile(self.io, path, .{});
        defer file.close(self.io);
        try std.Io.File.writeStreamingAll(file, self.io, payload);
    }

    /// Loads a slot into the world.
    pub fn load(self: *const Manager, world: *ecs.World, slot: []const u8, opts: Options) !void {
        var path_buf: [512]u8 = undefined;
        const path = try self.pathFor(slot, &path_buf);
        const raw = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(64 * 1024 * 1024)) catch
            return Error.NotASave;
        defer self.allocator.free(raw);

        const text = try self.decrypt(raw, slot, opts);
        defer self.allocator.free(text);
        try ecs.zson.replace(world, text);
    }

    /// The slots on disk, sorted by name.
    pub fn listSlots(self: *const Manager, out: *std.ArrayList(Slot)) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.dir, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var it = dir.iterate();
        while (try it.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".ember-save")) continue;
            const name = entry.name[0 .. entry.name.len - ".ember-save".len];
            var size: u64 = 0;
            if (std.Io.Dir.cwd().statFile(self.io, entry.name, .{})) |st| {
                size = st.size;
            } else |_| {}
            try out.append(self.allocator, .{
                .name = name,
                .encrypted = false,
                .size = size,
            });
        }
    }

    /// Deletes a slot.
    pub fn delete(self: *const Manager, slot: []const u8) !bool {
        var path_buf: [512]u8 = undefined;
        const path = try self.pathFor(slot, &path_buf);
        std.Io.Dir.cwd().deleteFile(self.io, path) catch return false;
        return true;
    }

    /// Whether an actor is one of the ones to save.
    fn wanted(_: *const Manager, world: *ecs.World, e: ecs.Entity, opts: Options) bool {
        const name = if (world.get(e, components.Name)) |n| n.slice() else "";
        if (opts.only) |list| {
            for (list) |want| {
                if (std.mem.eql(u8, want, name)) return true;
            }
            return false;
        }
        if (opts.exclude) |list| {
            for (list) |skip| {
                if (std.mem.eql(u8, skip, name)) return false;
            }
        }
        return true;
    }

    /// The file's bytes: the header, then the payload (encrypted or not).
    fn encrypt(self: *const Manager, text: []const u8, slot: []const u8, opts: Options) ![]u8 {
        const password = opts.password orelse {
            // Plain: the magic, the flags, the text.
            const out = try self.allocator.alloc(u8, magic_len + 1 + text.len);
            @memcpy(out[0..magic_len], magic);
            out[magic_len] = 0;
            @memcpy(out[magic_len + 1 ..], text);
            return out;
        };

        // The salt and the nonce come from the KERNEL, never from the
        // engine's PRNG: the PRNG is deterministic on purpose (the replays
        // depend on it), and a save's salt must not be predictable.
        var salt: [salt_len]u8 = undefined;
        randomBytes(&salt);
        var nonce: [nonce_len]u8 = undefined;
        randomBytes(&nonce);

        var key: [key_len]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&key, password, &salt, kdf_rounds, std.crypto.auth.hmac.sha2.HmacSha256);

        var tag: [tag_len]u8 = undefined;
        const out = try self.allocator.alloc(u8, magic_len + 1 + salt_len + nonce_len + tag_len + text.len);
        @memcpy(out[0..magic_len], magic);
        out[magic_len] = flag_encrypted;
        @memcpy(out[magic_len + 1 ..][0..salt_len], &salt);
        @memcpy(out[magic_len + 1 + salt_len ..][0..nonce_len], &nonce);
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(
            out[magic_len + 1 + salt_len + nonce_len + tag_len ..],
            &tag,
            text,
            slot,
            nonce,
            key,
        );
        @memcpy(out[magic_len + 1 + salt_len + nonce_len ..][0..tag_len], &tag);
        return out;
    }

    /// The file's bytes back into the save's text.
    fn decrypt(self: *const Manager, raw: []const u8, slot: []const u8, opts: Options) ![]u8 {
        if (raw.len < magic_len + 1) return Error.NotASave;
        if (!std.mem.eql(u8, raw[0..magic_len], magic)) return Error.NotASave;
        const flags = raw[magic_len];
        const encrypted = (flags & flag_encrypted) != 0;

        if (!encrypted) {
            if (opts.password != null) return Error.NotEncrypted;
            const text = try self.allocator.alloc(u8, raw.len - magic_len - 1);
            @memcpy(text, raw[magic_len + 1 ..]);
            return text;
        }

        const password = opts.password orelse return Error.PasswordRequired;
        if (raw.len < magic_len + 1 + salt_len + nonce_len + tag_len) return Error.NotASave;
        const salt: [salt_len]u8 = raw[magic_len + 1 ..][0..salt_len].*;
        const nonce: [nonce_len]u8 = raw[magic_len + 1 + salt_len ..][0..nonce_len].*;
        const tag: [tag_len]u8 = raw[magic_len + 1 + salt_len + nonce_len ..][0..tag_len].*;
        const cipher = raw[magic_len + 1 + salt_len + nonce_len + tag_len ..];

        var key: [key_len]u8 = undefined;
        try std.crypto.pwhash.pbkdf2(&key, password, &salt, kdf_rounds, std.crypto.auth.hmac.sha2.HmacSha256);

        const text = try self.allocator.alloc(u8, cipher.len);
        errdefer self.allocator.free(text);
        // A wrong password and a tampered file are the SAME failure: GCM
        // cannot tell them apart, and it must not: saying "wrong password" for a
        // tampered file would tell an attacker which one they managed.
        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(text, cipher, tag, slot, nonce, key) catch return Error.WrongPassword;
        return text;
    }
};
