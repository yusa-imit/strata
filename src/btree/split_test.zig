//! Contract tests for `split.zig` (ADR-0004 sections 8 and 13): the split point is chosen by bytes,
//! minimising `|left - right|`, and the halves built with the node mutators are valid nodes.
//!
//! The oracle never calls `split_point`: it recomputes every cell size from the ADR cell formulas
//! (varint width 1 below 128 and 2 up to 1024), brute-forces every candidate point, and compares
//! the resulting byte imbalance. Cases are seeded and reproduce from the seed.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const split = @import("split.zig");

const Id = header.Id;
const page_sizes = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
const Kind = enum { leaf, internal };
const Mode = enum { natural, first, last };
const right_child_raw: u32 = 900;

const Item = struct { key: []const u8, value: []const u8, child: u32 };

fn id_of(raw: u32) Id {
    assert(raw > 0);
    assert(raw < 1 << 20);
    return @enumFromInt(raw);
}

fn varint_size(len: usize) u32 {
    assert(len <= 1024);
    return if (len < 128) 1 else 2;
}

/// Encoded cell size from the ADR formulas, plus the 2 B slot when `with_slot`.
fn cell_bytes(kind: Kind, item: Item, with_slot: bool) u32 {
    assert(item.key.len <= 1024);
    assert(item.value.len <= 4);
    const key_len: u32 = @intCast(item.key.len);
    const slot: u32 = if (with_slot) 2 else 0;
    return switch (kind) {
        .leaf => blk: {
            const value_len: u32 = @intCast(item.value.len);
            break :blk varint_size(item.key.len) + 1 + key_len + value_len + slot;
        },
        .internal => varint_size(item.key.len) + key_len + 4 + slot,
    };
}

fn random_item(arena: std.mem.Allocator, random: std.Random, page_size: u32) !Item {
    assert(header.page_size_valid(page_size));
    const kind = random.uintLessThan(u8, 5);
    const key_max = node.key_len_max(page_size);
    assert(key_max <= 1024);
    const short_len: usize = 1 + random.uintLessThan(u8, 8);
    // Kind 0 is a maximal key; kind 1 a 128 .. key_max key (two-byte varint) where one exists.
    const mid_span = key_max -| 128;
    const mid_extra = if (mid_span > 0) random.uintLessThan(u32, mid_span) else 0;
    const mid_len: usize = if (mid_span > 0) 128 + mid_extra else short_len;
    const key_len: usize = switch (kind) {
        0 => key_max,
        1 => mid_len,
        else => short_len,
    };
    const key = try arena.alloc(u8, key_len);
    random.bytes(key);
    const value = try arena.alloc(u8, random.uintLessThan(u8, 5));
    random.bytes(value);
    return .{ .key = key, .value = value, .child = 1 + random.uintLessThan(u32, 800) };
}

/// First position whose key is >= `key`; `found` reports an equal key.
fn lower(items: []const Item, key: []const u8) struct { at: usize, found: bool } {
    assert(items.len < 1 << 16);
    assert(key.len <= 1024);
    var at: usize = 0;
    while (at < items.len and std.mem.order(u8, items[at].key, key) == .lt) at += 1;
    const found = at < items.len and std.mem.eql(u8, items[at].key, key);
    return .{ .at = at, .found = found };
}

const Fill = struct { incoming: Item, at: usize };

/// Fills `items` (sorted, unique) until the next random candidate no longer fits, then picks
/// the incoming cell by `mode`. The empty and all-0xFF keys sort before and after every key.
fn fill(
    arena: std.mem.Allocator,
    random: std.Random,
    ps: u32,
    kind: Kind,
    mode: Mode,
    items: *std.ArrayList(Item),
) !Fill {
    assert(header.page_size_valid(ps));
    assert(items.items.len == 0);
    assert(node.usable(ps) > 0);
    var used: u32 = 0;
    const fill_steps_max: u32 = 200_000;
    var natural: ?Fill = null;
    for (0..fill_steps_max) |_| {
        const item = try random_item(arena, random, ps);
        const where = lower(items.items, item.key);
        if (where.found) continue;
        const size = cell_bytes(kind, item, true);
        if (used + size > node.usable(ps) or items.items.len >= node.cell_count_max(ps)) {
            natural = .{ .incoming = item, .at = where.at };
            break;
        }
        try items.insert(arena, where.at, item);
        used += size;
    }
    const chosen = natural orelse return error.TestUnexpectedResult;
    switch (mode) {
        .natural => return chosen,
        .first => {
            const item: Item = .{ .key = "", .value = "", .child = 77 };
            if (lower(items.items, item.key).found) return chosen;
            return .{ .incoming = item, .at = 0 };
        },
        .last => {
            const key = try arena.alloc(u8, node.key_len_max(ps));
            @memset(key, 0xFF);
            const item: Item = .{ .key = key, .value = "", .child = 78 };
            if (lower(items.items, item.key).found) return chosen;
            return .{ .incoming = item, .at = items.items.len };
        },
    }
}

fn build(gpa: std.mem.Allocator, ps: u32, kind: Kind, items: []const Item, right: u32) ![]u8 {
    assert(header.page_size_valid(ps));
    assert(right > 0);
    assert(items.len <= node.cell_count_max(ps));
    const page = try gpa.alloc(u8, ps);
    errdefer gpa.free(page);

    switch (kind) {
        .leaf => node.format_leaf(page, id_of(2), null, 0),
        .internal => internal.format_internal(page, id_of(2), 1, id_of(right), 0),
    }
    for (items, 0..) |item, i| switch (kind) {
        .leaf => try node.leaf_insert(page, @intCast(i), item.key, .{ .bytes = item.value }),
        .internal => try internal.internal_insert(page, @intCast(i), item.key, id_of(item.child)),
    };
    node.seal(page, id_of(2), 0);
    return page;
}

/// Parses `page` as a valid node holding exactly `items` and returns its used bytes.
fn expect_half(kind: Kind, page: []u8, items: []const Item) !u32 {
    assert(items.len > 0);
    assert(page.len >= 512);
    switch (kind) {
        .leaf => {
            const leaf = try node.parse_leaf(page);
            try leaf.check_invariants();
            try std.testing.expectEqual(items.len, leaf.count);
            for (items, 0..) |item, i| {
                const entry = try leaf.entry(@intCast(i));
                try std.testing.expectEqualSlices(u8, item.key, entry.key);
                try std.testing.expectEqualSlices(u8, item.value, entry.value.bytes);
            }
            return leaf.used_bytes();
        },
        .internal => {
            const view = try internal.parse_internal(page, 1);
            try view.check_invariants();
            try std.testing.expectEqual(items.len, view.count);
            for (items, 0..) |item, i| {
                const entry = try view.entry(@intCast(i));
                try std.testing.expectEqualSlices(u8, item.key, entry.key);
                try std.testing.expectEqual(id_of(item.child), entry.child);
            }
            return view.used_bytes();
        },
    }
}

fn sum_bytes(kind: Kind, items: []const Item) u32 {
    assert(items.len < 1 << 16);
    var total: u32 = 0;
    for (items) |item| total += cell_bytes(kind, item, true);
    return total;
}

/// Brute force: the smallest achievable |left - right| over every legal split point.
fn best_diff(kind: Kind, ps: u32, virt: []const Item) u32 {
    assert(virt.len >= 3);
    assert(header.page_size_valid(ps));
    var best: u32 = std.math.maxInt(u32);
    const low: usize = 1;
    const high: usize = if (kind == .leaf) virt.len - 1 else virt.len - 2;
    for (low..high + 1) |point| {
        const left = sum_bytes(kind, virt[0..point]);
        const right_from = if (kind == .leaf) point else point + 1;
        const right = sum_bytes(kind, virt[right_from..]);
        if (left > node.usable(ps) or right > node.usable(ps)) continue;
        best = @min(best, if (left > right) left - right else right - left);
    }
    return best;
}

fn run_case(gpa: std.mem.Allocator, ps: u32, kind: Kind, mode: Mode, seed: u64) !void {
    assert(header.page_size_valid(ps));
    assert(seed != 0);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const arena = arena_state.allocator();
    var prng = std.Random.DefaultPrng.init(seed);
    var items: std.ArrayList(Item) = .empty;
    const picked = try fill(arena, prng.random(), ps, kind, mode, &items);
    const page = try build(gpa, ps, kind, items.items, right_child_raw);
    defer gpa.free(page);

    const incoming_bytes = cell_bytes(kind, picked.incoming, false);
    const point = try split.split_point(page, incoming_bytes, @intCast(picked.at));
    var virt: std.ArrayList(Item) = .empty;
    try virt.appendSlice(arena, items.items);
    try virt.insert(arena, picked.at, picked.incoming);

    const best = best_diff(kind, ps, virt.items);
    // A split of a node that really overflowed leaves both halves above the underflow floor.
    const floor: u32 = if (mode == .natural) node.underflow_bytes(ps) else 0;
    switch (kind) {
        .leaf => try check_leaf_split(gpa, ps, virt.items, point, best, floor),
        .internal => try check_internal_split(gpa, ps, virt.items, point, best, floor),
    }
}

fn check_leaf_split(
    gpa: std.mem.Allocator,
    ps: u32,
    virt: []const Item,
    point: u16,
    best: u32,
    floor: u32,
) !void {
    assert(virt.len >= 2);
    assert(header.page_size_valid(ps));
    try std.testing.expect(point >= 1 and point < virt.len);
    const left_items = virt[0..point];
    const right_items = virt[point..];
    const left = try build(gpa, ps, .leaf, left_items, 1);
    defer gpa.free(left);

    const right = try build(gpa, ps, .leaf, right_items, 1);
    defer gpa.free(right);

    const left_used = try expect_half(.leaf, left, left_items);
    const right_used = try expect_half(.leaf, right, right_items);
    try std.testing.expect(left_used <= node.usable(ps) and right_used <= node.usable(ps));
    try std.testing.expect(left_used >= floor and right_used >= floor);
    try std.testing.expectEqual(sum_bytes(.leaf, left_items), left_used);
    try std.testing.expectEqual(sum_bytes(.leaf, right_items), right_used);
    const diff = if (left_used > right_used) left_used - right_used else right_used - left_used;
    try std.testing.expectEqual(best, diff);
    // Together the halves reproduce the virtual sequence in strictly ascending order.
    for (virt[1..], 0..) |item, i| {
        try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, virt[i].key, item.key));
    }
}

fn check_internal_split(
    gpa: std.mem.Allocator,
    ps: u32,
    virt: []const Item,
    point: u16,
    best: u32,
    floor: u32,
) !void {
    assert(virt.len >= 3);
    assert(header.page_size_valid(ps));
    try std.testing.expect(point >= 1 and point + 1 < virt.len);
    const left_items = virt[0..point];
    const right_items = virt[point + 1 ..];
    const moved = virt[point];
    const left = try build(gpa, ps, .internal, left_items, moved.child);
    defer gpa.free(left);

    const right = try build(gpa, ps, .internal, right_items, right_child_raw);
    defer gpa.free(right);

    const left_used = try expect_half(.internal, left, left_items);
    const right_used = try expect_half(.internal, right, right_items);
    try std.testing.expect(left_used <= node.usable(ps) and right_used <= node.usable(ps));
    try std.testing.expect(left_used >= floor and right_used >= floor);
    const left_view = try internal.parse_internal(left, 1);
    const right_view = try internal.parse_internal(right, 1);
    try std.testing.expectEqual(id_of(moved.child), left_view.right_child);
    try std.testing.expectEqual(id_of(right_child_raw), right_view.right_child);
    const left_last = (try left_view.entry(left_view.count - 1)).key;
    const right_first = (try right_view.entry(0)).key;
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, left_last, moved.key));
    try std.testing.expectEqual(std.math.Order.lt, std.mem.order(u8, moved.key, right_first));
    const diff = if (left_used > right_used) left_used - right_used else right_used - left_used;
    try std.testing.expectEqual(best, diff);
}

test "split_point: leaf halves are valid and byte-balanced at all 8 page sizes" {
    const gpa = std.testing.allocator;
    for (page_sizes) |ps| {
        for ([_]Mode{ .natural, .first, .last }) |mode| {
            for (0..3) |seed| try run_case(gpa, ps, .leaf, mode, 0x5917 + seed * 31 + ps);
        }
    }
}

test "split_point: internal halves are valid, balanced and keep the moved key between them" {
    const gpa = std.testing.allocator;
    for (page_sizes) |ps| {
        for ([_]Mode{ .natural, .first, .last }) |mode| {
            for (0..3) |seed| try run_case(gpa, ps, .internal, mode, 0x7a11 + seed * 37 + ps);
        }
    }
}

test "split_point: four maximal cells at 512 bytes split two and two" {
    const gpa = std.testing.allocator;
    const page = try gpa.alloc(u8, 512);
    defer gpa.free(page);

    node.format_leaf(page, id_of(2), null, 0);
    var key: [108]u8 = undefined;
    for (0..3) |i| {
        @memset(&key, 'b' + @as(u8, @intCast(i)));
        try node.leaf_insert(page, @intCast(i), &key, .{ .bytes = "" });
    }
    // Leaf cell: 1 + 1 + 108 = 110 B; the incoming cell is equal-sized and goes last.
    try std.testing.expectEqual(@as(u16, 2), try split.split_point(page, 110, 3));
    try std.testing.expectEqual(@as(u16, 2), try split.split_point(page, 110, 0));
}

fn equal_cells(gpa: std.mem.Allocator, kind: Kind, cells: u8) ![]u8 {
    assert(cells >= 2);
    assert(cells <= 4);
    const page = try gpa.alloc(u8, 512);
    errdefer gpa.free(page);

    switch (kind) {
        .leaf => node.format_leaf(page, id_of(2), null, 0),
        .internal => internal.format_internal(page, id_of(2), 1, id_of(9), 0),
    }
    var key: [108]u8 = undefined;
    for (0..cells) |i| {
        @memset(&key, 'b' + @as(u8, @intCast(i)));
        switch (kind) {
            .leaf => try node.leaf_insert(page, @intCast(i), &key, .{ .bytes = "" }),
            .internal => try internal.internal_insert(page, @intCast(i), &key, id_of(3)),
        }
    }
    return page;
}

test "split_point: equal weights tie, and the lowest index wins" {
    const gpa = std.testing.allocator;
    // Leaf, 2 cells + incoming of 110 B: points 1 (1|2) and 2 (2|1) are equally unbalanced.
    const leaf = try equal_cells(gpa, .leaf, 2);
    defer gpa.free(leaf);

    for ([_]u16{ 0, 1, 2 }) |at| {
        try std.testing.expectEqual(@as(u16, 1), try split.split_point(leaf, 110, at));
    }
    // Internal, 3 cells of 113 B + incoming of 113 B: moved cell 1 (1|2) ties with 2 (2|1).
    const inner = try equal_cells(gpa, .internal, 3);
    defer gpa.free(inner);

    for ([_]u16{ 0, 1, 3 }) |at| {
        try std.testing.expectEqual(@as(u16, 1), try split.split_point(inner, 113, at));
    }
}

test "split_point: pages that cannot be split are Corrupted, never an assert" {
    const gpa = std.testing.allocator;
    const leaf = try equal_cells(gpa, .leaf, 2);
    defer gpa.free(leaf);

    const bytes = try gpa.dupe(u8, leaf);
    defer gpa.free(bytes);

    bytes[4] = 18; // Not a node page type.
    try std.testing.expectError(error.Corrupted, split.split_point(bytes, 110, 0));
    @memcpy(bytes, leaf);
    std.mem.writeInt(u16, bytes[24..26], 121, .little); // Above cell_count_max(512).
    try std.testing.expectError(error.Corrupted, split.split_point(bytes, 110, 0));
    std.mem.writeInt(u16, bytes[24..26], 0, .little); // A leaf of 0 cells has nothing to split.
    try std.testing.expectError(error.Corrupted, split.split_point(bytes, 110, 0));
    @memcpy(bytes, leaf);
    std.mem.writeInt(u16, bytes[32..34], 600, .little); // Cell 0 would end past the payload.
    try std.testing.expectError(error.Corrupted, split.split_point(bytes, 110, 0));
    std.mem.writeInt(u16, bytes[32..34], 488, .little); // Cell 0 would be empty.
    try std.testing.expectError(error.Corrupted, split.split_point(bytes, 110, 0));
    const inner = try equal_cells(gpa, .internal, 2);
    defer gpa.free(inner);

    std.mem.writeInt(u16, inner[24..26], 1, .little); // An internal node needs >= 2 cells.
    try std.testing.expectError(error.Corrupted, split.split_point(inner, 113, 0));
}
