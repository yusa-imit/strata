//! Overflow chains for values that are not inline (ADR-0004 sections 2, 6, 9): a value of `v`
//! bytes lives in `n = ceil(v / overflow_capacity)` pages of type 18, each `next u32 | len u32 |
//! data`, the rest of the page zero. `write` builds a chain, `walk` reads or checks one, and
//! `read` assembles one into a caller buffer.
//!
//! Invariants: every page but the last has `len == capacity` and `next != 0`; the last has
//! `next == 0` and `len == v - (n - 1) * capacity`; `n <= 2185` (1 MiB at 512 B). The reader walks
//! exactly `n` pages. Any other shape is `Corrupted`: a wrong page type, a wrong `len`, a `next`
//! that is 0 early, nonzero at the end, its own id or at or past `page_count`. A cycle can never
//! end in a page with `next == 0`, so walking exactly `n` pages names it without a visited set;
//! with a `visited` bitmap (validation) a page reached twice is `Corrupted` as well.
//! Every byte read is untrusted data, so malformed input is a typed error, never an assert.
//! Allocation: none; ids come from the page manager, frames from the pool. A walk holds one pin.
//! Logging: none yet (plan 005 item 9 adds one `page_images` frame per chunk, rule C).
//! Failure of `write`: the ids it allocated so far are in `ids[0..written]`; the caller owns
//! them and pushes them to `frees_pending` (the tree reserves the room before it writes).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");

const BufferPool = buffer_pool.BufferPool;
const Id = header.Id;

pub const offset_next: u32 = 24;
pub const offset_len: u32 = 28;
pub const offset_data: u32 = 32;
/// Pages of the longest chain: 1 MiB at 512 B pages (ADR-0004 section 2).
pub const chain_pages_max: u32 = 2185;

pub const WriteError = manager.AllocateError || buffer_pool.FetchNewError;
pub const ChainError = buffer_pool.FetchError || node.ParseError;

/// Where `walk` puts what it sees; every field is optional.
pub const Sink = struct {
    /// Receives the value bytes; length at least the value length.
    data: ?[]u8 = null,
    /// Receives the page ids in chain order; length at least the chain length.
    ids: ?[]Id = null,
    /// Visited bitmap of the whole tree (validation): marks each page, a second visit is
    /// `Corrupted`. Also turns on the check that the unused tail of every page is zero.
    visited: ?[]u8 = null,
};

/// Pages a value of `value_len` bytes needs at this page size (the cell form fixes it).
pub fn chain_len(page_size: u32, value_len: u32) u32 {
    assert(value_len >= 1 and value_len <= node.value_len_max);
    const capacity = node.overflow_capacity(page_size);
    const pages = @divFloor(value_len + capacity - 1, capacity);
    assert(pages >= 1 and pages <= chain_pages_max);
    return pages;
}

/// Marks `id` in the bitmap; a page already marked is shared, which is `Corrupted`.
pub fn mark_visited(bits: []u8, id: Id) node.ParseError!void {
    const raw = @intFromEnum(id);
    assert(raw != 0);
    assert(bits.len * 8 > raw);
    const mask = @as(u8, 1) << @intCast(raw % 8);
    if (bits[@divFloor(raw, 8)] & mask != 0) return error.Corrupted;
    bits[@divFloor(raw, 8)] |= mask;
}

/// Writes `value` (1 ..= `value_len_max` bytes) as a new chain and returns its head id. Each
/// allocated id is stored in `ids` at once and counted in `written`, so after an error the
/// caller can free `ids[0..written]`. Precondition: `ids.len >= chain_len`.
pub fn write(
    pool: *BufferPool,
    io: Io,
    value: []const u8,
    ids: []Id,
    written: *u32,
) WriteError!Id {
    assert(value.len >= 1 and value.len <= node.value_len_max);
    const page_size = pool.page_size;
    const capacity = node.overflow_capacity(page_size);
    const pages = chain_len(page_size, @intCast(value.len));
    assert(ids.len >= pages);
    written.* = 0;
    ids[0] = try pool.pages.allocate(io);
    written.* = 1;
    for (0..pages) |index| {
        const last = index + 1 == pages;
        if (!last) {
            ids[index + 1] = try pool.pages.allocate(io);
            written.* = @intCast(index + 2);
        }
        const start: u32 = @intCast(index * capacity);
        const len: u32 = @min(capacity, @as(u32, @intCast(value.len)) - start);
        const next: u32 = if (last) 0 else @intFromEnum(ids[index + 1]);
        var pinned = try pool.fetchNew(io, ids[index]);
        defer pinned.release();

        const page = pinned.bytes_mut();
        @memset(page, 0);
        node.put32(page, offset_next, next);
        node.put32(page, offset_len, len);
        @memcpy(page[offset_data..][0..len], value[start..][0..len]);
        header.encode(page, ids[index], .{ .page_type = .btree_overflow, .lsn = 0 });
    }
    assert(written.* == pages);
    return ids[0];
}

/// Walks exactly `chain_len` pages from `spill.head`, checking the shape of each, and feeds
/// `sink`. Any wrong shape is `Corrupted`; the page layer's typed errors pass through.
pub fn walk(pool: *BufferPool, io: Io, spill: node.Overflow, sink: Sink) ChainError!void {
    assert(spill.head != .file_header);
    const page_size = pool.page_size;
    const capacity = node.overflow_capacity(page_size);
    const pages = chain_len(page_size, spill.len);
    if (sink.data) |data| assert(data.len >= spill.len);
    if (sink.ids) |ids| assert(ids.len >= pages);
    var id = spill.head;
    var offset: u32 = 0;
    for (0..pages) |index| {
        if (id == .file_header or @intFromEnum(id) >= pool.pages.page_count) {
            return error.Corrupted;
        }
        if (sink.visited) |bits| try mark_visited(bits, id);
        var pinned = try pool.fetch(io, id);
        defer pinned.release();

        const page = pinned.bytes();
        if (page[node.offset_type] != @intFromEnum(header.Type.btree_overflow)) {
            return error.Corrupted;
        }
        const last = index + 1 == pages;
        const len = node.get32(page, offset_len);
        const next = node.get32(page, offset_next);
        if (len != (if (last) spill.len - offset else capacity)) return error.Corrupted;
        if ((next == 0) != last or next == @intFromEnum(id)) return error.Corrupted;
        if (sink.visited != null) {
            if (!std.mem.allEqual(u8, page[offset_data + len ..], 0)) return error.Corrupted;
        }
        if (sink.data) |data| @memcpy(data[offset..][0..len], page[offset_data..][0..len]);
        if (sink.ids) |ids| ids[index] = id;
        offset += len;
        id = @enumFromInt(next);
    }
    assert(offset == spill.len);
}

/// Assembles the value of `spill` into `out` and returns the filled prefix. A buffer shorter
/// than the value is the caller's contract (asserted); the tree checks it first.
pub fn read(pool: *BufferPool, io: Io, spill: node.Overflow, out: []u8) ChainError![]const u8 {
    assert(out.len >= spill.len);
    assert(spill.len >= 1);
    try walk(pool, io, spill, .{ .data = out });
    return out[0..spill.len];
}

/// Stores the ids of the chain of `spill` in `ids[0..chain_len]` after checking its shape.
pub fn collect_ids(pool: *BufferPool, io: Io, spill: node.Overflow, ids: []Id) ChainError!void {
    assert(ids.len >= chain_len(pool.page_size, spill.len));
    assert(spill.len >= 1);
    try walk(pool, io, spill, .{ .ids = ids });
}
