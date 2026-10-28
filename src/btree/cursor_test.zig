//! Contract tests for the cursor (plan 005 item 7, ADR-0004 sections 3, 5, 10): full forward and
//! backward scans equal the sorted model at three page sizes, never more than one pinned frame;
//! seek to an absent, the first, a before-first and a past-last key; a seeded random walk of
//! next, prev and seek against the model (including both exhausted ends); an empty tree gives
//! null both ways; crafted corrupt links and levels are `Corrupted` without a hang; a fetch
//! failure propagates and leaves the cursor released; `release` is idempotent.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const descend = @import("descend.zig");
const cursor_mod = @import("cursor.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Cursor = cursor_mod.Cursor;
const Entry = cursor_mod.Entry;
const Id = header.Id;
const scan_steps_max: u32 = 20_000;

fn value_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 6);
    assert(n < 100_000);
    const key = fx.key_of(buf, n);
    buf[0] = 'v';
    return key;
}

fn start(f: *Fixture, size: u32) !void {
    assert(size >= 512);
    assert(header.page_size_valid(size));
    const frames: u32 = 2 * @as(u32, node.height_max(size)) + 2; // The pool floor (ADR section 9).
    const pages_max: u32 = if (size >= 65536) 64 else 1024;
    try f.start(testing.allocator, size, frames, pages_max);
}

/// Inserts keys `i * stride` for `i` in `0 .. count` in seeded random order.
fn fill_shuffled(f: *Fixture, count: u32, stride: u32, seed: u64) !void {
    assert(count > 0 and stride > 0);
    assert(count * stride < 100_000);
    const order = try testing.allocator.alloc(u32, count);
    defer testing.allocator.free(order);

    for (order, 0..) |*slot, i| slot.* = @intCast(i);
    var prng = std.Random.DefaultPrng.init(seed);
    prng.random().shuffle(u32, order);
    var key_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;
    for (order) |i| {
        const n = i * stride;
        try f.tree.insert(testing.io, fx.key_of(&key_buf, n), value_of(&value_buf, n));
    }
}

/// `item` is the entry of model key `n`, or null when `n` is null.
fn expect_entry(item: ?Entry, n: ?u32) !void {
    assert(n == null or n.? < 100_000);
    assert(item == null or item.?.key.len > 0);
    var key_buf: [8]u8 = undefined;
    var value_buf: [8]u8 = undefined;
    const num = n orelse {
        try testing.expect(item == null);
        return;
    };
    const entry = item orelse return error.TestUnexpectedResult;
    try testing.expectEqualSlices(u8, fx.key_of(&key_buf, num), entry.key);
    try testing.expectEqualSlices(u8, value_of(&value_buf, num), entry.value);
}

fn scan_model(size: u32, count: u32, seed: u64) !void {
    assert(count > 0 and count < 100_000);
    assert(header.page_size_valid(size));
    var f: Fixture = undefined;
    try start(&f, size);
    defer f.stop(testing.allocator);

    try fill_shuffled(&f, count, 1, seed);
    try f.tree.validate(testing.io, testing.allocator);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    var item = try c.first(testing.io);
    for (0..count) |n| {
        try expect_entry(item, @intCast(n));
        try expect_entry(c.current(), @intCast(n));
        try testing.expectEqual(@as(u32, 1), f.pool.pinned_count());
        item = try c.next(testing.io);
    }
    try expect_entry(item, null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_entry(try c.next(testing.io), null); // Stays exhausted.

    item = try c.last(testing.io);
    for (0..count) |step| {
        try expect_entry(item, count - 1 - @as(u32, @intCast(step)));
        try testing.expect(f.pool.pinned_count() <= 1);
        item = try c.prev(testing.io);
    }
    try expect_entry(item, null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_entry(try c.prev(testing.io), null);
    try expect_entry(try c.next(testing.io), 0); // From before the first, `next` is the first.
}

test "cursor: forward and backward scans equal the sorted model at 512 B" {
    try scan_model(512, 3000, 1);
}

test "cursor: forward and backward scans equal the sorted model at 4 KiB" {
    try scan_model(4096, 3000, 2);
}

test "cursor: forward and backward scans equal the sorted model at 64 KiB" {
    try scan_model(65536, 5000, 3);
}

test "cursor: seek finds the lower bound of absent, first, before-first and past-last keys" {
    var f: Fixture = undefined;
    try start(&f, 512);
    defer f.stop(testing.allocator);

    const count: u32 = 400;
    try fill_shuffled(&f, count, 2, 4); // Keys 0, 2, 4, ...
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    var key_buf: [8]u8 = undefined;
    for (0..count) |i| {
        const n: u32 = @intCast(2 * i);
        try c.seek(testing.io, fx.key_of(&key_buf, n)); // Present.
        try expect_entry(c.current(), n);
        try c.seek(testing.io, fx.key_of(&key_buf, n + 1)); // Absent between two keys.
        try expect_entry(c.current(), if (i + 1 < count) n + 2 else null);
        try testing.expect(f.pool.pinned_count() <= 1);
    }
    try c.seek(testing.io, ""); // Before the first key.
    try expect_entry(c.current(), 0);
    try c.seek(testing.io, "a");
    try expect_entry(c.current(), 0);
    try c.seek(testing.io, "z"); // Past the last key.
    try expect_entry(c.current(), null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_entry(try c.next(testing.io), null);
    try c.seek(testing.io, "z");
    try expect_entry(try c.prev(testing.io), 2 * (count - 1)); // Back from past-last: the last.
    try expect_entry(try c.next(testing.io), null);
    try c.seek(testing.io, fx.key_of(&key_buf, 0));
    try expect_entry(try c.prev(testing.io), null); // Before the first.
    try expect_entry(try c.next(testing.io), 0);
    try expect_entry(try c.next(testing.io), 2);
}

fn random_walk(size: u32, count: u32, ops: u32, seed: u64) !void {
    assert(count > 0 and ops > 0);
    assert(header.page_size_valid(size));
    var f: Fixture = undefined;
    try start(&f, size);
    defer f.stop(testing.allocator);

    const stride: u32 = 2;
    try fill_shuffled(&f, count, stride, seed);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    var prng = std.Random.DefaultPrng.init(seed +% 77);
    const rnd = prng.random();
    var pos: i64 = 0; // Model index; -1 before the first, `count` past the last.
    try expect_entry(try c.first(testing.io), 0);
    var key_buf: [8]u8 = undefined;
    for (0..ops) |_| {
        var item: ?Entry = undefined;
        switch (rnd.uintLessThan(u32, 10)) {
            0...3 => {
                item = try c.next(testing.io);
                pos = @min(pos + 1, count);
            },
            4...6 => {
                item = try c.prev(testing.io);
                pos = @max(pos - 1, -1);
            },
            else => {
                const target = rnd.uintLessThan(u32, count * stride + 3);
                try c.seek(testing.io, fx.key_of(&key_buf, target));
                item = c.current();
                pos = @min(@divFloor(target + stride - 1, stride), count);
            },
        }
        const want: ?u32 = if (pos >= 0 and pos < count) @as(u32, @intCast(pos)) * stride else null;
        try expect_entry(item, want);
        try expect_entry(c.current(), want);
        try testing.expect(f.pool.pinned_count() <= 1);
    }
}

test "cursor: a seeded random walk of next, prev and seek matches the model at 512 B" {
    try random_walk(512, 600, 4000, 5);
}

test "cursor: a seeded random walk of next, prev and seek matches the model at 4 KiB" {
    try random_walk(4096, 1500, 3000, 6);
}

test "cursor: an empty tree gives null both ways" {
    inline for (.{ 512, 4096 }) |size| {
        var f: Fixture = undefined;
        try start(&f, size);
        defer f.stop(testing.allocator);

        var c: Cursor = undefined;
        Cursor.init(&c, &f.tree);
        defer c.release();

        try expect_entry(try c.first(testing.io), null);
        try expect_entry(try c.next(testing.io), null);
        try expect_entry(try c.last(testing.io), null);
        try expect_entry(try c.prev(testing.io), null);
        try c.seek(testing.io, "k00000");
        try expect_entry(c.current(), null);
        try expect_entry(try c.next(testing.io), null);
        try expect_entry(try c.prev(testing.io), null);
        try expect_entry(try c.next(testing.io), null);
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    }
}

test "cursor: a single entry is both first and last" {
    var f: Fixture = undefined;
    try start(&f, 512);
    defer f.stop(testing.allocator);

    try f.tree.insert(testing.io, "k00007", "v00007");
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try expect_entry(try c.first(testing.io), 7);
    try expect_entry(try c.next(testing.io), null);
    try expect_entry(try c.prev(testing.io), 7);
    try expect_entry(try c.prev(testing.io), null);
    try expect_entry(try c.last(testing.io), 7);
}

fn leaf_of(f: *Fixture, n: u32) !Id {
    assert(n < 100_000);
    assert(f.pool.pinned_count() == 0);
    var key_buf: [8]u8 = undefined;
    var path: descend.Path = undefined;
    var guard = try descend.descend(
        &f.pool,
        testing.io,
        f.tree.root,
        fx.key_of(&key_buf, n),
        false,
        &path,
    );
    guard.release();
    return path.leaf;
}

fn edit_page(f: *Fixture, id: Id, level: ?u8, next: ?Id, relink: bool) !void {
    assert(id != .file_header);
    assert(relink or next == null);
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    if (level) |value| page[node.offset_level] = value;
    if (relink) node.set_next(page, next);
    node.seal(page, id, header.peek(page).lsn);
}

fn forward_count(c: *Cursor) !u32 {
    assert(c.tree.root != .file_header);
    assert(c.current() == null);
    var count: u32 = 0;
    var item = try c.first(testing.io);
    for (0..scan_steps_max) |_| {
        if (item == null) return count;
        count += 1;
        item = try c.next(testing.io);
    }
    return error.TestUnexpectedResult; // A hang would end here instead.
}

fn backward_count(c: *Cursor) !u32 {
    assert(c.tree.root != .file_header);
    assert(c.current() == null);
    var count: u32 = 0;
    var item = try c.last(testing.io);
    for (0..scan_steps_max) |_| {
        if (item == null) return count;
        count += 1;
        item = try c.prev(testing.io);
    }
    return error.TestUnexpectedResult;
}

fn corrupt_start(f: *Fixture) !void {
    assert(scan_steps_max > 150); // A full scan of the tree below must fit.
    assert(@sizeOf(Fixture) > 0);
    try start(f, 512);
    errdefer f.stop(testing.allocator);

    try fill_shuffled(f, 150, 1, 9);
    const first_leaf = try leaf_of(f, 0);
    const middle = try leaf_of(f, 75);
    const end_leaf = try leaf_of(f, 149);
    try testing.expect(first_leaf != middle and middle != end_leaf and first_leaf != end_leaf);
    try testing.expectEqual(@as(u32, 150), blk: {
        var c: Cursor = undefined;
        Cursor.init(&c, &f.tree);
        defer c.release();

        break :blk try forward_count(&c);
    });
}

test "cursor: a leaf linking to itself is Corrupted, not a hang" {
    var f: Fixture = undefined;
    try corrupt_start(&f);
    defer f.stop(testing.allocator);

    const middle = try leaf_of(&f, 75);
    try edit_page(&f, middle, null, middle, true);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, forward_count(&c));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: a link back to an earlier leaf (keys not ascending) is Corrupted" {
    var f: Fixture = undefined;
    try corrupt_start(&f);
    defer f.stop(testing.allocator);

    const first_leaf = try leaf_of(&f, 0);
    const end_leaf = try leaf_of(&f, 149);
    try edit_page(&f, end_leaf, null, first_leaf, true);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, forward_count(&c));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: a predecessor whose link skips this leaf is Corrupted going backward" {
    var f: Fixture = undefined;
    try corrupt_start(&f);
    defer f.stop(testing.allocator);

    const first_leaf = try leaf_of(&f, 0);
    const end_leaf = try leaf_of(&f, 149);
    try edit_page(&f, first_leaf, null, end_leaf, true);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, backward_count(&c));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: an internal level that does not match its children is Corrupted" {
    var f: Fixture = undefined;
    try corrupt_start(&f);
    defer f.stop(testing.allocator);

    try edit_page(&f, f.tree.root, 2, null, false);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, c.last(testing.io));
    try testing.expect(c.current() == null);
    try testing.expectError(error.Corrupted, c.first(testing.io));
    try testing.expectError(error.Corrupted, c.seek(testing.io, "k00050"));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: a fetch failure propagates and leaves the cursor released" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 1024); // Fewer frames than pages, so pins can fill it.
    defer f.stop(testing.allocator);

    try fill_shuffled(&f, 400, 1, 11);
    try testing.expect(f.pm.page_count > 10);
    const target = try leaf_of(&f, 399);
    try f.cold();
    var pinned: u32 = 0;
    var guards: [64]buffer_pool.PageGuard = undefined;
    try testing.expect(f.pool.frames_max <= guards.len);
    for (1..f.pm.page_count) |raw| {
        if (pinned == f.pool.frames_max) break;
        if (@as(Id, @enumFromInt(raw)) == target) continue;
        guards[pinned] = f.pool.fetch(testing.io, @enumFromInt(raw)) catch |err| switch (err) {
            error.Unwritten => continue, // A page allocated but never written.
            else => return err,
        };
        pinned += 1;
    }
    try testing.expectEqual(f.pool.frames_max, pinned);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.PoolExhausted, c.last(testing.io));
    try testing.expectError(error.PoolExhausted, c.seek(testing.io, "k00399"));
    try testing.expect(c.current() == null);
    try testing.expectEqual(pinned, f.pool.pinned_count());
    for (guards[0..pinned]) |*guard| guard.release();
    try expect_entry(try c.last(testing.io), 399); // Usable again after the pool frees up.
}

test "cursor: release is idempotent and leaves no pin; an oversized seek key is KeyTooLarge" {
    var f: Fixture = undefined;
    try start(&f, 512);
    defer f.stop(testing.allocator);

    try fill_shuffled(&f, 100, 1, 12);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    c.release(); // Never positioned.
    try expect_entry(try c.first(testing.io), 0);
    try testing.expectEqual(@as(u32, 1), f.pool.pinned_count());
    c.release();
    c.release();
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try testing.expect(c.current() == null);

    const long_key = [_]u8{'k'} ** (node.key_len_cap + 1);
    try testing.expectError(error.KeyTooLarge, c.seek(testing.io, &long_key));
    const edge_key = [_]u8{'k'} ** (node.key_len_max(512) + 1);
    try testing.expectError(error.KeyTooLarge, c.seek(testing.io, &edge_key));
    try c.seek(testing.io, edge_key[0..node.key_len_max(512)]); // Allowed, past every key.
    try testing.expect(c.current() == null);
}

test "cursor: an oversized seek key from a positioned cursor drops the pin" {
    var f: Fixture = undefined;
    try start(&f, 512);
    defer f.stop(testing.allocator);

    try fill_shuffled(&f, 20, 1, 13);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try expect_entry(try c.first(testing.io), 0);
    try testing.expectEqual(@as(u32, 1), f.pool.pinned_count());
    const long_key = [_]u8{'k'} ** (node.key_len_max(512) + 1);
    try testing.expectError(error.KeyTooLarge, c.seek(testing.io, &long_key));
    try testing.expect(c.current() == null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: stepping after a write shrank the leaf is Corrupted, not an assert" {
    var f: Fixture = undefined;
    try start(&f, 512);
    defer f.stop(testing.allocator);

    try fill_shuffled(&f, 5, 1, 14);
    var key_buf: [8]u8 = undefined;
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try expect_entry(try c.last(testing.io), 4);
    try testing.expect(try f.tree.delete(testing.io, fx.key_of(&key_buf, 4)));
    try testing.expect(try f.tree.delete(testing.io, fx.key_of(&key_buf, 3)));
    try testing.expectError(error.Corrupted, c.next(testing.io));
    try testing.expect(c.current() == null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());

    try expect_entry(try c.last(testing.io), 2);
    try testing.expect(try f.tree.delete(testing.io, fx.key_of(&key_buf, 2)));
    try testing.expect(try f.tree.delete(testing.io, fx.key_of(&key_buf, 1)));
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}
