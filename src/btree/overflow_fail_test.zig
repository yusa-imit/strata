//! Failure and corruption tests for overflow values (plan 005 item 8, ADR-0004 sections 6, 9):
//! a chain shared by two cells is `Corrupted` for delete, overwrite and `validate` and never
//! reaches `frees_pending` twice, an overwrite of a chain needs `old + new` pending slots
//! exactly, a put that fails after its chain was written (split or mid-chain) accounts every
//! new page, a `value_buf` shorter than the stored value is `ValueTooLarge` through `get` and
//! the cursor, and a nonzero byte after a chain page's data is `Corrupted` under `validate`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const cursor_mod = @import("cursor.zig");
const tree_mod = @import("tree.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Tree = tree_mod.Tree;
const Id = header.Id;

const page_size: u32 = 512;
const chain_value_len: u32 = 3 * 480 + 1; // Four chain pages.

fn start(f: *Fixture, pages_max: u32) !void {
    assert(pages_max >= 2);
    assert(node.overflow_capacity(page_size) == 480);
    const frames: u32 = 2 * @as(u32, node.height_max(page_size)) + 2; // The pool floor.
    try f.start(testing.allocator, page_size, frames, pages_max);
}

fn fill_value(buf: []u8, seed: u8) []u8 {
    assert(buf.len <= node.value_len_max);
    assert(buf.len > 0);
    for (buf, 0..) |*byte, i| byte.* = @truncate((i *% 7) +% seed);
    return buf;
}

/// Two keys with a four page chain each (pages 2..5 and 6..9); then the cell of `k00002` is
/// redirected to the chain head `to`, so it shares that page with another owner.
fn shared_fixture(f: *Fixture, to: u32) !void {
    assert(to >= 1);
    assert(to != 6); // Its own chain head.
    try start(f, 64);
    errdefer f.stop(testing.allocator);

    var buf: [chain_value_len]u8 = undefined;
    try f.tree.insert(testing.io, "k00001", fill_value(&buf, 1));
    try f.tree.insert(testing.io, "k00002", fill_value(&buf, 2));
    var pinned = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    defer pinned.release();

    const page = pinned.bytes_mut();
    var from: [4]u8 = undefined;
    std.mem.writeInt(u32, &from, 6, .little);
    const at = std.mem.find(u8, page[header.header_size..], &from).? + header.header_size;
    std.mem.writeInt(u32, page[at..][0..4], to, .little);
    header.encode(page, f.tree.root, .{ .page_type = header.peek(page).page_type, .lsn = 0 });
}

test "overflow fail: two cells sharing a chain are never freed twice" {
    var f: Fixture = undefined;
    try shared_fixture(&f, 2);
    defer f.stop(testing.allocator);

    try testing.expect(try f.tree.delete(testing.io, "k00001"));
    try testing.expectEqual(@as(u32, 4), f.tree.frees_len);
    const pending_before = f.tree.frees_pending[0..4].*;
    var root_before: [page_size]u8 = undefined;
    try fx.page_copy(&f, f.tree.root, &root_before);

    try testing.expectError(error.Corrupted, f.tree.delete(testing.io, "k00002"));
    var buf: [chain_value_len]u8 = undefined;
    const put = f.tree.insert(testing.io, "k00002", fill_value(&buf, 3));
    try testing.expectError(error.Corrupted, put);
    try testing.expectEqual(@as(u32, 4), f.tree.frees_len);
    try testing.expectEqualSlices(Id, &pending_before, f.tree.frees_pending[0..4]);
    var root_after: [page_size]u8 = undefined;
    try fx.page_copy(&f, f.tree.root, &root_after);
    try testing.expectEqualSlices(u8, &root_before, &root_after);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "overflow fail: validate rejects a shared chain and a chain page that is a tree node" {
    for ([_]u32{ 2, 1 }) |to| {
        var f: Fixture = undefined;
        try shared_fixture(&f, to);
        defer f.stop(testing.allocator);

        const validated = f.tree.validate(testing.io, testing.allocator);
        try testing.expectError(error.Corrupted, validated);
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    }
}

test "overflow fail: an overwrite of a chain needs old plus new slots, exactly" {
    var f: Fixture = undefined;
    try start(&f, 64);
    defer f.stop(testing.allocator);

    var buf: [chain_value_len]u8 = undefined;
    const old = try testing.allocator.dupe(u8, fill_value(&buf, 1));
    defer testing.allocator.free(old);

    try f.tree.insert(testing.io, "k00001", old);
    const full = f.tree.frees_pending;
    const pages_before = f.pm.page_count;
    f.tree.frees_pending = full[0..7]; // One short of 4 + 4.
    const put = f.tree.insert(testing.io, "k00001", fill_value(&buf, 2));
    try testing.expectError(error.FreesPendingLimit, put);
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);
    try testing.expectEqual(pages_before, f.pm.page_count);
    try fx.expect_get(&f.tree, "k00001", old);

    f.tree.frees_pending = full[0..8];
    try f.tree.insert(testing.io, "k00001", fill_value(&buf, 2));
    try testing.expectEqual(@as(u32, 4), f.tree.frees_len); // The old chain only.
    try fx.expect_get(&f.tree, "k00001", fill_value(&buf, 2));
    f.tree.frees_pending = full;
    try f.tree.validate(testing.io, testing.allocator);
}

/// Inserts `value_len`-byte values under fresh keys until the leaf is full (`NoSpaceLeft`).
fn fill_leaf(f: *Fixture, next: u32, value_len: u32) !u32 {
    assert(value_len <= 60);
    assert(next < 90_000);
    var n = next;
    var buf: [60]u8 = undefined;
    var key_buf: [8]u8 = undefined;
    for (0..64) |_| {
        const key = fx.key_of(&key_buf, n);
        f.tree.insert(testing.io, key, fill_value(buf[0..value_len], 5)) catch |err| {
            try testing.expectEqual(error.NoSpaceLeft, err);
            return n;
        };
        n += 1;
    }
    return error.TestUnexpectedResult; // The leaf must fill within 64 cells.
}

test "overflow fail: a split that fails after the chain was written keeps the chain pending" {
    var f: Fixture = undefined;
    try start(&f, 2); // No room to split while the leaf fills.
    defer f.stop(testing.allocator);

    var n = try fill_leaf(&f, 0, 60);
    n = try fill_leaf(&f, n, 10);
    n = try fill_leaf(&f, n, 1);
    f.pm.page_count_max = 5; // Room for a three page chain and nothing else.
    var root_before: [page_size]u8 = undefined;
    try fx.page_copy(&f, f.tree.root, &root_before);

    var buf: [1000]u8 = undefined;
    const put = f.tree.insert(testing.io, "k99999", fill_value(&buf, 9));
    try testing.expectError(error.NoSpaceLeft, put);
    try testing.expectEqual(@as(u32, 3), f.tree.frees_len);
    for (f.tree.frees_pending[0..3], 0..) |id, i| {
        try testing.expectEqual(@as(u32, 2) + @as(u32, @intCast(i)), @intFromEnum(id));
    }
    var root_after: [page_size]u8 = undefined;
    try fx.page_copy(&f, f.tree.root, &root_after);
    try testing.expectEqualSlices(u8, &root_before, &root_after);
    try fx.expect_get(&f.tree, "k99999", null);
    try f.tree.validate(testing.io, testing.allocator);
    try testing.expectEqual(@as(u32, 3), try f.tree.release_frees(testing.io));
}

test "overflow fail: a chain write that fails half way accounts the pages it got" {
    var f: Fixture = undefined;
    try start(&f, 4); // Header, root and two chain pages.
    defer f.stop(testing.allocator);

    var buf: [chain_value_len]u8 = undefined;
    const put = f.tree.insert(testing.io, "k00001", fill_value(&buf, 1));
    try testing.expectError(error.NoSpaceLeft, put);
    try testing.expectEqual(@as(u32, 2), f.tree.frees_len);
    try testing.expectEqual(@as(u32, 2), @intFromEnum(f.tree.frees_pending[0]));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(f.tree.frees_pending[1]));
    try testing.expectEqual(@as(u32, 4), f.pm.page_count);
    try testing.expectEqual(@as(u32, 2), try f.tree.release_frees(testing.io));
    try testing.expectEqual(@as(u32, 0), f.tree.frees_len);

    try f.tree.insert(testing.io, "k00001", fill_value(buf[0..900], 2)); // Two pages, reused.
    try testing.expectEqual(@as(u32, 4), f.pm.page_count);
    try fx.expect_get(&f.tree, "k00001", fill_value(buf[0..900], 2));
    try f.tree.validate(testing.io, testing.allocator);
}

test "overflow fail: a value_buf shorter than the stored value is ValueTooLarge" {
    var f: Fixture = undefined;
    try start(&f, 64);
    defer f.stop(testing.allocator);

    var buf: [chain_value_len]u8 = undefined;
    try f.tree.insert(testing.io, "k00001", fill_value(&buf, 1));
    var small: [100]u8 = undefined;
    var reopened: Tree = undefined;
    try Tree.open(&reopened, &f.pool, f.tree.root, f.tree.frees_pending, &small);

    try testing.expectError(error.ValueTooLarge, reopened.get(testing.io, "k00001"));
    var c: cursor_mod.Cursor = undefined;
    cursor_mod.Cursor.init(&c, &reopened);
    defer c.release();

    try testing.expectError(error.ValueTooLarge, c.first(testing.io));
    try testing.expectError(error.ValueTooLarge, c.seek(testing.io, "k00001"));
    c.release();
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    try fx.expect_get(&f.tree, "k00001", fill_value(&buf, 1)); // The full-size tree still reads.
}

test "overflow fail: a nonzero byte after the data of a chain page is Corrupted in validate" {
    var f: Fixture = undefined;
    try start(&f, 64);
    defer f.stop(testing.allocator);

    var buf: [chain_value_len]u8 = undefined;
    try f.tree.insert(testing.io, "k00001", fill_value(&buf, 1));
    try f.tree.validate(testing.io, testing.allocator);
    {
        var pinned = try f.pool.fetchForUpdate(testing.io, @enumFromInt(5)); // The short last page.
        defer pinned.release();

        const page = pinned.bytes_mut();
        assert(node.get32(page, 28) == 1);
        page[page_size - 1] = 1;
        header.encode(page, @enumFromInt(5), .{ .page_type = .btree_overflow, .lsn = 0 });
    }
    const validated = f.tree.validate(testing.io, testing.allocator);
    try testing.expectError(error.Corrupted, validated);
    try fx.expect_get(&f.tree, "k00001", fill_value(&buf, 1)); // Only validate checks the tail.
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}
