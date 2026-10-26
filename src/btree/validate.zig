//! Whole-tree validation for the B+Tree (ADR-0004 sections 5, 7, 10): a depth-first walk over an
//! explicit stack of at most `height_limit` frames, no recursion.
//!
//! Checks, per node: type, level (the root's is free but bounded by `height_max`; every child is
//! exactly one lower), reserved byte, every cell, strict key order, the zero gap, fill within
//! `usable` and `cell_count_max` (underfill is allowed until delete lands; only the root leaf
//! may be empty), links that never name the node itself, child ids in `1 ..< page_count`.
//! Across nodes: each child's keys lie in `[low, high)` where the bounds are the neighbouring
//! separators (a key equal to a separator lives right of it, section 5); the leaf `next` chain
//! equals the in-order leaves and ends in 0; with a visited set, every page is reached once (no
//! cycle, no shared child). Any violation is `error.Corrupted`; the page layer's typed errors
//! pass through. Overflow chains are a later item.
//! Bounds: the loop runs at most `2 * page_count + 2` steps (one push and one pop per page), so
//! a cyclic or sharing tree ends in `Corrupted` instead of looping.
//! Allocation: none here. `run` takes an optional visited bitmap (`page_count` bits, zeroed) from
//! the caller, which is how `Tree.validate` uses its `gpa`; without it (`check_invariants`)
//! sharing is still bounded by the step limit but is not named. Stack: about 70 KiB of frames.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");

const BufferPool = buffer_pool.BufferPool;
const Id = header.Id;

pub const CheckError = buffer_pool.FetchError || node.ParseError;

const key_cap = node.key_len_cap;

const Bounds = struct {
    lo: [key_cap]u8,
    hi: [key_cap]u8,
    lo_len: u16,
    hi_len: u16,
    has_lo: bool,
    has_hi: bool,

    fn set_none(self: *Bounds) void {
        assert(key_cap == node.key_len_cap);
        self.has_lo = false;
        self.has_hi = false;
        self.lo_len = 0;
        self.hi_len = 0;
    }

    fn set_lo(self: *Bounds, key: []const u8) void {
        assert(key.len <= key_cap);
        @memcpy(self.lo[0..key.len], key);
        self.lo_len = @intCast(key.len);
        self.has_lo = true;
    }

    fn set_hi(self: *Bounds, key: []const u8) void {
        assert(key.len <= key_cap);
        @memcpy(self.hi[0..key.len], key);
        self.hi_len = @intCast(key.len);
        self.has_hi = true;
    }

    /// `lo <= key < hi` where a missing bound is open.
    fn contains(self: *const Bounds, key: []const u8) bool {
        assert(self.lo_len <= key_cap and self.hi_len <= key_cap);
        assert(key.len <= key_cap);
        if (self.has_lo and std.mem.order(u8, key, self.lo[0..self.lo_len]) == .lt) return false;
        if (self.has_hi and std.mem.order(u8, key, self.hi[0..self.hi_len]) != .lt) return false;
        return true;
    }
};

const Frame = struct { id: Id, count: u16, next_child: u32, bounds: Bounds };

const Walk = struct {
    pool: *BufferPool,
    visited: ?[]u8,
    frames: [node.height_limit]Frame,
    depth: u32,
    pending: Bounds,
    prev_next: ?Id,
    have_prev: bool,
};

/// Validates the tree rooted at `root`. `visited`, when given, is `ceil(page_count / 8)` zeroed
/// bytes. Cost: O(pages) fetches, each node read in full.
pub fn run(pool: *BufferPool, io: Io, root: Id, visited: ?[]u8) CheckError!void {
    assert(root != .file_header);
    assert(pool.page_size == pool.pages.page_size);
    if (visited) |bits| assert(bits.len * 8 >= pool.pages.page_count);
    const steps_max: u64 = 2 * @as(u64, pool.pages.page_count) + 2;
    var w: Walk = undefined;
    w.pool = pool;
    w.visited = visited;
    w.depth = 0;
    w.have_prev = false;
    w.prev_next = null;
    w.pending.set_none();
    if (@intFromEnum(root) >= pool.pages.page_count) return error.Corrupted;
    try visit(&w, io, root, null);
    var finished = false;
    var step: u64 = 0;
    while (step < steps_max) : (step += 1) {
        if (w.depth == 0) {
            finished = true;
            break;
        }
        const frame = &w.frames[w.depth - 1];
        if (frame.next_child > frame.count) {
            w.depth -= 1;
            continue;
        }
        const child = try child_step(&w, io, frame);
        try visit(&w, io, child.id, child.want);
    }
    if (!finished) return error.Corrupted;
    if (w.prev_next != null) return error.Corrupted; // The last leaf ends the chain.
}

const Child = struct { id: Id, want: u8 };

/// Reads the next child of `frame`, sets `w.pending` to its key bounds and advances the frame.
fn child_step(w: *Walk, io: Io, frame: *Frame) CheckError!Child {
    assert(frame.next_child <= frame.count);
    assert(w.depth >= 1 and w.depth <= node.height_limit);
    var pinned = try w.pool.fetch(io, frame.id);
    defer pinned.release();

    const page = pinned.bytes();
    const level = page[node.offset_level];
    const view = try internal.parse_internal(page, level);
    if (view.count != frame.count) return error.Corrupted;
    const index: u16 = @intCast(frame.next_child);
    const child = try view.child_at(index);
    if (child == frame.id or @intFromEnum(child) >= w.pool.pages.page_count) {
        return error.Corrupted;
    }
    w.pending.set_none();
    if (index == 0) {
        if (frame.bounds.has_lo) w.pending.set_lo(frame.bounds.lo[0..frame.bounds.lo_len]);
    } else {
        w.pending.set_lo((try view.entry(index - 1)).key);
    }
    if (index == view.count) {
        if (frame.bounds.has_hi) w.pending.set_hi(frame.bounds.hi[0..frame.bounds.hi_len]);
    } else {
        w.pending.set_hi((try view.entry(index)).key);
    }
    frame.next_child += 1;
    assert(level >= 1); // `parse_internal` accepted the level.
    assert(frame.next_child <= frame.count + 1);
    return .{ .id = child, .want = level - 1 };
}

/// Checks node `id` and either consumes a leaf or pushes an internal node's frame.
fn visit(w: *Walk, io: Io, id: Id, level_want: ?u8) CheckError!void {
    assert(id != .file_header);
    assert(@intFromEnum(id) < w.pool.pages.page_count);
    if (w.visited) |bits| {
        const raw = @intFromEnum(id);
        const mask = @as(u8, 1) << @intCast(raw % 8);
        if (bits[@divFloor(raw, 8)] & mask != 0) return error.Corrupted; // Reached twice.
        bits[@divFloor(raw, 8)] |= mask;
    }
    var pinned = try w.pool.fetch(io, id);
    defer pinned.release();

    const page = pinned.bytes();
    if (page[node.offset_type] == @intFromEnum(header.Type.btree_leaf)) {
        return visit_leaf(w, id, page, level_want);
    }
    const level = page[node.offset_level];
    if (level_want) |want| {
        if (level != want) return error.Corrupted;
    } else if (@as(u32, level) + 1 > node.height_max(w.pool.page_size)) {
        return error.Corrupted; // A root deeper than this page size allows.
    }
    const view = try internal.parse_internal(page, level);
    try view.check_children(id);
    try view.check_invariants();
    if (view.used_bytes() > node.usable(w.pool.page_size)) return error.Corrupted;
    const first = (try view.entry(0)).key;
    const last = (try view.entry(view.count - 1)).key;
    if (!w.pending.contains(first) or !w.pending.contains(last)) return error.Corrupted;
    if (w.depth >= node.height_limit) return error.Corrupted;
    w.frames[w.depth] = .{ .id = id, .count = view.count, .next_child = 0, .bounds = w.pending };
    w.depth += 1;
    assert(w.frames[w.depth - 1].count == view.count);
}

fn visit_leaf(w: *Walk, id: Id, page: []const u8, level_want: ?u8) CheckError!void {
    assert(id != .file_header);
    assert(page.len == w.pool.page_size);
    if (level_want) |want| {
        if (want != 0) return error.Corrupted;
    }
    const leaf = try node.parse_leaf(page);
    try leaf.check_link(id);
    try leaf.check_invariants();
    if (leaf.used_bytes() > node.usable(w.pool.page_size)) return error.Corrupted;
    if (leaf.count == 0 and level_want != null) return error.Corrupted; // Only the root is empty.
    if (leaf.count > 0) {
        const first = (try leaf.entry(0)).key;
        const last = (try leaf.entry(leaf.count - 1)).key;
        if (!w.pending.contains(first) or !w.pending.contains(last)) return error.Corrupted;
    }
    if (w.have_prev) {
        if (w.prev_next != id) return error.Corrupted; // Chain differs from the in-order leaves.
    }
    w.have_prev = true;
    w.prev_next = leaf.next;
    assert(w.prev_next != id);
}
