//! B+Tree insert that splits (ADR-0004 sections 8, 9, 10): a leaf that cannot take the edit is
//! split, the separator goes into the parent, and full ancestors split in turn up an explicit,
//! bounded path (no recursion; at most `height_max` levels). A root split keeps the root id.
//!
//! Prepare (may fail, changes no byte of the tree): pin the leaf and the ancestors that will
//! change, plan every split by bytes (`split.split_point`, working on a copy of the node), check
//! `HeightLimit`, then allocate and pin the new pages. A failure here (`HeightLimit`,
//! `PoolExhausted`, `NoSpaceLeft`, a read error, `Corrupted`) leaves every existing page as it
//! was (prepare runs `check_invariants` on the leaf and on every ancestor it will rebuild or
//! edit, and checks that each separator sorts strictly between its future neighbours, so apply
//! has no data-dependent failure left); new pages already allocated are formatted as empty
//! leaves, unreachable and leaked, which ADR-0002 calls safe.
//! Apply: rebuild each split node from the work copy, bottom up, then edit
//! the parent or the root. Everything it reads was verified in prepare, so its `Corrupted`
//! returns are defensive only (a page changing under a held pin, which cannot happen); they
//! are the one place an unlogged split could fail half way.
//! Pins: up to `2 * height_max + 1`, the ADR's pool floor.
//! Allocation: none (state lives on the stack, about 90 KiB); ids come from the page manager.
//! Page lsns are carried over unchanged: this stage is unlogged.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const split = @import("split.zig");
const descend = @import("descend.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const Id = header.Id;
const Path = descend.Path;

pub const SplitError = buffer_pool.FetchError || buffer_pool.FetchNewError ||
    manager.AllocateError || node.ParseError || error{HeightLimit};

const levels_max: u32 = node.height_limit;
const pins_max: u32 = 2 * levels_max + 1;

const Pins = struct {
    guards: [pins_max]PageGuard,
    len: u32,

    fn push(self: *Pins, pinned: PageGuard) void {
        assert(self.len < pins_max);
        self.guards[self.len] = pinned;
        self.len += 1;
    }

    fn release_all(self: *Pins) void {
        assert(self.len <= pins_max);
        for (0..self.len) |index| self.guards[index].release();
        self.len = 0;
    }
};

const Step = struct { at: u16, point: u16, sep_len: u16, left: Id, right: Id };

const Split = struct {
    pool: *BufferPool,
    path: *const Path,
    leaf: *PageGuard,
    key: []const u8,
    value: []const u8,
    found: bool,
    at_leaf: u16,
    leaf_bytes: u32,
    ancestors: Pins,
    fresh: Pins,
    steps: [levels_max]Step,
    seps: [levels_max][node.key_len_cap]u8,
    splits: u8,
    root_split: bool,
    work: [header.page_size_max]u8,

    /// The pinned existing node `j` levels above the leaf.
    fn old(self: *Split, j: u32) *PageGuard {
        assert(j <= self.path.len);
        if (j == 0) return self.leaf;
        assert(j <= self.ancestors.len);
        return &self.ancestors.guards[j - 1];
    }

    fn sep(self: *const Split, j: u32) []const u8 {
        assert(j < self.splits);
        return self.seps[j][0..self.steps[j].sep_len];
    }
};

/// Splits the full leaf and fixes the ancestors. `leaf` is the descent's pinned writable leaf
/// (the caller releases it); `slot` is where `key` goes (found: it replaces the old cell);
/// `leaf_bytes` is the encoded size of the new cell. Precondition: the leaf cannot take the
/// edit in place. Postcondition: `key` is in the tree, the root id is unchanged.
pub fn insert_split(
    pool: *BufferPool,
    io: Io,
    path: *const Path,
    leaf: *PageGuard,
    slot: node.Slot,
    key: []const u8,
    value: []const u8,
    leaf_bytes: u32,
) SplitError!void {
    assert(leaf_bytes >= 2 and leaf_bytes <= node.cell_bytes_max(pool.page_size));
    assert(key.len <= node.key_len_max(pool.page_size));
    var s: Split = undefined;
    s.pool = pool;
    s.path = path;
    s.leaf = leaf;
    s.key = key;
    s.value = value;
    s.found = slot.found;
    s.at_leaf = slot.index;
    s.leaf_bytes = leaf_bytes;
    s.ancestors.len = 0;
    s.fresh.len = 0;
    defer s.ancestors.release_all();
    defer s.fresh.release_all();

    try plan(&s, io);
    try acquire(&s, io);
    try apply(&s);
}

/// Prepare, part 1: decide which levels split (bottom up), their split points and separators.
fn plan(s: *Split, io: Io) SplitError!void {
    assert(s.path.len < node.height_limit);
    assert(s.ancestors.len == 0);
    const page_size = s.pool.page_size;
    try plan_leaf(s);
    s.splits = 1;
    s.root_split = false;
    for (1..@as(u32, s.path.len) + 1) |j| {
        const at_index = s.path.len - j;
        const pinned = try s.pool.fetchForUpdate(io, s.path.ids[at_index]);
        s.ancestors.push(pinned);
        if (!try plan_internal(s, @intCast(j))) return;
        s.splits += 1;
    }
    s.root_split = true; // Every node up to the root splits.
    if (@as(u32, s.path.len) + 2 > node.height_max(page_size)) return error.HeightLimit;
}

fn plan_leaf(s: *Split) SplitError!void {
    const page_size = s.pool.page_size;
    const page = s.leaf.bytes();
    const view = try node.parse_leaf(page);
    if (s.path.len == 0 and view.next != null) return error.Corrupted; // The root has no peer.
    assert(s.at_leaf <= view.count);
    try view.check_invariants(); // Every cell and the order of all of them, not just near the slot.
    const work = s.work[0..page_size];
    @memcpy(work, page);
    if (s.found) try node.leaf_remove(work, s.at_leaf);
    const point = try split.split_point(work, s.leaf_bytes, s.at_leaf);
    const parsed = try node.parse_leaf(work);
    const at: u32 = s.at_leaf;
    var key = s.key;
    if (point != at) key = (try parsed.entry(@intCast(virtual_index(at, point)))).key;
    assert(key.len <= node.key_len_max(page_size));
    assert(point >= 1 and point <= parsed.count);
    @memcpy(s.seps[0][0..key.len], key);
    s.steps[0] = .{
        .at = s.at_leaf,
        .point = point,
        .sep_len = @intCast(key.len),
        .left = s.path.leaf,
        .right = s.path.leaf,
    };
}

/// Index of virtual cell `v` among the stored cells when the incoming cell sits at `at`.
fn virtual_index(at: u32, v: u32) u32 {
    assert(v != at);
    return if (v < at) v else v - 1;
}

/// Plans ancestor `j` (j levels above the leaf); true when it must split too.
fn plan_internal(s: *Split, j: u32) SplitError!bool {
    assert(j >= 1 and j <= s.path.len);
    const page_size = s.pool.page_size;
    const index = s.path.len - j;
    const page = s.old(j).bytes();
    const level = page[node.offset_level];
    const view = try internal.parse_internal(page, level);
    try view.check_children(s.path.ids[index]);
    try view.check_invariants(); // All cells and their order: apply re-inserts every one.
    const below = s.sep(@intCast(j - 1));
    const below_len: u32 = @intCast(below.len);
    const size: u32 = codec.varint.encoded_size(below_len) + below_len + 4;
    const at: u32 = s.path.slots[index];
    assert(at <= view.count);
    // The separator must sort strictly between the cells that will border it, else the
    // insert (or the rebuild) would fail after the first byte moved.
    if (at > 0 and std.mem.order(u8, (try view.entry(@intCast(at - 1))).key, below) != .lt) {
        return error.Corrupted;
    }
    if (at < view.count and std.mem.order(u8, below, (try view.entry(@intCast(at))).key) != .lt) {
        return error.Corrupted;
    }
    const used = view.used_bytes() + size + node.slot_size;
    if (view.count < node.cell_count_max(page_size) and used <= node.usable(page_size)) {
        return false;
    }
    const point = try split.split_point(page, size, @intCast(at));
    var key = below;
    if (point != at) key = (try view.entry(@intCast(virtual_index(at, point)))).key;
    assert(key.len <= node.key_len_max(page_size));
    assert(point >= 1 and point <= view.count);
    @memcpy(s.seps[j][0..key.len], key);
    s.steps[j] = .{
        .at = @intCast(at),
        .point = point,
        .sep_len = @intCast(key.len),
        .left = s.path.ids[index],
        .right = s.path.ids[index],
    };
    return true;
}

/// Prepare, part 2: allocate and pin the new pages (one per split, one more for a root split).
/// Each is formatted at once as an empty leaf, so a later failure leaves a legal, leaked page.
fn acquire(s: *Split, io: Io) SplitError!void {
    const needed: u32 = @as(u32, s.splits) + @intFromBool(s.root_split);
    assert(needed >= 1 and needed <= pins_max);
    for (0..needed) |_| {
        const id = try s.pool.pages.allocate(io);
        var pinned = try s.pool.fetchNew(io, id);
        node.format_leaf(pinned.bytes_mut(), id, null, 0);
        s.fresh.push(pinned);
    }
    for (0..s.splits) |j| {
        const root_level = s.root_split and j + 1 == s.splits;
        const step = &s.steps[j];
        step.left = if (root_level) s.fresh.guards[j].id() else step.left;
        step.right = if (root_level) s.fresh.guards[j + 1].id() else s.fresh.guards[j].id();
        assert(step.left != step.right);
    }
}

/// Apply: cannot fail on a well-formed tree; see the file doc for what a lie would leave.
fn apply(s: *Split) SplitError!void {
    assert(s.splits >= 1 and s.splits <= s.path.len + 1);
    assert(s.fresh.len == @as(u32, s.splits) + @intFromBool(s.root_split));
    for (0..s.splits) |j| {
        const root_level = s.root_split and j + 1 == s.splits;
        const source = s.old(@intCast(j));
        const lsn = header.peek(source.bytes()).lsn;
        @memcpy(s.work[0..s.pool.page_size], source.bytes());
        const left = if (root_level) &s.fresh.guards[j] else source;
        const right = if (root_level) &s.fresh.guards[j + 1] else &s.fresh.guards[j];
        const left_page = left.bytes_mut();
        const right_page = right.bytes_mut();
        if (j == 0) {
            try build_leaf(s, left_page, right_page, lsn);
        } else {
            try build_internal(s, @intCast(j), left_page, right_page, lsn);
        }
    }
    const top: u32 = s.splits;
    if (s.root_split) return finish_root(s, top - 1);
    assert(top <= s.path.len); // A non-root split has a parent that absorbs the separator.
    return finish_parent(s, top);
}

fn build_leaf(s: *Split, left: []u8, right: []u8, lsn: u64) SplitError!void {
    assert(left.len == s.pool.page_size and right.len == left.len);
    assert(s.splits >= 1);
    const step = s.steps[0];
    const work = s.work[0..s.pool.page_size];
    if (s.found) try node.leaf_remove(work, step.at);
    const view = try node.parse_leaf(work);
    node.format_leaf(left, step.left, step.right, lsn);
    node.format_leaf(right, step.right, view.next, lsn);
    const total: u32 = @as(u32, view.count) + 1;
    assert(total <= node.cell_count_max(s.pool.page_size) + 1);
    for (0..total) |u| {
        const entry: node.Entry = if (u == step.at)
            .{ .key = s.key, .value = .{ .bytes = s.value } }
        else
            try view.entry(@intCast(virtual_index(step.at, @intCast(u))));
        const to_left = u < step.point;
        const index: u16 = @intCast(if (to_left) u else u - step.point);
        const target = if (to_left) left else right;
        node.leaf_insert(target, index, entry.key, entry.value) catch |err| switch (err) {
            error.NodeFull, error.Corrupted => return error.Corrupted, // Checked in prepare.
        };
    }
    node.seal(left, step.left, lsn);
    node.seal(right, step.right, lsn);
    assert((try node.parse_leaf(left)).count == step.point);
    assert((try node.parse_leaf(right)).count == total - step.point);
}

/// Virtual cell `u` of internal level `j`: the child's separator at `at`, the stored cells
/// around it, and the stored cell `at` pointing at the child's new right half.
fn internal_cell(
    s: *const Split,
    view: internal.Internal,
    j: u32,
    u: u32,
) SplitError!internal.InternalEntry {
    assert(j >= 1 and j < s.splits);
    assert(u <= view.count);
    const step = s.steps[j];
    const below = s.steps[j - 1];
    if (u == step.at) return .{ .key = s.sep(@intCast(j - 1)), .child = below.left };
    const stored = try view.entry(@intCast(virtual_index(step.at, u)));
    const replaced = virtual_index(step.at, u) == step.at;
    return .{ .key = stored.key, .child = if (replaced) below.right else stored.child };
}

fn build_internal(s: *Split, j: u32, left: []u8, right: []u8, lsn: u64) SplitError!void {
    assert(j >= 1 and j < s.splits);
    assert(left.len == s.pool.page_size and right.len == left.len);
    const step = s.steps[j];
    const work = s.work[0..s.pool.page_size];
    const level = work[node.offset_level];
    const view = try internal.parse_internal(work, level);
    const total: u32 = @as(u32, view.count) + 1;
    assert(step.point >= 1 and step.point + 1 < total);
    const middle = try internal_cell(s, view, j, step.point);
    const last_child = if (step.at == view.count) s.steps[j - 1].right else view.right_child;
    internal.format_internal(left, step.left, level, middle.child, lsn);
    internal.format_internal(right, step.right, level, last_child, lsn);
    for (0..total) |u| {
        if (u == step.point) continue;
        const cell = try internal_cell(s, view, j, @intCast(u));
        const to_left = u < step.point;
        const index: u16 = @intCast(if (to_left) u else u - step.point - 1);
        const target = if (to_left) left else right;
        internal.internal_insert(target, index, cell.key, cell.child) catch |err| switch (err) {
            error.NodeFull, error.Corrupted => return error.Corrupted, // Checked in prepare.
        };
    }
    node.seal(left, step.left, lsn);
    node.seal(right, step.right, lsn);
    assert((try internal.parse_internal(left, level)).count == step.point);
    assert((try internal.parse_internal(right, level)).count == total - step.point - 1);
}

/// The root (level `top`) split into two new pages: it becomes internal one level higher.
fn finish_root(s: *Split, top: u32) SplitError!void {
    assert(s.root_split and top + 1 == s.splits);
    assert(top == s.path.len);
    const step = s.steps[top];
    const root_guard = s.old(top);
    const lsn = header.peek(root_guard.bytes()).lsn;
    const level_old: u8 = if (top == 0) 0 else root_guard.bytes()[node.offset_level];
    assert(level_old + 2 <= node.height_max(s.pool.page_size));
    const page = root_guard.bytes_mut();
    const root_id = s.path.ids[0];
    internal.format_internal(page, root_id, level_old + 1, step.right, lsn);
    internal.internal_insert(page, 0, s.sep(@intCast(top)), step.left) catch {
        return error.Corrupted; // A fresh node always has room for one cell.
    };
    node.seal(page, root_id, lsn);
    assert((try internal.parse_internal(page, level_old + 1)).count == 1);
}

/// The first non-splitting ancestor takes the separator of the node below it.
fn finish_parent(s: *Split, top: u32) SplitError!void {
    assert(top >= 1 and top <= s.path.len);
    const below = s.steps[top - 1];
    const index = s.path.len - top;
    const parent = s.old(top);
    const lsn = header.peek(parent.bytes()).lsn;
    const page = parent.bytes_mut();
    const view = try internal.parse_internal(page, page[node.offset_level]);
    const at = s.path.slots[index];
    assert(at <= view.count);
    if (at < view.count) {
        try internal.set_child(page, at, below.right);
    } else {
        internal.set_right_child(page, below.right);
    }
    internal.internal_insert(page, at, s.sep(@intCast(top - 1)), below.left) catch {
        return error.Corrupted; // Room was proven in prepare.
    };
    node.seal(page, s.path.ids[index], lsn);
    assert((try internal.parse_internal(page, page[node.offset_level])).count == view.count + 1);
}
