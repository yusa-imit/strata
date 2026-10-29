//! Contract tests for splitting inserts (plan 005 item 5, ADR-0004 sections 2, 8, 9): 10k
//! sequential and 10k seeded random inserts at 512 B and 4 KiB validate and read back; a smaller
//! count at all eight page sizes; variable-length keys and values with overwrites after splits;
//! the root id never changes; no allocation after init; and every prepare-phase failure
//! (`HeightLimit`, `PoolExhausted`, `NoSpaceLeft`) leaves every existing page byte-identical.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const tree_mod = @import("tree.zig");
const fx = @import("tree_fixtures.zig");
const buffer_pool_guard = @import("../cache/buffer_pool.zig").PageGuard;

const Fixture = fx.Fixture;
const big_value = "v" ** 60; // Larger than any space a full node has left.
const Tree = tree_mod.Tree;
var no_frees: [1]header.Id = undefined; // Storage for trees that never delete.

/// Root page type and level, read through the pool.
fn root_shape(f: *Fixture) !struct { page_type: header.Type, level: u8 } {
    assert(f.pool.pinned_count() == 0);
    assert(f.tree.root != .file_header);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const page = guard.bytes();
    assert(page.len == f.pool.page_size);
    return .{ .page_type = header.peek(page).page_type, .level = page[node.offset_level] };
}

fn value_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 8);
    assert(n < 1_000_000);
    std.mem.writeInt(u32, buf[0..4], n, .little);
    std.mem.writeInt(u32, buf[4..8], n *% 2654435761, .little);
    return buf[0..8];
}

test "split: 10k sequential inserts at 512 B and 4 KiB validate and read back" {
    for ([_]u32{ 512, 4096 }) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 40, 4096);
        defer f.stop(testing.allocator);

        var key_buf: [8]u8 = undefined;
        var value_buf: [8]u8 = undefined;
        for (0..10_000) |n| {
            const key = fx.key_of(&key_buf, @intCast(n));
            try f.tree.insert(testing.io, key, value_of(&value_buf, @intCast(n)));
            if (n % 2000 == 1999) try f.tree.validate(testing.io, testing.allocator);
        }
        try f.tree.check_invariants(testing.io);
        try f.cold();
        for (0..10_000) |n| {
            const key = fx.key_of(&key_buf, @intCast(n));
            try fx.expect_get(&f.tree, key, value_of(&value_buf, @intCast(n)));
        }
        try fx.expect_get(&f.tree, "k99999", null);
        try fx.expect_get(&f.tree, "", null);
        try testing.expectEqual(@as(u32, 1), @intFromEnum(f.tree.root));
        try testing.expect(f.pm.page_count > 20);
    }
}

test "split: 10k seeded random inserts (with overwrites) agree with a model" {
    for ([_]u32{ 512, 4096 }, 0..) |size, size_index| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 40, 4096);
        defer f.stop(testing.allocator);

        var model: fx.Model = .empty;
        defer fx.model_free(&model);

        var prng = std.Random.DefaultPrng.init(0x5EED_5005 + size_index);
        const random = prng.random();
        var key_buf: [8]u8 = undefined;
        var value_buf: [40]u8 = undefined;
        for (0..10_000) |step| {
            const key = fx.key_of(&key_buf, random.uintLessThan(u32, 9000));
            const value = value_buf[0..random.uintAtMost(usize, 40)]; // Overwrites change sizes.
            random.bytes(value);
            try f.tree.insert(testing.io, key, value);
            try fx.model_put(&model, key, value);
            if (step % 2500 == 2499) try fx.model_compare(&f.tree, &model);
        }
        try fx.model_compare(&f.tree, &model);
        try f.cold();
        try fx.model_compare(&f.tree, &model);
        try testing.expect(model.count() > 5000);
    }
}

test "split: a few thousand inserts at every page size, variable keys and values" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 40, 64);
        defer f.stop(testing.allocator);

        var model: fx.Model = .empty;
        defer fx.model_free(&model);

        var prng = std.Random.DefaultPrng.init(0xA11_5125 + size);
        const random = prng.random();
        const count = @divFloor(4 * node.usable(size), 40) + 50; // About four leaves of cells.
        var key_buf: [24]u8 = undefined;
        var value_buf: [60]u8 = undefined;
        for (0..count) |_| {
            const key = key_buf[0..random.intRangeAtMost(usize, 3, 24)];
            random.bytes(key);
            const value = value_buf[0..random.uintAtMost(usize, 60)];
            random.bytes(value);
            try f.tree.insert(testing.io, key, value);
            try fx.model_put(&model, key, value);
        }
        try fx.model_compare(&f.tree, &model);
        const shape = try root_shape(&f);
        try testing.expectEqual(header.Type.btree_internal, shape.page_type);
        try testing.expect(f.pm.page_count >= 4);
    }
}

test "split: the root id is fixed across root splits, which raise its level by one" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 2048);
    defer f.stop(testing.allocator);

    const root = f.tree.root;
    var key_buf: [8]u8 = undefined;
    var level_seen: u8 = 0;
    var raises: u32 = 0;
    for (0..3000) |n| {
        try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "vvvvvvvv");
        const shape = try root_shape(&f);
        try testing.expectEqual(root, f.tree.root);
        if (shape.level != level_seen) {
            try testing.expectEqual(level_seen + 1, shape.level); // One level at a time.
            level_seen = shape.level;
            raises += 1;
            try f.tree.validate(testing.io, testing.allocator);
        }
    }
    try testing.expect(raises >= 2); // A leaf root became internal, then that root split.
    var reopened: Tree = undefined;
    try f.cold();
    try Tree.open(&reopened, &f.pool, root, &no_frees, &fx.value_buf);
    try fx.expect_get(&reopened, "k02999", "vvvvvvvv");
}

test "split: descending-order and out-of-order inserts keep the tree valid" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 2048);
    defer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    for (0..1500) |n| {
        try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(1499 - n)), "d");
    }
    for (0..1500) |n| { // Longer values: each overwrite can outgrow its leaf and split it.
        try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "overwritten value");
    }
    try f.tree.validate(testing.io, testing.allocator);
    for (0..1500) |n| {
        try fx.expect_get(&f.tree, fx.key_of(&key_buf, @intCast(n)), "overwritten value");
    }
}

test "split: nothing allocates after init, even through many splits" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var f: Fixture = undefined;
    try f.start(failing.allocator(), 512, 40, 2048);
    defer f.stop(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    var key_buf: [8]u8 = undefined;
    for (0..2000) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "value");
    try f.tree.check_invariants(testing.io);
    try testing.expectEqual(allocs, failing.alloc_index);
    try testing.expectError(error.OutOfMemory, f.tree.validate(testing.io, failing.allocator()));
    try f.tree.validate(testing.io, testing.allocator);
}

fn root_bytes(f: *Fixture, out: []u8) !void {
    assert(out.len == f.pool.page_size);
    assert(f.pool.pinned_count() == 0);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    @memcpy(out, guard.bytes());
}

test "split: PoolExhausted and NoSpaceLeft are returned before any existing page changes" {
    const Case = struct { frames: u32, pages_max: u32, want: anyerror };
    const cases = [_]Case{
        .{ .frames = 2, .pages_max = 64, .want = error.PoolExhausted }, // Leaf plus two new pages.
        .{ .frames = 8, .pages_max = 2, .want = error.NoSpaceLeft }, // No spare id at all.
    };
    for (cases) |case| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, 512, case.frames, case.pages_max);
        defer f.stop(testing.allocator);

        var before: [512]u8 = undefined;
        var after: [512]u8 = undefined;
        var key_buf: [8]u8 = undefined;
        var failed = false;
        for (0..200) |n| {
            try root_bytes(&f, &before);
            const key = fx.key_of(&key_buf, @intCast(n));
            f.tree.insert(testing.io, key, "vvvvvvvv") catch |err| {
                try testing.expectEqual(case.want, err);
                failed = true;
            };
            if (failed) break;
        }
        try testing.expect(failed);
        try root_bytes(&f, &after);
        try testing.expectEqualSlices(u8, &before, &after);
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
        try testing.expectEqual(header.Type.btree_leaf, (try root_shape(&f)).page_type);
        try fx.expect_get(&f.tree, "k00000", "vvvvvvvv"); // Still readable.
    }
}

/// Fills `page` (an internal or leaf node already formatted) with ascending cells until full.
fn fill_internal(page: []u8, child: header.Id, prefix: u8) !void {
    assert(page[node.offset_type] == @intFromEnum(header.Type.btree_internal));
    assert(child != .file_header);
    var n: u32 = 0;
    while (n < 100_000) : (n += 1) {
        var key_buf: [8]u8 = undefined;
        const key = fx.key_of(&key_buf, n)[1..]; // 5 bytes: a 10 byte cell.
        key_buf[1] = prefix; // Deeper levels get larger prefixes, so separators nest in order.
        internal.internal_insert(page, @intCast(n), key, child) catch |err| switch (err) {
            error.NodeFull => return,
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

fn fill_leaf(page: []u8) !void {
    assert(page[node.offset_type] == @intFromEnum(header.Type.btree_leaf));
    assert(page.len >= header.page_size_min);
    var n: u32 = 0;
    while (n < 100_000) : (n += 1) {
        var key_buf: [8]u8 = undefined;
        const key = fx.key_of(&key_buf, n); // 6 bytes: wider than an internal key.
        key_buf[0] = 'r'; // Above the prefix of every internal level.
        node.leaf_insert(page, @intCast(n), key, .{ .bytes = "v" }) catch |err| switch (err) {
            error.NodeFull => return,
            else => return err,
        };
    }
    return error.TestUnexpectedResult;
}

/// Hand-builds a chain of `height_max` levels whose nodes are all full on the right edge, so a
/// split of the leaf cascades to the root. Children of cells are dummies: only the right edge
/// is descended by the keys used below.
fn build_full_chain(f: *Fixture, height: u8) !void {
    assert(height >= 2 and height <= node.height_max(f.pool.page_size));
    assert(f.pm.page_count == 2); // Page 0 and the root.
    const dummy: header.Id = @enumFromInt(2); // The leaf: a valid id that is no internal node's.
    var child: header.Id = undefined;
    var level: u8 = 0;
    while (level < height) : (level += 1) {
        const id = if (level == height - 1) f.tree.root else try f.pm.allocate(testing.io);
        var guard = if (level == height - 1)
            try f.pool.fetchForUpdate(testing.io, id)
        else
            try f.pool.fetchNew(testing.io, id);
        defer guard.release();

        const page = guard.bytes_mut();
        if (level == 0) {
            node.format_leaf(page, id, null, 0);
            try fill_leaf(page);
        } else {
            internal.format_internal(page, id, level, child, 0);
            try fill_internal(page, dummy, @intCast('a' + height - level));
        }
        node.seal(page, id, 0);
        child = id;
    }
    assert(f.pm.page_count == height + 1);
    assert(f.pool.pinned_count() == 0);
}

test "split: HeightLimit at the deepest tree is returned in prepare, nothing changes" {
    for ([_]u32{ 512, 65536 }) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2 * node.height_max(size) + 4, 64);
        defer f.stop(testing.allocator);

        try build_full_chain(&f, node.height_max(size));
        const count_before = f.pm.page_count;
        const total = @as(usize, count_before) * size;
        const saved = try testing.allocator.alloc(u8, total);
        defer testing.allocator.free(saved);

        for (1..count_before) |id| {
            var guard = try f.pool.fetch(testing.io, @enumFromInt(id));
            defer guard.release();

            @memcpy(saved[id * size ..][0..size], guard.bytes());
        }
        const err = f.tree.insert(testing.io, "zzzzzz", "v");
        try testing.expectError(error.HeightLimit, err);
        try testing.expectEqual(count_before, f.pm.page_count); // Nothing was allocated.
        for (1..count_before) |id| {
            var guard = try f.pool.fetch(testing.io, @enumFromInt(id));
            defer guard.release();

            try testing.expectEqualSlices(u8, saved[id * size ..][0..size], guard.bytes());
        }
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
        try fx.expect_get(&f.tree, "zzzzzz", null);
        try fx.expect_get(&f.tree, "r00000", "v");
    }
}

test "split: a cascade that stops below the root splits only the full levels" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 2048);
    defer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    var model: fx.Model = .empty;
    defer fx.model_free(&model);

    var prng = std.Random.DefaultPrng.init(0xCA5_CADE);
    const random = prng.random();
    for (0..4000) |n| {
        const key = fx.key_of(&key_buf, random.uintLessThan(u32, 50_000));
        try f.tree.insert(testing.io, key, "x");
        try fx.model_put(&model, key, "x");
        if (n % 500 == 499) try f.tree.check_invariants(testing.io);
    }
    try fx.model_compare(&f.tree, &model);
    const shape = try root_shape(&f);
    try testing.expect(shape.level >= 2); // At least two internal levels were built.
}

/// Copies pages `1 ..< page_count` as the pool sees them into `out` (`page_count * 512` bytes).
fn snapshot(f: *Fixture, out: []u8) !void {
    assert(f.pool.page_size == 512);
    assert(out.len == @as(usize, f.pm.page_count) * 512);
    for (1..f.pm.page_count) |id| {
        var guard = try f.pool.fetch(testing.io, @enumFromInt(id));
        defer guard.release();

        @memcpy(out[id * 512 ..][0..512], guard.bytes());
    }
}

fn expect_unchanged(f: *Fixture, before: []const u8) !void {
    assert(before.len == @as(usize, f.pm.page_count) * 512);
    assert(f.pool.pinned_count() == 0);
    for (1..f.pm.page_count) |id| {
        var guard = try f.pool.fetch(testing.io, @enumFromInt(id));
        defer guard.release();

        try testing.expectEqualSlices(u8, before[id * 512 ..][0..512], guard.bytes());
    }
}

/// A 512 B tree of two levels whose right-most leaf is full of keys `kb####` (above every
/// separator), so inserting `kzzzzz` splits that leaf. Returns the right leaf's id.
fn prepare_full_right(f: *Fixture) !header.Id {
    assert(f.pool.page_size == 512);
    var key_buf: [8]u8 = undefined;
    for (0..80) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "vvvvvvvv");
    try testing.expectEqual(@as(u8, 1), (try root_shape(f)).level);
    var path: descend.Path = undefined;
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, "kzzzzz", true, &path);
    defer guard.release();

    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        var buf: [8]u8 = undefined;
        const key = fx.key_of(&buf, n);
        buf[1] = 'b';
        const count = (try node.parse_leaf(guard.bytes())).count;
        const value: node.Value = .{ .bytes = "vvvvvvvv" };
        node.leaf_insert(guard.bytes_mut(), count, key, value) catch |err| switch (err) {
            error.NodeFull => break,
            else => return err,
        };
    }
    try testing.expect(n > 5 and n < 1000);
    return path.leaf;
}

/// Inserting `kzzzzz` must be `Corrupted`, leave every page byte-identical, and pin nothing.
fn expect_insert_corrupted(f: *Fixture) !void {
    assert(f.pool.pinned_count() == 0);
    const total = @as(usize, f.pm.page_count) * 512;
    const before = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(before);

    try snapshot(f, before);
    try testing.expectError(error.Corrupted, f.tree.insert(testing.io, "kzzzzz", big_value));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_unchanged(f, before);
}

/// Page offset of the key bytes of root cell `index`.
fn root_key_offset(f: *Fixture, index: u16) !u32 {
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const page = guard.bytes();
    const view = try internal.parse_internal(page, 1);
    const key = (try view.entry(index)).key;
    assert(key.len >= 2);
    return @intCast(@intFromPtr(key.ptr) - @intFromPtr(page.ptr));
}

test "split: a full leaf with a bad cell away from the slot is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
        defer guard.release();

        const count = (try node.parse_leaf(guard.bytes())).count;
        const key = fx.key_of(&key_buf, n);
        node.leaf_insert(guard.bytes_mut(), count, key, .{ .bytes = "vv" }) catch break;
    }
    try testing.expect(n > 5 and n < 1000);
    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    const page = guard.bytes_mut();
    page[page.len - 3] = 'z'; // Cell 0's key now sorts after cell 1: far from the new slot.
    guard.release();
    try testing.expectError(error.Corrupted, f.tree.insert(testing.io, "kzzzzz", big_value));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    var after: [512]u8 = undefined;
    try root_bytes(&f, &after);
    try testing.expectEqual(@as(u8, 'z'), after[after.len - 3]); // Left as it was, not rebuilt.
    try testing.expectEqual(@as(u32, 2), f.pm.page_count); // No page was allocated.
}

test "split: a root leaf with a next link is Corrupted before any split" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    var n: u32 = 0;
    while (n < 1000) : (n += 1) {
        var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
        defer guard.release();

        const count = (try node.parse_leaf(guard.bytes())).count;
        const key = fx.key_of(&key_buf, n);
        node.leaf_insert(guard.bytes_mut(), count, key, .{ .bytes = "vv" }) catch break;
    }
    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    node.set_next(guard.bytes_mut(), @enumFromInt(1 + 1));
    guard.release();
    var before: [512]u8 = undefined;
    var after: [512]u8 = undefined;
    try root_bytes(&f, &before);
    try testing.expectError(error.Corrupted, f.tree.insert(testing.io, "kzzzzz", big_value));
    try root_bytes(&f, &after);
    try testing.expectEqualSlices(u8, &before, &after);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try testing.expectEqual(@as(u32, 2), f.pm.page_count);
}

test "split: a parent whose neighbour does not bound the new separator is Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 256);
    defer f.stop(testing.allocator);

    _ = try prepare_full_right(&f);
    const at = try root_key_offset(&f, (try root_count(&f)) - 1);
    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    guard.bytes_mut()[at + 1] = 'z'; // Last separator `kz0...`: above the new separator `kb...`.
    guard.release();
    try expect_insert_corrupted(&f);
}

fn root_count(f: *Fixture) !u16 {
    assert(f.pool.pinned_count() == 0);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const view = try internal.parse_internal(guard.bytes(), 1);
    assert(view.count >= 1);
    return view.count;
}

test "split: an ancestor with a cell child equal to itself is Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 256);
    defer f.stop(testing.allocator);

    _ = try prepare_full_right(&f);
    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    const page = guard.bytes_mut();
    std.mem.writeInt(u32, page[page.len - 4 ..][0..4], @intFromEnum(f.tree.root), .little);
    guard.release();
    try expect_insert_corrupted(&f);
}

test "split: prepare failures on a two-level tree change nothing and the tree still validates" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 5, 256);
    defer f.stop(testing.allocator);

    _ = try prepare_full_right(&f);
    const total = @as(usize, f.pm.page_count) * 512;
    const before = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(before);

    try snapshot(&f, before);
    var held: [3]buffer_pool_guard = undefined;
    for (&held) |*slot| {
        const id = try f.pm.allocate(testing.io);
        slot.* = try f.pool.fetchNew(testing.io, id);
        node.format_leaf(slot.bytes_mut(), id, null, 0);
    }
    // Two frames left: leaf and parent are pinned, the new page has none.
    try testing.expectError(error.PoolExhausted, f.tree.insert(testing.io, "kzzzzz", big_value));
    for (&held) |*slot| slot.release();
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_unchanged_prefix(&f, before);
    try f.tree.validate(testing.io, testing.allocator);
}

fn expect_unchanged_prefix(f: *Fixture, before: []const u8) !void {
    assert(before.len % 512 == 0);
    assert(f.pool.pinned_count() == 0);
    for (1..@divExact(before.len, 512)) |id| {
        var guard = try f.pool.fetch(testing.io, @enumFromInt(id));
        defer guard.release();

        try testing.expectEqualSlices(u8, before[id * 512 ..][0..512], guard.bytes());
    }
}

test "split: NoSpaceLeft on the second fresh page of a cascade changes no existing page" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 12, 4); // Page 0, root, leaf, plus one spare id.
    defer f.stop(testing.allocator);

    try build_full_chain(&f, 2);
    try testing.expectEqual(@as(u32, 3), f.pm.page_count);
    const before = try testing.allocator.alloc(u8, 3 * 512);
    defer testing.allocator.free(before);

    try snapshot(&f, before);
    try testing.expectError(error.NoSpaceLeft, f.tree.insert(testing.io, "zzzzzz", "v"));
    try testing.expectEqual(@as(u32, 4), f.pm.page_count); // The first fresh id leaked.
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try expect_unchanged_prefix(&f, before);
    try fx.expect_get(&f.tree, "r00000", "v");
}
