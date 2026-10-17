//! Contract tests for `PageManager.ensure_page_count` (plan 004 item 9): growth to an exact page
//! count, persistence across reopen, no-op below the current count, the `page_count_max` limit,
//! and that the freelist is left alone.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("header.zig");
const fx = @import("manager_fixtures.zig");
const fault_io = @import("../testing/fault_io.zig");

const PageManager = @import("manager.zig").PageManager;

test "ensure_page_count: grows to the count, pages read unwritten, reopen sees it" {
    for (fx.sizes_all) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "g.db", fx.opts(size));
        try pm.ensure_page_count(testing.io, 5);
        try testing.expectEqual(@as(u32, 5), pm.page_count);
        try testing.expectEqual(@as(u64, size) * 5, try pm.file.length(testing.io));
        try fx.expect_read_error(&pm, 4, error.Unwritten);
        try fx.expect_page0_intact(&pm, 5);
        pm.close(testing.io);

        try fx.expect_open_ok(tmp.dir, "g.db", size, 5);
    }
}

test "ensure_page_count: a count at or below page_count changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "n.db", fx.opts(512));
    defer pm.close(testing.io);

    try pm.ensure_page_count(testing.io, 1);
    try testing.expectEqual(@as(u32, 1), pm.page_count);
    try pm.ensure_page_count(testing.io, 4);
    try pm.ensure_page_count(testing.io, 2);
    try testing.expectEqual(@as(u32, 4), pm.page_count);
    try testing.expectEqual(@as(u64, 512) * 4, try pm.file.length(testing.io));
}

test "ensure_page_count: past page_count_max is NoSpaceLeft and the manager is unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "m.db", fx.opts(512));
    defer pm.close(testing.io);

    const over = fx.page_count_max + 1;
    try testing.expectError(error.NoSpaceLeft, pm.ensure_page_count(testing.io, over));
    try testing.expectEqual(@as(u32, 1), pm.page_count);
    try testing.expectEqual(@as(u64, 512), try pm.file.length(testing.io));
    try pm.ensure_page_count(testing.io, fx.page_count_max); // The limit itself is allowed.
    try testing.expectEqual(fx.page_count_max, pm.page_count);
}

test "ensure_page_count: the freelist survives growth and still serves allocate first" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "f.db", fx.opts(1024));
    defer pm.close(testing.io);

    const a = try pm.allocate(testing.io);
    const b = try pm.allocate(testing.io);
    try pm.free(testing.io, a);
    const head = pm.freelist_head;
    try testing.expect(head != null);
    try pm.ensure_page_count(testing.io, 8);
    try testing.expectEqual(head, pm.freelist_head);
    try testing.expectEqual(@as(u32, 8), pm.page_count);
    try testing.expectEqual(a, try pm.allocate(testing.io)); // LIFO reuse, not the grown pages.
    try testing.expect(b != a);
    assert(header.page_size_valid(pm.page_size));
}

test "ensure_page_count: a failed page-0 write leaves page_count and page 0 as they were" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "x.db", fx.opts(512));
    defer pm.close(testing.io);

    try pm.ensure_page_count(testing.io, 3);
    var fio: fault_io.FaultIo = undefined;
    const plan: fault_io.Plan = .{ .write = .canceled, .read = .none, .after_calls = 0 };
    fault_io.FaultIo.init(&fio, testing.io, plan);
    // The space is reserved before page 0 is written, so the file may be longer afterwards.
    try testing.expectError(error.Canceled, pm.ensure_page_count(fio.io(), 9));
    try testing.expectEqual(@as(u32, 3), pm.page_count);
    try fx.expect_page0_intact(&pm, 3);
    try pm.ensure_page_count(testing.io, 9); // The retry succeeds.
    try fx.expect_page0_intact(&pm, 9);
}
