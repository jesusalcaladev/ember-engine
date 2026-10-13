const std = @import("std");
const clip_mod = @import("clip.zig");
pub const Clip = clip_mod.Clip;

pub const Registry = struct {
    allocator: std.mem.Allocator,
    clips: std.AutoHashMap(u32, Clip),
    by_guid: std.AutoHashMap(u64, u32),
    next_id: u32 = 1,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{
            .allocator = alloc,
            .clips = std.AutoHashMap(u32, Clip).init(alloc),
            .by_guid = std.AutoHashMap(u64, u32).init(alloc),
        };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.clips.valueIterator();
        while (it.next()) |clip| clip_mod.deinitClip(self.allocator, @constCast(clip));
        self.clips.deinit();
        self.by_guid.deinit();
    }

    pub fn add(self: *Registry, clip_in: Clip) !u32 {
        var clip = clip_in;
        if (clip.id == 0) clip.id = self.next_id;
        if (clip.id == 0) return error.InvalidId;
        if (self.clips.contains(clip.id)) return error.DuplicateId;
        try self.clips.put(clip.id, clip);
        try self.by_guid.put(clip.guid, clip.id);
        if (clip.id >= self.next_id) self.next_id = clip.id + 1;
        return clip.id;
    }

    pub fn get(self: *const Registry, id: u32) ?*const Clip {
        if (id == 0) return null;
        return self.clips.getPtr(id);
    }

    pub fn getMut(self: *Registry, id: u32) ?*Clip {
        if (id == 0) return null;
        return self.clips.getPtr(id);
    }

    pub fn findByGuid(self: *const Registry, guid: u64) ?u32 {
        return self.by_guid.get(guid);
    }

    pub fn remove(self: *Registry, id: u32) void {
        if (id == 0) return;
        if (self.clips.get(id)) |clip| {
            _ = self.by_guid.remove(clip.guid);
            var mut = clip;
            clip_mod.deinitClip(self.allocator, &mut);
        }
        _ = self.clips.remove(id);
    }
};
