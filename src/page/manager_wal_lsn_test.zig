//! Contract tests for `PageManager.set_wal_lsn` (plan 004 item 10): the value persists across
//! reopen with a valid page-0 checksum, equal and larger values are accepted, the other header
//! fields (page count, freelist head) are untouched, and a failed write leaves memory unchanged.
//! Every scripted test runs at all eight page sizes.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("../testing/fault_io.zig");
const fx = @import("manager_fixtures.zig");

const PageManager = @import("manager.zig").PageManager;

fn reopen_wal_lsn(dir: std.Io.Dir, size: u32) !u64 {
    assert(size >= 512);
    assert(size <= 65536);
    var pm: PageManager = undefined;
    try PageManager.open(&pm, testing.io, dir, "w.db", fx.opts(size));
    defer pm.close(testing.io);

    return pm.wal_lsn;
}

test "set_wal_lsn: persists across reopen, monotonic including equal and the u64 boundary" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "w.db", fx.opts(size));
        try testing.expectEqual(@as(u64, 0), pm.wal_lsn);
        try pm.set_wal_lsn(testing.io, 0); // Equal to the fresh value: allowed.
        try pm.set_wal_lsn(testing.io, 24);
        try testing.expectEqual(@as(u64, 24), pm.wal_lsn);
        try pm.set_wal_lsn(testing.io, 24); // Equal again.
        try pm.set_wal_lsn(testing.io, std.math.maxInt(u64)); // Opaque u64: the top is legal.
        try fx.expect_page0_intact(&pm, 1);
        pm.close(testing.io);

        try testing.expectEqual(std.math.maxInt(u64), try reopen_wal_lsn(tmp.dir, size));
    }
}

test "set_wal_lsn: page count and freelist head are carried over unchanged" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "w.db", fx.opts(size));
        const a = try pm.allocate(testing.io);
        _ = try pm.allocate(testing.io);
        try pm.free(testing.io, a);
        const head = pm.freelist_head;
        try testing.expect(head != null);
        try pm.set_wal_lsn(testing.io, 77);
        try testing.expectEqual(head, pm.freelist_head);
        try testing.expectEqual(@as(u32, 3), pm.page_count);
        pm.close(testing.io);

        var again: PageManager = undefined;
        try PageManager.open(&again, testing.io, tmp.dir, "w.db", fx.opts(size));
        defer again.close(testing.io);

        try testing.expectEqual(@as(u64, 77), again.wal_lsn);
        try testing.expectEqual(head, again.freelist_head);
        try testing.expectEqual(@as(u32, 3), again.page_count);
        try testing.expectEqual(a, try again.allocate(testing.io)); // The list still works.
    }
}

test "set_wal_lsn: a failed write leaves the value in memory and on disk as it was" {
    const faults = [_]fault_io.Fault{ .canceled, .zero };
    const wants = [_]anyerror{ error.Canceled, error.NoSpaceLeft };
    for (faults, wants) |fault, want| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "w.db", fx.opts(512));
        try pm.set_wal_lsn(testing.io, 9);
        var fio: fault_io.FaultIo = undefined;
        const plan: fault_io.Plan = .{ .write = fault, .read = .none, .after_calls = 0 };
        fault_io.FaultIo.init(&fio, testing.io, plan);
        try testing.expectError(want, pm.set_wal_lsn(fio.io(), 50));
        try testing.expectEqual(@as(u64, 9), pm.wal_lsn);
        try fx.expect_page0_intact(&pm, 1);
        try pm.set_wal_lsn(testing.io, 50); // The retry succeeds.
        pm.close(testing.io);

        try testing.expectEqual(@as(u64, 50), try reopen_wal_lsn(tmp.dir, 512));
    }
}
