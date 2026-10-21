//! Contract tests for `internal.zig` internal-node cells (ADR-0004 sections 3, 5, 7, 10, 11).
//!
//! Expected values are independent of the codec: golden pages are committed bytes, limits are
//! literals from the ADR section 2 table, and the model tests compare against a sorted array that
//! never looks at page bytes. Offsets in the corruption tests are for a 512 B page whose three
//! cells (`a`, `c`, `e`) are 6 B each at payload offsets 482, 476 and 470.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const split = @import("split.zig");

const Id = header.Id;
const page_sizes = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };

fn id_of(raw: u32) Id {
    assert(raw > 0);
    assert(raw < 1 << 20);
    return @enumFromInt(raw);
}

fn put16(page: []u8, offset: usize, value: u16) void {
    assert(offset + 2 <= page.len);
    assert(offset >= 24);
    std.mem.writeInt(u16, page[offset..][0..2], value, .little);
}

fn put32(page: []u8, offset: usize, value: u32) void {
    assert(offset + 4 <= page.len);
    assert(offset >= 24);
    std.mem.writeInt(u32, page[offset..][0..4], value, .little);
}

fn new_internal(gpa: std.mem.Allocator, page_size: u32, id: Id, right: Id) ![]u8 {
    assert(header.page_size_valid(page_size));
    assert(id != right);
    const page = try gpa.alloc(u8, page_size);
    @memset(page, 0xAA); // format_internal must overwrite stale bytes.
    internal.format_internal(page, id, 1, right, 0);
    return page;
}

fn three_cells(gpa: std.mem.Allocator) ![]u8 {
    const page = try new_internal(gpa, 512, id_of(2), id_of(20));
    errdefer gpa.free(page);

    assert(page.len == 512);
    try internal.internal_insert(page, 0, "a", id_of(11));
    try internal.internal_insert(page, 1, "c", id_of(12));
    try internal.internal_insert(page, 2, "e", id_of(13));
    node.seal(page, id_of(2), 0);
    try (try internal.parse_internal(page, 1)).check_invariants();
    return page;
}

test "golden internal node at 512 bytes matches the ADR section 11 image" {
    const gpa = std.testing.allocator;
    const page = try new_internal(gpa, 512, id_of(2), id_of(4));
    defer gpa.free(page);

    try internal.internal_insert(page, 0, "kiwi", id_of(3));
    node.seal(page, id_of(2), 0);

    var expected: [512]u8 = @splat(0);
    const head = [_]u8{ 0x53, 0x54, 0x52, 0x41, 0x11, 0x00, 0x01, 0x00, 0xac, 0x51, 0x2e, 0x33 };
    @memcpy(expected[0..12], &head);
    @memcpy(expected[24..32], &[_]u8{ 0x01, 0x00, 0x01, 0x00, 0x04, 0x00, 0x00, 0x00 });
    @memcpy(expected[32..34], &[_]u8{ 0xdf, 0x01 });
    @memcpy(expected[503..512], &[_]u8{ 4, 'k', 'i', 'w', 'i', 3, 0, 0, 0 });
    try std.testing.expectEqualSlices(u8, &expected, page);
    try std.testing.expectEqual(@as(u32, 0x332E51AC), header.checksum(page, id_of(2)));
    _ = try header.decode(page, id_of(2));

    const view = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(@as(u16, 1), view.count);
    try std.testing.expectEqual(id_of(4), view.right_child);
    const cell = try view.entry(0);
    try std.testing.expectEqualStrings("kiwi", cell.key);
    try std.testing.expectEqual(id_of(3), cell.child);
    try view.check_invariants();
}

test "format_internal: empty node is canonical, unparseable until a cell exists" {
    const gpa = std.testing.allocator;
    for (page_sizes) |ps| {
        const page = try new_internal(gpa, ps, id_of(5), id_of(6));
        defer gpa.free(page);

        try std.testing.expectError(error.Corrupted, internal.parse_internal(page, 1));
        const open = try internal.parse_internal_raw(page, 1);
        try std.testing.expectEqual(@as(u16, 0), open.count);
        try std.testing.expectEqual(id_of(6), open.right_child);
        try std.testing.expect(std.mem.allEqual(u8, page[32..], 0));
        try std.testing.expectEqual(@as(u8, 17), page[4]);
        try internal.internal_insert(page, 0, "m", id_of(7));
        const view = try internal.parse_internal(page, 1);
        try std.testing.expectEqual(@as(u16, 1), view.count);
        internal.set_right_child(page, id_of(8));
        try std.testing.expectEqual(id_of(8), (try internal.parse_internal(page, 1)).right_child);
        try view.check_link(id_of(5));
    }
}

test "check_link: a right_child equal to the node's own id is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    const view = try internal.parse_internal(page, 1);
    try view.check_link(id_of(2));
    try std.testing.expectError(error.Corrupted, view.check_link(id_of(20)));
    try view.check_children(id_of(2));
    try std.testing.expectError(error.Corrupted, view.check_children(id_of(12)));
}

const Pair = struct { raw: u32, child: u32 };

fn model_key(buf: *[4]u8, raw: u32) []const u8 {
    assert(buf.len == 4);
    assert(@sizeOf(u32) == buf.len);
    assert(raw < 1 << 20);
    std.mem.writeInt(u32, buf, raw, .big);
    return buf;
}

/// Finds the first model position whose raw key is >= `raw`.
fn model_lower(items: []const Pair, raw: u32) usize {
    assert(items.len < 1 << 20);
    assert(raw < 1 << 20);
    var at: usize = 0;
    while (at < items.len and items[at].raw < raw) at += 1;
    return at;
}

fn expect_matches(page: []u8, items: []const Pair) !void {
    assert(page.len >= 512);
    assert(items.len > 0);
    const view = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(items.len, view.count);
    try view.check_invariants();
    for (items, 0..) |pair, i| {
        var buf: [4]u8 = undefined;
        const cell = try view.entry(@intCast(i));
        try std.testing.expectEqualSlices(u8, model_key(&buf, pair.raw), cell.key);
        try std.testing.expectEqual(id_of(pair.child), cell.child);
        try std.testing.expectEqual(id_of(pair.child), try view.child_at(@intCast(i)));
    }
    try std.testing.expectEqual(id_of(999), try view.child_at(view.count));
}

fn run_model(gpa: std.mem.Allocator, page_size: u32, seed: u64, ops: u32) !void {
    assert(header.page_size_valid(page_size));
    assert(ops > 0);
    assert(seed != 0);
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    const page = try new_internal(gpa, page_size, id_of(2), id_of(999));
    defer gpa.free(page);

    var model: std.ArrayList(Pair) = .empty;
    defer model.deinit(gpa);

    var full_seen = false;
    for (0..ops) |_| {
        const raw = random.uintLessThan(u32, 600);
        const at = model_lower(model.items, raw);
        const present = at < model.items.len and model.items[at].raw == raw;
        if (present or (model.items.len > 1 and random.uintLessThan(u8, 3) == 0)) {
            if (!present or model.items.len < 2) continue;
            try internal.internal_remove(page, @intCast(at));
            _ = model.orderedRemove(at);
        } else {
            var buf: [4]u8 = undefined;
            const child = 1 + random.uintLessThan(u32, 1000);
            const key = model_key(&buf, raw);
            const result = internal.internal_insert(page, @intCast(at), key, id_of(child));
            if (result) {
                try model.insert(gpa, at, .{ .raw = raw, .child = child });
            } else |err| switch (err) {
                error.NodeFull => {
                    // Oracle: a 9 B cell plus its 2 B slot genuinely did not fit.
                    try std.testing.expect(11 * (model.items.len + 1) > page_size - 32);
                    full_seen = true;
                },
                error.Corrupted => return error.TestUnexpectedResult,
            }
        }
        if (model.items.len > 0) try expect_matches(page, model.items);
    }
    if (page_size == 512) try std.testing.expect(full_seen);
}

test "model: random insert and remove at every page size matches a sorted array" {
    const gpa = std.testing.allocator;
    for (page_sizes, 0..) |ps, i| {
        try run_model(gpa, ps, 0x1217 + i, if (ps == 512) 4000 else 1500);
    }
}

test "child_index: key below, at, between and above separators; empty key" {
    const gpa = std.testing.allocator;
    const page = try new_internal(gpa, 512, id_of(2), id_of(20));
    defer gpa.free(page);

    try internal.internal_insert(page, 0, "b", id_of(11));
    try internal.internal_insert(page, 1, "d", id_of(12));
    try internal.internal_insert(page, 2, "f", id_of(13));
    const view = try internal.parse_internal(page, 1);
    const keys = [_][]const u8{ "", "a", "b", "bz", "c", "d", "e", "f", "g", "\xff" };
    const expected = [_]u16{ 0, 0, 1, 1, 1, 2, 2, 3, 3, 3 };
    for (keys, expected) |key, want| {
        try std.testing.expectEqual(want, try view.child_index(key));
    }
    try std.testing.expectEqual(id_of(11), try view.child_at(0));
    try std.testing.expectEqual(id_of(13), try view.child_at(2));
    try std.testing.expectEqual(id_of(20), try view.child_at(3));

    // An empty separator sends the empty key right of slot 0.
    const zero = try new_internal(gpa, 512, id_of(2), id_of(20));
    defer gpa.free(zero);

    try internal.internal_insert(zero, 0, "", id_of(11));
    const lone = try internal.parse_internal(zero, 1);
    try std.testing.expectEqual(@as(u16, 1), try lone.child_index(""));
    try std.testing.expectEqual(@as(u16, 1), try lone.child_index("a"));
}

fn expect_corrupt_parse(page: []u8, level: u8) !void {
    assert(page.len >= 512);
    assert(level < 255);
    try std.testing.expectError(error.Corrupted, internal.parse_internal(page, level));
}

fn expect_corrupt_entry(page: []u8, index: u16) !void {
    assert(page.len >= 512);
    assert(index < 3);
    const view = try internal.parse_internal(page, 1);
    const result = view.entry(index);
    try std.testing.expectError(error.Corrupted, result);
    try std.testing.expectError(error.Corrupted, view.check_invariants());
}

test "parse: level mismatch and out-of-range levels are Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    _ = try internal.parse_internal(page, 1);
    try expect_corrupt_parse(page, 2);
    try expect_corrupt_parse(page, 0);
    page[26] = 0;
    try expect_corrupt_parse(page, 0);
    page[26] = node.height_limit;
    try expect_corrupt_parse(page, node.height_limit);
    page[26] = node.height_limit - 1;
    _ = try internal.parse_internal(page, node.height_limit - 1);
}

test "parse: wrong page type is Corrupted in both directions" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    page[4] = 16;
    try expect_corrupt_parse(page, 1);
    page[4] = 18;
    try expect_corrupt_parse(page, 1);
    page[4] = 17;
    _ = try internal.parse_internal(page, 1);
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
}

test "parse: reserved byte must be zero" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    page[27] = 1;
    try expect_corrupt_parse(page, 1);
}

test "parse: cell_count 0 and above cell_count_max are Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put16(page, 24, 0);
    try expect_corrupt_parse(page, 1);
    // 120 = cell_count_max(512) passes the count rule, but the last slot is then read from
    // zeroed bytes: offset 0 is under the slot table.
    put16(page, 24, 120);
    try expect_corrupt_parse(page, 1);
    put16(page, 24, 121); // One above cell_count_max.
    try expect_corrupt_parse(page, 1);
    put16(page, 24, 65535);
    try expect_corrupt_parse(page, 1);
}

test "parse: right_child 0 is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put32(page, 28, 0);
    try expect_corrupt_parse(page, 1);
}

test "parse: lowest cell offset outside the payload or under the slot table is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put16(page, 36, 489); // last slot beyond the payload end (488).
    try expect_corrupt_parse(page, 1);
    put16(page, 36, 13); // under 8 + 2 * 3 = 14.
    try expect_corrupt_parse(page, 1);
}

test "entry: cell child 0 is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put32(page, 24 + 482 + 2, 0);
    try expect_corrupt_entry(page, 0);
}

test "entry: a slot below the slot table end is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put16(page, 32, 13);
    try expect_corrupt_entry(page, 0);
}

test "entry: a gap or overlap between neighbouring cells is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    put16(page, 34, 474); // Gap: cell 1 would span 474 .. 482 = 8 B, but it holds 6 B.
    try expect_corrupt_entry(page, 1);
    put16(page, 34, 480); // Cell 1 would span 480 .. 482 = 2 B, too short for its 6 B.
    try expect_corrupt_entry(page, 1);
    put16(page, 34, 486); // Overlap: cell 1 would start at 486, past cell 0's start at 482.
    try expect_corrupt_entry(page, 1);
}

/// Hand-encodes a one-cell node whose cell is `klen` bytes of 'k' plus child 3, right_child 4.
fn craft_one_cell(page: []u8, klen: u8) void {
    assert(page.len == 512);
    assert(klen < 128); // One varint byte.
    internal.format_internal(page, id_of(2), 1, id_of(4), 0);
    const size: u32 = 1 + @as(u32, klen) + 4;
    const start: u32 = 488 - size;
    put16(page, 24, 1);
    put16(page, 32, @intCast(start));
    page[24 + start] = klen;
    @memset(page[24 + start + 1 ..][0..klen], 'k');
    put32(page, 24 + start + 1 + klen, 3);
    node.seal(page, id_of(2), 0);
}

test "entry: key_len above key_len_max is Corrupted, key_len_max itself is fine" {
    const gpa = std.testing.allocator;
    const page = try gpa.alloc(u8, 512);
    defer gpa.free(page);

    craft_one_cell(page, 108); // key_len_max(512) = 108; the cell is 113 of 118 B.
    const fine = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(@as(usize, 108), (try fine.entry(0)).key.len);
    craft_one_cell(page, 109); // A well-formed 114 B cell, but its key is one byte too long.
    const view = try internal.parse_internal(page, 1);
    try std.testing.expectError(error.Corrupted, view.entry(0));
    try std.testing.expectError(error.Corrupted, view.check_invariants());
}

test "entry: key_len that does not span the cell exactly (trailing or missing bytes)" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    page[24 + 482] = 0; // 1 + 0 + 4 = 5 of 6 B: one trailing garbage byte.
    try expect_corrupt_entry(page, 0);
    page[24 + 482] = 2; // 1 + 2 + 4 = 7 of 6 B: the child runs past the cell.
    try expect_corrupt_entry(page, 0);
    page[24 + 482] = 0x80; // truncated varint continuation.
    try expect_corrupt_entry(page, 0);
}

test "check_invariants: duplicate keys, descending keys and a dirty gap are Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    page[24 + 476 + 1] = 'a'; // sep[1] = "a" equals sep[0].
    try expect_invariants_corrupted(page);
    page[24 + 476 + 1] = 'c';
    page[24 + 476 + 1] = 'A'; // "A" < "a": descending.
    try expect_invariants_corrupted(page);
    page[24 + 476 + 1] = 'c';
    try (try internal.parse_internal(page, 1)).check_invariants();
    page[40] = 1; // gap starts at 32 + 6 = 38.
    try expect_invariants_corrupted(page);
}

fn expect_invariants_corrupted(page: []u8) !void {
    assert(page.len >= 512);
    assert(page[4] == 17);
    const view = try internal.parse_internal(page, 1);
    try std.testing.expectError(error.Corrupted, view.check_invariants());
}

fn expect_unchanged(before: []const u8, page: []const u8) !void {
    assert(before.len == page.len);
    assert(page.len >= 512);
    try std.testing.expectEqualSlices(u8, before, page);
}

test "internal_insert: NodeFull is returned before the first write; exact fit vs one over" {
    const gpa = std.testing.allocator;
    const page = try new_internal(gpa, 512, id_of(2), id_of(20));
    defer gpa.free(page);

    var key: [108]u8 = undefined;
    for (0..4) |i| { // 4 * (1 + 108 + 4 + 2) = 460 of 480 B.
        @memset(&key, 'b' + @as(u8, @intCast(i)));
        try internal.internal_insert(page, @intCast(i), &key, id_of(10 + @as(u32, @intCast(i))));
    }
    const before = try gpa.dupe(u8, page);
    defer gpa.free(before);

    @memset(key[0..14], 'z'); // 1 + 14 + 4 + 2 = 21 B > 20 B left.
    const over = internal.internal_insert(page, 4, key[0..14], id_of(50));
    try std.testing.expectError(error.NodeFull, over);
    try expect_unchanged(before, page);

    try internal.internal_insert(page, 4, key[0..13], id_of(50)); // 20 B: exactly fits.
    const full = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(@as(u32, 480), full.used_bytes());
    try full.check_invariants();
    const after = try gpa.dupe(u8, page);
    defer gpa.free(after);

    const none = internal.internal_insert(page, 0, "", id_of(51)); // 7 B into 0 B left.
    try std.testing.expectError(error.NodeFull, none);
    try expect_unchanged(after, page);
}

test "max-size keys: key_len_max fits, fills to the oracle count, then NodeFull" {
    const gpa = std.testing.allocator;
    const key_max = [_]u32{ 108, 236, 492, 1004, 1024, 1024, 1024, 1024 };
    for (page_sizes, key_max) |ps, klen| {
        const page = try new_internal(gpa, ps, id_of(2), id_of(3));
        defer gpa.free(page);

        const varint: u32 = if (klen < 128) 1 else 2;
        const per_cell = varint + klen + 4 + 2;
        const fit = (ps - 32) / per_cell;
        const key = try gpa.alloc(u8, klen);
        defer gpa.free(key);

        @memset(key, 'k');
        for (0..fit) |i| {
            std.mem.writeInt(u16, key[0..2], @intCast(i), .big);
            try internal.internal_insert(page, @intCast(i), key, id_of(10 + @as(u32, @intCast(i))));
        }
        const before = try gpa.dupe(u8, page);
        defer gpa.free(before);

        std.mem.writeInt(u16, key[0..2], @intCast(fit), .big);
        const result = internal.internal_insert(page, @intCast(fit), key, id_of(7));
        try std.testing.expectError(error.NodeFull, result);
        try expect_unchanged(before, page);
        const view = try internal.parse_internal(page, 1);
        try std.testing.expectEqual(fit, view.count);
        try view.check_invariants();
        try std.testing.expectEqual(klen, (try view.entry(0)).key.len);
        try std.testing.expectEqual(klen, (try view.entry(@intCast(fit - 1))).key.len);
    }
}

test "internal_insert: unsorted neighbours or a wrong index are Corrupted, page unchanged" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    const before = try gpa.dupe(u8, page);
    defer gpa.free(before);

    try std.testing.expectError(error.Corrupted, internal.internal_insert(page, 1, "c", id_of(9)));
    try std.testing.expectError(error.Corrupted, internal.internal_insert(page, 1, "z", id_of(9)));
    try std.testing.expectError(error.Corrupted, internal.internal_insert(page, 0, "a", id_of(9)));
    try std.testing.expectError(error.Corrupted, internal.internal_insert(page, 3, "d", id_of(9)));
    try expect_unchanged(before, page);
    // Cells 0 and 1 stay valid, but the last slot (the lowest cell) now sits above slot 1: the
    // bytes to move do not lie in the page, which only the move-range loop can notice.
    put16(page, 36, 486);
    const before_bad = try gpa.dupe(u8, page);
    defer gpa.free(before_bad);

    const view = try internal.parse_internal(page, 1);
    _ = try view.entry(0);
    _ = try view.entry(1);
    try std.testing.expectError(error.Corrupted, internal.internal_insert(page, 1, "b", id_of(9)));
    try expect_unchanged(before_bad, page);
}

test "internal_remove: closes the gap, zeroes it, and a bad slot is Corrupted unchanged" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    try internal.internal_remove(page, 1);
    var view = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(@as(u16, 2), view.count);
    try view.check_invariants();
    try std.testing.expectEqualStrings("e", (try view.entry(1)).key);
    try std.testing.expect(std.mem.allEqual(u8, page[36 .. 24 + 476], 0));
    try std.testing.expectEqual(id_of(20), view.right_child);
    try internal.internal_remove(page, 1);
    view = try internal.parse_internal(page, 1);
    try std.testing.expectEqual(@as(u16, 1), view.count);
    try std.testing.expectEqualStrings("a", (try view.entry(0)).key);

    const bad = try three_cells(gpa);
    defer gpa.free(bad);

    put16(bad, 36, 500); // Past the payload end: parse itself refuses the node.
    const before = try gpa.dupe(u8, bad);
    defer gpa.free(before);

    try std.testing.expectError(error.Corrupted, internal.internal_remove(bad, 0));
    try expect_unchanged(before, bad);
}

fn four_cells(gpa: std.mem.Allocator) ![]u8 {
    const page = try new_internal(gpa, 512, id_of(2), id_of(20));
    errdefer gpa.free(page);

    assert(page.len == 512);
    assert(page[4] == 17);
    const keys = [_][]const u8{ "a", "c", "e", "g" };
    for (keys, 0..) |key, i| {
        try internal.internal_insert(page, @intCast(i), key, id_of(11 + @as(u32, @intCast(i))));
    }
    node.seal(page, id_of(2), 0);
    return page;
}

test "internal_remove: slots outside [lowest, start] parse but are Corrupted, page unchanged" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { index: u16, slot: u16, offset: usize }{
        .{ .index = 1, .slot = 478, .offset = 36 }, // a later slot above `start` (476).
        .{ .index = 1, .slot = 460, .offset = 36 }, // a later slot below the lowest cell (464).
        .{ .index = 0, .slot = 486, .offset = 38 }, // the lowest slot above `start` (482).
    };
    for (cases) |case| {
        const page = try four_cells(gpa);
        defer gpa.free(page);

        put16(page, case.offset, case.slot);
        const view = try internal.parse_internal(page, 1); // The bad slot is not caught here.
        _ = try view.entry(case.index);
        const before = try gpa.dupe(u8, page);
        defer gpa.free(before);

        try std.testing.expectError(error.Corrupted, internal.internal_remove(page, case.index));
        try expect_unchanged(before, page);
    }
}

test "set_child: replaces one child, validates first, leaves the page unchanged on Corrupted" {
    const gpa = std.testing.allocator;
    const page = try three_cells(gpa);
    defer gpa.free(page);

    try internal.set_child(page, 1, id_of(77));
    const view = try internal.parse_internal(page, 1);
    try view.check_invariants();
    try std.testing.expectEqual(id_of(77), (try view.entry(1)).child);
    try std.testing.expectEqual(id_of(11), (try view.entry(0)).child);
    try std.testing.expectEqual(id_of(13), (try view.entry(2)).child);
    try std.testing.expectEqualStrings("c", (try view.entry(1)).key);

    put16(page, 34, 474); // Cell 1 no longer spans its 6 B.
    const before = try gpa.dupe(u8, page);
    defer gpa.free(before);

    try std.testing.expectError(error.Corrupted, internal.set_child(page, 1, id_of(5)));
    try expect_unchanged(before, page);
    put32(page, 28, 0); // right_child 0: the node itself is invalid.
    const before_node = try gpa.dupe(u8, page);
    defer gpa.free(before_node);

    try std.testing.expectError(error.Corrupted, internal.set_child(page, 0, id_of(5)));
    try expect_unchanged(before_node, page);
}

/// A valid node of 2..5 cells (ascending keys of 1..6 bytes), the base the sweep mutates.
fn random_valid(page: []u8, random: std.Random) !void {
    assert(page.len >= 512);
    assert(page.len <= header.page_size_max);
    internal.format_internal(page, id_of(2), 1 + random.uintLessThan(u8, 3), id_of(9), 0);
    const cells = 2 + random.uintLessThan(u8, 4);
    for (0..cells) |i| {
        var key: [6]u8 = undefined;
        random.bytes(&key);
        key[0] = @intCast(10 * i + random.uintLessThan(usize, 10)); // Strictly ascending.
        const len = 1 + random.uintLessThan(usize, 6);
        const child = id_of(1 + @as(u32, random.int(u8)));
        try internal.internal_insert(page, @intCast(i), key[0..len], child);
    }
}

/// Flips 1..3 bytes: half in the header and slot table, half in the cell area at the page end.
fn mutate(page: []u8, random: std.Random) void {
    assert(page.len >= 512);
    assert(page.len <= header.page_size_max);
    for (0..1 + random.uintLessThan(u8, 3)) |_| {
        const at = if (random.boolean())
            24 + random.uintLessThan(usize, 24)
        else
            page.len - 1 - random.uintLessThan(usize, 48);
        page[at] = random.int(u8);
    }
}

const Sweep = struct { parsed: u32 = 0, total: u32 = 0 };

/// Runs every operation on a scratch copy; whenever one fails, the bytes must be unchanged.
fn probe(gpa: std.mem.Allocator, page: []u8, random: std.Random, sweep: *Sweep) !void {
    assert(page.len >= 512);
    assert(page.len <= header.page_size_max);
    sweep.total += 1;
    const view = internal.parse_internal(page, page[26]) catch return;
    sweep.parsed += 1;
    var key: [6]u8 = undefined;
    random.bytes(&key);
    for (0..view.count) |i| _ = view.entry(@intCast(i)) catch {};
    _ = view.child_index(key[0..random.uintLessThan(usize, 6)]) catch {};
    _ = view.child_at(@intCast(random.uintLessThan(usize, @as(usize, view.count) + 1))) catch {};
    view.check_invariants() catch {};
    view.check_link(id_of(2)) catch {};
    view.check_children(id_of(2)) catch {};
    const before = try gpa.dupe(u8, page);
    defer gpa.free(before);

    const index: u16 = @intCast(random.uintLessThan(usize, view.count));
    const klen = random.uintLessThan(usize, 7);
    const slot_at: u16 = @intCast(random.uintLessThan(usize, @as(usize, view.count) + 1));
    internal.internal_insert(page, slot_at, key[0..klen], id_of(5)) catch {
        try expect_unchanged(before, page);
    };
    @memcpy(page, before);
    if (view.count > 1) internal.internal_remove(page, index) catch {
        try expect_unchanged(before, page);
    };
    @memcpy(page, before);
    internal.set_child(page, index, id_of(6)) catch try expect_unchanged(before, page);
    @memcpy(page, before);
    const at: u16 = @intCast(random.uintLessThan(usize, @as(usize, view.count) + 1));
    _ = split.split_point(page, 5 + random.uintLessThan(u32, 100), at) catch {};
    try expect_unchanged(before, page);
}

test "sweep: mutated valid pages and raw random bytes give typed errors and unchanged pages" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5eed17);
    const random = prng.random();
    var sweep: Sweep = .{};
    for ([_]u32{ 512, 4096 }) |ps| {
        const page = try gpa.alloc(u8, ps);
        defer gpa.free(page);

        for (0..3000) |_| {
            try random_valid(page, random);
            mutate(page, random);
            try probe(gpa, page, random, &sweep);
        }
        for (0..1000) |_| {
            random.bytes(page);
            page[4] = 17;
            try probe(gpa, page, random, &sweep);
        }
    }
    try std.testing.expectEqual(@as(u32, 8000), sweep.total);
    try std.testing.expect(sweep.parsed * 4 >= sweep.total); // At least 25% reach the cells.
}
