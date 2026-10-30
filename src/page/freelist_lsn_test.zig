//! Tests that the freelist never lowers the lsn of a trunk stamped by `free_at` (ADR-0004 rule
//! B): `allocate` and a plain push keep `max(old, new)`, and a full head trunk makes the freed
//! page a new trunk with `next` and the given stamp.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fx = @import("manager_fixtures.zig");
const header = @import("header.zig");
const freelist = @import("freelist.zig");

const PageManager = @import("manager.zig").PageManager;

fn lsn_of(pm: *PageManager, id: header.Id) !u64 {
    assert(@intFromEnum(id) >= 1);
    assert(@intFromEnum(id) < pm.page_count);
    const buf = try testing.allocator.alloc(u8, pm.page_size);
    defer testing.allocator.free(buf);

    const got = try pm.read(testing.io, id, buf);
    try testing.expectEqual(header.Type.free_trunk, got.page_type);
    return got.lsn;
}

test "allocate after free_at never lowers the head trunk lsn" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "a.db", fx.opts(size));
        defer pm.close(testing.io);

        try pm.set_wal_lsn(testing.io, 10);
        const a = try pm.allocate(testing.io);
        const b = try pm.allocate(testing.io);
        const c = try pm.allocate(testing.io);
        try pm.free_at(testing.io, a, 500);
        try pm.free_at(testing.io, b, 600);
        try pm.free_at(testing.io, c, 700);
        try testing.expectEqual(@as(u64, 700), try lsn_of(&pm, a));
        const popped = try pm.allocate(testing.io); // Pops `c`; the trunk keeps its stamp.
        try testing.expectEqual(c, popped);
        try testing.expect(try lsn_of(&pm, a) >= 700);
        try pm.free(testing.io, popped); // A plain free (lsn 0) must not lower it either.
        try testing.expect(try lsn_of(&pm, a) >= 700);
    }
}

test "free_at into a full head trunk starts a new trunk that links the old head" {
    const size: u32 = 512;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    var options = fx.opts(size);
    options.page_count_max = 200; // Room for a full 512 B trunk (120 ids) plus a few.
    try PageManager.create(&pm, testing.io, tmp.dir, "a.db", options);
    defer pm.close(testing.io);

    const capacity = freelist.trunk_capacity(size);
    const total: u32 = capacity + 3; // Head trunk + capacity entries, then one more.
    var ids: [200]header.Id = undefined;
    assert(total <= ids.len);
    for (0..total) |index| ids[index] = try pm.allocate(testing.io);
    for (0..total) |index| try pm.free_at(testing.io, ids[index], 900);
    const head = pm.freelist_head.?;
    try testing.expect(head != ids[0]); // The overflow page became the new head trunk.
    try testing.expectEqual(ids[capacity + 1], head);
    try testing.expectEqual(@as(u64, 900), try lsn_of(&pm, head));
    try testing.expectEqual(@as(u64, 900), try lsn_of(&pm, ids[0]));
}
