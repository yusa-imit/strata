//! Contract tests for delete (plan 005 item 6, ADR-0004 sections 8, 9): every key deleted in
//! seeded random, ascending and descending order at 512 B and 4 KiB (validate every 100 ops,
//! an empty root leaf at the end); a page-id counter model (every id is live in the tree or
//! freed exactly once); absent keys; the borrow and merge paths, internal merges and root
//! collapse provoked by shape; prepare failures (`FreesPendingLimit`, `PoolExhausted`,
//! `Corrupted`) leave every page byte-identical; no allocation after init; a model test
//! against a hash map with interleaved insert, delete and get; `BufferPool.discard`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const tree_mod = @import("tree.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Tree = tree_mod.Tree;
const Id = header.Id;
const stack_max: u32 = 4096;

const Shape = struct { pages: u32, height: u32, leaves: u32, level1: u32 };

/// Walks the whole tree with an explicit stack; marks every reached id in `live` when given.
fn walk(f: *Fixture, live: ?[]bool) !Shape {
    assert(f.pool.pinned_count() == 0);
    assert(f.tree.root != .file_header);
    assert(live == null or live.?.len == f.pm.page_count);
    var stack: [stack_max]Id = undefined;
    var shape: Shape = .{ .pages = 0, .height = 0, .leaves = 0, .level1 = 0 };
    stack[0] = f.tree.root;
    var len: u32 = 1;
    while (len > 0) {
        len -= 1;
        const id = stack[len];
        if (live) |marks| {
            try testing.expect(!marks[@intFromEnum(id)]); // Reached twice: shared page.
            marks[@intFromEnum(id)] = true;
        }
        var guard = try f.pool.fetch(testing.io, id);
        defer guard.release();

        const page = guard.bytes();
        shape.pages += 1;
        if (id == f.tree.root) shape.height = @as(u32, page[node.offset_level]) + 1;
        if (page[node.offset_type] == @intFromEnum(header.Type.btree_leaf)) {
            shape.leaves += 1;
            continue;
        }
        const view = try internal.parse_internal(page, page[node.offset_level]);
        if (view.level == 1) shape.level1 += 1;
        try testing.expect(len + view.count + 1 <= stack_max);
        for (0..view.count) |index| {
            stack[len] = (try view.entry(@intCast(index))).child;
            len += 1;
        }
        stack[len] = view.right_child;
        len += 1;
    }
    return shape;
}

/// Every page of the file, concatenated, read through the pool (unwritten pages are zeros).
fn snapshot(f: *Fixture, gpa: Allocator) ![]u8 {
    assert(f.pool.pinned_count() == 0);
    const size = f.pool.page_size;
    const out = try gpa.alloc(u8, @as(usize, f.pm.page_count) * size);
    errdefer gpa.free(out);

    @memset(out, 0);
    for (1..f.pm.page_count) |raw| {
        var guard = f.pool.fetch(testing.io, @enumFromInt(raw)) catch |err| switch (err) {
            error.Unwritten => continue,
            else => return err,
        };
        defer guard.release();

        @memcpy(out[raw * size ..][0..size], guard.bytes());
    }
    return out;
}

fn fill(f: *Fixture, count: u32) !void {
    assert(f.tree.frees_len == 0);
    assert(count < 100_000);
    assert(f.pool.pinned_count() == 0);
    var key_buf: [8]u8 = undefined;
    for (0..count) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "12345678");
}

/// Page-id counter model: after `release_frees`, every id below `page_count` is either live in
/// the tree or comes back from the freelist exactly once (a leak or a double free fails).
fn account(f: *Fixture, gpa: Allocator) !void {
    assert(f.tree.frees_len == 0);
    assert(f.pool.pinned_count() == 0);
    const count = f.pm.page_count;
    const seen = try gpa.alloc(bool, count);
    defer gpa.free(seen);

    @memset(seen, false);
    seen[0] = true; // The file header.
    _ = try walk(f, seen);
    f.pool.discardAll();
    for (0..count) |_| {
        const id = try f.pm.allocate(testing.io);
        if (@intFromEnum(id) >= count) break;
        try testing.expect(!seen[@intFromEnum(id)]); // Live or freed twice.
        seen[@intFromEnum(id)] = true;
    }
    for (seen) |mark| try testing.expect(mark); // A false entry is a leaked page.
}

fn delete_key(f: *Fixture, n: u32) !bool {
    assert(n < 100_000);
    assert(f.pool.pinned_count() == 0);
    var key_buf: [8]u8 = undefined;
    return f.tree.delete(testing.io, fx.key_of(&key_buf, n));
}

fn expect_empty_root_leaf(f: *Fixture) !void {
    assert(f.pool.pinned_count() == 0);
    assert(f.tree.frees_len <= f.tree.frees_pending.len);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const leaf = try node.parse_leaf(guard.bytes());
    try testing.expectEqual(@as(u16, 0), leaf.count);
    try testing.expectEqual(@as(?Id, null), leaf.next);
}

const Order = enum { random, ascending, descending };

fn delete_all(size: u32, order: Order, seed: u64, count: u32) !void {
    assert(header.page_size_valid(size));
    assert(count > 0 and count < 100_000);
    var f: Fixture = undefined;
    try f.start(testing.allocator, size, 40, 4096);
    defer f.stop(testing.allocator);

    try fill(&f, count);
    const before = try walk(&f, null);
    const keys = try testing.allocator.alloc(u32, count);
    defer testing.allocator.free(keys);

    for (keys, 0..) |*slot, n| slot.* = @intCast(if (order == .descending) count - 1 - n else n);
    var prng = std.Random.DefaultPrng.init(seed);
    if (order == .random) prng.random().shuffle(u32, keys);
    var freed: u32 = 0;
    for (keys, 0..) |n, op| {
        try testing.expect(try delete_key(&f, n));
        try testing.expect(!try delete_key(&f, n));
        if (op % 100 == 99) try f.tree.validate(testing.io, testing.allocator);
        if (f.tree.frees_len >= 32) freed += try f.tree.release_frees(testing.io);
    }
    freed += try f.tree.release_frees(testing.io);
    try f.tree.validate(testing.io, testing.allocator);
    try expect_empty_root_leaf(&f);
    try testing.expectEqual(before.pages - 1, freed);
    try account(&f, testing.allocator);
}

test "delete: all keys in seeded random order at 512 B and 4 KiB" {
    try delete_all(512, .random, 7, 3000);
    try delete_all(4096, .random, 11, 3000);
}

test "delete: ascending and descending order empty the tree" {
    for ([_]Order{ .ascending, .descending }) |order| {
        try delete_all(512, order, 1, 2000);
        try delete_all(4096, order, 1, 2000);
    }
}

test "delete: absent keys and an empty tree return false and change nothing" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try testing.expect(!try delete_key(&f, 5)); // Empty tree.
    try fill(&f, 36);
    const before = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(before);

    try testing.expect(!try delete_key(&f, 99));
    try testing.expect(!try f.tree.delete(testing.io, ""));
    const after = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
    try testing.expectError(error.KeyTooLarge, f.tree.delete(testing.io, "k" ** 200));
}

fn leftmost_count(f: *Fixture) !u16 {
    assert(f.pool.pinned_count() == 0);
    assert(f.tree.root != .file_header);
    var path: descend.Path = undefined;
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, "", false, &path);
    defer guard.release();

    return (try node.parse_leaf(guard.bytes())).count;
}

test "delete: an underfull leaf borrows when the merge would not fit" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 36);
    try testing.expectEqual(@as(u32, 2), (try walk(&f, null)).leaves);
    var borrowed = false;
    for (0..12) |n| {
        const count = try leftmost_count(&f);
        try testing.expect(try delete_key(&f, @intCast(n)));
        if (try leftmost_count(&f) >= count) borrowed = true; // Gained a cell on a delete.
        if (borrowed) break;
    }
    try testing.expect(borrowed);
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len); // Nothing was unlinked.
    try testing.expectEqual(@as(u32, 2), (try walk(&f, null)).leaves);
    try f.tree.validate(testing.io, testing.allocator);
}

test "delete: an underfull leaf merges into its left survivor and the root collapses" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    try testing.expectEqual(@as(u32, 2), (try walk(&f, null)).leaves);
    const first_leaf = blk: {
        var path: descend.Path = undefined;
        var guard = try descend.descend(&f.pool, testing.io, f.tree.root, "", false, &path);
        defer guard.release();

        break :blk path.leaf;
    };
    for (0..10) |n| {
        _ = try delete_key(&f, @intCast(n));
        if (f.tree.frees_len > 0) break;
    }
    try testing.expectEqual(@as(u32, 2), f.tree.frees_len); // Right leaf, then collapsed child.
    const shape = try walk(&f, null);
    try testing.expectEqual(@as(u32, 1), shape.pages); // A leaf root again; the id is unchanged.
    try testing.expect(f.tree.frees_pending[0] != f.tree.frees_pending[1]);
    try testing.expect(f.tree.frees_pending[0] != f.tree.root);
    try testing.expect(f.tree.frees_pending[1] != f.tree.root);
    try testing.expect(first_leaf != f.tree.root);
    try f.tree.validate(testing.io, testing.allocator);
    try testing.expectEqual(@as(u32, 2), try f.tree.release_frees(testing.io));
}

test "delete: internal nodes merge and the height shrinks to one" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 4096);
    defer f.stop(testing.allocator);

    try fill(&f, 3000);
    const start = try walk(&f, null);
    try testing.expectEqual(@as(u32, 3), start.height);
    var level1_min = start.level1;
    var height_min = start.height;
    for (0..3000) |n| {
        try testing.expect(try delete_key(&f, @intCast(n)));
        if (n % 25 == 0 or n > 2900) {
            const shape = try walk(&f, null);
            level1_min = @min(level1_min, shape.level1);
            height_min = @min(height_min, shape.height);
        }
        if (f.tree.frees_len >= 32) _ = try f.tree.release_frees(testing.io);
    }
    try testing.expect(level1_min < start.level1); // An internal merge freed a level-1 node.
    try testing.expectEqual(@as(u32, 1), height_min); // The root collapsed twice.
    _ = try f.tree.release_frees(testing.io);
    try expect_empty_root_leaf(&f);
}

test "delete: FreesPendingLimit leaves every page byte-identical" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    f.tree.frees_pending = f.tree.frees_pending[0..1]; // Room for one id; the merge needs two.
    var hit = false;
    for (0..10) |n| {
        const before = try snapshot(&f, testing.allocator);
        defer testing.allocator.free(before);

        _ = delete_key(&f, @intCast(n)) catch |err| switch (err) {
            error.FreesPendingLimit => {
                const after = try snapshot(&f, testing.allocator);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
                hit = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "delete: PoolExhausted with a two-frame pool leaves the tree unchanged" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    try f.cold();
    var small: buffer_pool.BufferPool = undefined;
    try buffer_pool.BufferPool.init(&small, testing.allocator, &f.pm, .{
        .frames_max = 2,
        .page_size = 512,
    });
    defer small.deinit(testing.allocator);

    var t: Tree = undefined;
    try Tree.open(&t, &small, f.tree.root, &f.frees, &fx.value_buf);
    var hit = false;
    for (0..10) |n| {
        var key_buf: [8]u8 = undefined;
        small.check_invariants();
        const before = try snapshot_of(&small, f.pm.page_count);
        defer testing.allocator.free(before);

        _ = t.delete(testing.io, fx.key_of(&key_buf, @intCast(n))) catch |err| switch (err) {
            error.PoolExhausted => {
                const after = try snapshot_of(&small, f.pm.page_count);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                try testing.expectEqual(@as(u32, 0), t.frees_len);
                hit = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(u32, 0), small.pinned_count());
    try small.flushAll(testing.io);
    small.discardAll();
}

fn snapshot_of(pool: *buffer_pool.BufferPool, page_count: u32) ![]u8 {
    assert(pool.pinned_count() == 0);
    assert(page_count >= 1);
    const size = pool.page_size;
    const out = try testing.allocator.alloc(u8, @as(usize, page_count) * size);
    errdefer testing.allocator.free(out);

    @memset(out, 0);
    for (1..page_count) |raw| {
        var guard = pool.fetch(testing.io, @enumFromInt(raw)) catch |err| switch (err) {
            error.Unwritten => continue,
            else => return err,
        };
        defer guard.release();

        @memcpy(out[raw * size ..][0..size], guard.bytes());
    }
    return out;
}

/// Swaps the first key byte of cell 0 with a larger one so the leaf is out of order, re-sealed.
fn break_leaf_order(f: *Fixture, id: Id) !void {
    assert(f.pool.pinned_count() == 0);
    assert(id != .file_header);
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    const leaf = try node.parse_leaf(page);
    const first = try leaf.entry(0);
    const offset = @intFromPtr(first.key.ptr) - @intFromPtr(page.ptr);
    page[offset + 5] = '~'; // Last digit of the first key becomes the largest byte.
    node.seal(page, id, header.peek(page).lsn);
}

test "delete: a corrupt leaf or sibling is Corrupted and no page changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    var path: descend.Path = undefined;
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, "k99999", false, &path);
    const right_leaf = path.leaf; // Sibling of the left leaf.
    guard.release();
    try break_leaf_order(&f, right_leaf);
    var hit = false;
    for (0..10) |n| {
        const before = try snapshot(&f, testing.allocator);
        defer testing.allocator.free(before);

        _ = delete_key(&f, @intCast(n)) catch |err| switch (err) {
            error.Corrupted => {
                const after = try snapshot(&f, testing.allocator);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                hit = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(hit);
    const before = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(before);

    try testing.expectError(error.Corrupted, delete_key(&f, 26)); // The corrupt leaf itself.
    const after = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

/// Inserts keys `prefix` + zero-padded counter of `width` bytes in total, ascending, until the
/// node is full; returns how many went in.
fn fill_internal(page: []u8, prefix: u8, width: usize, child: Id) !u16 {
    assert(width >= 1 and width <= 40);
    assert(child != .file_header);
    var key: [40]u8 = undefined;
    var added: u16 = 0;
    while (added < 200) : (added += 1) {
        const view = try internal.parse_internal_raw(page, page[node.offset_level]);
        @memset(key[0..width], '0');
        key[0] = prefix;
        key[width - 1] = '0' + @as(u8, @intCast(added % 10));
        if (width > 2) key[width - 2] = '0' + @as(u8, @intCast(@divTrunc(added, 10) % 10));
        internal.internal_insert(page, view.count, key[0..width], child) catch |err| switch (err) {
            error.NodeFull => return added,
            error.Corrupted => return err,
        };
    }
    return error.NodeFull; // The bound was reached without filling: a test setup bug.
}

/// Level 2 root R (full, short separator at cell 0) over an almost empty level-1 node X and a
/// full level-1 node Y: the delete of X's only key empties X, Y is too full to merge, and the
/// borrow's longer separator cannot replace the short one in R.
fn build_no_space_tree(f: *Fixture) !void {
    assert(f.pool.pinned_count() == 0);
    assert(f.pm.page_count == 2); // Only the created root leaf exists.
    const size = f.pool.page_size;
    var ids: [5]Id = undefined; // leaf a, leaf b, x, y, spare
    for (&ids) |*slot| slot.* = try f.pm.allocate(testing.io);
    const leaf_values = [_][]const u8{ "k00000", "k00009" };
    for (ids[0..2], 0..) |id, n| {
        var guard = try f.pool.fetchNew(testing.io, id);
        defer guard.release();

        const page = guard.bytes_mut();
        node.format_leaf(page, id, if (n == 0) ids[1] else null, 0);
        try node.leaf_insert(page, 0, leaf_values[n], .{ .bytes = "v" });
        node.seal(page, id, 0);
    }
    var x = try f.pool.fetchNew(testing.io, ids[2]);
    defer x.release();

    internal.format_internal(x.bytes_mut(), ids[2], 1, ids[1], 0);
    try internal.internal_insert(x.bytes_mut(), 0, "k00005", ids[0]);
    node.seal(x.bytes_mut(), ids[2], 0);
    var y = try f.pool.fetchNew(testing.io, ids[3]);
    defer y.release();

    internal.format_internal(y.bytes_mut(), ids[3], 1, ids[0], 0);
    for ([_]struct { u8, usize }{ .{ 'p', 40 }, .{ 'q', 10 }, .{ 'r', 3 }, .{ 's', 1 } }) |kind| {
        _ = try fill_internal(y.bytes_mut(), kind[0], kind[1], ids[0]);
    }
    node.seal(y.bytes_mut(), ids[3], 0);
    var r = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    defer r.release();

    const page = r.bytes_mut();
    internal.format_internal(page, f.tree.root, 2, ids[4], 0);
    try internal.internal_insert(page, 0, "k5", ids[2]);
    try internal.internal_insert(page, 1, "t", ids[3]);
    for ([_]struct { u8, usize }{ .{ 'u', 40 }, .{ 'v', 10 }, .{ 'w', 3 }, .{ 'x', 1 } }) |kind| {
        _ = try fill_internal(page, kind[0], kind[1], ids[4]);
    }
    node.seal(page, f.tree.root, 0);
    assert(size == 512);
}

test "delete: NoSpaceLeft when a forced borrow cannot fit its separator in the parent" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 16, 64);
    defer f.stop(testing.allocator);

    try build_no_space_tree(&f);
    const before = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(before);

    try testing.expectError(error.NoSpaceLeft, delete_key(&f, 0));
    const after = try snapshot(&f, testing.allocator);
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

/// Rewrites the leaf `id` with every key's first byte replaced by `lead` (same length, so it
/// fits), re-sealed: a CRC-valid page whose keys lie outside the range its parent promises.
fn rekey_leaf(f: *Fixture, id: Id, lead: u8) !void {
    assert(f.pool.pinned_count() == 0);
    assert(lead != 'k');
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    var copy: [512]u8 = undefined;
    @memcpy(&copy, page);
    const old = try node.parse_leaf(&copy);
    node.format_leaf(page, id, old.next, header.peek(&copy).lsn);
    for (0..old.count) |index| {
        const entry = try old.entry(@intCast(index));
        var key: [8]u8 = undefined;
        @memcpy(key[0..entry.key.len], entry.key);
        key[0] = lead;
        try node.leaf_insert(page, @intCast(index), key[0..entry.key.len], entry.value);
    }
    node.seal(page, id, header.peek(&copy).lsn);
}

test "delete: a borrow separator outside the parent's bounds is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 16, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 45);
    try testing.expectEqual(@as(u32, 3), (try walk(&f, null)).leaves);
    const first_count = try leftmost_count(&f);
    for (first_count + 1..first_count + 9) |n| { // Fatten leaf 1 so a merge cannot fit.
        var raw: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&raw, "k{d:0>5}a", .{n});
        try f.tree.insert(testing.io, key, "12345678");
    }
    try testing.expectEqual(@as(u32, 3), (try walk(&f, null)).leaves);
    var path: descend.Path = undefined;
    var probe: [8]u8 = undefined;
    const second_key = fx.key_of(&probe, try leftmost_count(&f)); // First key of leaf 1.
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, second_key, false, &path);
    const middle = path.leaf; // Right sibling of the leftmost leaf, with a right neighbour.
    guard.release();
    try rekey_leaf(&f, middle, 'z'); // Keys now sort above the parent's next separator.
    var hit = false;
    for (0..20) |n| {
        const before = try snapshot(&f, testing.allocator);
        defer testing.allocator.free(before);

        _ = delete_key(&f, @intCast(n)) catch |err| switch (err) {
            error.Corrupted => {
                const after = try snapshot(&f, testing.allocator);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                hit = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "delete: an id already pending in frees_pending is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    var path: descend.Path = undefined;
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, "k99999", false, &path);
    f.tree.frees_pending[0] = path.leaf; // The right leaf, which the merge would unlink.
    f.tree.frees_len = 1;
    guard.release();
    var hit = false;
    for (0..10) |n| {
        const before = try snapshot(&f, testing.allocator);
        defer testing.allocator.free(before);

        _ = delete_key(&f, @intCast(n)) catch |err| switch (err) {
            error.Corrupted => {
                const after = try snapshot(&f, testing.allocator);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                try testing.expectEqual(@as(u32, 1), f.tree.frees_len);
                hit = true;
                break;
            },
            else => return err,
        };
    }
    try testing.expect(hit);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "delete: no allocation after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var f: Fixture = undefined;
    try f.start(failing.allocator(), 512, 40, 4096);
    defer f.stop(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: the next allocation fails.
    try fill(&f, 1500);
    for (0..1500) |n| {
        try testing.expect(try delete_key(&f, @intCast(n)));
        if (f.tree.frees_len >= 32) _ = try f.tree.release_frees(testing.io);
    }
    _ = try f.tree.release_frees(testing.io);
    try expect_empty_root_leaf(&f);
    try testing.expect(!failing.has_induced_failure);
}

test "delete: model test with interleaved insert, delete and get" {
    for ([_]u64{ 1, 2, 3 }) |seed| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, 512, 40, 4096);
        defer f.stop(testing.allocator);

        var model: fx.Model = .empty;
        defer fx.model_free(&model);

        var prng = std.Random.DefaultPrng.init(seed);
        const random = prng.random();
        var key_buf: [8]u8 = undefined;
        for (0..6000) |op| {
            const key = fx.key_of(&key_buf, random.uintLessThan(u32, 700));
            switch (random.uintLessThan(u8, 5)) {
                0, 1 => {
                    const value = if (op % 2 == 0) "short" else "a much longer value text";
                    try f.tree.insert(testing.io, key, value);
                    try fx.model_put(&model, key, value);
                },
                2, 3 => {
                    const present = model.contains(key);
                    try testing.expectEqual(present, try f.tree.delete(testing.io, key));
                    try f.tree.validate(testing.io, testing.allocator);
                    if (present) {
                        const removed = model.fetchRemove(key).?;
                        testing.allocator.free(removed.key);
                        testing.allocator.free(removed.value);
                    }
                },
                else => try fx.expect_get(&f.tree, key, model.get(key)),
            }
            if (f.tree.frees_len >= 32) _ = try f.tree.release_frees(testing.io);
            if (op % 500 == 499) try fx.model_compare(&f.tree, &model);
        }
        _ = try f.tree.release_frees(testing.io);
        try fx.model_compare(&f.tree, &model);
        try account(&f, testing.allocator);
    }
}

test "pool discard: drops an unpinned dirty frame without write-back" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    const id = try f.pm.allocate(testing.io);
    var guard = try f.pool.fetchNew(testing.io, id);
    guard.release();
    try testing.expect(f.pool.dirty_count >= 1);
    const dirty_before = f.pool.dirty_count;
    f.pool.discard(id);
    try testing.expectEqual(dirty_before - 1, f.pool.dirty_count);
    f.pool.check_invariants();
    f.pool.discard(id); // Not resident: a no-op.
    try testing.expectEqual(dirty_before - 1, f.pool.dirty_count);
}
