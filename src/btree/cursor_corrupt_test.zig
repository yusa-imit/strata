//! Crafted-page `Corrupted` tests for the cursor (plan 006 item 2): each test builds a valid
//! tree, edits ONE page, re-seals it with a valid CRC and expects `error.Corrupted` with no pin
//! left behind. Branches covered here: `last` and `seek_bound` on an empty non-root leaf, `next`
//! and `prev` key-order checks inside a leaf, `cross_forward` with an out-of-range link and an
//! empty entered leaf, `step_back` with a moved first key, an empty predecessor and a
//! predecessor whose last key is not smaller, `left_sibling` with an invalid child, and
//! `rightmost` with a wrong level and an out-of-range right child.
//!
//! Not testable on a sealed page (defensive only): `left_sibling` `slot > view.count` (the page
//! cannot change between the descent and the fetch in one thread) and the final `Corrupted`
//! of `rightmost` (levels must strictly decrease, so a chain longer than `height_max` is
//! rejected by the level check first).

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const cursor_mod = @import("cursor.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Cursor = cursor_mod.Cursor;
const Id = header.Id;
const scan_steps_max: u32 = 20_000;

fn setup(f: *Fixture, count: u32) !void {
    assert(count > 0 and count < 100_000);
    const size: u32 = 512;
    try f.start(testing.allocator, size, 2 * @as(u32, node.height_max(size)) + 2, 4096);
    errdefer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    for (0..count) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "12345678");
    try f.tree.validate(testing.io, testing.allocator);
    assert(f.pool.pinned_count() == 0);
}

fn leaf_of(f: *Fixture, n: u32) !Id {
    assert(n < 100_000);
    assert(f.pool.pinned_count() <= 1); // A positioned cursor holds one pin.
    var key_buf: [8]u8 = undefined;
    var path: descend.Path = undefined;
    const key = fx.key_of(&key_buf, n);
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, key, false, &path);
    guard.release();
    assert(path.leaf != .file_header);
    return path.leaf;
}

/// Runs `edit` on a mutable frame of `id`, then re-seals it with the same lsn.
fn edit(f: *Fixture, id: Id, comptime body: fn ([]u8, Id) anyerror!void) !void {
    assert(id != .file_header);
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    assert(page.len == f.pool.page_size);
    try body(page, id);
    node.seal(page, id, header.peek(page).lsn);
}

fn empty_page(page: []u8, id: Id) !void {
    assert(id != .file_header);
    while ((try node.parse_leaf(page)).count > 0) try node.leaf_remove(page, 0);
    assert((try node.parse_leaf(page)).count == 0);
}

fn dangling_next(page: []u8, id: Id) !void {
    assert(id != .file_header);
    node.set_next(page, @enumFromInt(9000));
    assert((try node.parse_leaf(page)).next != null);
}

fn dangling_right(page: []u8, id: Id) !void {
    assert(id != .file_header);
    internal.set_right_child(page, @enumFromInt(9000));
    assert((try internal.parse_internal(page, page[node.offset_level])).right_child != id);
}

fn level_two(page: []u8, id: Id) !void {
    assert(id != .file_header);
    page[node.offset_level] = 2;
    assert(page[node.offset_level] == 2);
}

/// Makes the last digit of cell `index` the largest byte, so the key sorts above its successors.
fn bump_key(f: *Fixture, id: Id, index: i32) !void {
    assert(id != .file_header);
    assert(index >= -1 and index < 1000);
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    const leaf = try node.parse_leaf(page);
    const at: u16 = if (index < 0) leaf.count - 1 else @intCast(index);
    const key = (try leaf.entry(at)).key;
    page[@intFromPtr(key.ptr) - @intFromPtr(page.ptr) + 5] = '~';
    node.seal(page, id, header.peek(page).lsn);
}

fn key_number(f: *Fixture, id: Id, which: u16) !u32 {
    assert(id != .file_header);
    var guard = try f.pool.fetch(testing.io, id);
    defer guard.release();

    const leaf = try node.parse_leaf(guard.bytes());
    const key = (try leaf.entry(which)).key;
    assert(key.len == 6);
    return try std.fmt.parseInt(u32, key[1..], 10);
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
    return error.TestUnexpectedResult;
}

fn expect_released(f: *Fixture, c: *Cursor) !void {
    assert(f.tree.root != .file_header);
    assert(c.tree == &f.tree);
    try testing.expect(c.current() == null);
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "cursor: last on an empty non-root leaf is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    try edit(&f, try leaf_of(&f, 149), empty_page);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, c.last(testing.io));
    try expect_released(&f, &c);
}

test "cursor: first and seek landing on an empty non-root leaf are Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    try edit(&f, try leaf_of(&f, 0), empty_page);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, c.first(testing.io));
    try expect_released(&f, &c);
    try testing.expectError(error.Corrupted, c.seek(testing.io, "k00000"));
    try expect_released(&f, &c);
}

test "cursor: next into a key that is not larger is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectEqualSlices(u8, "k00000", (try c.first(testing.io)).?.key);
    try bump_key(&f, try leaf_of(&f, 0), 0); // The pinned key now sorts above cell 1.
    try testing.expectError(error.Corrupted, c.next(testing.io));
    try expect_released(&f, &c);
}

test "cursor: prev into a key that is not smaller is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    _ = try c.first(testing.io);
    try testing.expectEqualSlices(u8, "k00001", (try c.next(testing.io)).?.key);
    try bump_key(&f, try leaf_of(&f, 0), 0); // Cell 0 now sorts above the current cell 1.
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try expect_released(&f, &c);
}

test "cursor: a link past the end of the file is Corrupted going forward" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    try edit(&f, try leaf_of(&f, 0), dangling_next);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, forward_count(&c));
    try expect_released(&f, &c);
}

test "cursor: entering an empty linked leaf is Corrupted going forward" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    try edit(&f, try leaf_of(&f, 75), empty_page);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, forward_count(&c));
    try expect_released(&f, &c);
}

/// Cursor on the first entry of the middle leaf, ready to step back; returns that leaf's id.
fn at_middle_first(f: *Fixture, c: *Cursor) !Id {
    assert(f.pool.pinned_count() == 0);
    const middle = try leaf_of(f, 75);
    const first_n = try key_number(f, middle, 0);
    try testing.expect(first_n > 0);
    assert(first_n < 150);
    var key_buf: [8]u8 = undefined;
    try c.seek(testing.io, fx.key_of(&key_buf, first_n));
    try testing.expectEqualSlices(u8, fx.key_of(&key_buf, first_n), c.current().?.key);
    return middle;
}

test "cursor: stepping back after the first key moved out of its leaf's range is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    const middle = try at_middle_first(&f, &c);
    {
        var guard = try f.pool.fetchForUpdate(testing.io, middle);
        defer guard.release();

        const page = guard.bytes_mut();
        const key = (try (try node.parse_leaf(page)).entry(0)).key;
        page[@intFromPtr(key.ptr) - @intFromPtr(page.ptr) + 1] = '!'; // Sorts below the range.
        node.seal(page, middle, header.peek(page).lsn);
    }
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try expect_released(&f, &c);
}

test "cursor: stepping back into an empty predecessor leaf is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    const middle = try at_middle_first(&f, &c);
    const before = try leaf_of(&f, try key_number(&f, middle, 0) - 1);
    try testing.expect(before != middle);
    try edit(&f, before, empty_page);
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try expect_released(&f, &c);
}

test "cursor: a predecessor whose last key is not below the first key is Corrupted" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    const middle = try at_middle_first(&f, &c);
    const before = try leaf_of(&f, try key_number(&f, middle, 0) - 1);
    try testing.expect(before != middle);
    try bump_key(&f, before, -1); // Its last key now sorts above the cursor's key.
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try expect_released(&f, &c);
}

fn left_sibling_case(bad: ?Id) !void {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    const middle = try at_middle_first(&f, &c);
    var path: descend.Path = undefined;
    var key_buf: [8]u8 = undefined;
    const key = fx.key_of(&key_buf, try key_number(&f, middle, 0));
    var probe = try descend.descend(&f.pool, testing.io, f.tree.root, key, false, &path);
    probe.release();
    const parent = path.ids[path.len - 1];
    const slot = path.slots[path.len - 1];
    try testing.expect(slot > 0);
    assert(parent != .file_header);
    assert(slot <= path.len * 1000);
    var guard = try f.pool.fetchForUpdate(testing.io, parent);
    const page = guard.bytes_mut();
    try internal.set_child(page, slot - 1, bad orelse parent); // Invalid, or the node itself.
    node.seal(page, parent, header.peek(page).lsn);
    guard.release();
    try testing.expectError(error.Corrupted, c.prev(testing.io));
    try expect_released(&f, &c);
}

test "cursor: a left sibling past the end of the file is Corrupted" {
    try left_sibling_case(@enumFromInt(9000));
}

test "cursor: a left sibling that is its own parent is Corrupted" {
    try left_sibling_case(null);
}

test "cursor: a right-most internal node of the wrong level is Corrupted at height 3" {
    var f: Fixture = undefined;
    try setup(&f, 3000);
    defer f.stop(testing.allocator);

    var root_guard = try f.pool.fetch(testing.io, f.tree.root);
    const root_page = root_guard.bytes();
    const root = try internal.parse_internal(root_page, root_page[node.offset_level]);
    const level = root.level;
    const mid = root.right_child;
    root_guard.release();
    try testing.expectEqual(@as(u8, 2), level); // Height 3.
    try edit(&f, mid, level_two);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, c.last(testing.io));
    try expect_released(&f, &c);
}

test "cursor: a right child past the end of the file is Corrupted going to the last key" {
    var f: Fixture = undefined;
    try setup(&f, 150);
    defer f.stop(testing.allocator);

    try edit(&f, f.tree.root, dangling_right);
    var c: Cursor = undefined;
    Cursor.init(&c, &f.tree);
    defer c.release();

    try testing.expectError(error.Corrupted, c.last(testing.io));
    try expect_released(&f, &c);
}
