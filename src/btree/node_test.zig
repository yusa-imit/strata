//! Contract tests for `node.zig` leaf cells (ADR-0004 sections 2, 3, 4, 7, 10, 11).
//!
//! Expected values are independent of the codec: limits are literals from the ADR section 2
//! table, golden pages are committed bytes, and the model tests compare against a sorted array of
//! keys that never looks at page bytes.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("../page/header.zig");
const node = @import("node.zig");

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
    assert(page.len >= 512);
    std.mem.writeInt(u16, page[offset..][0..2], value, .little);
}

fn new_leaf(gpa: std.mem.Allocator, page_size: u32, id: Id) ![]u8 {
    assert(header.page_size_valid(page_size));
    assert(id != .file_header);
    const page = try gpa.alloc(u8, page_size);
    @memset(page, 0xAA); // format_leaf must overwrite stale bytes.
    node.format_leaf(page, id, null, 0);
    return page;
}

/// Inserts `key` at its sorted position (the key must be absent).
fn put_bytes(page: []u8, key: []const u8, value: []const u8) !void {
    assert(page.len >= 512);
    assert(key.len <= 108);
    const leaf = try node.parse_leaf(page);
    const slot = try leaf.search(key);
    try std.testing.expect(!slot.found);
    try node.leaf_insert(page, slot.index, key, .{ .bytes = value });
}

/// Rewrites a field inside a leaf and reseals, so only one rule can fire.
fn reseal(page: []u8, id: Id) void {
    assert(page.len >= 512);
    assert(id != .file_header);
    node.seal(page, id, 0);
}

test "limits match the ADR section 2 table at all 8 page sizes" {
    const cell_max = [_]u32{ 118, 246, 502, 1014, 2038, 4086, 8182, 16374 };
    const key_max = [_]u32{ 108, 236, 492, 1004, 1024, 1024, 1024, 1024 };
    const overflow_cap = [_]u32{ 480, 992, 2016, 4064, 8160, 16352, 32736, 65504 };
    const images = [_]u32{ 2032, 1019, 510, 255, 127, 63, 31, 15 };
    const heights = [_]u8{ 16, 16, 16, 16, 16, 16, 15, 7 };
    for (page_sizes, 0..) |ps, i| {
        try std.testing.expectEqual(ps - 32, node.usable(ps));
        try std.testing.expectEqual(cell_max[i], node.cell_bytes_max(ps));
        try std.testing.expectEqual(key_max[i], node.key_len_max(ps));
        try std.testing.expectEqual(overflow_cap[i], node.overflow_capacity(ps));
        try std.testing.expectEqual(images[i], node.images_per_frame_max(ps));
        try std.testing.expectEqual(heights[i], node.height_max(ps));
        try std.testing.expectEqual((ps - 32) / 4, node.underflow_bytes(ps));
        try std.testing.expectEqual((ps - 32) / 4, node.cell_count_max(ps));
    }
    try std.testing.expectEqual(@as(u8, 16), node.height_limit);
    try std.testing.expectEqual(@as(u32, 1 << 20), node.value_len_max);
}

test "value_inline: 16 B key inline values match the ADR table and flip one byte later" {
    const inline_max = [_]u32{ 100, 227, 483, 995, 2019, 4067, 8163, 16355 };
    for (page_sizes, inline_max) |ps, expected| {
        try std.testing.expect(node.value_inline(ps, 16, expected));
        try std.testing.expect(!node.value_inline(ps, 16, expected + 1));
    }
    try std.testing.expect(node.value_inline(512, 0, 0));
    try std.testing.expect(!node.value_inline(512, 0, 1 << 20));
}

test "golden leaf at 512 bytes matches the ADR section 11 image" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    try put_bytes(page, "kiwi", "green");
    try put_bytes(page, "apple", "red");
    reseal(page, id_of(1));

    var expected: [512]u8 = @splat(0);
    const head = [_]u8{ 0x53, 0x54, 0x52, 0x41, 0x10, 0x00, 0x01, 0x00, 0x3e, 0x6f, 0xe1, 0xff };
    @memcpy(expected[0..12], &head);
    @memcpy(expected[24..28], &[_]u8{ 0x02, 0x00, 0x00, 0x00 });
    @memcpy(expected[32..36], &[_]u8{ 0xde, 0x01, 0xd3, 0x01 });
    @memcpy(expected[491..502], &[_]u8{ 4, 5, 'k', 'i', 'w', 'i', 'g', 'r', 'e', 'e', 'n' });
    @memcpy(expected[502..512], &[_]u8{ 5, 3, 'a', 'p', 'p', 'l', 'e', 'r', 'e', 'd' });
    try std.testing.expectEqualSlices(u8, &expected, page);
    try std.testing.expectEqual(@as(u32, 0xFFE16F3E), header.checksum(page, id_of(1)));
    _ = try header.decode(page, id_of(1));

    const leaf = try node.parse_leaf(page);
    try std.testing.expectEqual(@as(u16, 2), leaf.count);
    try std.testing.expectEqualStrings("apple", (try leaf.entry(0)).key);
    try std.testing.expectEqualStrings("red", (try leaf.entry(0)).value.bytes);
    try std.testing.expectEqualStrings("kiwi", (try leaf.entry(1)).key);
    try leaf.check_invariants();
}

test "ADR negative pins: wrong id is ChecksumMismatch, slot 0 = 479 is Corrupted at entry(0)" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    try put_bytes(page, "apple", "red");
    try put_bytes(page, "kiwi", "green");
    reseal(page, id_of(1));
    try std.testing.expectEqual(@as(u32, 0xED82B6EB), header.checksum(page, id_of(2)));
    try std.testing.expectError(error.ChecksumMismatch, header.decode(page, id_of(2)));

    put16(page, 32, 479);
    reseal(page, id_of(1));
    try std.testing.expectEqual(@as(u32, 0x77133504), header.checksum(page, id_of(1)));
    _ = try header.decode(page, id_of(1));
    const leaf = try node.parse_leaf(page);
    try std.testing.expectError(error.Corrupted, leaf.entry(0));
    // Cell 1 must end where slot 0 now starts, so it is no longer a valid span either.
    try std.testing.expectError(error.Corrupted, leaf.entry(1));
}

test "format_leaf: empty leaf is canonical, parses, and carries next" {
    const gpa = std.testing.allocator;
    for (page_sizes) |ps| {
        const page = try new_leaf(gpa, ps, id_of(3));
        defer gpa.free(page);

        const leaf = try node.parse_leaf(page);
        try std.testing.expectEqual(@as(u16, 0), leaf.count);
        try std.testing.expectEqual(@as(?Id, null), leaf.next);
        try leaf.check_invariants();
        try std.testing.expect(std.mem.allEqual(u8, page[32..], 0));
        node.set_next(page, id_of(9));
        try std.testing.expectEqual(@as(?Id, id_of(9)), (try node.parse_leaf(page)).next);
        const linked = try node.parse_leaf(page);
        try std.testing.expectError(error.Corrupted, linked.check_link(id_of(9)));
        node.set_next(page, null);
        try (try node.parse_leaf(page)).check_link(id_of(3));
        const found = try leaf.search("anything");
        try std.testing.expectEqual(node.Slot{ .index = 0, .found = false }, found);
    }
}

/// Independent oracle: bytes one entry uses (slot + cell) for the model's key/value shapes.
fn model_entry_bytes(key_len: u32, value_len: u32) u32 {
    assert(key_len < 128);
    assert(value_len < 128);
    return 2 + 1 + 1 + key_len + value_len;
}

fn model_key(buf: *[4]u8, raw: u32) []const u8 {
    assert(buf.len == 4);
    assert(@sizeOf(@TypeOf(raw)) == 4);
    std.mem.writeInt(u32, buf, raw, .big);
    return buf;
}

fn model_value(buf: []u8, raw: u32) []const u8 {
    const len = raw % 24;
    assert(len <= buf.len);
    assert(buf.len == 24);
    @memset(buf[0..len], @truncate(raw));
    return buf[0..len];
}

const Model = struct {
    keys: [4096]u32 = undefined,
    count: u32 = 0,

    fn position(self: *const Model, raw: u32) u32 {
        assert(self.count <= self.keys.len);
        var lo: u32 = 0;
        var hi: u32 = self.count;
        for (0..16) |_| { // 2^16 > keys.len, so the search converges.
            if (lo >= hi) break;
            const mid = lo + (hi - lo) / 2;
            if (self.keys[mid] < raw) lo = mid + 1 else hi = mid;
        }
        assert(lo <= self.count);
        return lo;
    }

    fn used(self: *const Model) u32 {
        assert(self.count <= self.keys.len);
        var total: u32 = 0;
        for (self.keys[0..self.count]) |raw| total += model_entry_bytes(4, raw % 24);
        return total;
    }

    fn insert(self: *Model, at: u32, raw: u32) void {
        assert(at <= self.count);
        assert(self.count < self.keys.len);
        std.mem.copyBackwards(u32, self.keys[at + 1 .. self.count + 1], self.keys[at..self.count]);
        self.keys[at] = raw;
        self.count += 1;
    }

    fn remove(self: *Model, at: u32) void {
        assert(at < self.count);
        assert(self.count > 0);
        std.mem.copyForwards(u32, self.keys[at .. self.count - 1], self.keys[at + 1 .. self.count]);
        self.count -= 1;
    }
};

fn check_matches(page: []u8, model: *const Model) !void {
    assert(page.len >= 512);
    assert(model.count <= model.keys.len);
    const leaf = try node.parse_leaf(page);
    try std.testing.expectEqual(model.count, leaf.count);
    try leaf.check_invariants();
    var key_buf: [4]u8 = undefined;
    var value_buf: [24]u8 = undefined;
    for (model.keys[0..model.count], 0..) |raw, i| {
        const entry = try leaf.entry(@intCast(i));
        try std.testing.expectEqualSlices(u8, model_key(&key_buf, raw), entry.key);
        try std.testing.expectEqualSlices(u8, model_value(&value_buf, raw), entry.value.bytes);
    }
}

fn run_model(gpa: std.mem.Allocator, page_size: u32, seed: u64, ops: u32, check_every: u32) !void {
    assert(ops > 0);
    assert(check_every > 0);
    const page = try new_leaf(gpa, page_size, id_of(2));
    defer gpa.free(page);

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var model: Model = .{};
    const usable = node.usable(page_size);
    const key_space: u32 = if (page_size == 512) 300 else 100_000;
    for (0..ops) |op| {
        const raw = random.uintLessThan(u32, key_space);
        const at = model.position(raw);
        const present = at < model.count and model.keys[at] == raw;
        var key_buf: [4]u8 = undefined;
        var value_buf: [24]u8 = undefined;
        const key = model_key(&key_buf, raw);
        const slot = try (try node.parse_leaf(page)).search(key);
        try std.testing.expectEqual(present, slot.found);
        try std.testing.expectEqual(@as(u16, @intCast(at)), slot.index);
        if (present and random.boolean()) {
            try node.leaf_remove(page, slot.index);
            model.remove(at);
        } else if (!present) {
            const value = model_value(&value_buf, raw);
            const fits = model.used() + model_entry_bytes(4, raw % 24) <= usable and
                model.count < model.keys.len;
            const result = node.leaf_insert(page, slot.index, key, .{ .bytes = value });
            if (fits) {
                try result;
                model.insert(at, raw);
            } else {
                try std.testing.expectError(error.NodeFull, result);
            }
        }
        if (op % check_every == 0) try check_matches(page, &model);
    }
    try check_matches(page, &model);
}

test "model: random insert and remove at 512 bytes matches a sorted array every step" {
    const gpa = std.testing.allocator;
    for (0..4) |seed| try run_model(gpa, 512, 0x5EED + seed, 3000, 1);
}

test "round trip at 4 KiB and 64 KiB against the sorted-array model" {
    const gpa = std.testing.allocator;
    try run_model(gpa, 4096, 0xA11CE, 4000, 16);
    try run_model(gpa, 65536, 0xB0B, 6000, 256);
}

test "four maximal cells fit at 512 bytes and the fifth entry is NodeFull" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    var key: [108]u8 = @splat('k');
    var value: [8]u8 = @splat('v');
    for (0..4) |i| {
        key[0] = @intCast('a' + i);
        const leaf = try node.parse_leaf(page);
        try node.leaf_insert(page, leaf.count, &key, .{ .bytes = &value });
        try (try node.parse_leaf(page)).check_invariants();
    }
    const leaf = try node.parse_leaf(page);
    try std.testing.expectEqual(@as(u32, 480), leaf.used_bytes());
    try std.testing.expectEqual(node.usable(512), leaf.used_bytes());
    const err = node.leaf_insert(page, 0, "", .{ .bytes = "" });
    try std.testing.expectError(error.NodeFull, err);
    try std.testing.expectEqual(@as(u16, 4), (try node.parse_leaf(page)).count);
    // An overflow-form cell with the largest key and value_len_max also fits one maximal slot.
    try node.leaf_remove(page, 3);
    const big: node.Value = .{ .overflow = .{ .head = id_of(7), .len = node.value_len_max } };
    key[0] = 'z';
    try node.leaf_insert(page, 3, &key, big);
    const stored = try (try node.parse_leaf(page)).entry(3);
    try std.testing.expectEqual(big.overflow.head, stored.value.overflow.head);
    try std.testing.expectEqual(node.value_len_max, stored.value.overflow.len);
}

fn two_cell_leaf(gpa: std.mem.Allocator) ![]u8 {
    assert(@sizeOf(std.mem.Allocator) > 0);
    assert(header.page_size_valid(512));
    const page = try new_leaf(gpa, 512, id_of(1));
    errdefer gpa.free(page);

    try put_bytes(page, "apple", "red");
    try put_bytes(page, "kiwi", "green");
    return page;
}

fn expect_entry_corrupted(page: []u8, index: u16) !void {
    assert(page.len == 512);
    assert(index < 2);
    reseal(page, id_of(1));
    _ = try header.decode(page, id_of(1)); // The checksum is good: only the layout is bad.
    const leaf = try node.parse_leaf(page);
    try std.testing.expectError(error.Corrupted, leaf.entry(index));
}

test "section 10 cell(i): slot below the slot table end is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try two_cell_leaf(gpa);
    defer gpa.free(page);

    put16(page, 32, 11); // 8 + 2*2 = 12 > 11: inside the slot table.
    put16(page, 34, 467);
    try expect_entry_corrupted(page, 0);
}

test "section 10 cell(i): truncated, overlong and oversized varints are Corrupted" {
    const gpa = std.testing.allocator;
    const cases = [_][]const u8{
        &.{0x80}, // key_len truncated: continuation bit with nothing after it
        &.{ 0x80, 0x00 }, // key_len overlong
        &.{ 0x01, 0x80 }, // value_len truncated
        &([_]u8{0xFF} ** 10), // ten continuation bytes: a real oversized varint
        &([_]u8{0xFF} ** 9 ++ [_]u8{0x01}), // decodes to u64 max, far above key_len_max
    };
    for (cases) |bytes| {
        const page = try new_leaf(gpa, 512, id_of(1));
        defer gpa.free(page);

        try put_bytes(page, "a", "b");
        const start = 512 - bytes.len;
        @memcpy(page[start..512], bytes);
        put16(page, 32, @intCast(start - 24));
        try expect_entry_corrupted(page, 0);
    }
}

test "section 10 cell(i): key_len and value_len above their limits are Corrupted" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    try put_bytes(page, "a", "b");
    // key_len 109 > key_len_max(512) = 108, value_len 0, then 109 key bytes.
    const long_key_start = 512 - 111;
    page[long_key_start] = 109;
    page[long_key_start + 1] = 0;
    put16(page, 32, @intCast(long_key_start - 24));
    try expect_entry_corrupted(page, 0);
    // value_len = value_len_max + 1 (varint 81 80 40), key_len 0, 4-byte head.
    @memcpy(page[504..512], &[_]u8{ 0, 0x81, 0x80, 0x40, 1, 0, 0, 0 });
    put16(page, 32, 480);
    try expect_entry_corrupted(page, 0);
}

test "section 10 cell(i): the form must match value_inline in both directions" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    try put_bytes(page, "a", "b");
    // Inline spelling of a 200 B value: 1 + 2 + 1 + 200 = 204 bytes, but 204 > cell_bytes_max.
    const start = 512 - 204;
    @memcpy(page[start..][0..4], &[_]u8{ 1, 0xC8, 0x01, 'a' });
    put16(page, 32, @intCast(start - 24));
    try expect_entry_corrupted(page, 0);
    // Overflow spelling of a 3 B value (inline by section 2): 1 + 1 + 1 + 4 = 7 bytes.
    @memcpy(page[505..512], &[_]u8{ 1, 3, 'a', 1, 0, 0, 0 });
    put16(page, 32, 481);
    try expect_entry_corrupted(page, 0);
}

test "section 10 cell(i): overflow head 0 is Corrupted and head 1 round trips" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    try put_bytes(page, "a", "b");
    @memcpy(page[504..512], &[_]u8{ 1, 0xC8, 0x01, 'a', 1, 0, 0, 0 });
    put16(page, 32, 480);
    reseal(page, id_of(1));
    const ok = try (try node.parse_leaf(page)).entry(0);
    try std.testing.expectEqual(@as(u32, 200), ok.value.overflow.len);
    try std.testing.expectEqual(id_of(1), ok.value.overflow.head);
    page[508] = 0;
    try expect_entry_corrupted(page, 0);
}

test "section 10 cell(i): a gap or overlap between neighbours is Corrupted" {
    const gpa = std.testing.allocator;
    const page = try two_cell_leaf(gpa);
    defer gpa.free(page);

    put16(page, 34, 466); // cell 1 would span 12 bytes, but its decoded size is 11.
    try expect_entry_corrupted(page, 1);
    put16(page, 34, 478); // zero-size span: o[1] == o[0].
    try expect_entry_corrupted(page, 1);
    put16(page, 34, 480); // o[1] above o[0].
    try expect_entry_corrupted(page, 1);
    put16(page, 32, 479); // o[0] + 10 != 488.
    put16(page, 34, 467);
    try expect_entry_corrupted(page, 0);
}

test "section 10 parse: type, level, reserved, count and slot table rules" {
    const gpa = std.testing.allocator;
    const page = try two_cell_leaf(gpa);
    defer gpa.free(page);

    _ = try node.parse_leaf(page);
    var saved: [512]u8 = undefined;
    @memcpy(&saved, page);
    page[4] = 17;
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    page[4] = 2;
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    @memcpy(page, &saved);
    page[26] = 1;
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    @memcpy(page, &saved);
    page[27] = 1;
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    @memcpy(page, &saved);
    put16(page, 24, 121); // cell_count_max(512) = 120.
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    put16(page, 24, 120); // slot table ends at 24 + 8 + 240 = 272 > lowest cell.
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    @memcpy(page, &saved);
    put16(page, 34, 11); // lowest cell inside the slot table (8 + 4 = 12 > 11).
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    put16(page, 34, 489); // lowest cell past the payload end (488).
    try std.testing.expectError(error.Corrupted, node.parse_leaf(page));
    @memcpy(page, &saved);
    _ = try node.parse_leaf(page);
}

test "remove and insert zero the gap, keep cells dense, and never touch the header" {
    const gpa = std.testing.allocator;
    const page = try two_cell_leaf(gpa);
    defer gpa.free(page);

    try node.leaf_remove(page, 0);
    var leaf = try node.parse_leaf(page);
    try std.testing.expectEqual(@as(u16, 1), leaf.count);
    try std.testing.expectEqualStrings("kiwi", (try leaf.entry(0)).key);
    try std.testing.expect(std.mem.allEqual(u8, page[34..501], 0));
    try leaf.check_invariants();
    try node.leaf_remove(page, 0);
    leaf = try node.parse_leaf(page);
    try std.testing.expectEqual(@as(u16, 0), leaf.count);
    try std.testing.expect(std.mem.allEqual(u8, page[32..], 0));
    try leaf.check_invariants();
    try std.testing.expectEqual(@as(u8, 16), page[4]);
}

/// Builds "aa"->"x", "bb"->"y", "cc"->"z": three 5-byte cells at payload offsets 483, 478, 473.
fn three_cell_leaf(gpa: std.mem.Allocator) ![]u8 {
    assert(@sizeOf(std.mem.Allocator) > 0);
    assert(node.usable(512) == 480);
    assert(node.cell_count_max(512) == 120);
    const page = try new_leaf(gpa, 512, id_of(1));
    errdefer gpa.free(page);

    try put_bytes(page, "aa", "x");
    try put_bytes(page, "bb", "y");
    try put_bytes(page, "cc", "z");
    return page;
}

test "slot-table overlap is judged against 8 + 2n, not 8 + 2i (slots 13, 11, 400)" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    put16(page, 24, 3);
    put16(page, 32, 13); // 13 >= 8 + 2 but < 8 + 2*3 = 14.
    put16(page, 34, 11);
    put16(page, 36, 400);
    const leaf = try node.parse_leaf(page); // Only the lowest cell (400) is checked here.
    try std.testing.expectEqual(@as(u16, 3), leaf.count);
    try std.testing.expectError(error.Corrupted, leaf.entry(0));
    try std.testing.expectError(error.Corrupted, leaf.entry(1));
    try std.testing.expectError(error.Corrupted, leaf.entry(2));
}

test "check_invariants rejects duplicate keys, descending keys and a dirty gap" {
    const gpa = std.testing.allocator;
    const page = try three_cell_leaf(gpa);
    defer gpa.free(page);

    try (try node.parse_leaf(page)).check_invariants();
    const saved = try gpa.dupe(u8, page);
    defer gpa.free(saved);

    @memcpy(page[504..506], "aa"); // cell 1 key "bb" -> "aa": duplicates cell 0.
    try std.testing.expectError(error.Corrupted, (try node.parse_leaf(page)).check_invariants());
    @memcpy(page[504..506], "00"); // descending: "00" < "aa".
    try std.testing.expectError(error.Corrupted, (try node.parse_leaf(page)).check_invariants());
    @memcpy(page, saved);
    page[100] = 1; // a non-zero byte inside the gap.
    try std.testing.expectError(error.Corrupted, (try node.parse_leaf(page)).check_invariants());
    @memcpy(page, saved);
    try (try node.parse_leaf(page)).check_invariants();
}

test "leaf_remove: a slot outside [lowest, start] is Corrupted and the page is unchanged" {
    const gpa = std.testing.allocator;
    const page = try three_cell_leaf(gpa);
    defer gpa.free(page);

    const saved = try gpa.dupe(u8, page);
    defer gpa.free(saved);

    put16(page, 34, 500); // slot 1 above the removed cell's start (483).
    @memcpy(saved, page);
    try std.testing.expectError(error.Corrupted, node.leaf_remove(page, 0));
    try std.testing.expectEqualSlices(u8, saved, page);
    put16(page, 34, 478);
    put16(page, 36, 484); // lowest (484) above cell 0's start (483).
    @memcpy(saved, page);
    try std.testing.expectError(error.Corrupted, node.leaf_remove(page, 0));
    try std.testing.expectEqualSlices(u8, saved, page);
}

test "leaf_insert: a bad slot to move is Corrupted and the page is unchanged" {
    const gpa = std.testing.allocator;
    const page = try three_cell_leaf(gpa);
    defer gpa.free(page);

    put16(page, 34, 500); // slot 1 above the page end: the shift range is not inside the page.
    const saved = try gpa.dupe(u8, page);
    defer gpa.free(saved);

    const err = node.leaf_insert(page, 0, "0", .{ .bytes = "w" });
    try std.testing.expectError(error.Corrupted, err);
    try std.testing.expectEqualSlices(u8, saved, page);
}

test "leaf_insert: an unsorted neighbour or a wrong index is Corrupted, page unchanged" {
    const gpa = std.testing.allocator;
    const page = try two_cell_leaf(gpa);
    defer gpa.free(page);

    page[502 + 2] = 'z'; // cell 0 key "apple" -> "zpple": the page is CRC-valid but unsorted.
    reseal(page, id_of(1));
    _ = try header.decode(page, id_of(1));
    const saved = try gpa.dupe(u8, page);
    defer gpa.free(saved);

    const value: node.Value = .{ .bytes = "v" };
    try std.testing.expectError(error.Corrupted, node.leaf_insert(page, 1, "mango", value));
    try std.testing.expectEqualSlices(u8, saved, page);
    try std.testing.expectError(error.Corrupted, node.leaf_insert(page, 1, "kj", value));
    try std.testing.expectEqualSlices(u8, saved, page);
    try std.testing.expectError(error.Corrupted, node.leaf_insert(page, 0, "zzz", value));
    try std.testing.expectEqualSlices(u8, saved, page);
}

test "leaf_insert: a crafted count at cell_count_max is NodeFull and the page is unchanged" {
    const gpa = std.testing.allocator;
    const page = try new_leaf(gpa, 512, id_of(1));
    defer gpa.free(page);

    put16(page, 24, 120); // cell_count_max(512), far fewer bytes used than usable.
    for (0..120) |i| put16(page, 32 + 2 * i, 487);
    page[511] = 0;
    const leaf = try node.parse_leaf(page);
    try std.testing.expect(leaf.used_bytes() + 4 + 3 <= node.usable(512));
    const saved = try gpa.dupe(u8, page);
    defer gpa.free(saved);

    const err = node.leaf_insert(page, 0, "a", .{ .bytes = "v" });
    try std.testing.expectError(error.NodeFull, err);
    try std.testing.expectEqualSlices(u8, saved, page);
}

test "sweep: random pages and single-byte mutations give typed errors only" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0xF422);
    const random = prng.random();
    const page = try gpa.alloc(u8, 512);
    defer gpa.free(page);

    const base = try two_cell_leaf(gpa);
    defer gpa.free(base);

    for (0..20_000) |round| {
        if (round % 2 == 0) {
            random_leaf(page, random);
        } else {
            @memcpy(page, base);
            for (0..1 + round % 3) |_| page[24 + random.uintLessThan(u16, 488)] = random.int(u8);
        }
        try probe(page, random);
    }
}

/// Random bytes shaped like a leaf: a small count, descending in-range slots, and cell bytes
/// biased to small varints so `entry`, `search` and the mutators are reached.
fn random_leaf(page: []u8, random: std.Random) void {
    assert(page.len == 512);
    assert(@intFromPtr(page.ptr) != 0);
    random.bytes(page);
    for (page[400..]) |*byte| {
        if (random.boolean()) byte.* &= 0x0F;
    }
    page[4] = 16;
    page[26] = 0;
    page[27] = 0;
    const count = random.uintLessThan(u16, 6);
    put16(page, 24, count);
    var offset: u16 = 488;
    for (0..count) |i| {
        offset -= @min(offset, 2 + random.uintLessThan(u16, 12));
        put16(page, 32 + 2 * i, @max(offset, 8 + 2 * @as(u16, count)));
    }
}

fn expect_unchanged(before: []const u8, page: []const u8) !void {
    assert(before.len == page.len);
    assert(page.len == 512);
    try std.testing.expectEqualSlices(u8, before, page);
}

fn probe(page: []u8, random: std.Random) !void {
    assert(page.len == 512);
    assert(@intFromPtr(page.ptr) != 0); // Only typed errors may come out; a panic fails.
    var before: [512]u8 = undefined;
    @memcpy(&before, page);
    const leaf = node.parse_leaf(page) catch |err| switch (err) {
        error.Corrupted => return,
    };
    for (0..leaf.count) |i| {
        _ = leaf.entry(@intCast(i)) catch |err| switch (err) {
            error.Corrupted => continue,
        };
    }
    var key: [6]u8 = undefined;
    random.bytes(&key);
    const key_len = random.uintLessThan(u8, 7);
    _ = leaf.search(key[0..key_len]) catch |err| switch (err) {
        error.Corrupted => {},
    };
    leaf.check_invariants() catch |err| switch (err) {
        error.Corrupted => {},
    };
    try expect_unchanged(&before, page);
    const at = random.uintLessThan(u16, leaf.count + 1);
    node.leaf_insert(page, at, key[0..key_len], .{ .bytes = key[0..2] }) catch |err| switch (err) {
        error.NodeFull, error.Corrupted => try expect_unchanged(&before, page),
    };
    @memcpy(page, &before);
    if (leaf.count == 0) return;
    node.leaf_remove(page, random.uintLessThan(u16, leaf.count)) catch |err| switch (err) {
        error.Corrupted => try expect_unchanged(&before, page),
    };
}
