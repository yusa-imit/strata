//! Contract tests for `Tree.validate` and `check_invariants` (plan 005 item 5, ADR-0004
//! sections 5, 7, 10): a good tree of height 3 passes, and every hand-made break gives
//! `Corrupted`: a separator that no longer bounds its child, broken leaf links, a wrong level,
//! a shared child, a cycle, a child past the file, and a child id of 0. The walk is bounded.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");
const descend = @import("descend.zig");
const fx = @import("tree_fixtures.zig");

const Fixture = fx.Fixture;

/// A 512 B tree of three levels over keys `k00000 ..< k01500`, written out and cold.
fn build(f: *Fixture) !void {
    try f.start(testing.allocator, 512, 40, 2048);
    errdefer f.stop(testing.allocator);

    var key_buf: [8]u8 = undefined;
    for (0..1500) |n| try f.tree.insert(testing.io, fx.key_of(&key_buf, @intCast(n)), "vvvvvvvv");
    try f.tree.validate(testing.io, testing.allocator);
    try f.cold();
    assert(f.pool.dirty_count == 0);
    assert(f.pm.page_count > 100);
}

fn path_to(f: *Fixture, key: []const u8) !descend.Path {
    var path: descend.Path = undefined;
    var guard = try descend.descend(&f.pool, testing.io, f.tree.root, key, false, &path);
    guard.release();
    assert(path.len >= 2);
    assert(path.leaf != .file_header);
    return path;
}

/// Overwrites `bytes` at `offset` of page `id` and writes it back with a good checksum.
fn rewrite(f: *Fixture, id: header.Id, offset: u32, bytes: []const u8) !void {
    assert(f.pool.pinned_count() == 0);
    assert(offset >= header.header_size);
    assert(offset + bytes.len <= 512);
    try f.cold(); // Drop frames loaded by earlier reads, so the next walk reads the edit.
    var buf: [512]u8 = undefined;
    _ = try f.pm.read(testing.io, id, &buf);
    @memcpy(buf[offset..][0..bytes.len], bytes);
    try f.pm.write(testing.io, id, &buf, header.peek(&buf));
}

fn read_page(f: *Fixture, id: header.Id, buf: *[512]u8) !void {
    assert(f.pool.page_size == buf.len);
    assert(id != .file_header);
    _ = try f.pm.read(testing.io, id, buf);
}

/// Offset in the page of cell `index`'s child field (the last four bytes of the cell).
fn child_offset(f: *Fixture, id: header.Id, index: u16) !u32 {
    var buf: [512]u8 = undefined;
    try read_page(f, id, &buf);
    const view = try internal.parse_internal(&buf, buf[node.offset_level]);
    assert(index <= view.count);
    const end = if (index == 0) 512 else header.header_size + view.slot(index - 1);
    assert(end >= header.header_size + 4);
    return @intCast(end - 4);
}

fn expect_corrupted(f: *Fixture) !void {
    assert(f.pool.pinned_count() == 0);
    assert(f.pool.dirty_count == 0);
    try testing.expectError(error.Corrupted, f.tree.validate(testing.io, testing.allocator));
    try testing.expectError(error.Corrupted, f.tree.check_invariants(testing.io));
    try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
}

test "validate: empty root leaf, a grown tree and a reopened tree pass" {
    var empty: Fixture = undefined;
    try empty.start(testing.allocator, 512, 4, 8);
    defer empty.stop(testing.allocator);

    try empty.tree.validate(testing.io, testing.allocator);
    try empty.tree.check_invariants(testing.io);

    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    try f.tree.validate(testing.io, testing.allocator);
    const path = try path_to(&f, "k00700");
    try testing.expectEqual(@as(u8, 2), path.len); // Height 3: two internal levels, one leaf.
}

test "validate: a separator that no longer bounds its child is Corrupted" {
    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    const path = try path_to(&f, "k00000");
    var buf: [512]u8 = undefined;
    try read_page(&f, path.ids[1], &buf); // The level-1 node over the left-most leaves.
    const view = try internal.parse_internal(&buf, 1);
    const key = (try view.entry(0)).key;
    const last_byte: u32 = @intCast(@intFromPtr(key.ptr) - @intFromPtr(&buf) + key.len - 1);
    try rewrite(&f, path.ids[1], last_byte, &.{key[key.len - 1] - 1}); // Child 0 reaches past it.
    try expect_corrupted(&f);
}

test "validate: a root separator moved below its left subtree is Corrupted" {
    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    var buf: [512]u8 = undefined;
    try read_page(&f, f.tree.root, &buf);
    const view = try internal.parse_internal(&buf, buf[node.offset_level]);
    const key = (try view.entry(0)).key;
    const at: u32 = @intCast(@intFromPtr(key.ptr) - @intFromPtr(&buf) + key.len - 3);
    try rewrite(&f, f.tree.root, at, "000"); // Key `k00000`: below every key of the left subtree.
    try expect_corrupted(&f);
}

test "validate: broken leaf links are Corrupted" {
    const Link = struct { key: []const u8, next: u32 };
    const links = [_]Link{
        .{ .key = "k00000", .next = 0 }, // The chain ends at the first leaf.
        .{ .key = "k00000", .next = 1 }, // A link to a page that is not the next leaf.
        .{ .key = "k01499", .next = 1 }, // The last leaf must end in 0.
    };
    for (links) |link| {
        var f: Fixture = undefined;
        try build(&f);
        defer f.stop(testing.allocator);

        const path = try path_to(&f, link.key);
        var next: [4]u8 = undefined;
        std.mem.writeInt(u32, &next, link.next, .little);
        try rewrite(&f, path.leaf, node.offset_link, &next);
        try expect_corrupted(&f);
    }
}

test "validate: a wrong level, a leaf in an internal slot and a cycle are Corrupted" {
    const Break = enum { level_up, level_down, child_root, child_past_file, child_zero };
    for (std.enums.values(Break)) |kind| {
        var f: Fixture = undefined;
        try build(&f);
        defer f.stop(testing.allocator);

        const path = try path_to(&f, "k00300");
        const low = path.ids[1]; // A level-1 node.
        switch (kind) {
            .level_up => try rewrite(&f, low, node.offset_level, &.{2}),
            .level_down => try rewrite(&f, path.ids[0], node.offset_level, &.{1}),
            .child_root, .child_past_file, .child_zero => {
                const raw: u32 = switch (kind) {
                    .child_root => @intFromEnum(f.tree.root),
                    .child_past_file => f.pm.page_count,
                    else => 0,
                };
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, raw, .little);
                try rewrite(&f, low, try child_offset(&f, low, 0), &bytes);
            },
        }
        try expect_corrupted(&f);
    }
}

test "validate: a child shared by two parents is Corrupted (and named by the visited set)" {
    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    const path = try path_to(&f, "k00000");
    const low = path.ids[1];
    var buf: [512]u8 = undefined;
    try read_page(&f, low, &buf);
    const view = try internal.parse_internal(&buf, 1);
    const first = (try view.entry(0)).child;
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intFromEnum(first), .little);
    try rewrite(&f, low, try child_offset(&f, low, 1), &bytes); // Cell 1 now names cell 0's leaf.
    try expect_corrupted(&f);
}

test "validate: a leaf key that leaves the range its parent allows is Corrupted" {
    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    const path = try path_to(&f, "k00300");
    var buf: [512]u8 = undefined;
    try read_page(&f, path.leaf, &buf);
    const leaf = try node.parse_leaf(&buf);
    const first = (try leaf.entry(0)).key;
    const at: u32 = @intCast(@intFromPtr(first.ptr) - @intFromPtr(&buf));
    try rewrite(&f, path.leaf, at + 1, &.{'9'}); // 'k' then '9...': above every sibling bound.
    try expect_corrupted(&f);
}

test "validate: a non-root leaf with no cells is Corrupted" {
    var f: Fixture = undefined;
    try build(&f);
    defer f.stop(testing.allocator);

    const path = try path_to(&f, "k00300");
    const zeros = [_]u8{0} ** 480;
    try rewrite(&f, path.leaf, node.offset_count, zeros[0..2]);
    try rewrite(&f, path.leaf, node.offset_slots, &zeros); // Slots and cells gone, next kept.
    try expect_corrupted(&f);
}
