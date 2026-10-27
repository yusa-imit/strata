//! B+Tree over the buffer pool (ADR-0004): `create` allocates the fixed root page (section 8),
//! `get` descends from it through internal nodes to a leaf, `insert` edits a leaf in place or
//! splits it (and full ancestors, up to a root split that keeps the root id, in
//! `split_tree.zig`), `check_invariants` and `validate` walk the whole tree (`validate.zig`).
//! Overflow values, delete and logging arrive in later plan 005 items, so this stage is
//! unlogged (page `lsn`s are kept as they are).
//!
//! Invariants: `root` is a page id allocated by `create`, never 0 and never changed, even by a
//! root split; the root is a leaf (type 16, level 0) or an internal node (type 17) whose level
//! is the tree height minus one, at most `height_max(page_size) - 1`; every node's cells are
//! strictly ascending (section 7); every byte read from a page is untrusted data, so a
//! malformed page is `Corrupted` (the page layer's `Unwritten`, `ChecksumMismatch` and
//! `TornWrite` pass through) and never an assert.
//! Allocation: `create` and splits take page ids from the page manager (never `gpa`); the pool
//! allocated every frame at its own `init`. Only `validate` takes a `gpa`, for a visited bitmap
//! it frees before returning. The tree never stores an `Io`: `io` is the first parameter after
//! the receiver of every method that can touch the file (ADR-0001).
//! Ownership: the tree does not own the pool or the page manager; both must outlive it and no
//! guard of the tree outlives a call. The caller persists `root` (there is no meta page).
//! Atomicity (section 9, prepare then apply): an insert that fails before it mutates anything
//! (`KeyTooLarge`, `ValueTooLarge`, `HeightLimit`, `PoolExhausted`, `NoSpaceLeft`, a typed read
//! error, `Corrupted` found while planning) changes no byte of an existing page; a split needs
//! `2 * height + 1` pins at most, and a pool too small for that gives `PoolExhausted` up front.
//! Pages allocated before such a failure are leaked as empty leaves, which ADR-0002 calls safe.
//! Prepare fully validates every node apply will touch, so a split cannot fail after its first
//! byte moves on any page content; the apply-phase `Corrupted` returns are defensive only. There
//! is still no log to roll back with, so the WAL item (one frame per op) owns crash atomicity.
//! Borrowing: `get` returns a slice into a pool frame, see its doc for the lifetime.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const descend = @import("descend.zig");
const split_tree = @import("split_tree.zig");
const delete_tree = @import("delete_tree.zig");
const validate_mod = @import("validate.zig");

const BufferPool = buffer_pool.BufferPool;
const Id = header.Id;

/// `create` pops or grows an id, then pins it new; an id that was allocated before a later
/// failure leaks, which ADR-0002 calls safe.
pub const CreateError = manager.AllocateError || buffer_pool.FetchNewError;

/// A persisted root id outside `1 ..< page_count`.
pub const OpenError = node.ParseError;

/// Read-only failures: the page layer's typed errors, plus `Corrupted` for a page whose
/// checksum is right but whose layout, level, child id or key order is not valid.
pub const CheckError = buffer_pool.FetchError || node.ParseError;

/// `validate` adds the `gpa` allocation of its visited bitmap.
pub const ValidateError = CheckError || error{OutOfMemory};

/// `KeyTooLarge`: the key is longer than `node.key_len_max(page_size)`.
pub const GetError = CheckError || error{KeyTooLarge};

/// `FreesPendingLimit`: `frees_pending` has no room for the ids this delete would unlink;
/// nothing changed. `NoSpaceLeft`: a forced borrow whose new separator does not fit in its
/// parent (nothing changed).
pub const DeleteError = delete_tree.DeleteError;

/// The page manager's own error set: `release_frees` frees through it.
pub const FreeError = manager.FreeError;

/// `ValueTooLarge`: over `node.value_len_max`, or not inline at this page size (overflow values
/// are a later item). `HeightLimit`: the split would raise the tree past `height_max`; nothing
/// changed. A split also allocates (`manager.AllocateError`) and pins new pages
/// (`FetchNewError`). `NodeFull` is gone: a full leaf splits.
pub const InsertError = GetError || split_tree.SplitError || error{ValueTooLarge};

pub const Tree = struct {
    pool: *BufferPool,
    root: Id,
    page_size: u32,
    /// Caller-provided storage for ids unlinked by `delete`; its length is `frees_pending_max`.
    frees_pending: []Id,
    /// Ids in `frees_pending[0..frees_len]` wait for `release_frees`.
    frees_len: u32,

    /// Allocates the root id from the page manager and writes an empty leaf there, in the pool
    /// (dirty, not yet on disk: `flushAll` and the caller's `sync` make it durable). The root
    /// id is persisted by the caller. On error nothing in `target` is set. `frees` is the
    /// storage of the pending-free list (its length is `frees_pending_max`) and must outlive
    /// the tree.
    pub fn create(target: *Tree, io: Io, pool: *BufferPool, frees: []Id) CreateError!void {
        assert(pool.page_size == pool.pages.page_size);
        assert(header.page_size_valid(pool.page_size));
        const id = try pool.pages.allocate(io);
        var guard = try pool.fetchNew(io, id);
        defer guard.release();

        node.format_leaf(guard.bytes_mut(), id, null, 0);
        target.* = .{
            .pool = pool,
            .root = id,
            .page_size = pool.page_size,
            .frees_pending = frees,
            .frees_len = 0,
        };
        assert(target.root != .file_header);
        assert(@intFromEnum(target.root) < pool.pages.page_count);
    }

    /// Attaches to an existing tree whose root id the caller persisted. Reads no page: a bad
    /// root page surfaces from the first `get` or `insert`. The id itself is data from outside
    /// (the caller's own storage), so a root of 0 or at or past `page_count` is `Corrupted` and
    /// `target` is left untouched.
    pub fn open(target: *Tree, pool: *BufferPool, root: Id, frees: []Id) OpenError!void {
        assert(pool.page_size == pool.pages.page_size);
        assert(pool.pages.page_count >= 1);
        if (root == .file_header) return error.Corrupted;
        if (@intFromEnum(root) >= pool.pages.page_count) return error.Corrupted;
        target.* = .{
            .pool = pool,
            .root = root,
            .page_size = pool.page_size,
            .frees_pending = frees,
            .frees_len = 0,
        };
        assert(target.root != .file_header);
    }

    /// The value stored under `key`, or null when absent. The slice borrows a pool frame: it
    /// stays valid until the next call on this tree or any fetch on its pool (a fetch may evict
    /// the frame), and is overwritten by the next write to that leaf; copy it to keep it. A key
    /// longer than `key_len_max` is `KeyTooLarge` (no such key can exist). Cost: one fetch per
    /// level (at most `height_max`) and a binary search per node that checks only the cells it
    /// touches; a bad level, type or child id on the way is `Corrupted`.
    pub fn get(self: *Tree, io: Io, key: []const u8) GetError!?[]const u8 {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        if (key.len > node.key_len_max(self.page_size)) return error.KeyTooLarge;
        var path: descend.Path = undefined;
        var guard = try descend.descend(self.pool, io, self.root, key, false, &path);
        defer guard.release();

        const leaf = try node.parse_leaf(guard.bytes());
        const slot = try leaf.search(key);
        if (!slot.found) return null;
        const entry = try leaf.entry(slot.index);
        switch (entry.value) {
            .bytes => |bytes| return bytes,
            .overflow => return error.Corrupted, // Overflow cells are never written yet.
        }
    }

    /// Stores `value` under `key`, replacing the value of an existing key. A leaf with room is
    /// edited in place and re-sealed (checksum, same `lsn`); a full leaf splits (see
    /// `split_tree.zig`, which also says what a failure leaves). Nothing is written to the file
    /// until the pool writes the frames back. Errors that can be known up front (`KeyTooLarge`,
    /// `ValueTooLarge`, `HeightLimit`, `PoolExhausted`, `NoSpaceLeft`, `Corrupted`, read errors)
    /// are returned before the first byte of an existing page moves.
    pub fn insert(self: *Tree, io: Io, key: []const u8, value: []const u8) InsertError!void {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        if (key.len > node.key_len_max(self.page_size)) return error.KeyTooLarge;
        if (value.len > node.value_len_max) return error.ValueTooLarge;
        const value_len: u32 = @intCast(value.len); // Bounded by `value_len_max` just above.
        const key_len: u32 = @intCast(key.len); // Bounded by `key_len_max` just above.
        if (!node.value_inline(self.page_size, key_len, value_len)) return error.ValueTooLarge;

        var path: descend.Path = undefined;
        var guard = try descend.descend(self.pool, io, self.root, key, true, &path);
        defer guard.release();

        const leaf = try node.parse_leaf(guard.bytes());
        const slot = try leaf.search(key);
        try check_neighbours(leaf, slot, key);
        const freed = if (slot.found) try cell_bytes(leaf, slot.index) else 0;
        const added = cell_bytes_of(key_len, value_len);
        const grows_count = !slot.found and leaf.count >= node.cell_count_max(self.page_size);
        // `used_bytes` derives from untrusted slots: a cell larger than it reports is a bad page.
        const used_kept = std.math.sub(u32, leaf.used_bytes(), freed) catch {
            return error.Corrupted;
        };
        const slot_added: u32 = if (slot.found) 0 else node.slot_size;
        const used_after = used_kept + added + slot_added;
        if (grows_count or used_after > node.usable(self.page_size)) {
            return split_tree.insert_split(self.pool, io, &path, &guard, slot, key, value, added);
        }
        try edit_leaf(&guard, path.leaf, slot, key, value);
    }

    /// Removes `key`, merging or redistributing underfull nodes (see `delete_tree.zig`). True
    /// when the key was present. Unlinked pages wait in `frees_pending` for `release_frees`.
    pub fn delete(self: *Tree, io: Io, key: []const u8) DeleteError!bool {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        if (key.len > node.key_len_max(self.page_size)) return error.KeyTooLarge;
        return delete_tree.delete(self, io, key);
    }

    /// Hands every pending id to the page manager, after dropping its pool frame without a
    /// write-back (a stale tree page must never overwrite a freelist page). Returns how many
    /// ids were freed. An id whose `free` fails stays pending, with the ones after it.
    pub fn release_frees(self: *Tree, io: Io) FreeError!u32 {
        assert(self.frees_len <= self.frees_pending.len);
        assert(self.pool.pinned_count() == 0);
        var freed: u32 = 0;
        while (self.frees_len > 0) {
            const id = self.frees_pending[self.frees_len - 1];
            self.pool.discard(id);
            try self.pool.pages.free(io, id);
            self.frees_len -= 1;
            freed += 1;
        }
        assert(self.frees_len == 0);
        return freed;
    }

    /// Full O(n) check without a scratch allocation: every node, strict key order, separator
    /// bounds, levels, the leaf chain, fill. Sharing is bounded, not named; see `validate`.
    pub fn check_invariants(self: *Tree, io: Io) CheckError!void {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        try validate_mod.run(self.pool, io, self.root, null);
    }

    /// `check_invariants` plus a visited bitmap (`page_count` bits from `gpa`, freed before
    /// return): every page is reached exactly once, so a cycle or a shared child is `Corrupted`.
    /// This is the only place the tree allocates. Cost: O(pages) fetches.
    pub fn validate(self: *Tree, io: Io, gpa: Allocator) ValidateError!void {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        const bytes_len = @divFloor(@as(usize, self.pool.pages.page_count) + 7, 8);
        const visited = try gpa.alloc(u8, bytes_len);
        defer gpa.free(visited);

        @memset(visited, 0);
        try validate_mod.run(self.pool, io, self.root, visited);
    }
};

/// The in-place edit: replace or insert the cell and re-seal. Room was proven by the caller.
fn edit_leaf(
    guard: *buffer_pool.PageGuard,
    id: Id,
    slot: node.Slot,
    key: []const u8,
    value: []const u8,
) InsertError!void {
    assert(id != .file_header);
    assert(slot.index <= node.cell_count_max(node.page_size_of(guard.bytes())));
    const lsn = header.peek(guard.bytes()).lsn;
    const page = guard.bytes_mut();
    if (slot.found) try node.leaf_remove(page, slot.index);
    node.leaf_insert(page, slot.index, key, .{ .bytes = value }) catch |err| switch (err) {
        error.Corrupted => return error.Corrupted,
        error.NodeFull => unreachable, // The caller checked count and bytes on this same page.
    };
    node.seal(page, id, lsn);
    const after = try node.parse_leaf(page);
    assert(after.count >= 1);
}

/// Total bytes of an inline cell for these lengths (matches `node`'s encoding).
fn cell_bytes_of(key_len: u32, value_len: u32) u32 {
    assert(key_len <= node.key_len_cap);
    assert(value_len <= node.value_len_max);
    return codec.varint.encoded_size(key_len) + codec.varint.encoded_size(value_len) +
        key_len + value_len;
}

/// Size of the existing cell at `index`; a spilled (overflow) cell cannot exist at this stage.
fn cell_bytes(leaf: node.Leaf, index: u16) node.ParseError!u32 {
    assert(index < leaf.count);
    assert(leaf.count <= node.cell_count_max(node.page_size_of(leaf.page)));
    const entry = try leaf.entry(index);
    switch (entry.value) {
        .bytes => |bytes| {
            return cell_bytes_of(@intCast(entry.key.len), @intCast(bytes.len));
        },
        .overflow => return error.Corrupted,
    }
}

/// The cells that would border `key` after the edit must exist, decode and order around it, so
/// that the later unchecked-by-construction steps cannot fail half way.
fn check_neighbours(leaf: node.Leaf, slot: node.Slot, key: []const u8) node.ParseError!void {
    assert(slot.index <= leaf.count);
    assert(!slot.found or slot.index < leaf.count);
    if (slot.index > 0) {
        const before = try leaf.entry(slot.index - 1);
        if (std.mem.order(u8, before.key, key) != .lt) return error.Corrupted;
    }
    const upper = @as(u32, slot.index) + @intFromBool(slot.found);
    if (upper < leaf.count) {
        const after = try leaf.entry(@intCast(upper));
        if (std.mem.order(u8, key, after.key) != .lt) return error.Corrupted;
    }
}

test {
    _ = @import("tree_test.zig"); // Contract tests live in their own files (800-line limit).
    _ = @import("split_tree_test.zig");
    _ = @import("delete_tree_test.zig");
    _ = @import("validate_test.zig");
}
