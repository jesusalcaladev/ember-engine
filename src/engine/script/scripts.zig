//! Script cache + hot-reload (ROADMAP M3: "hot-reload < 100 ms without losing
//! state, migrate the `self` table").
//!
//! The object model that makes state-preserving reload almost free:
//!
//! - A **script** is a chunk that returns a *prototype* table (its methods and
//!   defaults). `load` compiles it once and keeps a registry ref to the
//!   prototype.
//! - A **behavior instance** is a `self` table. Every `self` of a given script
//!   shares ONE metatable whose `__index` is that script's prototype. So
//!   `self:update(dt)` resolves `update` on the prototype, while `self.speed`
//!   (per-instance state) lives on `self` itself.
//! - **Hot-reload** recompiles the source into a NEW prototype and repoints the
//!   shared metatable's `__index` at it. Every live `self` instantly sees the
//!   new methods and keeps its own fields — no copying, no migration pass, no
//!   lost state. It is O(1) in the number of instances, which is why "migrate
//!   the `self` table" costs nothing here: the `self` tables are never touched.
//!
//! Instance overrides survive a reload on purpose: if a prototype field is
//! `speed = 100` and an instance set `self.speed = 50`, the reloaded prototype
//! may say `speed = 200` but the instance still reads 50 (its own field wins
//! over `__index`). That is exactly the "editing during play reflects instantly
//! but the run's state is safe" contract the roadmap wants.

const std = @import("std");
const vm_mod = @import("vm.zig");
const lua = @import("luajit.zig");

const Vm = vm_mod.Vm;
const no_ref = vm_mod.no_ref;

/// A dense, stable id for a loaded script. Stored in the serializable `Script`
/// component so a scene can reference "the behavior in player.lua" without
/// embedding VM refs (which are meaningless across save/load).
pub const ScriptId = u32;

pub const Scripts = struct {
    vm: *Vm,
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    by_name: std.StringHashMapUnmanaged(ScriptId) = .{},

    const Entry = struct {
        /// Owned copy of the script name (map key + error messages).
        name: []u8,
        /// Registry ref to the prototype table (the chunk's return value).
        prototype_ref: i32,
        /// Registry ref to the shared metatable (`__index` = prototype).
        metatable_ref: i32,
    };

    pub const Error = error{ LoadFailed, RuntimeError, OutOfMemory } || Vm.Error;

    pub fn init(vm: *Vm, allocator: std.mem.Allocator) Scripts {
        return .{ .vm = vm, .allocator = allocator };
    }

    pub fn deinit(self: *Scripts) void {
        for (self.entries.items) |*e| {
            self.vm.unref(e.prototype_ref);
            self.vm.unref(e.metatable_ref);
            self.allocator.free(e.name);
        }
        self.entries.deinit(self.allocator);
        var it = self.by_name.iterator();
        while (it.next()) |kv| self.allocator.free(kv.key_ptr.*);
        self.by_name.deinit(self.allocator);
    }

    /// Number of loaded scripts (diagnostics).
    pub fn count(self: *const Scripts) usize {
        return self.entries.items.len;
    }
    /// Loads (or reloads) `name` from `source`. First call compiles and caches;
    /// a later call with the same name is a hot-reload: it recompiles, swaps the
    /// prototype behind the shared metatable and returns the SAME id, so every
    /// instance bound to that id keeps running with its state intact.
    pub fn load(self: *Scripts, name: []const u8, source: []const u8) Error!ScriptId {
        if (self.by_name.get(name)) |id| return self.reloadById(id, source);
        return self.loadNew(name, source);
    }

    fn loadNew(self: *Scripts, name: []const u8, source: []const u8) Error!ScriptId {
        const proto_ref = try self.compilePrototype(name, source);
        errdefer self.vm.unref(proto_ref);

        const mt_ref = try self.makeMetatable(proto_ref);
        errdefer self.vm.unref(mt_ref);

        const owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned);

        const id: ScriptId = @intCast(self.entries.items.len);
        try self.entries.append(self.allocator, .{
            .name = owned,
            .prototype_ref = proto_ref,
            .metatable_ref = mt_ref,
        });
        // The map owns its own copy of the key so it outlives any caller slice.
        const key = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(key);
        try self.by_name.put(self.allocator, key, id);
        return id;
    }

    /// Recompiles `source` and repoints the shared metatable at the new
    /// prototype. O(1): instances are never visited, so their state is safe by
    /// construction. Returns the same id for chaining.
    pub fn reloadById(self: *Scripts, id: ScriptId, source: []const u8) Error!ScriptId {
        if (id >= self.entries.items.len) return error.LoadFailed;
        var entry = &self.entries.items[id];

        const new_proto = try self.compilePrototype(entry.name, source);
        // Repoint the shared metatable's __index at the new prototype.
        const L = self.vm.state().?;
        self.vm.pushRef(entry.metatable_ref); // push metatable
        self.vm.pushRef(new_proto); // push new prototype
        lua.setField(L, -2, "__index"); // metatable.__index = new_proto (pops proto)
        lua.pop(L, 1); // pop metatable

        self.vm.unref(entry.prototype_ref); // old prototype is now unreferenced
        entry.prototype_ref = new_proto;
        return id;
    }

    /// Hot-reloads by name (what the editor's "reload script" action calls).
    pub fn reload(self: *Scripts, name: []const u8, source: []const u8) Error!void {
        const id = self.by_name.get(name) orelse return self.loadNew(name, source) catch return error.LoadFailed;
        try self.reloadById(id, source);
    }

    /// Compiles `source` as a chunk, runs it, refs the returned prototype table
    /// and returns the ref (the table is popped). Load-time only.
    fn compilePrototype(self: *Scripts, name: []const u8, source: []const u8) Error!i32 {
        const L = self.vm.state().?;
        // A null-terminated chunk name for Lua's error messages.
        var name_buf: [256]u8 = undefined;
        const nname = @min(name.len, name_buf.len - 1);
        @memcpy(name_buf[0..nname], name[0..nname]);
        name_buf[nname] = 0;
        const cname: [*:0]const u8 = @ptrCast(&name_buf);

        self.vm.loadBuffer(source, cname) catch |e| {
            lua.pop(L, 1); // the compile error message
            return e;
        };
        self.vm.callPrototype() catch |e| return e; // runs chunk, leaves prototype
        return self.vm.refTop(); // ref + pop prototype
    }

    /// Creates a metatable `{ __index = prototype }` and refs it. Shared by all
    /// instances of the script so a reload is one write, not N.
    fn makeMetatable(self: *Scripts, prototype_ref: i32) Error!i32 {
        const L = self.vm.state().?;
        _ = lua.lua_createtable(L, 0, 1); // metatable
        self.vm.pushRef(prototype_ref); // push prototype
        lua.setField(L, -2, "__index"); // mt.__index = prototype (pops proto)
        return self.vm.refTop(); // ref + pop metatable
    }

    /// Creates a fresh `self` table with this script's shared metatable and
    /// leaves it on top of the stack. The caller stamps the entity handle into
    /// it and refs it. One table allocation; instantiation happens at load or
    /// on an explicit spawn, never in the frame loop.
    pub fn instantiate(self: *Scripts, id: ScriptId) void {
        const L = self.vm.state().?;
        _ = lua.lua_createtable(L, 0, 0); // self
        self.vm.pushRef(self.entries.items[id].metatable_ref); // push metatable
        _ = lua.lua_setmetatable(L, -2); // set on self (pops metatable)
    }

    /// The prototype ref for a script (tests + behavior method-cache warm-up).
    pub fn prototypeRef(self: *const Scripts, id: ScriptId) i32 {
        return self.entries.items[id].prototype_ref;
    }

    /// Resolves a script name to its id, or null.
    pub fn idOf(self: *const Scripts, name: []const u8) ?ScriptId {
        return self.by_name.get(name);
    }
};

