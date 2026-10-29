//! Contract tests for overflow values (plan 005 item 8, ADR-0004 sections 2, 4, 6, 9): a 1 MiB
//! value round-trips at 512 B and 64 KiB pages, a 3-pages-and-one-byte value at all eight page
//! sizes, the inline/overflow/`ValueTooLarge` boundaries, overwrites in both directions and
//! with shrinking chains, delete and overwrite hand every chain page to `frees_pending`, every
//! malformed chain (cycle, short, long, wrong `len`, wrong type, id out of range) is
//! `Corrupted` through `get`, `validate` and the cursor, a full `frees_pending` changes
//! nothing, a cursor scan over mixed values equals the sorted model, and a seeded model test.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const overflow = @import("overflow.zig");
const cursor_mod = @import("cursor.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Id = header.Id;

fn start(f: *Fixture, size: u32, pages_max: u32) !void {
    assert(header.page_size_valid(size));
    assert(pages_max >= 2);
    const frames: u32 = 2 * @as(u32, node.height_max(size)) + 2; // The pool floor (ADR section 9).
    try f.start(testing.allocator, size, frames, pages_max);
}

/// Deterministic bytes: byte `i` is a function of `seed` and `i`, so a mix-up shows.
fn fill_value(buf: []u8, seed: u32) []u8 {
    assert(buf.len <= node.value_len_max);
    assert(seed < 1_000_000);
    for (buf, 0..) |*byte, i| byte.* = @truncate((i *% 31) +% (seed *% 17) +% (i >> 8));
    return buf;
}

fn chain_pages(size: u32, len: u32) u32 {
    assert(len >= 1 and len <= node.value_len_max);
    return overflow.chain_len(size, len);
}

fn put_expect(f: *Fixture, key: []const u8, value: []const u8) !void {
    assert(f.tree.root != .file_header);
    assert(key.len <= 6);
    try f.tree.insert(testing.io, key, value);
    try fx.expect_get(&f.tree, key, value);
    try f.tree.check_invariants(testing.io);
    try f.tree.validate(testing.io, testing.allocator);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

fn round_trip(size: u32, len: u32) !void {
    assert(header.page_size_valid(size));
    assert(len >= 1 and len <= node.value_len_max);
    var f: Fixture = undefined;
    try start(&f, size, 4096);
    defer f.stop(testing.allocator);

    const value = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(value);

    try put_expect(&f, "k00001", fill_value(value, 1));
    try f.cold();
    try fx.expect_get(&f.tree, "k00001", value);
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
}

test "overflow: a 1 MiB value round-trips at 512 B pages" {
    try round_trip(512, node.value_len_max);
}

test "overflow: a 1 MiB value round-trips at 64 KiB pages" {
    try round_trip(65536, node.value_len_max);
}

test "overflow: 3 * capacity + 1 bytes round-trip at every page size" {
    for (fx.sizes_all) |size| try round_trip(size, 3 * node.overflow_capacity(size) + 1);
}

fn inline_max(size: u32, key_len: u32) u32 {
    assert(header.page_size_valid(size));
    assert(key_len <= node.key_len_max(size));
    var len: u32 = 0;
    while (node.value_inline(size, key_len, len + 1)) len += 1;
    assert(node.value_inline(size, key_len, len));
    return len;
}

test "overflow: the inline, capacity and limit boundaries at 512 B and 4 KiB" {
    const big = try testing.allocator.alloc(u8, node.value_len_max + 1);
    defer testing.allocator.free(big);

    for ([_]u32{ 512, 4096 }) |size| {
        var f: Fixture = undefined;
        try start(&f, size, 4096);
        defer f.stop(testing.allocator);

        const cap = node.overflow_capacity(size);
        const inline_len = inline_max(size, 6);
        const lens = [_]u32{ inline_len, inline_len + 1, cap, cap + 1, node.value_len_max };
        for (lens, 0..) |len, i| {
            var key_buf: [8]u8 = undefined;
            try put_expect(&f, fx.key_of(&key_buf, @intCast(i)), fill_value(big[0..len], 7));
        }
        const frees_before = f.tree.frees_len;
        const err = f.tree.insert(testing.io, "k00009", big);
        try testing.expectError(error.ValueTooLarge, err);
        try testing.expectEqual(frees_before, f.tree.frees_len);
        try f.tree.validate(testing.io, testing.allocator);
    }
}

test "overflow: overwrite inline to overflow to inline and shrink a chain" {
    var f: Fixture = undefined;
    try start(&f, 512, 4096);
    defer f.stop(testing.allocator);

    var buf: [4000]u8 = undefined;
    try put_expect(&f, "k00001", fill_value(buf[0..10], 1));
    try put_expect(&f, "k00001", fill_value(buf[0..4000], 2)); // 9 pages.
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
    try put_expect(&f, "k00001", fill_value(buf[0..1000], 3)); // 3 pages.
    try testing.expectEqual(chain_pages(512, 4000), f.tree.frees_len);
    _ = try f.tree.release_frees(testing.io);
    try put_expect(&f, "k00001", fill_value(buf[0..10], 4));
    try testing.expectEqual(chain_pages(512, 1000), f.tree.frees_len);
    _ = try f.tree.release_frees(testing.io);
    try put_expect(&f, "k00001", fill_value(buf[0..10], 5));
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
}

test "overflow: delete returns every chain page and the page count balances" {
    var f: Fixture = undefined;
    try start(&f, 512, 4096);
    defer f.stop(testing.allocator);

    const value = try testing.allocator.alloc(u8, 100_000);
    defer testing.allocator.free(value);

    try put_expect(&f, "k00001", fill_value(value, 1));
    const count_after_insert = f.pm.page_count;
    const n = chain_pages(512, 100_000);
    try testing.expect(try f.tree.delete(testing.io, "k00001"));
    try testing.expectEqual(n, f.tree.frees_len);
    for (f.tree.frees_pending[0..n], 0..) |id, i| {
        try testing.expectEqual(@as(u32, 2) + @as(u32, @intCast(i)), @intFromEnum(id));
    }
    try testing.expectEqual(n, try f.tree.release_frees(testing.io));
    try fx.expect_get(&f.tree, "k00001", null);
    try put_expect(&f, "k00002", fill_value(value, 2)); // Reuses the freed pages.
    try testing.expectEqual(count_after_insert, f.pm.page_count);
}

const Damage = enum {
    self_next,
    back_next,
    early_zero,
    long_tail,
    bad_len,
    bad_type,
    out_of_range,
};

fn damage_page(f: *Fixture, id: Id, how: Damage) !void {
    assert(id != .file_header);
    assert(@intFromEnum(id) < f.pm.page_count);
    var pinned = try f.pool.fetchForUpdate(testing.io, id);
    defer pinned.release();

    const page = pinned.bytes_mut();
    const raw = @intFromEnum(id);
    var page_type = header.peek(page).page_type;
    switch (how) {
        .self_next => node.put32(page, 24, raw),
        .back_next => node.put32(page, 24, 2),
        .early_zero => node.put32(page, 24, 0),
        .long_tail => node.put32(page, 24, 1),
        .bad_len => node.put32(page, 28, node.get32(page, 28) - 1),
        .bad_type => page_type = .btree_leaf,
        .out_of_range => node.put32(page, 24, 99_999),
    }
    header.encode(page, id, .{ .page_type = page_type, .lsn = 0 });
}

fn damaged_fixture(f: *Fixture, how: Damage) !void {
    assert(@sizeOf(Fixture) > 0);
    assert(@intFromEnum(how) < 7);
    try start(f, 512, 64);
    errdefer f.stop(testing.allocator);

    var buf: [3 * 480 + 1]u8 = undefined; // Chain pages 2, 3, 4, 5.
    try put_expect(f, "k00001", fill_value(&buf, 1));
    const target: u32 = switch (how) {
        .long_tail => 5,
        .back_next => 4,
        else => 3,
    };
    try damage_page(f, @enumFromInt(target), how);
}

test "overflow: every malformed chain is Corrupted through get, validate and the cursor" {
    inline for (comptime std.enums.values(Damage)) |how| {
        var f: Fixture = undefined;
        try damaged_fixture(&f, how);
        defer f.stop(testing.allocator);

        try testing.expectError(error.Corrupted, f.tree.get(testing.io, "k00001"));
        try testing.expectError(error.Corrupted, f.tree.check_invariants(testing.io));
        const validated = f.tree.validate(testing.io, testing.allocator);
        try testing.expectError(error.Corrupted, validated);
        var c: cursor_mod.Cursor = undefined;
        cursor_mod.Cursor.init(&c, &f.tree);
        try testing.expectError(error.Corrupted, c.first(testing.io));
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
        const before = f.tree.frees_len;
        try testing.expectError(error.Corrupted, f.tree.delete(testing.io, "k00001"));
        try testing.expectEqual(before, f.tree.frees_len);
    }
}

test "overflow: a full frees_pending changes nothing" {
    var f: Fixture = undefined;
    try start(&f, 512, 4096);
    defer f.stop(testing.allocator);

    var buf: [2000]u8 = undefined;
    try put_expect(&f, "k00001", fill_value(&buf, 1));
    const n = chain_pages(512, 2000);
    const full = f.tree.frees_pending;
    const pages_before = f.pm.page_count;
    f.tree.frees_pending = full[0 .. n - 1];
    try testing.expectError(error.FreesPendingLimit, f.tree.delete(testing.io, "k00001"));
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
    try testing.expectError(
        error.FreesPendingLimit,
        f.tree.insert(testing.io, "k00001", fill_value(&buf, 2)), // Old chain plus a new one.
    );
    try testing.expectError(
        error.FreesPendingLimit,
        f.tree.insert(testing.io, "k00002", fill_value(&buf, 3)),
    );
    try testing.expectEqual(pages_before, f.pm.page_count);
    f.tree.frees_pending = full;
    try fx.expect_get(&f.tree, "k00001", fill_value(&buf, 1));
    try f.tree.validate(testing.io, testing.allocator);
    try testing.expect(try f.tree.delete(testing.io, "k00001"));
    try testing.expectEqual(n, f.tree.frees_len);
}

fn size_of_key(n: u32) u32 {
    assert(n < 100_000);
    assert(node.value_len_max > 2000);
    return switch (n % 4) {
        0 => 5,
        1 => 70,
        2 => 481,
        else => 1500 + n % 300,
    };
}

test "overflow: a cursor scan over mixed inline and overflow values equals the model" {
    var f: Fixture = undefined;
    try start(&f, 512, 4096);
    defer f.stop(testing.allocator);

    var buf: [2000]u8 = undefined;
    var key_buf: [8]u8 = undefined;
    for (0..60) |i| {
        const n: u32 = @intCast(i);
        const value = fill_value(buf[0..size_of_key(n)], n);
        try f.tree.insert(testing.io, fx.key_of(&key_buf, n), value);
    }
    try f.tree.validate(testing.io, testing.allocator);
    var c: cursor_mod.Cursor = undefined;
    cursor_mod.Cursor.init(&c, &f.tree);
    defer c.release();

    var want: [2000]u8 = undefined;
    var n: u32 = 0;
    var item = try c.first(testing.io);
    while (item) |entry| : (item = try c.next(testing.io)) {
        try testing.expectEqualSlices(u8, fx.key_of(&key_buf, n), entry.key);
        try testing.expectEqualSlices(u8, fill_value(want[0..size_of_key(n)], n), entry.value);
        n += 1;
    }
    try testing.expectEqual(@as(u32, 60), n);
    item = try c.last(testing.io);
    while (item) |entry| : (item = try c.prev(testing.io)) {
        n -= 1;
        try testing.expectEqualSlices(u8, fx.key_of(&key_buf, n), entry.key);
        try testing.expectEqualSlices(u8, fill_value(want[0..size_of_key(n)], n), entry.value);
    }
    try testing.expectEqual(@as(u32, 0), n);
}

test "overflow: a seeded model of insert, overwrite, delete and get with mixed sizes" {
    var f: Fixture = undefined;
    try start(&f, 512, 8192);
    defer f.stop(testing.allocator);

    var model: fx.Model = .empty;
    defer fx.model_free(&model);

    var prng = std.Random.DefaultPrng.init(0x5eed_0f10);
    const random = prng.random();
    var buf: [3000]u8 = undefined;
    var key_buf: [8]u8 = undefined;
    for (0..400) |step| {
        const key = fx.key_of(&key_buf, random.uintLessThan(u32, 40));
        if (random.uintLessThan(u32, 4) == 0) {
            const had = model.fetchRemove(key);
            try testing.expectEqual(had != null, try f.tree.delete(testing.io, key));
            if (had) |pair| {
                testing.allocator.free(pair.key);
                testing.allocator.free(pair.value);
            }
        } else {
            const len = random.uintLessThan(u32, 3000);
            const value = fill_value(buf[0..len], @intCast(step));
            try f.tree.insert(testing.io, key, value);
            try fx.model_put(&model, key, value);
        }
        if (f.tree.frees_len > 1500) _ = try f.tree.release_frees(testing.io);
        try f.tree.check_invariants(testing.io);
        try f.tree.validate(testing.io, testing.allocator);
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    }
    try fx.model_compare(&f.tree, &model);
}
