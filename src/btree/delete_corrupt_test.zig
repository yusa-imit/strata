//! Crafted-page `Corrupted` tests for delete (plan 006 item 2): each test builds a valid tree,
//! edits ONE page, re-seals it with a valid CRC and deletes until `error.Corrupted`; every failed
//! attempt must leave every page byte-identical and nothing pinned. Branches covered here: a root
//! leaf with a link, an overflow chain page already pending, a sibling id past the end of the
//! file or equal to the node, a left leaf not linking to its right sibling, an empty sibling on
//! either side, leaf keys out of order across the pair, a borrow separator below the parent's
//! previous separator, and internal pairs (level 1 siblings) whose keys cross the separator.
//!
//! Not testable on a sealed page (defensive only): `plan` used-bytes underflow and `parent_view`
//! level mismatch (descent already proved the levels and `check_invariants` the used bytes),
//! `plan_level` `slot > parent.count` (the path was read in the same call), `plan_after_merge`
//! used-bytes underflow, and every `Corrupted` of the apply phase (`append_leaf`,
//! `append_internal`, `move_leaf_cell`, `rotate_internal`, `replace_separator`): prepare proved
//! that the cells fit before any page is edited.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;
const Id = header.Id;

fn fill(f: *Fixture, count: u32) !void {
    assert(f.tree.frees_len == 0);
    assert(count < 100_000);
    var key_buf: [8]u8 = undefined;
    for (0..count) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "12345678");
}

fn leaf_of(f: *Fixture, n: u32) !Id {
    assert(n < 100_000);
    assert(f.pool.pinned_count() == 0);
    var key_buf: [8]u8 = undefined;
    var path: descend.Path = undefined;
    const key = fx.key_of(&key_buf, n);
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, key, false, &path);
    guard.release();
    return path.leaf;
}

fn snapshot(f: *Fixture, gpa: Allocator) ![]u8 {
    assert(f.pool.pinned_count() == 0);
    const size = f.pool.page_size;
    const out = try gpa.alloc(u8, @as(usize, f.pm.page_count) * size);
    errdefer gpa.free(out);

    @memset(out, 0);
    for (1..f.pm.page_count) |raw| {
        fx.page_copy(f, @enumFromInt(raw), out[raw * size ..][0..size]) catch |err| switch (err) {
            error.Unwritten => continue,
            else => return err,
        };
    }
    assert(out.len == @as(usize, f.pm.page_count) * size);
    return out;
}

/// Deletes `first`, then the next keys (`down` selects descending) until one is `Corrupted`;
/// every attempt before it must succeed, the failing one must change no byte. Returns the count.
fn delete_until_corrupted(f: *Fixture, first: u32, down: bool, limit: u32) !u32 {
    assert(limit > 0 and first < 100_000);
    assert(!down or first + 1 >= limit);
    assert(f.pool.pinned_count() == 0);
    var key_buf: [8]u8 = undefined;
    for (0..limit) |step| {
        const delta: u32 = @intCast(step);
        const n: u32 = if (down) first - delta else first + delta;
        const before = try snapshot(f, testing.allocator);
        defer testing.allocator.free(before);

        const frees = f.tree.frees_len;
        _ = f.tree.delete(testing.io, fx.key_of(&key_buf, n)) catch |err| switch (err) {
            error.Corrupted => {
                const after = try snapshot(f, testing.allocator);
                defer testing.allocator.free(after);

                try testing.expectEqualSlices(u8, before, after);
                try testing.expectEqual(frees, f.tree.frees_len);
                try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
                return @intCast(step);
            },
            else => return err,
        };
    }
    return error.TestUnexpectedResult; // The corruption was never reached.
}

const Edit = fn ([]u8, Id) anyerror!void;

fn edit(f: *Fixture, id: Id, comptime body: Edit) !void {
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

fn link_to_seven(page: []u8, id: Id) !void {
    assert(id != .file_header);
    node.set_next(page, @enumFromInt(7));
    assert((try node.parse_leaf(page)).next.? == @as(Id, @enumFromInt(7)));
}

fn rekey_below(page: []u8, id: Id) !void {
    assert(id != .file_header);
    assert(page.len == 512);
    var copy: [512]u8 = undefined;
    @memcpy(&copy, page);
    const old = try node.parse_leaf(&copy);
    node.format_leaf(page, id, old.next, header.peek(&copy).lsn);
    for (0..old.count) |index| {
        const entry = try old.entry(@intCast(index));
        var key: [8]u8 = undefined;
        @memcpy(key[0..entry.key.len], entry.key);
        key[0] = 'a'; // Below every 'k' key of the left neighbour.
        try node.leaf_insert(page, @intCast(index), key[0..entry.key.len], entry.value);
    }
}

test "delete: a root leaf that links to another page is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 5);
    try testing.expectEqual(@as(u32, 2), f.pm.page_count); // One root leaf.
    try edit(&f, f.tree.root, link_to_seven);
    try testing.expectEqual(@as(u32, 0), try delete_until_corrupted(&f, 2, false, 1));
}

test "delete: an overflow chain page already pending is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    var big: [2000]u8 = undefined;
    @memset(&big, 'x');
    try f.tree.insert(testing.io, "k00001", "12345678");
    try f.tree.insert(testing.io, "k00002", &big);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    const leaf = try node.parse_leaf(guard.bytes());
    const slot = try leaf.search("k00002");
    const head = (try leaf.entry(slot.index)).value.overflow.head; // A spilled value.
    guard.release();
    f.tree.frees_pending[0] = head;
    f.tree.frees_len = 1;
    try testing.expectEqual(@as(u32, 0), try delete_until_corrupted(&f, 2, false, 1));
    try testing.expectEqual(@as(u32, 1), f.tree.frees_len);
    var present = try f.tree.get(testing.io, "k00002"); // The value is still readable.
    try testing.expectEqual(@as(usize, 2000), present.?.len);
    present = null;
}

fn sibling_case(bad: ?Id) !void {
    assert(bad == null or bad.? != .file_header);
    assert(@sizeOf(Fixture) > 0);
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    const left = try leaf_of(&f, 0);
    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    const page = guard.bytes_mut();
    internal.set_right_child(page, bad orelse left); // Past the file, or the node itself.
    node.seal(page, f.tree.root, header.peek(page).lsn);
    guard.release();
    const steps = try delete_until_corrupted(&f, 0, false, 12);
    try testing.expect(steps > 0); // The first deletes leave the leaf big enough.
}

test "delete: a sibling id past the end of the file is Corrupted, nothing changes" {
    try sibling_case(@enumFromInt(9000));
}

test "delete: a sibling that is the node itself is Corrupted, nothing changes" {
    try sibling_case(null);
}

test "delete: a left leaf that does not link to its right sibling is Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 45);
    const first = try leaf_of(&f, 0);
    const last = try leaf_of(&f, 44);
    try testing.expect(first != last and try leaf_of(&f, 22) != first);
    var guard = try f.pool.fetchForUpdate(testing.io, first);
    node.set_next(guard.bytes_mut(), last); // Skips the middle leaf.
    node.seal(guard.bytes_mut(), first, header.peek(guard.bytes()).lsn);
    guard.release();
    try testing.expect(try delete_until_corrupted(&f, 0, false, 14) > 0);
}

test "delete: an empty right sibling is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    try testing.expect(try leaf_of(&f, 0) != try leaf_of(&f, 26));
    try edit(&f, try leaf_of(&f, 26), empty_page);
    try testing.expect(try delete_until_corrupted(&f, 0, false, 12) > 0);
}

test "delete: an empty left sibling is Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    try testing.expect(try leaf_of(&f, 0) != try leaf_of(&f, 26));
    try edit(&f, try leaf_of(&f, 0), empty_page);
    try testing.expect(try delete_until_corrupted(&f, 26, true, 12) > 0);
}

test "delete: leaf keys that do not ascend across the pair are Corrupted, nothing changes" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 8, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 27);
    try testing.expect(try leaf_of(&f, 0) != try leaf_of(&f, 26));
    try edit(&f, try leaf_of(&f, 26), rekey_below); // Right leaf now sorts below the left one.
    try testing.expect(try delete_until_corrupted(&f, 0, false, 12) > 0);
}

test "delete: a borrow separator below the parent's previous separator is Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 16, 64);
    defer f.stop(testing.allocator);

    try fill(&f, 45);
    const n0 = try leaf_count(&f, try leaf_of(&f, 0)); // The middle leaf starts at key n0.
    for (n0 + 1..n0 + 9) |n| { // Fatten the middle leaf so the merge with the last leaf cannot fit.
        var raw: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&raw, "k{d:0>5}a", .{n});
        try f.tree.insert(testing.io, key, "12345678");
    }
    const middle = try leaf_of(&f, n0);
    try testing.expect(middle != try leaf_of(&f, 0) and middle != try leaf_of(&f, 44));
    try edit(&f, middle, rekey_below);
    try testing.expect(try delete_until_corrupted(&f, 44, true, 14) > 0);
}

fn leaf_count(f: *Fixture, id: Id) !u16 {
    assert(f.pool.pinned_count() == 0);
    assert(id != .file_header);
    var guard = try f.pool.fetch(testing.io, id);
    defer guard.release();

    return (try node.parse_leaf(guard.bytes())).count;
}

fn level_one_ids(f: *Fixture) ![2]Id {
    assert(f.pool.pinned_count() == 0);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const page = guard.bytes();
    assert(page.len == f.pool.page_size);
    try testing.expectEqual(@as(u8, 2), page[node.offset_level]); // Height 3.
    const view = try internal.parse_internal(page, 2);
    return .{ (try view.entry(0)).child, (try view.entry(1)).child };
}

/// Replaces the first byte of cell `index` (negative: the last one) of an internal node.
fn poke_cell(f: *Fixture, id: Id, index: i32, byte: u8) !void {
    assert(id != .file_header);
    assert(index >= -1 and byte != 'k');
    var guard = try f.pool.fetchForUpdate(testing.io, id);
    defer guard.release();

    const page = guard.bytes_mut();
    const view = try internal.parse_internal(page, page[node.offset_level]);
    const at: u16 = if (index < 0) view.count - 1 else @intCast(index);
    const key = (try view.entry(at)).key;
    page[@intFromPtr(key.ptr) - @intFromPtr(page.ptr)] = byte;
    node.seal(page, id, header.peek(page).lsn);
}

test "delete: level-1 siblings whose last key is not below the separator are Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 4096);
    defer f.stop(testing.allocator);

    try fill(&f, 3000);
    const ids = try level_one_ids(&f);
    try poke_cell(&f, ids[0], -1, 'z'); // The left node's last key now sorts above the separator.
    try testing.expect(try delete_until_corrupted(&f, 0, false, 3000) > 100);
}

test "delete: level-1 siblings whose first key is not above the separator are Corrupted" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 40, 4096);
    defer f.stop(testing.allocator);

    try fill(&f, 3000);
    const ids = try level_one_ids(&f);
    try poke_cell(&f, ids[1], 0, 'a'); // The right node's first key now sorts below the separator.
    try testing.expect(try delete_until_corrupted(&f, 0, false, 3000) > 100);
}
