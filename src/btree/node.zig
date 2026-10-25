//! B+Tree node pages (ADR-0004): per-page-size limits and the leaf cell codec over frame bytes.
//!
//! Layout (payload offsets are page offsets minus 24): `cell_count u16 | level u8 | reserved u8 |
//! link u32`, then a `u16` slot table growing up from payload offset 8, a zeroed gap, and dense,
//! ordered cells growing down from the page end. A leaf cell is `key_len varint | value_len
//! varint | key | value` (inline) or `... | key | head u32` (overflow); the form is a pure
//! function of `value_inline`, so one key set has exactly one byte image.
//! Invariants: bytes read from a page are untrusted data, so every malformed offset, varint,
//! length or form is `error.Corrupted` and never an assert, an out-of-bounds read or a panic;
//! only caller contracts (a valid page size, an index within the parsed count, a key within
//! `key_len_max`, key order at an insert) are asserted. Mutators check, before writing, that the
//! bytes they move lie inside the page.
//! Allocation: none. Every function is pure over caller-owned slices and takes no `io`
//! (ADR-0001). Mutators edit frame bytes only and leave the page checksum stale: a caller ends
//! an edit with `seal`, which stamps the header and CRC through `page/header.zig`.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const frame = @import("../wal/frame.zig");

pub const Id = header.Id;

pub const height_limit: u8 = 16;
pub const value_len_max: u32 = 1 << 20;
pub const slot_size: u32 = 2;

pub const payload_start: u32 = 8; // Payload offset of slot 0.
const images_header_size: u32 = 8; // `count` + `page_size` of a page_images frame (ADR section 9).
const image_id_size: u32 = 4;
pub const offset_count: u32 = 24;
pub const offset_level: u32 = 26;
pub const offset_reserved: u32 = 27;
pub const offset_link: u32 = 28;
pub const offset_slots: u32 = 32;
pub const offset_type: u32 = 4;
pub const key_len_cap: u32 = 1024;
const cell_overhead_max: u32 = 10; // two 3-byte varints plus a 4-byte overflow head.
pub const search_steps_max: u32 = 16; // 2^16 > cell_count_max at every page size.

pub const ParseError = error{Corrupted};
pub const InsertError = error{ NodeFull, Corrupted };
pub const Overflow = struct { head: Id, len: u32 };
pub const Value = union(enum) { bytes: []const u8, overflow: Overflow };
pub const Entry = struct { key: []const u8, value: Value };
pub const Slot = struct { index: u16, found: bool };

/// Bytes available to the slot table plus cells (ADR section 2).
pub fn usable(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    assert(page_size > offset_slots);
    return page_size - offset_slots;
}

/// Largest one cell may be; with its slot it is at most a quarter of `usable`.
pub fn cell_bytes_max(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    const quarter = @divFloor(usable(page_size), 4);
    assert(quarter > slot_size);
    return quarter - slot_size;
}

/// Largest key a node accepts at this page size (ADR section 2).
pub fn key_len_max(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    const bound = cell_bytes_max(page_size) - cell_overhead_max;
    assert(bound > 0);
    return @min(bound, key_len_cap);
}

/// True when a value of `value_len` bytes lives inside the leaf cell (ADR section 2).
pub fn value_inline(page_size: u32, key_len: u32, value_len: u32) bool {
    assert(header.page_size_valid(page_size));
    assert(cell_bytes_max(page_size) > 0);
    const key_vs = codec.varint.encoded_size(key_len);
    const value_vs = codec.varint.encoded_size(value_len);
    const total: u64 = @as(u64, key_vs) + value_vs + key_len + value_len;
    return total <= cell_bytes_max(page_size);
}

/// Data bytes one overflow page holds.
pub fn overflow_capacity(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    return usable(page_size);
}

/// Fill below which a non-root node is underfull (ADR section 8).
pub fn underflow_bytes(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    return @divFloor(usable(page_size), 4);
}

/// Most cells a node may hold: smallest cell 2 B plus its 2 B slot.
pub fn cell_count_max(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    return @divFloor(usable(page_size), 4); // Smallest cell 2 B plus its 2 B slot.
}

/// Page images one `page_images` frame holds (ADR section 9).
pub fn images_per_frame_max(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    assert(frame.payload_bytes_max > images_header_size);
    return @divFloor(frame.payload_bytes_max - images_header_size, page_size + image_id_size);
}

/// Deepest tree whose worst-case split cascade fits one `page_images` frame.
pub fn height_max(page_size: u32) u8 {
    assert(header.page_size_valid(page_size));
    const images = images_per_frame_max(page_size);
    assert(images >= 1);
    return @intCast(@min(@as(u32, height_limit), @divFloor(images - 1, 2)));
}

comptime {
    for (0..8) |shift| {
        const ps: u32 = header.page_size_min << @intCast(shift);
        const ops: u32 = 2 * @as(u32, height_max(ps)) + 1;
        assert(images_header_size + ops * (image_id_size + ps) <= frame.payload_bytes_max);
        assert(4 * (cell_bytes_max(ps) + slot_size) <= usable(ps));
        assert(ps - header.header_size <= std.math.maxInt(u16));
        assert(height_max(ps) >= 7);
        assert(key_len_max(ps) + cell_overhead_max <= cell_bytes_max(ps));
    }
    assert(cell_bytes_max(512) == 118);
    assert(key_len_max(512) == 108);
    assert(key_len_max(65536) == 1024);
    assert(height_max(65536) == 7);
    assert(codec.varint.encoded_size(value_len_max) == 3);
}

pub fn get16(page: []const u8, offset: u32) u32 {
    assert(offset + 2 <= page.len);
    assert(offset >= header.header_size);
    return std.mem.readInt(u16, page[offset..][0..2], .little);
}

pub fn put16(page: []u8, offset: u32, value: u32) void {
    assert(offset + 2 <= page.len);
    assert(offset >= header.header_size);
    assert(value <= std.math.maxInt(u16));
    std.mem.writeInt(u16, page[offset..][0..2], @intCast(value), .little);
}

pub fn get32(page: []const u8, offset: u32) u32 {
    assert(offset + 4 <= page.len);
    assert(offset >= header.header_size);
    return std.mem.readInt(u32, page[offset..][0..4], .little);
}

pub fn put32(page: []u8, offset: u32, value: u32) void {
    assert(offset + 4 <= page.len);
    assert(offset >= header.header_size);
    std.mem.writeInt(u32, page[offset..][0..4], value, .little);
}

pub fn page_size_of(page: []const u8) u32 {
    assert(page.len <= header.page_size_max);
    assert(header.page_size_valid(@intCast(page.len)));
    return @intCast(page.len);
}

/// Decodes one cell that must span exactly `cell` (ADR section 10 `cell(i)` checks).
fn parse_cell(page_size: u32, cell: []const u8) ParseError!Entry {
    assert(header.page_size_valid(page_size));
    assert(cell.len <= page_size);
    const key_varint = codec.varint.decode(cell) catch return error.Corrupted;
    if (key_varint.value > key_len_max(page_size)) return error.Corrupted;
    const value_varint = codec.varint.decode(cell[key_varint.size..]) catch return error.Corrupted;
    if (value_varint.value > value_len_max) return error.Corrupted;
    const key_len: u32 = @intCast(key_varint.value);
    const value_len: u32 = @intCast(value_varint.value);
    const lengths_size = key_varint.size + value_varint.size;
    const in_cell = value_inline(page_size, key_len, value_len);
    const tail_size: u32 = if (in_cell) value_len else 4;
    if (lengths_size + key_len + tail_size != cell.len) return error.Corrupted;
    const key = cell[lengths_size..][0..key_len];
    const tail = cell[lengths_size + key_len ..];
    if (in_cell) return .{ .key = key, .value = .{ .bytes = tail } };
    const head = std.mem.readInt(u32, tail[0..4], .little);
    if (head == 0) return error.Corrupted;
    const spill: Overflow = .{ .head = @enumFromInt(head), .len = value_len };
    return .{ .key = key, .value = .{ .overflow = spill } };
}

/// A parsed leaf: a read-only view that borrows its page. Re-parse after any mutation.
pub const Leaf = struct {
    page: []const u8,
    count: u16,
    next: ?Id,
    /// Payload offset of the lowest cell; the payload end when the leaf is empty.
    lowest: u32,

    fn payload_end(self: Leaf) u32 {
        assert(self.page.len > header.header_size);
        assert(self.page.len <= header.page_size_max);
        return @intCast(self.page.len - header.header_size);
    }

    /// Payload offset stored in slot `index`; unchecked data. Precondition: `index < count`.
    pub fn slot(self: Leaf, index: u32) u32 {
        assert(index < self.count);
        assert(self.count <= cell_count_max(page_size_of(self.page)));
        return get16(self.page, offset_slots + slot_size * index);
    }

    /// Payload offset where cell `index` must end: the page end or the previous cell's start.
    fn cell_end(self: Leaf, index: u32) u32 {
        assert(index < self.count);
        assert(self.lowest <= self.payload_end());
        if (index == 0) return self.payload_end();
        return self.slot(index - 1);
    }

    /// Slot table plus cell bytes in use.
    pub fn used_bytes(self: Leaf) u32 {
        assert(self.lowest <= self.payload_end());
        assert(self.count <= cell_count_max(page_size_of(self.page)));
        return slot_size * self.count + (self.payload_end() - self.lowest);
    }

    /// Reads and checks cell `index` (ADR section 10 `cell(i)`). Precondition: `index < count`.
    pub fn entry(self: Leaf, index: u16) ParseError!Entry {
        assert(index < self.count);
        const page_size = page_size_of(self.page);
        const start = self.slot(index);
        const end = self.cell_end(index);
        if (start < payload_start + slot_size * self.count) return error.Corrupted;
        if (end > self.payload_end() or start >= end) return error.Corrupted;
        const cell = self.page[header.header_size + start .. header.header_size + end];
        return parse_cell(page_size, cell);
    }

    /// Binary search in bytewise order (ADR section 7). Verifies the cells it touches.
    pub fn search(self: Leaf, key: []const u8) ParseError!Slot {
        assert(key.len <= std.math.maxInt(u32));
        var low: u32 = 0;
        var high: u32 = self.count;
        for (0..search_steps_max) |_| {
            if (low >= high) break;
            const mid = low + @divFloor(high - low, 2);
            const probe = try self.entry(@intCast(mid));
            switch (std.mem.order(u8, probe.key, key)) {
                .eq => return .{ .index = @intCast(mid), .found = true },
                .lt => low = mid + 1,
                .gt => high = mid,
            }
        }
        assert(low >= high); // The step bound covers every cell_count_max.
        return .{ .index = @intCast(low), .found = false };
    }

    /// The `next` link rule that needs the page's own id: a leaf never links to itself.
    pub fn check_link(self: Leaf, id: Id) ParseError!void {
        assert(id != .file_header);
        if (self.next) |next| {
            if (next == id) return error.Corrupted;
        }
        assert(self.count <= cell_count_max(page_size_of(self.page)));
    }

    /// Full O(n) check: every cell, strict key order and the zero gap (ADR section 10).
    pub fn check_invariants(self: Leaf) ParseError!void {
        assert(self.lowest <= self.payload_end());
        var previous: ?[]const u8 = null;
        for (0..self.count) |index| {
            const current = try self.entry(@intCast(index));
            if (previous) |before| {
                if (std.mem.order(u8, before, current.key) != .lt) return error.Corrupted;
            }
            previous = current.key;
        }
        const gap_start = header.header_size + payload_start + slot_size * self.count;
        const gap_end = header.header_size + self.lowest;
        if (!std.mem.allEqual(u8, self.page[gap_start..gap_end], 0)) return error.Corrupted;
        assert(gap_start <= gap_end);
    }
};

/// Writes a complete empty leaf image: clears `page`, stores `next`, stamps the header and CRC.
/// Preconditions: `page.len` is a valid page size and `id` is not the file header.
pub fn format_leaf(page: []u8, id: Id, next: ?Id, lsn: u64) void {
    const page_size = page_size_of(page);
    assert(id != .file_header);
    @memset(page, 0);
    put32(page, offset_link, if (next) |link| @intFromEnum(link) else 0);
    header.encode(page, id, .{ .page_type = .btree_leaf, .lsn = lsn });
    assert(page_size == page.len);
}

/// Re-stamps header, `lsn` and checksum after byte edits; keeps the node's page type.
pub fn seal(page: []u8, id: Id, lsn: u64) void {
    _ = page_size_of(page);
    const page_type = header.peek(page).page_type;
    assert(@intFromEnum(page_type) >= @intFromEnum(header.Type.btree_leaf));
    assert(@intFromEnum(page_type) <= @intFromEnum(header.Type.btree_overflow));
    header.encode(page, id, .{ .page_type = page_type, .lsn = lsn });
}

/// Sets a leaf's right-neighbour link. Precondition: `page` is a leaf (type byte 16).
pub fn set_next(page: []u8, next: ?Id) void {
    _ = page_size_of(page);
    assert(page[offset_type] == @intFromEnum(header.Type.btree_leaf));
    const raw: u32 = if (next) |link| @intFromEnum(link) else 0;
    put32(page, offset_link, raw);
    assert(get32(page, offset_link) == raw);
}

/// O(1) parse of a leaf page (ADR section 10 `parse`): type, level, reserved, count, slot table
/// against the lowest cell. The page's own id is not in its bytes: see `Leaf.check_link`.
pub fn parse_leaf(page: []const u8) ParseError!Leaf {
    const page_size = page_size_of(page);
    if (page[offset_type] != @intFromEnum(header.Type.btree_leaf)) return error.Corrupted;
    if (page[offset_level] != 0 or page[offset_reserved] != 0) return error.Corrupted;
    const count = get16(page, offset_count);
    if (count > cell_count_max(page_size)) return error.Corrupted;
    const payload_end = page_size - header.header_size;
    const last_slot = offset_slots + slot_size * (count -| 1);
    const lowest = if (count == 0) payload_end else get16(page, last_slot);
    if (lowest > payload_end) return error.Corrupted;
    if (payload_start + slot_size * count > lowest) return error.Corrupted;
    const link = get32(page, offset_link);
    return .{
        .page = page,
        .count = @intCast(count),
        .next = if (link == 0) null else @enumFromInt(link),
        .lowest = lowest,
    };
}

/// Bytes a cell takes; asserts the form is the canonical one for the sizes involved.
fn cell_size(page_size: u32, key: []const u8, value: Value) u32 {
    assert(key.len <= key_len_max(page_size));
    const key_len: u32 = @intCast(key.len);
    const key_vs = codec.varint.encoded_size(key_len);
    switch (value) {
        .bytes => |bytes| {
            assert(bytes.len <= value_len_max);
            const value_len: u32 = @intCast(bytes.len);
            assert(value_inline(page_size, key_len, value_len));
            return key_vs + codec.varint.encoded_size(value_len) + key_len + value_len;
        },
        .overflow => |spill| {
            assert(spill.len <= value_len_max);
            assert(spill.head != .file_header);
            assert(!value_inline(page_size, key_len, spill.len));
            return key_vs + codec.varint.encoded_size(spill.len) + key_len + 4;
        },
    }
}

fn encode_cell(cell: []u8, key: []const u8, value: Value) void {
    assert(cell.len >= key.len + 2);
    const key_len: u32 = @intCast(key.len);
    var at: u32 = codec.varint.encode(cell, key_len) catch |err| switch (err) {
        error.BufferTooSmall => unreachable, // `cell_size` sized `cell`, so the varint fits.
    };
    const value_len: u32 = switch (value) {
        .bytes => |bytes| @intCast(bytes.len),
        .overflow => |spill| spill.len,
    };
    at += codec.varint.encode(cell[at..], value_len) catch |err| switch (err) {
        error.BufferTooSmall => unreachable, // `cell_size` sized `cell`, so the varint fits.
    };
    @memcpy(cell[at..][0..key.len], key);
    at += key_len;
    switch (value) {
        .bytes => |bytes| @memcpy(cell[at..][0..bytes.len], bytes),
        .overflow => |spill| {
            std.mem.writeInt(u32, cell[at..][0..4], @intFromEnum(spill.head), .little);
        },
    }
    assert(at < cell.len or value_len == 0);
}

/// Inserts a cell so it becomes slot `index`, moving the cells below it down by the cell size.
/// Returns `error.NodeFull` when cell plus slot do not fit and `error.Corrupted` when the bytes
/// to move are not inside the page. Preconditions: `page` is a leaf, `index <= count`,
/// `key.len <= key_len_max`, the value form matches `value_inline`, and `key` sorts strictly
/// between its neighbours (asserted; they are verified first). The checksum goes stale.
pub fn leaf_insert(page: []u8, index: u16, key: []const u8, value: Value) InsertError!void {
    const page_size = page_size_of(page);
    const leaf = try parse_leaf(page);
    assert(index <= leaf.count);
    const size = cell_size(page_size, key, value);
    assert(size >= 2); // Two length varints at least.
    if (leaf.count >= cell_count_max(page_size)) return error.NodeFull;
    if (leaf.used_bytes() + size + slot_size > usable(page_size)) return error.NodeFull;
    // The neighbours are untrusted bytes: an order mismatch with them is a bad page or a bad
    // index, reported before any write so the page stays byte-identical.
    if (index > 0) {
        const before = try leaf.entry(index - 1);
        if (std.mem.order(u8, before.key, key) != .lt) return error.Corrupted;
    }
    if (index < leaf.count) {
        const after = try leaf.entry(index);
        if (std.mem.order(u8, key, after.key) != .lt) return error.Corrupted;
    }
    const high = if (index == 0) page_size - header.header_size else leaf.slot(index - 1);
    for (index..leaf.count) |j| {
        const start = leaf.slot(@intCast(j));
        if (start < leaf.lowest or start > high) return error.Corrupted;
    }
    const base = header.header_size;
    const moved = page[base + leaf.lowest .. base + high];
    std.mem.copyForwards(u8, page[base + leaf.lowest - size ..][0..moved.len], moved);
    const slot_at = offset_slots + slot_size * @as(u32, index);
    const slots = page[slot_at .. offset_slots + slot_size * leaf.count];
    std.mem.copyBackwards(u8, page[slot_at + slot_size ..][0..slots.len], slots);
    for (index + 1..@as(u32, leaf.count) + 1) |j| {
        const shifted = get16(page, offset_slots + slot_size * @as(u32, @intCast(j)));
        put16(page, offset_slots + slot_size * @as(u32, @intCast(j)), shifted - size);
    }
    put16(page, offset_slots + slot_size * index, high - size);
    encode_cell(page[base + high - size .. base + high], key, value);
    put16(page, offset_count, @as(u32, leaf.count) + 1);
    assert((try parse_leaf(page)).count == leaf.count + 1);
}

/// Removes slot `index`, closing the gap: cells below it move up and the vacated bytes are
/// zeroed. Returns `error.Corrupted` (page unchanged) if the cell or the bytes to move are not
/// inside the page. Preconditions: `page` is a leaf and `index < count`.
pub fn leaf_remove(page: []u8, index: u16) ParseError!void {
    _ = page_size_of(page);
    const leaf = try parse_leaf(page);
    assert(index < leaf.count);
    _ = try leaf.entry(index);
    const start = leaf.slot(index);
    const size = leaf.cell_end(index) - start;
    assert(size >= 2); // `entry` accepted the cell, so it holds both length varints.
    if (start < leaf.lowest) return error.Corrupted;
    for (index + 1..leaf.count) |j| {
        const later = leaf.slot(@intCast(j));
        if (later < leaf.lowest or later > start) return error.Corrupted;
    }
    const base = header.header_size;
    const moved = page[base + leaf.lowest .. base + start];
    std.mem.copyBackwards(u8, page[base + leaf.lowest + size ..][0..moved.len], moved);
    @memset(page[base + leaf.lowest ..][0..size], 0);
    const table_end = offset_slots + slot_size * leaf.count;
    const tail = page[offset_slots + slot_size * (index + 1) .. table_end];
    std.mem.copyForwards(u8, page[offset_slots + slot_size * index ..][0..tail.len], tail);
    @memset(page[table_end - slot_size .. table_end], 0);
    for (index..leaf.count - 1) |j| {
        const at = offset_slots + slot_size * @as(u32, @intCast(j));
        put16(page, at, get16(page, at) + size);
    }
    put16(page, offset_count, @as(u32, leaf.count) - 1);
    assert((try parse_leaf(page)).count + 1 == leaf.count);
}

test {
    _ = @import("node_test.zig"); // Contract tests live in their own file (800-line limit).
}
