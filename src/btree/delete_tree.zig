//! B+Tree delete (ADR-0004 sections 8, 9): remove the cell from its leaf; a non-root node that
//! is then underfull (`2n + sum(cells) < underflow_bytes`, or empty) merges with an adjacent
//! sibling under the same parent when the result fits (the left node survives, the right is
//! unlinked; an internal merge pulls the separator down) or else borrows cells from it by
//! bytes. A merge removes a cell from the parent, so the cascade climbs an explicit, bounded
//! path (no recursion) until a node is not underfull, a borrow is done, or the root is reached.
//! A root internal node left with one child collapses: the child's bytes move into the root
//! page (the root id never changes) and the child is unlinked. A delete never splits: when a
//! borrow's new separator would not fit in the parent, rebalancing is skipped (valid, the node
//! stays underfull) unless the node would be empty, which is `NoSpaceLeft`.
//!
//! Prepare (may fail, changes no byte): descend, pin every ancestor and sibling the cascade
//! needs, fully validate each (`check_invariants`, child ids, key order across the pair), plan
//! every level by arithmetic on sizes, then check room in `frees_pending`. Apply cannot fail on
//! a validated tree; its `Corrupted` returns are defensive only. Unlinked ids are appended to
//! the tree's `frees_pending`; `Tree.release_frees` hands them to the page manager.
//! Pins: at most `2 * height_max + 1` (path, one sibling per level, the leaf).
//! Allocation: none (state lives on the stack, about 80 KiB). Page lsns are carried over.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const overflow = @import("overflow.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const Id = header.Id;
const Path = descend.Path;
const Tree = @import("tree.zig").Tree;

pub const DeleteError = descend.DescendError ||
    error{ KeyTooLarge, FreesPendingLimit, NoSpaceLeft };

const levels_max: u32 = node.height_limit;
const pins_max: u32 = levels_max;
const frees_per_op_max: u32 = levels_max + 1;

const Pins = struct {
    guards: [pins_max]PageGuard,
    len: u32,

    fn push(self: *Pins, pinned: PageGuard) void {
        assert(pins_max == levels_max);
        assert(!pinned.released);
        assert(self.len < pins_max);
        self.guards[self.len] = pinned;
        self.len += 1;
    }

    fn release_all(self: *Pins) void {
        assert(pins_max >= 1);
        assert(self.len <= pins_max);
        for (0..self.len) |index| self.guards[index].release();
        self.len = 0;
    }
};

const Kind = enum { merge, borrow };

const Step = struct { kind: Kind, sib_left: bool, k: u16, sep_len: u16, pair: u16, sib: Id };

const Del = struct {
    pool: *BufferPool,
    path: *const Path,
    leaf: *PageGuard,
    ancestors: Pins,
    sibs: Pins,
    steps: [levels_max]Step,
    steps_len: u32,
    seps: [levels_max][node.key_len_cap]u8,
    cur_used: u32,
    cur_count: u32,
    collapse: bool,
    frees: [frees_per_op_max]Id,
    frees_len: u32,
    work: [header.page_size_max]u8,

    /// The pinned node at level `j` (0 = the leaf).
    fn at(self: *Del, j: u32) *PageGuard {
        assert(self.ancestors.len <= pins_max);
        assert(j <= self.path.len);
        if (j == 0) return self.leaf;
        return &self.ancestors.guards[j - 1];
    }

    fn id_at(self: *const Del, j: u32) Id {
        assert(self.path.len < node.height_limit);
        assert(j <= self.path.len);
        if (j == 0) return self.path.leaf;
        return self.path.ids[self.path.len - j];
    }

    fn sep(self: *const Del, j: u32) []const u8 {
        assert(self.steps[j].sep_len <= node.key_len_cap);
        assert(j < self.steps_len);
        return self.seps[j][0..self.steps[j].sep_len];
    }
};

/// Removes `key`; true when it was present. See the file doc for what a failure leaves.
pub fn delete(t: *Tree, io: Io, key: []const u8) DeleteError!bool {
    assert(key.len <= node.key_len_max(t.page_size));
    assert(t.frees_len <= t.frees_pending.len);
    var path: Path = undefined;
    var leaf = try descend.descend(t.pool, io, t.root, key, true, &path);
    defer leaf.release();

    const view = try node.parse_leaf(leaf.bytes());
    const slot = try view.search(key);
    if (!slot.found) return false;
    const spill: ?node.Overflow = switch ((try view.entry(slot.index)).value) {
        .bytes => null,
        .overflow => |found| found,
    };
    var d: Del = undefined;
    d.pool = t.pool;
    d.path = &path;
    d.leaf = &leaf;
    d.ancestors.len = 0;
    d.sibs.len = 0;
    d.steps_len = 0;
    d.collapse = false;
    d.frees_len = 0;
    defer d.ancestors.release_all();
    defer d.sibs.release_all();

    try plan(&d, io, view, slot.index);
    for (d.frees[0..d.frees_len]) |id| {
        // A page already waiting to be freed must not be unlinked again: shared page.
        if (std.mem.findScalar(Id, t.frees_pending[0..t.frees_len], id) != null) {
            return error.Corrupted;
        }
    }
    const chain_n: u32 = if (spill) |found| overflow.chain_len(t.page_size, found.len) else 0;
    if (t.frees_len + d.frees_len + chain_n > t.frees_pending.len) return error.FreesPendingLimit;
    if (spill) |found| {
        // Walked before apply, so a bad chain is `Corrupted` with the tree untouched; the ids
        // wait just past the node ids in the free slots and are counted once apply is done.
        const room = t.frees_pending[t.frees_len + d.frees_len ..][0..chain_n];
        try overflow.collect_ids(t.pool, io, found, room);
        // A chain page already waiting to be freed is owned twice: shared chain.
        if (t.pending_has_any(room)) return error.Corrupted;
    }
    try apply(&d, slot.index);
    for (d.frees[0..d.frees_len]) |id| {
        t.frees_pending[t.frees_len] = id;
        t.frees_len += 1;
    }
    t.frees_len += chain_n;
    return true;
}

fn leaf_cell_bytes(entry: node.Entry) node.ParseError!u32 {
    assert(entry.key.len <= node.key_len_cap);
    assert(entry.key.len <= node.key_len_cap);
    const key_len: u32 = @intCast(entry.key.len);
    const value_len: u32 = switch (entry.value) {
        .bytes => |bytes| @intCast(bytes.len),
        .overflow => |spill| spill.len,
    };
    const tail: u32 = switch (entry.value) {
        .bytes => value_len,
        .overflow => 4, // The head id; the chain pages are freed apart from the leaf.
    };
    return codec.varint.encoded_size(key_len) + codec.varint.encoded_size(value_len) +
        key_len + tail;
}

fn internal_cell_bytes(key_len: usize) u32 {
    assert(key_len <= std.math.maxInt(u16));
    assert(key_len <= node.key_len_cap);
    const len: u32 = @intCast(key_len);
    return codec.varint.encoded_size(len) + len + 4;
}

/// Prepare: plan every level bottom up. Fills `steps`, `frees` and `collapse`.
fn plan(d: *Del, io: Io, view: node.Leaf, index: u16) DeleteError!void {
    assert(index < view.count);
    assert(d.path.len < node.height_limit);
    try view.check_invariants();
    const removed = try leaf_cell_bytes(try view.entry(index));
    d.cur_used = std.math.sub(u32, view.used_bytes(), removed + node.slot_size) catch {
        return error.Corrupted;
    };
    d.cur_count = view.count - 1;
    if (d.path.len == 0) {
        if (view.next != null) return error.Corrupted; // A root leaf has no peer.
        return;
    }
    for (0..d.path.len) |j| {
        if (!try plan_level(d, io, @intCast(j))) return;
    }
}

/// Parses ancestor `level` (>= 1) fully; the view borrows its pinned page.
fn parent_view(d: *Del, level: u32) DeleteError!internal.Internal {
    assert(d.ancestors.len >= level);
    assert(d.sibs.len <= pins_max);
    assert(level >= 1 and level <= d.path.len);
    const page = d.at(level).bytes();
    const view = try internal.parse_internal(page, page[node.offset_level]);
    try view.check_children(d.id_at(level));
    try view.check_invariants();
    if (view.level != level) return error.Corrupted;
    return view;
}

/// Plans node `j` (non-root); true when the cascade continues with its parent.
fn plan_level(d: *Del, io: Io, j: u32) DeleteError!bool {
    assert(j < d.path.len);
    const page_size = d.pool.page_size;
    const must = d.cur_count == 0;
    if (!must and d.cur_used >= node.underflow_bytes(page_size)) return false;
    d.ancestors.push(try d.pool.fetchForUpdate(io, d.id_at(j + 1)));
    const parent = try parent_view(d, j + 1);
    const slot = d.path.slots[d.path.len - 1 - j];
    if (slot > parent.count) return error.Corrupted;
    const sib_left = slot == parent.count;
    const pair: u16 = if (sib_left) slot - 1 else slot;
    const sib_id = try parent.child_at(if (sib_left) slot - 1 else slot + 1);
    if (@intFromEnum(sib_id) >= d.pool.pages.page_count or sib_id == d.id_at(j)) {
        return error.Corrupted;
    }
    d.sibs.push(try d.pool.fetchForUpdate(io, sib_id));
    const separator = (try parent.entry(pair)).key;
    @memcpy(d.seps[j][0..separator.len], separator);
    d.steps[j] = .{
        .kind = .merge,
        .sib_left = sib_left,
        .k = 0,
        .sep_len = @intCast(separator.len),
        .pair = pair,
        .sib = sib_id,
    };
    d.steps_len = @intCast(j + 1);
    if (try plan_merge(d, j)) return plan_after_merge(d, j, parent);
    try plan_borrow(d, j, parent, must);
    return false;
}

/// True when the merge fits (and the step stays a merge); checks the order across the pair.
fn plan_merge(d: *Del, j: u32) DeleteError!bool {
    assert(j < d.steps_len);
    assert(d.sibs.len == j + 1);
    const page_size = d.pool.page_size;
    const step = d.steps[j];
    const sib_page = d.sibs.guards[j].bytes();
    const node_page = d.at(j).bytes();
    const left_page = if (step.sib_left) sib_page else node_page;
    const right_page = if (step.sib_left) node_page else sib_page;
    var sib_used: u32 = undefined;
    var sib_count: u32 = undefined;
    var extra: u32 = 0;
    if (j == 0) {
        const sib = try node.parse_leaf(sib_page);
        try sib.check_link(step.sib);
        try sib.check_invariants();
        const left = try node.parse_leaf(left_page);
        const right = try node.parse_leaf(right_page);
        const right_id = if (step.sib_left) d.id_at(0) else step.sib;
        if (left.next != right_id) return error.Corrupted;
        if (left.count == 0 or right.count == 0) return error.Corrupted;
        const last = try left.entry(left.count - 1);
        if (std.mem.order(u8, last.key, (try right.entry(0)).key) != .lt) return error.Corrupted;
        sib_used = sib.used_bytes();
        sib_count = sib.count;
    } else {
        const sib = try internal.parse_internal(sib_page, @intCast(j));
        try sib.check_children(step.sib);
        try sib.check_invariants();
        const left = try internal.parse_internal(left_page, @intCast(j));
        const right = try internal.parse_internal(right_page, @intCast(j));
        try check_pair_order(left, right, d.sep(j));
        sib_used = sib.used_bytes();
        sib_count = sib.count;
        extra = internal_cell_bytes(step.sep_len) + node.slot_size;
    }
    const used = d.cur_used + sib_used + extra;
    const count = d.cur_count + sib_count + @intFromBool(j > 0);
    return used <= node.usable(page_size) and count <= node.cell_count_max(page_size);
}

fn check_pair_order(left: internal.Internal, right: internal.Internal, sep: []const u8) !void {
    assert(left.level == right.level);
    assert(left.count >= 1 and right.count >= 1);
    const last = try left.entry(left.count - 1);
    if (std.mem.order(u8, last.key, sep) != .lt) return error.Corrupted;
    if (std.mem.order(u8, sep, (try right.entry(0)).key) != .lt) return error.Corrupted;
}

/// The merge is planned: the right node is unlinked and the parent loses a cell. True when the
/// parent is not the root, so the cascade goes on with it.
fn plan_after_merge(d: *Del, j: u32, parent: internal.Internal) DeleteError!bool {
    assert(parent.count >= 1);
    const step = d.steps[j];
    const left_id = if (step.sib_left) step.sib else d.id_at(j);
    const right_id = if (step.sib_left) d.id_at(j) else step.sib;
    assert(left_id != right_id);
    d.frees[d.frees_len] = right_id;
    d.frees_len += 1;
    const cell = internal_cell_bytes(step.sep_len);
    d.cur_used = std.math.sub(u32, parent.used_bytes(), cell + node.slot_size) catch {
        return error.Corrupted;
    };
    d.cur_count = parent.count - 1;
    if (j + 1 < d.path.len) return true;
    if (d.cur_count == 0) {
        d.collapse = true;
        d.frees[d.frees_len] = left_id;
        d.frees_len += 1;
    }
    return false;
}

fn improves(a: u32, b: u32, gain: u32, loss: u32) bool {
    assert(@as(u64, a) + gain <= std.math.maxInt(u32));
    assert(loss <= b);
    const before = @abs(@as(i64, b) - @as(i64, a));
    const after = @abs(@as(i64, b) - loss - (@as(i64, a) + gain));
    return after < before;
}

/// Plans a borrow of `k` cells (k = 0: skipped); the new separator replaces the old one.
fn plan_borrow(d: *Del, j: u32, parent: internal.Internal, must: bool) DeleteError!void {
    assert(j < d.steps_len);
    assert(parent.count >= 1);
    assert(must or !must);
    const page_size = d.pool.page_size;
    const step = &d.steps[j];
    const old_len = step.sep_len;
    step.kind = .borrow;
    step.k = if (j == 0) try borrow_leaf(d, j) else try borrow_internal(d, j);
    if (step.k > 0) try check_sep_bounds(d, j, parent);
    const grown = internal_cell_bytes(step.sep_len) + parent.used_bytes();
    const fits = step.k > 0 and grown - internal_cell_bytes(old_len) <= node.usable(page_size);
    if (fits) return;
    if (must) return error.NoSpaceLeft;
    d.steps_len = j; // Skipped: the node stays underfull, which is valid.
}

/// The new separator must stay strictly between the parent's neighbouring separators.
fn check_sep_bounds(d: *Del, j: u32, parent: internal.Internal) DeleteError!void {
    assert(j < d.steps_len);
    assert(d.steps[j].k > 0);
    const pair = d.steps[j].pair;
    const new = d.sep(j);
    if (pair > 0) {
        const below = (try parent.entry(pair - 1)).key;
        if (std.mem.order(u8, below, new) != .lt) return error.Corrupted;
    }
    if (pair + 1 < parent.count) {
        const above = (try parent.entry(pair + 1)).key;
        if (std.mem.order(u8, new, above) != .lt) return error.Corrupted;
    }
}

fn borrow_leaf(d: *Del, j: u32) DeleteError!u16 {
    assert(j < d.steps_len);
    assert(d.sibs.len == j + 1);
    const page_size = d.pool.page_size;
    const step = &d.steps[j];
    const sib = try node.parse_leaf(d.sibs.guards[j].bytes());
    var a = d.cur_used;
    var b = sib.used_bytes();
    var k: u16 = 0;
    for (0..node.cell_count_max(page_size)) |_| {
        if (k + 1 >= sib.count) break;
        const index: u16 = if (step.sib_left) sib.count - 1 - k else k;
        const x = try leaf_cell_bytes(try sib.entry(index)) + node.slot_size;
        if (a + x > node.usable(page_size)) break;
        if (d.cur_count + k + 1 > node.cell_count_max(page_size)) break;
        if (!improves(a, b, x, x)) break;
        a += x;
        b -= x;
        k += 1;
    }
    if (k == 0) return 0;
    const first: u16 = if (step.sib_left) sib.count - k else k;
    const key = (try sib.entry(first)).key;
    @memcpy(d.seps[j][0..key.len], key);
    step.sep_len = @intCast(key.len);
    return k;
}

fn borrow_internal(d: *Del, j: u32) DeleteError!u16 {
    assert(j >= 1 and j < d.steps_len);
    assert(d.sibs.len == j + 1);
    const page_size = d.pool.page_size;
    const step = &d.steps[j];
    const sib = try internal.parse_internal(d.sibs.guards[j].bytes(), @intCast(j));
    var a = d.cur_used;
    var b = sib.used_bytes();
    var k: u16 = 0;
    var cur_len: usize = step.sep_len;
    for (0..node.cell_count_max(page_size)) |_| {
        if (k + 1 >= sib.count) break;
        const index: u16 = if (step.sib_left) sib.count - 1 - k else k;
        const cell = try sib.entry(index);
        const gain = internal_cell_bytes(cur_len) + node.slot_size;
        const loss = internal_cell_bytes(cell.key.len) + node.slot_size;
        if (a + gain > node.usable(page_size)) break;
        if (d.cur_count + k + 1 > node.cell_count_max(page_size)) break;
        if (!improves(a, b, gain, loss)) break;
        a += gain;
        b -= loss;
        cur_len = cell.key.len;
        k += 1;
    }
    if (k == 0) return 0;
    const last: u16 = if (step.sib_left) sib.count - k else k - 1;
    const key = (try sib.entry(last)).key;
    @memcpy(d.seps[j][0..key.len], key);
    step.sep_len = @intCast(key.len);
    return k;
}

/// Apply: edits the pinned frames bottom up. Cannot fail on a tree prepare validated.
fn apply(d: *Del, index: u16) DeleteError!void {
    assert(d.steps_len <= d.path.len);
    assert(d.frees_len <= frees_per_op_max);
    const leaf_page = d.leaf.bytes_mut();
    const leaf_lsn = header.peek(leaf_page).lsn;
    try node.leaf_remove(leaf_page, index);
    node.seal(leaf_page, d.path.leaf, leaf_lsn);
    for (0..d.steps_len) |j| {
        switch (d.steps[j].kind) {
            .merge => try apply_merge(d, @intCast(j)),
            .borrow => try apply_borrow(d, @intCast(j)),
        }
    }
    if (d.collapse) try apply_collapse(d);
}

fn apply_merge(d: *Del, j: u32) DeleteError!void {
    assert(j < d.steps_len);
    assert(d.steps[j].kind == .merge);
    const step = d.steps[j];
    const sib_guard = &d.sibs.guards[j];
    const survivor = if (step.sib_left) sib_guard else d.at(j);
    const victim = if (step.sib_left) d.at(j) else sib_guard;
    const survivor_id = if (step.sib_left) step.sib else d.id_at(j);
    const lsn = header.peek(survivor.bytes()).lsn;
    const target = survivor.bytes_mut();
    if (j == 0) {
        try append_leaf(target, victim.bytes());
    } else {
        try append_internal(target, victim.bytes(), d.sep(j), @intCast(j));
    }
    node.seal(target, survivor_id, lsn);
    const parent = d.at(j + 1);
    const parent_id = d.id_at(j + 1);
    const parent_lsn = header.peek(parent.bytes()).lsn;
    const page = parent.bytes_mut();
    const view = try internal.parse_internal(page, page[node.offset_level]);
    if (view.count == 1) {
        internal.format_internal(page, parent_id, view.level, survivor_id, parent_lsn);
        return;
    }
    if (step.pair + 1 < view.count) {
        try internal.set_child(page, step.pair + 1, survivor_id);
    } else {
        internal.set_right_child(page, survivor_id);
    }
    try internal.internal_remove(page, step.pair);
    node.seal(page, parent_id, parent_lsn);
}

fn append_leaf(target: []u8, victim: []const u8) DeleteError!void {
    assert(target.len == victim.len);
    assert(target.ptr != victim.ptr);
    const from = try node.parse_leaf(victim);
    for (0..from.count) |index| {
        const entry = try from.entry(@intCast(index));
        const into = try node.parse_leaf(target);
        node.leaf_insert(target, into.count, entry.key, entry.value) catch return error.Corrupted;
    }
    node.set_next(target, from.next);
}

fn append_internal(target: []u8, victim: []const u8, sep: []const u8, level: u8) DeleteError!void {
    assert(level >= 1 and level < node.height_limit);
    assert(sep.len <= node.key_len_cap);
    const from = try internal.parse_internal(victim, level);
    var into = try internal.parse_internal_raw(target, level);
    internal.internal_insert(target, into.count, sep, into.right_child) catch {
        return error.Corrupted;
    };
    for (0..from.count) |index| {
        const cell = try from.entry(@intCast(index));
        into = try internal.parse_internal_raw(target, level);
        internal.internal_insert(target, into.count, cell.key, cell.child) catch {
            return error.Corrupted;
        };
    }
    internal.set_right_child(target, from.right_child);
}

fn apply_borrow(d: *Del, j: u32) DeleteError!void {
    assert(j < d.steps_len);
    assert(d.steps[j].kind == .borrow and d.steps[j].k >= 1);
    const step = d.steps[j];
    const parent = d.at(j + 1);
    var current: [node.key_len_cap]u8 = undefined;
    const view = try internal.parse_internal(parent.bytes(), parent.bytes()[node.offset_level]);
    const old = (try view.entry(step.pair)).key;
    @memcpy(current[0..old.len], old);
    var current_len = old.len;
    const target_guard = d.at(j);
    const source_guard = &d.sibs.guards[j];
    const target = target_guard.bytes_mut();
    const source = source_guard.bytes_mut();
    const lsn = header.peek(target).lsn;
    for (0..step.k) |_| {
        if (j == 0) {
            try move_leaf_cell(target, source, step.sib_left);
        } else {
            current_len = try rotate_internal(target, source, &current, current_len, step.sib_left);
        }
    }
    node.seal(target, d.id_at(j), lsn);
    node.seal(source, step.sib, header.peek(source).lsn);
    try replace_separator(d, j, step.pair);
}

fn move_leaf_cell(target: []u8, source: []u8, from_back: bool) DeleteError!void {
    assert(target.len == source.len);
    assert(target.ptr != source.ptr);
    const from = try node.parse_leaf(source);
    const into = try node.parse_leaf(target);
    const index: u16 = if (from_back) from.count - 1 else 0;
    const slot: u16 = if (from_back) 0 else into.count;
    const entry = try from.entry(index);
    node.leaf_insert(target, slot, entry.key, entry.value) catch return error.Corrupted;
    try node.leaf_remove(source, index);
}

/// One rotation through the parent; returns the new separator length (kept in `current`).
fn rotate_internal(
    target: []u8,
    source: []u8,
    current: *[node.key_len_cap]u8,
    current_len: usize,
    from_back: bool,
) DeleteError!usize {
    assert(target.len == source.len);
    assert(current_len <= node.key_len_cap);
    const level = target[node.offset_level];
    const from = try internal.parse_internal(source, level);
    const into = try internal.parse_internal_raw(target, level);
    const index: u16 = if (from_back) from.count - 1 else 0;
    const cell = try from.entry(index);
    const slot: u16 = if (from_back) 0 else into.count;
    const pulled_child = if (from_back) from.right_child else into.right_child;
    internal.internal_insert(target, slot, current[0..current_len], pulled_child) catch {
        return error.Corrupted;
    };
    if (from_back) {
        internal.set_right_child(source, cell.child);
    } else {
        internal.set_right_child(target, cell.child);
    }
    const next_len = cell.key.len;
    @memcpy(current[0..next_len], cell.key);
    try internal.internal_remove(source, index);
    return next_len;
}

/// Rebuilds the parent with the cell `pair` keyed by the new separator.
fn replace_separator(d: *Del, j: u32, pair: u16) DeleteError!void {
    assert(j < d.steps_len);
    assert(pair == d.steps[j].pair);
    const parent = d.at(j + 1);
    const parent_id = d.id_at(j + 1);
    const size = d.pool.page_size;
    const work = d.work[0..size];
    @memcpy(work, parent.bytes());
    const view = try internal.parse_internal(work, work[node.offset_level]);
    const lsn = header.peek(work).lsn;
    const page = parent.bytes_mut();
    internal.format_internal(page, parent_id, view.level, view.right_child, lsn);
    for (0..view.count) |index| {
        const cell = try view.entry(@intCast(index));
        const key = if (index == pair) d.sep(j) else cell.key;
        internal.internal_insert(page, @intCast(index), key, cell.child) catch {
            return error.Corrupted;
        };
    }
    node.seal(page, parent_id, lsn);
}

/// The root has one child left: the child's bytes become the root page.
fn apply_collapse(d: *Del) DeleteError!void {
    assert(d.collapse);
    assert(d.steps_len >= 1);
    const last = d.steps[d.steps_len - 1];
    const child = if (last.sib_left) &d.sibs.guards[d.steps_len - 1] else d.at(d.steps_len - 1);
    const root = d.at(d.path.len);
    const root_id = d.id_at(d.path.len);
    const lsn = header.peek(root.bytes()).lsn;
    const page = root.bytes_mut();
    @memcpy(page, child.bytes());
    if (page[node.offset_type] == @intFromEnum(header.Type.btree_leaf)) node.set_next(page, null);
    node.seal(page, root_id, lsn);
}
