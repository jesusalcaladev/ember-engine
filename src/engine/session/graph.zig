//! The visual node graph: state machines and animation clips as documents.
//!
//! ## Why the graph is a document and not a pile of components
//!
//! A state machine lives in the ECS as data and it runs fine there. The problem
//! is that nobody can EDIT a pile of components: `sm.add("chase")` and the wiring
//! between "chase" and "flee" are invisible until they are wrong. A graph gives
//! the editor something to draw — nodes the user can drag, edges they can
//! reconnect, a condition they can type — and the runtime something to read.
//! This module is the document half, with no Lua and no rendering in it.
//!
//! ## What it holds
//!
//! One `Graph` is a named document of nodes and edges. A node has a kind
//! (`entry`, `state`, `clip`, `blend`, `event`), a name, a position for the
//! layout, and free parameters the runtime reads (`param_a` is a clip name or a
//! signal, `param_b` a behaviour). An edge has a kind, a condition the runtime
//! evaluates in the entity's context, and a blend weight.
//!
//! ## The positions are not a layout, they ARE the layout
//!
//! `x`/`y` are grid units chosen by whoever placed the node — the user, an
//! auto-layout pass, a template. This module never moves a node on its own,
//! which is what keeps a save file stable: an editor that re-lays-out on load
//! destroys the arrangement the user made by hand.
//!
//! ## Ids, and why they are never reused
//!
//! A node's id is a handle that survives delete-and-undo inside a session. Hand
//! them out forwards and never reuse one, because the save file has to mean the
//! same thing after an undo as it did before it.
//!
//! ## Validation
//!
//! `validate` answers the questions an editor asks before the user presses play:
//! is there an entry, is every state reachable, is there a state with no way
//! out, is a transition ambiguous. Each problem names the node or the edge, so a
//! UI underlines the offending box rather than saying "the graph is broken".

const std = @import("std");

pub const GraphError = error{
    NotFound,
    SelfEdge,
    TooManyNodes,
    TooManyEdges,
    BadFormat,
    Truncated,
};

pub const Error = error{OutOfMemory} || GraphError;

pub const NodeKind = enum {
    /// Where the machine starts. Exactly one should exist.
    entry,
    /// A named state the machine can be in.
    state,
    /// An animation clip to play.
    clip,
    /// A blend of two inputs, weighted.
    blend,
    /// Emits a signal the rest of the engine can hear.
    event,

    pub fn text(k: NodeKind) []const u8 {
        return switch (k) {
            .entry => "entry",
            .state => "state",
            .clip => "clip",
            .blend => "blend",
            .event => "event",
        };
    }
};

pub const EdgeKind = enum {
    transition,
    blend,

    pub fn text(k: EdgeKind) []const u8 {
        return switch (k) {
            .transition => "transition",
            .blend => "blend",
        };
    }
};

pub const NodeId = u32;
pub const EdgeId = u32;

pub const no_node: NodeId = std.math.maxInt(u32);
pub const no_edge: EdgeId = std.math.maxInt(u32);

pub const Node = struct {
    id: NodeId,
    kind: NodeKind,
    name: []const u8,
    /// Grid units of the editor canvas: the layout the user made.
    x: i16,
    y: i16,
    /// Free parameters. `param_a` is a clip name or a signal; `param_b` a
    /// behaviour.
    param_a: []const u8,
    param_b: []const u8,
};

pub const Edge = struct {
    id: EdgeId,
    from: NodeId,
    to: NodeId,
    kind: EdgeKind,
    /// Evaluated in the entity's context. Empty means unconditional.
    condition: []const u8,
    /// For a blend edge: how much of this input to take.
    weight: f32,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    /// The next id to hand out, never reused.
    next_node: NodeId = 1,
    next_edge: EdgeId = 1,
    /// The bounds. A state machine larger than this is not a state machine, and
    /// a bound that stops a paste is a bound that stops a runaway.
    max_nodes: usize = 4096,
    max_edges: usize = 16384,
    /// One arena for every name and condition: the document is one allocation,
    /// so a save is a memcpy and an edit is a slice rewrite.
    arena: *std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) !Graph {
        const arena = try allocator.create(std.heap.ArenaAllocator);
        arena.* = std.heap.ArenaAllocator.init(allocator);
        return Graph{
            .allocator = allocator,
            .name = try arena.allocator().dupe(u8, name),
            .arena = arena,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.arena.deinit();
        self.allocator.destroy(self.arena);
        self.* = undefined;
    }

    /// Borrowed strings live in the arena, which outlives any call that made
    /// them: a name that cannot survive an edit is a name a save file cannot
    /// write.
    fn own(self: *Graph, text: []const u8) ![]const u8 {
        return self.arena.allocator().dupe(u8, text);
    }

    pub fn node(self: *const Graph, id: NodeId) ?Node {
        for (self.nodes.items) |n| if (n.id == id) return n;
        return null;
    }

    pub fn edge(self: *const Graph, id: EdgeId) ?Edge {
        for (self.edges.items) |e| if (e.id == id) return e;
        return null;
    }

    pub fn nodeCount(self: *const Graph) usize {
        return self.nodes.items.len;
    }

    pub fn edgeCount(self: *const Graph) usize {
        return self.edges.items.len;
    }

    pub fn entryNode(self: *const Graph) ?Node {
        for (self.nodes.items) |n| if (n.kind == .entry) return n;
        return null;
    }

    pub fn outgoingCount(self: *const Graph, id: NodeId) usize {
        var n: usize = 0;
        for (self.edges.items) |e| {
            if (e.from == id) n += 1;
        }
        return n;
    }

    pub fn addNode(self: *Graph, kind: NodeKind, name: []const u8, x: i16, y: i16, param_a: []const u8, param_b: []const u8) !NodeId {
        if (self.nodes.items.len >= self.max_nodes) return error.TooManyNodes;
        const id = self.next_node;
        self.next_node += 1;
        try self.nodes.append(self.allocator, .{
            .id = id,
            .kind = kind,
            .name = try self.own(name),
            .x = x,
            .y = y,
            .param_a = try self.own(param_a),
            .param_b = try self.own(param_b),
        });
        return id;
    }

    /// Removes a node and every edge touching it. A graph whose edges outlive
    /// their endpoint is a graph with dangling references, which a restore
    /// cannot rebuild.
    pub fn removeNode(self: *Graph, id: NodeId) !void {
        var found = false;
        var i: usize = 0;
        while (i < self.nodes.items.len) {
            if (self.nodes.items[i].id == id) {
                _ = self.nodes.orderedRemove(i);
                found = true;
                break;
            }
            i += 1;
        }
        if (!found) return error.NotFound;

        var e: usize = 0;
        while (e < self.edges.items.len) {
            const link = self.edges.items[e];
            if (link.from == id or link.to == id) {
                _ = self.edges.orderedRemove(e);
                continue;
            }
            e += 1;
        }
    }

    pub fn addEdge(self: *Graph, from: NodeId, to: NodeId, kind: EdgeKind, condition: []const u8, weight: f32) !EdgeId {
        if (self.edges.items.len >= self.max_edges) return error.TooManyEdges;
        if (self.node(from) == null) return error.NotFound;
        if (self.node(to) == null) return error.NotFound;
        if (from == to) return error.SelfEdge;
        const id = self.next_edge;
        self.next_edge += 1;
        try self.edges.append(self.allocator, .{
            .id = id,
            .from = from,
            .to = to,
            .kind = kind,
            .condition = try self.own(condition),
            .weight = weight,
        });
        return id;
    }

    pub fn removeEdge(self: *Graph, id: EdgeId) !void {
        var i: usize = 0;
        while (i < self.edges.items.len) {
            if (self.edges.items[i].id == id) {
                _ = self.edges.orderedRemove(i);
                return;
            }
            i += 1;
        }
        return error.NotFound;
    }

    /// The operation a drag produces. Ids are untouched, because the layout is
    /// the editor's and a move that re-identified anything would break every
    /// edge pointing at it.
    pub fn moveNode(self: *Graph, id: NodeId, x: i16, y: i16) !void {
        for (self.nodes.items) |*n| {
            if (n.id != id) continue;
            n.x = x;
            n.y = y;
            return;
        }
        return error.NotFound;
    }

    pub fn renameNode(self: *Graph, id: NodeId, name: []const u8) !void {
        for (self.nodes.items) |*n| {
            if (n.id != id) continue;
            n.name = try self.own(name);
            return;
        }
        return error.NotFound;
    }

    pub fn setCondition(self: *Graph, id: EdgeId, condition: []const u8) !void {
        for (self.edges.items) |*e| {
            if (e.id != id) continue;
            e.condition = try self.own(condition);
            return;
        }
        return error.NotFound;
    }

    /// Is `target` reachable from `from`? A depth-first walk with an explicit
    /// stack and a seen list, bounded: a graph is allowed to have a cycle, and a
    /// cycle through a recursive walk is a stack overflow.
    pub fn reachable(self: *const Graph, from: NodeId, target: NodeId) bool {
        var stack = [_]NodeId{0} ** max_walk;
        var seen = [_]NodeId{0} ** max_walk;
        var depth: usize = 0;
        var counted: usize = 0;
        stack[depth] = from;
        depth += 1;
        while (depth > 0) {
            depth -= 1;
            const at = stack[depth];
            if (at == target) return true;
            var known = false;
            for (seen[0..counted]) |s| {
                if (s == at) known = true;
            }
            if (known) continue;
            if (counted < seen.len) {
                seen[counted] = at;
                counted += 1;
            }
            for (self.edges.items) |e| {
                if (e.from != at) continue;
                if (depth >= stack.len) return false;
                stack[depth] = e.to;
                depth += 1;
            }
        }
        return false;
    }

    // ── Validation ─────────────────────────────────────────────────────────

    pub const ProblemKind = enum {
        no_entry,
        unreachable_state,
        dead_end,
        ambiguous,
        duplicate_entry,
    };

    pub const Problem = struct {
        kind: ProblemKind,
        node: NodeId,
        edge: EdgeId,
    };

    /// Every problem found, in a fixed array the caller owns. The array is
    /// returned as a slice rather than allocated because a validation runs on
    /// every edit while the user drags a node, and one that allocated would be
    /// one that stutters.
    pub fn validate(self: *const Graph, problems: []Problem) []Problem {
        var n: usize = 0;

        const entry = self.entryNode() orelse {
            if (n < problems.len) {
                problems[n] = Problem{ .kind = .no_entry, .node = no_node, .edge = no_edge };
                n += 1;
            }
            return problems[0..n];
        };

        // Two entries: which one starts? The question has no answer a user can
        // predict, so it is a problem rather than a rule.
        var entries: usize = 0;
        for (self.nodes.items) |nd| {
            if (nd.kind != .entry) continue;
            entries += 1;
        }
        if (entries > 1 and n < problems.len) {
            problems[n] = Problem{ .kind = .duplicate_entry, .node = entry.id, .edge = no_edge };
            n += 1;
        }

        // A state nobody can reach never runs.
        for (self.nodes.items) |nd| {
            if (nd.kind == .entry) continue;
            if (self.reachable(entry.id, nd.id)) continue;
            if (n >= problems.len) break;
            problems[n] = Problem{ .kind = .unreachable_state, .node = nd.id, .edge = no_edge };
            n += 1;
        }

        // A state with no way out cannot be left.
        for (self.nodes.items) |nd| {
            if (nd.kind == .entry) continue;
            if (self.outgoingCount(nd.id) > 0) continue;
            if (n >= problems.len) break;
            problems[n] = Problem{ .kind = .dead_end, .node = nd.id, .edge = no_edge };
            n += 1;
        }

        // Two conditional transitions out of one state: both can hold, and the
        // machine takes one of them. That is a question the user cannot answer
        // by reading, which is why it is reported.
        for (self.edges.items) |a| {
            if (a.kind != .transition) continue;
            if (a.condition.len == 0) continue;
            if (n >= problems.len) break;
            for (self.edges.items) |b| {
                if (b.id == a.id) continue;
                if (b.from != a.from) continue;
                if (b.kind != .transition) continue;
                if (b.condition.len == 0) continue;
                problems[n] = Problem{ .kind = .ambiguous, .node = a.from, .edge = b.id };
                n += 1;
                if (n >= problems.len) break;
            }
        }
        return problems[0..n];
    }

    // ── Serialization ──────────────────────────────────────────────────────
    //
    // Lines with a length before every free-form text, so a name with spaces,
    // a newline or a `"` round-trips. A pretty format is for humans; this one
    /// is for a save file that must not drift.

    /// The document as bytes. A length is written before every free-form text,
    /// which is what makes a name with a space survive a round-trip.
    pub fn encode(self: *const Graph, allocator: std.mem.Allocator) ![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);

        try out.appendSlice(allocator, "zgraph 1\ngraph ");
        try appendLen(allocator, &out, self.name.len);
        try out.appendSlice(allocator, self.name);
        try out.appendSlice(allocator, "\n");

        var buf: [32]u8 = undefined;
        try out.appendSlice(allocator, "node ");
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}\n", .{self.nodes.items.len}));
        for (self.nodes.items) |nd| {
            try out.appendSlice(allocator, "node ");
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {s} {d} {d} ", .{ nd.id, nd.kind.text(), nd.x, nd.y }));
            try appendLen(allocator, &out, nd.param_a.len);
            try out.appendSlice(allocator, nd.param_a);
            try appendLen(allocator, &out, nd.param_b.len);
            try out.appendSlice(allocator, nd.param_b);
            try appendLen(allocator, &out, nd.name.len);
            try out.appendSlice(allocator, nd.name);
            try out.appendSlice(allocator, "\n");
        }

        try out.appendSlice(allocator, "edges ");
        try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d}\n", .{self.edges.items.len}));
        for (self.edges.items) |e| {
            try out.appendSlice(allocator, "edge ");
            try out.appendSlice(allocator, try std.fmt.bufPrint(&buf, "{d} {d} {d} {s} {d} ", .{
                e.id, e.from, e.to, e.kind.text(), @as(u32, @bitCast(e.weight)),
            }));
            try appendLen(allocator, &out, e.condition.len);
            try out.appendSlice(allocator, e.condition);
            try out.appendSlice(allocator, "\n");
        }
        return out.toOwnedSlice(allocator);
    }

    fn appendLen(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), len: usize) !void {
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{d}:", .{len}) catch return error.BadFormat;
        try out.appendSlice(allocator, text);
    }
};

const max_walk = 512;

/// A length-prefixed reader: the same rule the writer uses, so a document is
/// exactly what it was.
const Cursor = struct {
    text: []const u8,
    at: usize = 0,

    /// The next token. Unlike `chunk`, a token may be separated from the last
    /// one by a newline, because a token lives at the start of a line.
    fn word(c: *Cursor) []const u8 {
        while (c.at < c.text.len and (c.text[c.at] == ' ' or c.text[c.at] == '\n' or c.text[c.at] == '\r' or c.text[c.at] == '\t')) c.at += 1;
        const start = c.at;
        while (c.at < c.text.len and c.text[c.at] > ' ') c.at += 1;
        return c.text[start..c.at];
    }

    fn count(c: *Cursor) !usize {
        const w = c.word();
        return std.fmt.parseInt(usize, w, 10) catch error.BadFormat;
    }

    fn newline(c: *Cursor) !void {
        while (c.at < c.text.len and c.text[c.at] != '\n') c.at += 1;
        if (c.at < c.text.len) c.at += 1;
    }

    /// Reads `<len>:<bytes>` and returns the bytes. No whitespace is assumed
    /// between blobs — the writer puts them back to back — so the length is read
    /// from the position rather than from a word. A word reader here would see
    /// `0:0:5:start` as one token and take the first zero it found.
    fn chunk(c: *Cursor) ![]const u8 {
        while (c.at < c.text.len and (c.text[c.at] == ' ' or c.text[c.at] == '\t')) c.at += 1;
        var i: usize = c.at;
        while (i < c.text.len and c.text[i] >= '0' and c.text[i] <= '9') i += 1;
        if (i >= c.text.len or c.text[i] != ':') return error.BadFormat;
        const len = std.fmt.parseInt(usize, c.text[c.at..i], 10) catch return error.BadFormat;
        i += 1;
        if (i + len > c.text.len) return error.Truncated;
        const out = c.text[i .. i + len];
        c.at = i + len;
        return out;
    }
};

/// Reads a document back. The ids are the ones that were written, so a restored
/// graph has the same handles the editor left.
pub fn decode(allocator: std.mem.Allocator, text: []const u8) !Graph {
    var c = Cursor{ .text = text };
    const magic = c.word();
    if (!std.mem.eql(u8, magic, "zgraph")) return error.BadFormat;
    // The version, for a reader from the future: this one skips it and refuses
    // nothing, which is what a format that only ever appends can promise.
    _ = try c.count();

    const g = c.word();
    if (!std.mem.eql(u8, g, "graph")) return error.BadFormat;
    const name = try c.chunk();
    try c.newline();

    var graph = try Graph.init(allocator, name);
    errdefer graph.deinit();

    const n = c.word();
    if (!std.mem.eql(u8, n, "node")) return error.BadFormat;
    const node_count = try c.count();
    try c.newline();

    var i: usize = 0;
    while (i < node_count) : (i += 1) {
        const tag = c.word();
        if (!std.mem.eql(u8, tag, "node")) return error.BadFormat;
        const id = try c.count();
        const kind_word = c.word();
        const kind = kindFromText(kind_word) orelse return error.BadFormat;
        // Positions are signed, and the minus sign is part of the number.
        const x = std.fmt.parseInt(i16, c.word(), 10) catch return error.BadFormat;
        const y = std.fmt.parseInt(i16, c.word(), 10) catch return error.BadFormat;
        const param_a = try c.chunk();
        const param_b = try c.chunk();
        const node_name = try c.chunk();
        try c.newline();

        try graph.nodes.append(allocator, .{
            .id = @intCast(id),
            .kind = kind,
            .name = try graph.own(node_name),
            .x = x,
            .y = y,
            .param_a = try graph.own(param_a),
            .param_b = try graph.own(param_b),
        });
        if (id >= graph.next_node) graph.next_node = @intCast(id + 1);
    }

    const e = c.word();
    if (!std.mem.eql(u8, e, "edges")) return error.BadFormat;
    const edge_count = try c.count();
    try c.newline();

    i = 0;
    while (i < edge_count) : (i += 1) {
        const tag = c.word();
        if (!std.mem.eql(u8, tag, "edge")) return error.BadFormat;
        const id = try c.count();
        const from = try c.count();
        const to = try c.count();
        const kind_word = c.word();
        const kind: EdgeKind = if (std.mem.eql(u8, kind_word, "blend")) .blend else .transition;
        const weight_bits = std.fmt.parseInt(u32, c.word(), 10) catch return error.BadFormat;
        const condition = try c.chunk();
        try c.newline();

        try graph.edges.append(allocator, .{
            .id = @intCast(id),
            .from = @intCast(from),
            .to = @intCast(to),
            .kind = kind,
            .condition = try graph.own(condition),
            .weight = @bitCast(weight_bits),
        });
        if (id >= graph.next_edge) graph.next_edge = @intCast(id + 1);
    }
    return graph;
}

fn kindFromText(word: []const u8) ?NodeKind {
    if (std.mem.eql(u8, word, "entry")) return .entry;
    if (std.mem.eql(u8, word, "state")) return .state;
    if (std.mem.eql(u8, word, "clip")) return .clip;
    if (std.mem.eql(u8, word, "blend")) return .blend;
    if (std.mem.eql(u8, word, "event")) return .event;
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn testGraph() !Graph {
    var g = try Graph.init(testing.allocator, "brain");
    errdefer g.deinit();
    const entry = try g.addNode(.entry, "start", 0, 0, "", "");
    const idle = try g.addNode(.state, "idle", 40, 0, "idle_clip", "sm.idle");
    const chase = try g.addNode(.state, "chase", 40, 40, "", "");
    _ = try g.addEdge(entry, idle, .transition, "", 1.0);
    _ = try g.addEdge(idle, chase, .transition, "seen", 1.0);
    _ = try g.addEdge(chase, idle, .transition, "lost", 1.0);
    return g;
}

test "a graph is a document with ids" {
    var g = try testGraph();
    defer g.deinit();

    try testing.expectEqual(@as(usize, 3), g.nodeCount());
    try testing.expectEqual(@as(usize, 3), g.edgeCount());
    try testing.expectEqual(NodeKind.entry, g.entryNode().?.kind);
    // Ids go forward and are never reused.
    const extra = try g.addNode(.state, "idle2", 0, 0, "", "");
    try testing.expect(extra > g.entryNode().?.id);
}

test "removing a node removes its edges" {
    var g = try testGraph();
    defer g.deinit();
    try g.removeNode(3);
    try testing.expectEqual(@as(usize, 2), g.nodeCount());
    // Both edges that pointed at `chase` are gone.
    try testing.expectEqual(@as(usize, 1), g.edgeCount());
    for (g.edges.items) |e| {
        try testing.expect(e.from != 3 and e.to != 3);
    }
}

test "a self edge and an unknown node are refused" {
    var g = try testGraph();
    defer g.deinit();
    try testing.expectError(error.SelfEdge, g.addEdge(2, 2, .transition, "", 1.0));
    try testing.expectError(error.NotFound, g.addEdge(2, 999, .transition, "", 1.0));
}

test "moving a node keeps its id" {
    var g = try testGraph();
    defer g.deinit();
    try g.moveNode(2, -10, 90);
    const moved = g.node(2).?;
    try testing.expectEqual(@as(i16, -10), moved.x);
    try testing.expectEqual(@as(i16, 90), moved.y);
    // `idle` has one way out (to `chase`), and it is still there.
    try testing.expectEqual(@as(usize, 1), g.outgoingCount(2));
}

test "validation finds the questions an editor asks" {
    var g = try testGraph();
    defer g.deinit();

    var problems: [16]Graph.Problem = undefined;
    const clean = g.validate(problems[0..]);
    try testing.expectEqual(@as(usize, 0), clean.len);

    // An orphan state nobody can reach.
    _ = try g.addNode(.state, "orphan", 0, 0, "", "");
    const found = g.validate(problems[0..]);
    // Two problems, not one: the orphan is unreachable AND a dead end, and an
    // editor that stops at the first would hide the second while the user fixes
    // the first.
    try testing.expectEqual(@as(usize, 2), found.len);
    var unreachable_found = false;
    for (found) |p| {
        if (p.kind == .unreachable_state) unreachable_found = true;
    }
    try testing.expect(unreachable_found);

    // A dead end is reported next to it.
    var dead = false;
    for (found) |p| {
        if (p.kind == .dead_end) dead = true;
    }
    try testing.expect(dead);
}

test "a graph without an entry says so" {
    const a = testing.allocator;
    var g = try Graph.init(a, "headless");
    defer g.deinit();
    _ = try g.addNode(.state, "idle", 0, 0, "", "");

    var problems: [8]Graph.Problem = undefined;
    const found = g.validate(problems[0..]);
    try testing.expectEqual(@as(usize, 1), found.len);
    try testing.expectEqual(Graph.ProblemKind.no_entry, found[0].kind);
}

test "a name with spaces survives a save" {
    const a = testing.allocator;
    // The first partition failed on this: a space-separated format is a format
    // that cannot hold a name a user typed.
    var g = try Graph.init(a, "brain");
    defer g.deinit();
    _ = try g.addNode(.entry, "start \"here\" now", 0, 0, "", "");
    _ = try g.addNode(.state, "idle", 1, 0, "a clip with spaces", "");
    _ = try g.addEdge(1, 2, .transition, "x == \"y\" and seen", 1.0);

    const text = try g.encode(a);
    defer a.free(text);
    var back = try decode(a, text);
    defer back.deinit();

    try testing.expectEqualStrings("brain", back.name);
    try testing.expectEqual(@as(usize, 2), back.nodeCount());
    try testing.expectEqual(@as(usize, 1), back.edgeCount());
    try testing.expectEqualStrings("start \"here\" now", back.node(1).?.name);
    try testing.expectEqualStrings("idle", back.node(2).?.name);
    try testing.expectEqualStrings("a clip with spaces", back.node(2).?.param_a);
    try testing.expectEqualStrings("x == \"y\" and seen", back.edge(1).?.condition);
}

test "a save and a restore give the same graph, not a similar one" {
    const a = testing.allocator;
    var g = try testGraph();
    defer g.deinit();

    const text = try g.encode(a);
    defer a.free(text);
    var back = try decode(a, text);
    defer back.deinit();

    try testing.expectEqual(g.nodeCount(), back.nodeCount());
    try testing.expectEqual(g.edgeCount(), back.edgeCount());
    // The ids are the ones that were written: a handle in the editor keeps
    // meaning the same node after a load.
    try testing.expectEqual(@as(NodeId, 1), back.entryNode().?.id);
    const both = try back.encode(a);
    defer a.free(both);
    try testing.expectEqualSlices(u8, text, both);
}

test "a document that is not a graph is refused, not half read" {
    const a = testing.allocator;
    try testing.expectError(error.BadFormat, decode(a, "not a graph at all"));
    // A length that runs past the end of the file is a truncated document, and
    // it is refused rather than half read: a graph missing a name is a graph
    // whose save is broken, not one to guess at.
    try testing.expectError(error.Truncated, decode(a, "zgraph 1\ngraph 9:brain\n"));
    // A missing marker is a different refusal: the document stopped too early.
    try testing.expectError(error.BadFormat, decode(a, "zgraph 1\ngraph 5:brain\nnode 0\n"));
}

