//! B+Tree cursor (ADR-0004 sections 3, 5, 10): ordered iteration over a `Tree` with `seek`,
//! `first`, `last`, `next` and `prev`, in bytewise key order.
//!
//! Invariants: the cursor is in one of four states. `on_entry`: exactly one leaf is pinned,
//! `index < count` and `at` is the verified entry at `index`. `before_first` and `after_last`:
//! nothing is pinned (the two exhausted ends; `next` from the first is `after_last`, `prev`
//! from the last is `before_first`, and the opposite step re-enters at the nearest end).
//! `unpositioned`: nothing is pinned; this is the state after `init`, after `release` and after
//! any error. Using a cursor that is `unpositioned` for `next` or `prev` is a caller error and
//! asserts; call `seek`, `first` or `last` first.
//! Pins: at most one page at any time (the old leaf is released before the next page is
//! fetched). The tree needs a pool of at least `2 * height_max + 2` frames (ADR section 9),
//! otherwise a fetch returns `PoolExhausted`, which is propagated.
//! Bounds: a descent takes at most `height_max(page_size)` fetches; `prev` across a leaf
//! re-descends from the root with the first key of the leaf, O(height) fetches per leaf
//! boundary, because leaves hold no back link (`path` is that descent's bounded stack,
//! `node.height_limit` entries, scratch otherwise). A forward step across a leaf checks that the
//! next leaf's first key is strictly above the last key left behind and a backward step checks
//! the same and that the predecessor's `next` is the leaf just left, so a link cycle or a
//! shared leaf is `error.Corrupted` and never a loop. Every byte read is untrusted data
//! (section 10): corruption is `error.Corrupted`, only caller contracts are asserted.
//! Allocation: none. `io` is a parameter and is never stored (ADR-0001). `release` takes no
//! `io` and cannot fail.
//! Borrowing: an `Entry` slices the pinned leaf's frame; see each function for its lifetime.
//! A write to the tree (insert or delete) invalidates the cursor; seek again afterwards.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const overflow = @import("overflow.zig");
const tree_mod = @import("tree.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const Tree = tree_mod.Tree;
const Id = header.Id;

/// Page-layer fetch errors plus `Corrupted` for a page, link or overflow chain that is not
/// valid, and `ValueTooLarge` for a stored value longer than the tree's `value_buf`.
pub const Error = buffer_pool.FetchError || node.ParseError || error{ValueTooLarge};

/// `KeyTooLarge`: the key is longer than `node.key_len_max(page_size)`; no such key exists.
pub const SeekError = Error || error{KeyTooLarge};

/// A key and its value. The key and an inline value borrow the pinned leaf frame (see the
/// functions that return one); an overflow value borrows `tree.value_buf`, so `Tree.get`
/// during a scan overwrites it. Copy them to keep them.
pub const Entry = struct { key: []const u8, value: []const u8 };

const State = enum { unpositioned, on_entry, before_first, after_last };

/// Single-threaded ordered cursor over one `Tree`. The tree must outlive it and not move, and
/// any write to the tree invalidates it: `seek`, `first` or `last` again before stepping.
pub const Cursor = struct {
    tree: *Tree,
    /// The pinned leaf; non-null exactly in state `on_entry`.
    guard: ?PageGuard,
    /// Descent stack of the last re-descent (`prev` across a leaf); scratch otherwise.
    path: descend.Path,
    /// The entry the cursor is on; meaningful only in state `on_entry`.
    at: Entry,
    index: u16,
    state: State,

    /// Builds an unpositioned cursor over `tree` in place. Reads no page and pins nothing. The
    /// tree must outlive the cursor and not move.
    pub fn init(target: *Cursor, tree: *Tree) void {
        assert(tree.root != .file_header);
        assert(tree.page_size == tree.pool.page_size);
        target.* = .{
            .tree = tree,
            .guard = null,
            .path = undefined,
            .at = .{ .key = &.{}, .value = &.{} },
            .index = 0,
            .state = .unpositioned,
        };
        assert(target.guard == null);
    }

    /// Drops the pin, if any, and leaves the cursor unpositioned. Idempotent, no `io`, cannot
    /// fail. Any `Entry` handed out earlier is invalid afterwards.
    pub fn release(self: *Cursor) void {
        if (self.guard) |*held| {
            held.release();
            self.guard = null;
        }
        self.state = .unpositioned;
        self.at = .{ .key = &.{}, .value = &.{} };
        assert(self.guard == null);
        assert(self.state == .unpositioned);
    }

    /// The entry the cursor is on, or null when it is exhausted or unpositioned. The entry
    /// borrows the pinned leaf until the next `seek`, `first`, `last`, `next`, `prev` or
    /// `release` on this cursor, or any write to the tree.
    pub fn current(self: *const Cursor) ?Entry {
        assert((self.state == .on_entry) == (self.guard != null));
        if (self.state != .on_entry) return null;
        assert(self.index < node.cell_count_max(self.tree.page_size));
        return self.at;
    }

    /// Positions on the first entry whose key is >= `key` (the lower bound); a key past the
    /// last one leaves the cursor `after_last`. Read the result with `current`, which borrows
    /// as documented there. An error leaves the cursor unpositioned. Cost: one descent.
    pub fn seek(self: *Cursor, io: Io, key: []const u8) SeekError!void {
        assert(self.tree.root != .file_header);
        assert((self.state == .on_entry) == (self.guard != null));
        if (key.len > node.key_len_max(self.tree.page_size)) {
            self.release();
            return error.KeyTooLarge;
        }
        try self.seek_bound(io, key);
    }

    /// Positions on the smallest key; null (and `after_last`) in an empty tree. The entry
    /// borrows the pinned leaf until the next call on this cursor or any tree write.
    pub fn first(self: *Cursor, io: Io) Error!?Entry {
        assert(self.tree.root != .file_header);
        assert((self.state == .on_entry) == (self.guard != null));
        try self.seek_bound(io, "");
        return self.current();
    }

    /// Positions on the largest key; null (and `before_first`) in an empty tree. The entry
    /// borrows the pinned leaf until the next call on this cursor or any tree write.
    pub fn last(self: *Cursor, io: Io) Error!?Entry {
        assert(self.tree.root != .file_header);
        assert((self.state == .on_entry) == (self.guard != null));
        self.release();
        errdefer self.release();

        const pool = self.tree.pool;
        self.guard = try rightmost(pool, io, self.tree.root, null);
        const leaf = try node.parse_leaf(self.guard.?.bytes());
        if (leaf.count == 0) {
            if (self.guard.?.id() != self.tree.root) return error.Corrupted;
            self.release();
            self.state = .before_first;
            return null;
        }
        return try self.settle(io, leaf, leaf.count - 1);
    }

    /// Steps to the next larger key; null once past the last (the cursor is then `after_last`
    /// and stays there). From `before_first` it enters at the first entry. The entry borrows
    /// the pinned leaf until the next call on this cursor or any tree write; the previous
    /// entry is invalid after the call. Precondition: not unpositioned. An error leaves the
    /// cursor unpositioned.
    pub fn next(self: *Cursor, io: Io) Error!?Entry {
        assert(self.state != .unpositioned);
        assert((self.state == .on_entry) == (self.guard != null));
        switch (self.state) {
            .unpositioned => unreachable, // Asserted just above.
            .after_last => return null,
            .before_first => return self.first(io),
            .on_entry => {},
        }
        errdefer self.release();

        const leaf = try node.parse_leaf(self.guard.?.bytes());
        if (self.index >= leaf.count) return error.Corrupted; // A write shrank the leaf.
        const following = @as(u32, self.index) + 1;
        if (following >= leaf.count) return try self.cross_forward(io);
        const entry = try entry_of(leaf, @intCast(following));
        if (std.mem.order(u8, self.at.key, entry.key) != .lt) return error.Corrupted;
        return try self.settle(io, leaf, @intCast(following));
    }

    /// Steps to the next smaller key; null once before the first (the cursor is then
    /// `before_first` and stays there). From `after_last` it enters at the last entry. At the
    /// first slot of a leaf it re-descends from the root to find the left neighbour (the
    /// leaves hold no back link). Borrowing and error behaviour are those of `next`.
    /// Precondition: not unpositioned.
    pub fn prev(self: *Cursor, io: Io) Error!?Entry {
        assert(self.state != .unpositioned);
        assert((self.state == .on_entry) == (self.guard != null));
        switch (self.state) {
            .unpositioned => unreachable, // Asserted just above.
            .before_first => return null,
            .after_last => return self.last(io),
            .on_entry => {},
        }
        errdefer self.release();

        if (self.index == 0) return try self.step_back(io);
        const leaf = try node.parse_leaf(self.guard.?.bytes());
        if (self.index > leaf.count) return error.Corrupted; // A write shrank the leaf.
        const entry = try entry_of(leaf, self.index - 1);
        if (std.mem.order(u8, entry.key, self.at.key) != .lt) return error.Corrupted;
        return try self.settle(io, leaf, self.index - 1);
    }

    /// Descends to the leaf for `key` and takes the lower bound in it or, past its end, the
    /// first entry of the right neighbour. `key` is within `key_len_max`.
    fn seek_bound(self: *Cursor, io: Io, key: []const u8) Error!void {
        assert(key.len <= node.key_len_max(self.tree.page_size));
        assert(self.tree.root != .file_header);
        self.release();
        errdefer self.release();

        const pool = self.tree.pool;
        self.guard = try descend.descend(pool, io, self.tree.root, key, false, &self.path);
        const leaf = try node.parse_leaf(self.guard.?.bytes());
        if (leaf.count == 0 and self.guard.?.id() != self.tree.root) return error.Corrupted;
        const slot = try leaf.search(key);
        if (slot.index < leaf.count) {
            _ = try self.settle(io, leaf, slot.index);
            return;
        }
        _ = try self.cross_forward(io);
    }

    /// Records `index` of the pinned `leaf` as the current entry; an overflow value is
    /// assembled into the tree's `value_buf` (see `Tree.get`), so it is valid only until the
    /// next call on the cursor or the tree.
    fn settle(self: *Cursor, io: Io, leaf: node.Leaf, index: u16) Error!Entry {
        assert(self.guard != null);
        assert(index < leaf.count);
        const cell = try leaf.entry(index);
        const value: []const u8 = switch (cell.value) {
            .bytes => |bytes| bytes,
            .overflow => |spill| blk: {
                if (spill.len > self.tree.value_buf.len) return error.ValueTooLarge;
                const pool = self.tree.pool;
                break :blk try overflow.read(pool, io, spill, self.tree.value_buf);
            },
        };
        const entry: Entry = .{ .key = cell.key, .value = value };
        self.at = entry;
        self.index = index;
        self.state = .on_entry;
        return entry;
    }

    /// Leaves the pinned leaf for its right neighbour: the first entry there, or null with the
    /// cursor `after_last` when there is none. The old leaf is unpinned before the new one is
    /// fetched; its last key is kept on the stack to prove the order.
    fn cross_forward(self: *Cursor, io: Io) Error!?Entry {
        assert(self.guard != null);
        const pool = self.tree.pool;
        const from = self.guard.?.id();
        const leaf = try node.parse_leaf(self.guard.?.bytes());
        try leaf.check_link(from);
        var floor_buf: [node.key_len_cap]u8 = undefined;
        var floor: ?[]const u8 = null;
        if (leaf.count > 0) floor = key_copy(&floor_buf, (try entry_of(leaf, leaf.count - 1)).key);
        const link = leaf.next;
        self.release();
        const target = link orelse {
            self.state = .after_last;
            return null;
        };
        if (!id_valid(pool, target) or target == from) return error.Corrupted;
        self.guard = try pool.fetch(io, target);
        const entered = try node.parse_leaf(self.guard.?.bytes());
        try entered.check_link(target);
        if (entered.count == 0) return error.Corrupted;
        const entry = try entry_of(entered, 0);
        if (floor) |bound| {
            if (std.mem.order(u8, bound, entry.key) != .lt) return error.Corrupted;
        }
        return try self.settle(io, entered, 0);
    }

    /// From slot 0 of the pinned leaf to the last entry of its left neighbour: re-descend with
    /// the leaf's first key, take the nearest ancestor with a smaller sibling slot, then the
    /// rightmost leaf below that sibling. Null (cursor `before_first`) at the leftmost leaf.
    fn step_back(self: *Cursor, io: Io) Error!?Entry {
        assert(self.state == .on_entry);
        assert(self.index == 0);
        const pool = self.tree.pool;
        const leaf_id = self.guard.?.id();
        var key_buf: [node.key_len_cap]u8 = undefined;
        const first_key = key_copy(&key_buf, self.at.key);
        self.release();
        var probe = try descend.descend(pool, io, self.tree.root, first_key, false, &self.path);
        probe.release();
        if (self.path.leaf != leaf_id) return error.Corrupted;
        const depth = ancestor_with_left_sibling(&self.path) orelse {
            self.state = .before_first;
            return null;
        };
        const sibling = try self.left_sibling(io, depth);
        self.guard = try rightmost(pool, io, sibling.child, sibling.level);
        const leaf = try node.parse_leaf(self.guard.?.bytes());
        if (leaf.next != leaf_id or leaf.count == 0) return error.Corrupted;
        const entry = try self.settle(io, leaf, leaf.count - 1);
        if (std.mem.order(u8, entry.key, first_key) != .lt) return error.Corrupted;
        return entry;
    }

    /// The child at `slot - 1` of the path's ancestor at `depth`, with the level it must have.
    fn left_sibling(self: *Cursor, io: Io, depth: u8) Error!Sibling {
        assert(depth < self.path.len);
        assert(self.path.slots[depth] > 0);
        const pool = self.tree.pool;
        const id = self.path.ids[depth];
        var pinned = try pool.fetch(io, id);
        defer pinned.release();

        const page = pinned.bytes();
        const level = page[node.offset_level];
        const view = try internal.parse_internal(page, level);
        try view.check_link(id);
        const slot = self.path.slots[depth];
        if (slot > view.count) return error.Corrupted; // The page changed since the descent.
        const child = try view.child_at(slot - 1);
        if (!id_valid(pool, child) or child == id) return error.Corrupted;
        return .{ .child = child, .level = level - 1 }; // `parse_internal` accepted level >= 1.
    }
};

const Sibling = struct { child: Id, level: u8 };

/// Deepest ancestor on `path` whose descent slot is not the leftmost, or null.
fn ancestor_with_left_sibling(path: *const descend.Path) ?u8 {
    assert(path.len <= node.height_limit);
    assert(path.leaf != .file_header);
    var depth: u8 = path.len;
    for (0..node.height_limit) |_| {
        if (depth == 0) return null;
        depth -= 1;
        if (path.slots[depth] > 0) return depth;
    }
    return null;
}

/// Walks right children from `start` down to a leaf, pinned for the caller. `level_first` is
/// the level `start` must have (null for the root, whose level is free); every later node must
/// be one level lower and the walk takes at most `height_max` fetches.
fn rightmost(pool: *BufferPool, io: Io, start: Id, level_first: ?u8) Error!PageGuard {
    assert(start != .file_header);
    assert(id_valid(pool, start));
    var id = start;
    var want = level_first;
    for (0..node.height_max(pool.page_size)) |_| {
        var pinned = try pool.fetch(io, id);
        const page = pinned.bytes();
        if (page[node.offset_type] == @intFromEnum(header.Type.btree_leaf)) {
            errdefer pinned.release();

            if (want) |level| {
                if (level != 0) return error.Corrupted;
            }
            const leaf = try node.parse_leaf(page);
            try leaf.check_link(id);
            return pinned;
        }
        defer pinned.release();

        const level = page[node.offset_level];
        if (want) |expected| {
            if (level != expected) return error.Corrupted;
        }
        const view = try internal.parse_internal(page, level);
        try view.check_link(id);
        if (!id_valid(pool, view.right_child)) return error.Corrupted;
        want = level - 1; // `parse_internal` accepted `level >= 1`.
        id = view.right_child;
    }
    assert(level_first == null or level_first.? <= node.height_limit);
    return error.Corrupted; // Deeper than any valid tree of this page size.
}

/// A leaf cell with its key checked; the value (inline or spilled) is read by `settle`.
fn entry_of(leaf: node.Leaf, index: u16) node.ParseError!node.Entry {
    assert(index < leaf.count);
    assert(leaf.count <= node.cell_count_max(node.page_size_of(leaf.page)));
    return leaf.entry(index);
}

/// Copies a parsed key (at most `key_len_cap` bytes) into `buf`; the copy outlives the page.
fn key_copy(buf: *[node.key_len_cap]u8, key: []const u8) []const u8 {
    assert(key.len <= node.key_len_cap);
    assert(key.len <= buf.len);
    @memcpy(buf[0..key.len], key);
    return buf[0..key.len];
}

fn id_valid(pool: *const BufferPool, id: Id) bool {
    assert(pool.pages.page_count >= 1);
    assert(pool.page_size == pool.pages.page_size);
    return id != .file_header and @intFromEnum(id) < pool.pages.page_count;
}

test {
    _ = @import("cursor_test.zig"); // Contract tests live in their own file (800-line limit).
}
