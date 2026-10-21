//! B+Tree internal node cells (ADR-0004 sections 3, 5, 7, 10): the codec over frame bytes.
//!
//! An internal cell is `key_len varint | key | child u32 LE` (child != 0). The header is the
//! leaf's (`cell_count u16 | level u8 | reserved 0 | link u32`) with `level` in
//! `1 .. height_limit - 1` and `link` = `right_child` (!= 0). Slot table and dense, ordered cell
//! layout are exactly the leaf's. `child[i]` holds the keys `sep[i-1] <= k < sep[i]` and
//! `right_child` holds the keys `k >= sep[count-1]`, so a key equal to a separator descends right.
//! Invariants: bytes read from a page are untrusted data, so every malformed offset, varint,
//! length or zero child is `error.Corrupted`, never an assert or a panic; only caller contracts
//! (a valid page size, an index within the parsed count, a key within `key_len_max`, a non-zero
//! child) are asserted. A node with `cell_count == 0` is valid only while it is being built:
//! `format_internal` writes one, `parse_internal` refuses it (every internal node has at least 2
//! children) and only `internal_insert` accepts it, through `parse_internal_raw`.
//! Allocation: none. Mutators edit frame bytes only and leave the page checksum stale: a caller
//! ends an edit with `node.seal`.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("../codec.zig");
const header = @import("../page/header.zig");
const node = @import("node.zig");

pub const Id = header.Id;
pub const ParseError = node.ParseError;
pub const InsertError = node.InsertError;
pub const InternalEntry = struct { key: []const u8, child: Id };

const child_size: u32 = 4;

/// A parsed internal node: a read-only view that borrows its page. Re-parse after any mutation.
pub const Internal = struct {
    page: []const u8,
    count: u16,
    level: u8,
    right_child: Id,
    /// Payload offset of the lowest cell; the payload end when the node has no cell yet.
    lowest: u32,

    fn payload_end(self: Internal) u32 {
        assert(self.page.len > header.header_size);
        assert(self.page.len <= header.page_size_max);
        return @intCast(self.page.len - header.header_size);
    }

    /// Payload offset stored in slot `index`; unchecked data. Precondition: `index < count`.
    pub fn slot(self: Internal, index: u32) u32 {
        assert(index < self.count);
        assert(self.count <= node.cell_count_max(node.page_size_of(self.page)));
        return node.get16(self.page, node.offset_slots + node.slot_size * index);
    }

    /// Payload offset where cell `index` must end: the page end or the previous cell's start.
    fn cell_end(self: Internal, index: u32) u32 {
        assert(index < self.count);
        assert(self.lowest <= self.payload_end());
        if (index == 0) return self.payload_end();
        return self.slot(index - 1);
    }

    /// Slot table plus cell bytes in use.
    pub fn used_bytes(self: Internal) u32 {
        assert(self.lowest <= self.payload_end());
        assert(self.count <= node.cell_count_max(node.page_size_of(self.page)));
        return node.slot_size * self.count + (self.payload_end() - self.lowest);
    }

    /// Reads and checks cell `index` (ADR section 10 `cell(i)`). Precondition: `index < count`.
    pub fn entry(self: Internal, index: u16) ParseError!InternalEntry {
        assert(index < self.count);
        const page_size = node.page_size_of(self.page);
        const start = self.slot(index);
        const end = self.cell_end(index);
        if (start < node.payload_start + node.slot_size * self.count) return error.Corrupted;
        if (end > self.payload_end() or start >= end) return error.Corrupted;
        const cell = self.page[header.header_size + start .. header.header_size + end];
        const key_varint = codec.varint.decode(cell) catch return error.Corrupted;
        if (key_varint.value > node.key_len_max(page_size)) return error.Corrupted;
        const key_len: u32 = @intCast(key_varint.value);
        if (key_varint.size + key_len + child_size != cell.len) return error.Corrupted;
        const key = cell[key_varint.size..][0..key_len];
        const raw = std.mem.readInt(u32, cell[key_varint.size + key_len ..][0..4], .little);
        if (raw == 0) return error.Corrupted;
        return .{ .key = key, .child = @enumFromInt(raw) };
    }

    /// Descent slot for `key`: the number of separators <= `key`, in `0 .. count`. Slot `count`
    /// is `right_child`; a key equal to a separator goes right of it. Verifies the cells it
    /// touches.
    pub fn child_index(self: Internal, key: []const u8) ParseError!u16 {
        assert(key.len <= std.math.maxInt(u32));
        var low: u32 = 0;
        var high: u32 = self.count;
        for (0..node.search_steps_max) |_| {
            if (low >= high) break;
            const mid = low + @divFloor(high - low, 2);
            const probe = try self.entry(@intCast(mid));
            switch (std.mem.order(u8, probe.key, key)) {
                .lt, .eq => low = mid + 1,
                .gt => high = mid,
            }
        }
        assert(low >= high); // The step bound covers every cell_count_max.
        return @intCast(low);
    }

    /// Child page id at descent slot `index` in `0 .. count`; `count` is `right_child`.
    pub fn child_at(self: Internal, index: u16) ParseError!Id {
        assert(index <= self.count);
        assert(self.right_child != .file_header);
        if (index == self.count) return self.right_child;
        return (try self.entry(index)).child;
    }

    /// The link rule that needs the page's own id (O(1)): `right_child` is never the node itself.
    pub fn check_link(self: Internal, id: Id) ParseError!void {
        assert(id != .file_header);
        if (self.right_child == id) return error.Corrupted;
        assert(self.right_child != .file_header); // `parse_internal_raw` refused link 0.
        assert(self.right_child != id);
    }

    /// O(n) companion of `check_link`: no cell child is the node itself.
    pub fn check_children(self: Internal, id: Id) ParseError!void {
        assert(id != .file_header);
        try self.check_link(id);
        for (0..self.count) |index| {
            if ((try self.entry(@intCast(index))).child == id) return error.Corrupted;
        }
    }

    /// Full O(n) check: every cell, strict key order and the zero gap (ADR section 10).
    pub fn check_invariants(self: Internal) ParseError!void {
        assert(self.lowest <= self.payload_end());
        var previous: ?[]const u8 = null;
        for (0..self.count) |index| {
            const current = try self.entry(@intCast(index));
            if (previous) |before| {
                if (std.mem.order(u8, before, current.key) != .lt) return error.Corrupted;
            }
            previous = current.key;
        }
        const gap_start = header.header_size + node.payload_start + node.slot_size * self.count;
        const gap_end = header.header_size + self.lowest;
        if (!std.mem.allEqual(u8, self.page[gap_start..gap_end], 0)) return error.Corrupted;
        assert(gap_start <= gap_end);
    }
};

/// Writes a node image with no cell yet: clears `page`, stores `level` and `right_child`, stamps
/// the header and CRC. Such a node is not a valid internal node until a cell is inserted.
/// Preconditions: valid page size, `id` and `right_child` are not the file header, they differ,
/// and `level` is in `1 .. height_limit - 1`.
pub fn format_internal(page: []u8, id: Id, level: u8, right_child: Id, lsn: u64) void {
    const page_size = node.page_size_of(page);
    assert(id != .file_header);
    assert(right_child != .file_header);
    assert(right_child != id);
    assert(level >= 1 and level < node.height_limit);
    @memset(page, 0);
    page[node.offset_level] = level;
    node.put32(page, node.offset_link, @intFromEnum(right_child));
    header.encode(page, id, .{ .page_type = .btree_internal, .lsn = lsn });
    assert(page[node.offset_level] == level);
    assert(node.get32(page, node.offset_link) == @intFromEnum(right_child));
    assert(node.get16(page, node.offset_count) == 0 and page_size == page.len);
}

/// Sets the right-most child. Precondition: `page` is internal (type byte 17), `child != 0`.
pub fn set_right_child(page: []u8, child: Id) void {
    _ = node.page_size_of(page);
    assert(page[node.offset_type] == @intFromEnum(header.Type.btree_internal));
    assert(child != .file_header);
    node.put32(page, node.offset_link, @intFromEnum(child));
    assert(node.get32(page, node.offset_link) == @intFromEnum(child));
}

/// O(1) parse of an internal page that allows `cell_count == 0` (a node under construction).
pub fn parse_internal_raw(page: []const u8, level: u8) ParseError!Internal {
    const page_size = node.page_size_of(page);
    if (page[node.offset_type] != @intFromEnum(header.Type.btree_internal)) return error.Corrupted;
    if (level < 1 or level >= node.height_limit) return error.Corrupted;
    if (page[node.offset_level] != level or page[node.offset_reserved] != 0) return error.Corrupted;
    const count = node.get16(page, node.offset_count);
    if (count > node.cell_count_max(page_size)) return error.Corrupted;
    const payload_end = page_size - header.header_size;
    const last_slot = node.offset_slots + node.slot_size * (count -| 1);
    const lowest = if (count == 0) payload_end else node.get16(page, last_slot);
    if (lowest > payload_end) return error.Corrupted;
    if (node.payload_start + node.slot_size * count > lowest) return error.Corrupted;
    const link = node.get32(page, node.offset_link);
    if (link == 0) return error.Corrupted;
    assert(count <= node.cell_count_max(page_size));
    assert(lowest <= payload_end);
    return .{
        .page = page,
        .count = @intCast(count),
        .level = level,
        .right_child = @enumFromInt(link),
        .lowest = lowest,
    };
}

/// O(1) parse of an internal page (ADR section 10 `parse`): type 17, `level` (which must equal
/// the byte and lie in `1 .. height_limit - 1`), reserved, `1 <= count <= cell_count_max`, slot
/// table against the lowest cell and `right_child != 0`. See `Internal.check_link` for the id.
pub fn parse_internal(page: []const u8, level: u8) ParseError!Internal {
    const view = try parse_internal_raw(page, level);
    if (view.count == 0) return error.Corrupted;
    assert(view.right_child != .file_header);
    return view;
}

fn encode_cell(cell: []u8, key: []const u8, child: Id) void {
    assert(cell.len == key.len + 1 + child_size or cell.len == key.len + 2 + child_size);
    assert(child != .file_header);
    const key_len: u32 = @intCast(key.len);
    var at: u32 = codec.varint.encode(cell, key_len) catch |err| switch (err) {
        error.BufferTooSmall => unreachable, // `cell` was sized from the varint width.
    };
    @memcpy(cell[at..][0..key.len], key);
    at += key_len;
    std.mem.writeInt(u32, cell[at..][0..4], @intFromEnum(child), .little);
    assert(at + child_size == cell.len);
}

/// Inserts a cell so it becomes slot `index`, moving the cells below it down by the cell size.
/// Returns `error.NodeFull` when cell plus slot do not fit and `error.Corrupted` when the bytes
/// to move are not inside the page or a neighbour does not sort around `key`; in both cases the
/// page is byte-identical. Preconditions: `page` is internal (a fresh `format_internal` node is
/// fine), `index <= count`, `key.len <= key_len_max`, `child != 0`. The checksum goes stale.
pub fn internal_insert(page: []u8, index: u16, key: []const u8, child: Id) InsertError!void {
    const page_size = node.page_size_of(page);
    const view = try parse_internal_raw(page, page[node.offset_level]);
    assert(index <= view.count);
    assert(key.len <= node.key_len_max(page_size));
    assert(child != .file_header);
    const key_len: u32 = @intCast(key.len);
    const size: u32 = codec.varint.encoded_size(key_len) + key_len + child_size;
    if (view.count >= node.cell_count_max(page_size)) return error.NodeFull;
    if (view.used_bytes() + size + node.slot_size > node.usable(page_size)) return error.NodeFull;
    if (index > 0) {
        const before = try view.entry(index - 1);
        if (std.mem.order(u8, before.key, key) != .lt) return error.Corrupted;
    }
    if (index < view.count) {
        const after = try view.entry(index);
        if (std.mem.order(u8, key, after.key) != .lt) return error.Corrupted;
    }
    const high = if (index == 0) page_size - header.header_size else view.slot(index - 1);
    for (index..view.count) |j| {
        const start = view.slot(@intCast(j));
        if (start < view.lowest or start > high) return error.Corrupted;
    }
    shift_down(page, view, index, high, size);
    const at = node.offset_slots + node.slot_size * @as(u32, index);
    node.put16(page, at, high - size);
    const base = header.header_size;
    encode_cell(page[base + high - size .. base + high], key, child);
    node.put16(page, node.offset_count, @as(u32, view.count) + 1);
    assert((try parse_internal(page, view.level)).count == view.count + 1);
}

/// Opens the cell gap for `internal_insert`: cells `index ..` move down by `size` and the slots
/// from `index` shift up one entry, each offset reduced by `size`. Bytes are in range (checked).
fn shift_down(page: []u8, view: Internal, index: u16, high: u32, size: u32) void {
    assert(high <= view.payload_end());
    assert(index <= view.count);
    // `internal_insert` proved room: slot table, cells and the new cell all fit under `usable`.
    assert(view.lowest >= size + node.payload_start + node.slot_size * view.count);
    const base = header.header_size;
    const moved = page[base + view.lowest .. base + high];
    std.mem.copyForwards(u8, page[base + view.lowest - size ..][0..moved.len], moved);
    const slot_at = node.offset_slots + node.slot_size * @as(u32, index);
    const slots = page[slot_at .. node.offset_slots + node.slot_size * view.count];
    std.mem.copyBackwards(u8, page[slot_at + node.slot_size ..][0..slots.len], slots);
    for (index + 1..@as(u32, view.count) + 1) |j| {
        const at = node.offset_slots + node.slot_size * @as(u32, @intCast(j));
        node.put16(page, at, node.get16(page, at) - size);
    }
}

/// Replaces the child of cell `index` (the tree needs it after a child splits). Returns
/// `error.Corrupted`, page unchanged, if the node or the cell is not valid. Preconditions: `page`
/// is internal, `index < count`, `child != 0`. The checksum goes stale.
pub fn set_child(page: []u8, index: u16, child: Id) ParseError!void {
    _ = node.page_size_of(page);
    assert(child != .file_header);
    const view = try parse_internal(page, page[node.offset_level]);
    assert(index < view.count);
    _ = try view.entry(index); // The cell is validated, so its last 4 bytes are the child.
    const end = header.header_size + view.cell_end(index);
    std.mem.writeInt(u32, page[end - child_size ..][0..4], @intFromEnum(child), .little);
    assert((try view.entry(index)).child == child);
}

/// Removes slot `index`, closing the gap: cells below it move up and the vacated bytes are
/// zeroed. The child of the removed cell leaves the node with it. Returns `error.Corrupted`
/// (page unchanged) if the cell or the bytes to move are not inside the page. Preconditions:
/// `page` is internal, `index < count` and `count > 1`: a cell is never removed from a 1-cell
/// node, because that node still has two children and the tree merges or collapses it instead.
pub fn internal_remove(page: []u8, index: u16) ParseError!void {
    _ = node.page_size_of(page);
    const view = try parse_internal(page, page[node.offset_level]);
    assert(index < view.count);
    assert(view.count > 1);
    _ = try view.entry(index);
    const start = view.slot(index);
    const size = view.cell_end(index) - start;
    assert(size >= 2 + child_size - 1); // `entry` accepted the cell: varint, key and child.
    if (start < view.lowest) return error.Corrupted;
    for (index + 1..view.count) |j| {
        const later = view.slot(@intCast(j));
        if (later < view.lowest or later > start) return error.Corrupted;
    }
    const base = header.header_size;
    const moved = page[base + view.lowest .. base + start];
    std.mem.copyBackwards(u8, page[base + view.lowest + size ..][0..moved.len], moved);
    @memset(page[base + view.lowest ..][0..size], 0);
    const table_end = node.offset_slots + node.slot_size * view.count;
    const tail = page[node.offset_slots + node.slot_size * (index + 1) .. table_end];
    const head_at = node.offset_slots + node.slot_size * index;
    std.mem.copyForwards(u8, page[head_at..][0..tail.len], tail);
    @memset(page[table_end - node.slot_size .. table_end], 0);
    for (index..view.count - 1) |j| {
        const at = node.offset_slots + node.slot_size * @as(u32, @intCast(j));
        node.put16(page, at, node.get16(page, at) + size);
    }
    node.put16(page, node.offset_count, @as(u32, view.count) - 1);
    assert((try parse_internal(page, view.level)).count + 1 == view.count);
}

test {
    _ = @import("internal_test.zig"); // Contract tests live in their own file (800-line limit).
}
