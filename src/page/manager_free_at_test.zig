//! Contract tests for `PageManager.free_at` (plan 005 item 9, ADR-0004 rule B): every trunk page
//! the free writes is stamped with `max(wal_lsn, lsn)`, a lower `lsn` behaves exactly like
//! `free`, and the freelist works as before. Every test runs at all eight page sizes.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fx = @import("manager_fixtures.zig");
const header = @import("header.zig");

const PageManager = @import("manager.zig").PageManager;

/// The header lsn of the trunk page `id`, read through the manager.
fn lsn_of(pm: *PageManager, id: header.Id) !u64 {
    assert(@intFromEnum(id) >= 1);
    assert(@intFromEnum(id) < pm.page_count);
    const buf = try testing.allocator.alloc(u8, pm.page_size);
    defer testing.allocator.free(buf);

    const got = try pm.read(testing.io, id, buf);
    try testing.expectEqual(header.Type.free_trunk, got.page_type);
    return got.lsn;
}

test "free_at: a new trunk and an extended trunk are stamped with the given lsn" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "a.db", fx.opts(size));
        defer pm.close(testing.io);

        try pm.set_wal_lsn(testing.io, 10);
        const a = try pm.allocate(testing.io);
        const b = try pm.allocate(testing.io);
        try pm.free_at(testing.io, a, 50); // Empty list: `a` becomes the head trunk.
        try testing.expectEqual(@as(u64, 50), try lsn_of(&pm, a));
        try pm.free_at(testing.io, b, 70); // Appended to the head trunk, which is rewritten.
        try testing.expectEqual(@as(u64, 70), try lsn_of(&pm, a));
        try testing.expectEqual(b, try pm.allocate(testing.io)); // LIFO order is unchanged.
        try testing.expectEqual(a, try pm.allocate(testing.io));
    }
}

test "free_at: a lower lsn than wal_lsn behaves like free" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "b.db", fx.opts(size));
        defer pm.close(testing.io);

        try pm.set_wal_lsn(testing.io, 100);
        const a = try pm.allocate(testing.io);
        const b = try pm.allocate(testing.io);
        const c = try pm.allocate(testing.io);
        try pm.free_at(testing.io, a, 5);
        try testing.expectEqual(@as(u64, 100), try lsn_of(&pm, a));
        try pm.free(testing.io, b);
        try testing.expectEqual(@as(u64, 100), try lsn_of(&pm, a));
        try pm.free_at(testing.io, c, 0);
        try testing.expectEqual(@as(u64, 100), try lsn_of(&pm, a));
    }
}
