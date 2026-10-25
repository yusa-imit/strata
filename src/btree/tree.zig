//! B+Tree over the buffer pool (ADR-0004), root-leaf stage: `create` allocates the fixed root
//! page (section 8), `get` and `insert` work on that one leaf. A leaf that cannot take the edit
//! is `error.NodeFull`; splitting, internal nodes, overflow values and logging arrive in later
//! plan 005 items, so this stage is unlogged (page `lsn`s are kept as they are).
//!
//! Invariants: `root` is a page id allocated by `create`, never 0 and never changed; the root
//! page is a leaf (type 16, level 0) whose cells are strictly ascending (section 7); every byte
//! read from the page is untrusted data, so a malformed page is `Corrupted` (the page layer's
//! `Unwritten`, `ChecksumMismatch` and `TornWrite` pass through) and never an assert.
//! Allocation: none. The tree stores a borrowed `*BufferPool` and the root id, takes no `gpa`
//! (the pool allocated every frame at its own `init`) and never stores an `Io`: `io` is the
//! first parameter after the receiver of every method that can touch the file (ADR-0001).
//! Ownership: the tree does not own the pool or the page manager; both must outlive it and no
//! guard of the tree outlives a call. The caller persists `root` (there is no meta page).
//! Atomicity: an insert that fails (`KeyTooLarge`, `ValueTooLarge`, `NodeFull`, a typed read
//! error) changes no byte of the page; the only checks that happen after the first byte moves
//! cannot fail because the same facts were verified before (section 9 prepare/apply split).
//! Borrowing: `get` returns a slice into a pool frame, see its doc for the lifetime.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");

const BufferPool = buffer_pool.BufferPool;
const Id = header.Id;

/// `create` pops or grows an id, then pins it new; an id that was allocated before a later
/// failure leaks, which ADR-0002 calls safe.
pub const CreateError = manager.AllocateError || buffer_pool.FetchNewError;

/// Read-only failures: the page layer's typed errors, plus `Corrupted` for a root page whose
/// checksum is right but whose layout is not a valid leaf.
pub const CheckError = buffer_pool.FetchError || node.ParseError;

/// `KeyTooLarge`: the key is longer than `node.key_len_max(page_size)`.
pub const GetError = CheckError || error{KeyTooLarge};

/// `ValueTooLarge`: over `node.value_len_max`, or not inline at this page size (overflow values
/// are a later item). `NodeFull`: the leaf has no room (no split yet).
pub const InsertError = GetError || error{ ValueTooLarge, NodeFull };

pub const Tree = struct {
    pool: *BufferPool,
    root: Id,
    page_size: u32,

    /// Allocates the root id from the page manager and writes an empty leaf there, in the pool
    /// (dirty, not yet on disk: `flushAll` and the caller's `sync` make it durable). The root
    /// id is persisted by the caller. On error nothing in `target` is set.
    pub fn create(target: *Tree, io: Io, pool: *BufferPool) CreateError!void {
        assert(pool.page_size == pool.pages.page_size);
        assert(header.page_size_valid(pool.page_size));
        const id = try pool.pages.allocate(io);
        var guard = try pool.fetchNew(io, id);
        defer guard.release();

        node.format_leaf(guard.bytes_mut(), id, null, 0);
        target.* = .{ .pool = pool, .root = id, .page_size = pool.page_size };
        assert(target.root != .file_header);
        assert(@intFromEnum(target.root) < pool.pages.page_count);
    }

    /// Attaches to an existing tree whose root id the caller persisted. Reads nothing: a bad
    /// root surfaces from the first `get` or `insert`. Preconditions: `0 < root < page_count`.
    pub fn open(target: *Tree, pool: *BufferPool, root: Id) void {
        assert(root != .file_header);
        assert(@intFromEnum(root) < pool.pages.page_count);
        target.* = .{ .pool = pool, .root = root, .page_size = pool.page_size };
        assert(target.page_size == pool.pages.page_size);
    }

    /// The value stored under `key`, or null when absent. The slice borrows a pool frame: it
    /// stays valid until the next call on this tree or any fetch on its pool (a fetch may evict
    /// the frame), and is overwritten by the next write to the root; copy it to keep it. A key
    /// longer than `key_len_max` is `KeyTooLarge` (no such key can exist). Cost: one fetch of the
    /// root and a binary search that checks only the cells it touches.
    pub fn get(self: *Tree, io: Io, key: []const u8) GetError!?[]const u8 {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        if (key.len > node.key_len_max(self.page_size)) return error.KeyTooLarge;
        var guard = try self.pool.fetch(io, self.root);
        defer guard.release();

        const leaf = try self.root_leaf(guard.bytes());
        const slot = try leaf.search(key);
        if (!slot.found) return null;
        const entry = try leaf.entry(slot.index);
        switch (entry.value) {
            .bytes => |bytes| return bytes,
            .overflow => return error.Corrupted, // Overflow cells are never written yet.
        }
    }

    /// Stores `value` under `key`, replacing the value of an existing key. The leaf is edited in
    /// place and re-sealed (checksum, same `lsn`); nothing is written to the file until the pool
    /// writes the frame back. Errors are checked before the first byte moves, so a failed insert
    /// leaves the page as it was. A replacement that grows the cell beyond the free space is
    /// `NodeFull` too, and the old value stays.
    pub fn insert(self: *Tree, io: Io, key: []const u8, value: []const u8) InsertError!void {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        if (key.len > node.key_len_max(self.page_size)) return error.KeyTooLarge;
        if (value.len > node.value_len_max) return error.ValueTooLarge;
        const value_len: u32 = @intCast(value.len); // Bounded by `value_len_max` just above.
        const key_len: u32 = @intCast(key.len); // Bounded by `key_len_max` just above.
        if (!node.value_inline(self.page_size, key_len, value_len)) return error.ValueTooLarge;

        var guard = try self.pool.fetchForUpdate(io, self.root);
        defer guard.release();

        const leaf = try self.root_leaf(guard.bytes());
        const slot = try leaf.search(key);
        try check_neighbours(leaf, slot, key);
        const freed = if (slot.found) try cell_bytes(leaf, slot.index) else 0;
        const added = cell_bytes_of(key_len, value_len);
        const grows_count = !slot.found and leaf.count >= node.cell_count_max(self.page_size);
        const slot_added: u32 = if (slot.found) 0 else node.slot_size;
        const used_after = leaf.used_bytes() - freed + added + slot_added;
        if (grows_count or used_after > node.usable(self.page_size)) return error.NodeFull;

        const lsn = header.peek(guard.bytes()).lsn;
        const page = guard.bytes_mut();
        if (slot.found) try node.leaf_remove(page, slot.index);
        try node.leaf_insert(page, slot.index, key, .{ .bytes = value });
        node.seal(page, self.root, lsn);
        const after = try node.parse_leaf(page);
        assert(after.count == leaf.count + @intFromBool(!slot.found));
    }

    /// Full O(n) check of the root leaf: link, every cell, strict key order, zero gap.
    pub fn check_invariants(self: *Tree, io: Io) CheckError!void {
        assert(self.page_size == self.pool.page_size);
        assert(self.root != .file_header);
        var guard = try self.pool.fetch(io, self.root);
        defer guard.release();

        const leaf = try self.root_leaf(guard.bytes());
        try leaf.check_invariants();
    }

    /// O(1) parse of the root page plus the rule that needs its id (no self link).
    fn root_leaf(self: *const Tree, page: []const u8) node.ParseError!node.Leaf {
        assert(page.len == self.page_size);
        assert(self.root != .file_header);
        const leaf = try node.parse_leaf(page);
        try leaf.check_link(self.root);
        return leaf;
    }
};

/// Total bytes of an inline cell for these lengths (matches `node`'s encoding).
fn cell_bytes_of(key_len: u32, value_len: u32) u32 {
    assert(key_len <= 1024);
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
    _ = @import("tree_test.zig"); // Contract tests live in their own file (800-line limit).
}
