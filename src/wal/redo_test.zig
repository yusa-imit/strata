//! Contract tests for `PageRedo` (plan 004 item 9, ADR-0003 section 10): the apply rule (restore
//! a damaged page, skip a page at or past the frame's lsn), re-stamping of a stale image header,
//! file growth, the `Corrupted` and `Failed` variants, ignored frame types, and replay twice
//! equal to once through the real `Recovery.replay`. Page sizes: all eight where cheap.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("../testing/fault_io.zig");
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const manager = @import("../page/manager.zig");
const frame = @import("frame.zig");
const redo = @import("redo.zig");
const rx = @import("redo_fixtures.zig");

const Env = rx.Env;

/// Faults from the first call on in the given directions.
fn plan(write: fault_io.Fault, read: fault_io.Fault) fault_io.Plan {
    assert(write != .none or read != .none);
    assert(write != .short and read != .short);
    return .{ .write = write, .read = read, .after_calls = 0 };
}

test "redo: every kind of damaged page is restored from the image at all sizes" {
    for (rx.sizes_all) |size| for (rx.damages) |kind| {
        var env: Env = undefined;
        try env.init(size, 4);
        defer env.deinit();

        // The damaged page's lsn was above the frame's: damage, not the lsn, decides.
        try env.put_page(3, 11, 500);
        try env.damage(3, kind);
        try env.apply_image(3, 22, 90);
        try env.expect_page(3, 22, 90);
        try env.expect_stats(1, 0, 0);
        try testing.expectEqual(@as(u32, 4), env.pm.page_count);
        try testing.expectEqual(@as(u64, size) * 4, try env.pm.file.length(testing.io));
    };
}

test "redo: an unwritten page inside the file is restored" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 3);
        defer env.deinit();

        try fx.expect_read_error(&env.pm, 2, error.Unwritten);
        try env.apply_image(2, 5, 7);
        try env.expect_page(2, 5, 7);
        try env.expect_stats(1, 0, 0);
    }
}

test "redo: older page is replaced, newer and equal pages are untouched" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 4);
        defer env.deinit();

        try env.put_page(1, 5, 40);
        try env.put_page(2, 5, 100);
        try env.put_page(3, 5, 60);
        try env.apply_image(1, 6, 60);
        try env.apply_image(2, 6, 60);
        try env.apply_image(3, 6, 60);
        try env.expect_page(1, 6, 60);
        try env.expect_page(2, 5, 100);
        try env.expect_page(3, 5, 60);
        try env.expect_stats(1, 2, 0);
    }
}

test "redo: a stale image header is re-stamped with the frame lsn and keeps its type" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 3);
        defer env.deinit();

        const kind: header.Type = @enumFromInt(200);
        const payload = try rx.image_payload(size, 2, 9, kind, rx.stale_lsn);
        defer testing.allocator.free(payload);

        // The image's own checksum does not verify: redo must not need it to.
        const raw = payload[4..];
        try testing.expectError(error.ChecksumMismatch, header.decode(raw, @enumFromInt(2)));
        try env.apply_with(testing.io, .page_image, 77, payload);
        const buf = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(buf);

        const got = try env.pm.read(testing.io, @enumFromInt(2), buf);
        try testing.expectEqual(kind, got.page_type);
        try testing.expectEqual(@as(u64, 77), got.lsn);
        try testing.expectEqualSlices(u8, raw[header.header_size..], buf[header.header_size..]);
    }
}

test "redo: a page past page_count grows the file and the gap reads unwritten" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 1);
        defer env.deinit();

        try env.apply_image(6, 3, 12);
        try testing.expectEqual(@as(u32, 7), env.pm.page_count);
        try testing.expectEqual(@as(u64, size) * 7, try env.pm.file.length(testing.io));
        try env.expect_page(6, 3, 12);
        try fx.expect_read_error(&env.pm, 3, error.Unwritten);
        try fx.expect_page0_intact(&env.pm, 7);
        try env.expect_stats(1, 0, 0);
    }
}

test "redo: other frame types are ignored and touch nothing" {
    var env: Env = undefined;
    try env.init(512, 3);
    defer env.deinit();

    const before = try env.snapshot();
    defer testing.allocator.free(before);

    const redo_lsn: [8]u8 = .{ 5, 0, 0, 0, 0, 0, 0, 0 };
    try env.apply_with(testing.io, .record, 5, "hello");
    try env.apply_with(testing.io, .checkpoint, 5, &redo_lsn);
    try env.apply_with(testing.io, @enumFromInt(130), 6, "consumer");
    try env.expect_stats(0, 0, 3);
    const after = try env.snapshot();
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
}

test "redo: a bad image is Corrupted before anything is grown or written" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 4);
        defer env.deinit();

        const wrong = if (size == 512) size * 2 else size / 2;
        const half = try rx.image_payload(wrong, 9, 1, rx.consumer_type, 1);
        defer testing.allocator.free(half);

        try env.expect_apply_error(error.Corrupted, 10, half); // Size mismatch.
        try env.expect_apply_error(error.Corrupted, 10, half[0..3]); // Under the id.
        try env.expect_apply_error(error.Corrupted, 10, half[0..4]); // An empty image.

        const good = try rx.image_payload(size, 9, 1, rx.consumer_type, 1);
        defer testing.allocator.free(good);

        good[4] ^= 1; // Magic.
        try env.expect_apply_error(error.Corrupted, 10, good);
        good[4] ^= 1;
        for ([_]u8{ 1, 0, 64, 127 }) |bad_type| { // Legal at page 0, or reserved.
            good[8] = bad_type;
            try env.expect_apply_error(error.Corrupted, 10, good);
        }
        try testing.expectEqual(@as(u32, 4), env.pm.page_count);
        try testing.expectEqual(@as(u64, size) * 4, try env.pm.file.length(testing.io));
    }
}

test "redo: page 0 has no image path and is Corrupted" {
    var env: Env = undefined;
    try env.init(512, 2);
    defer env.deinit();

    const payload = try rx.image_payload(512, 1, 1, rx.consumer_type, 1);
    defer testing.allocator.free(payload);

    std.mem.writeInt(u32, payload[0..4], 0, .little);
    try env.expect_apply_error(error.Corrupted, 10, payload);
    try fx.expect_page0_intact(&env.pm, 2);
}

test "redo: a page id at the file limit is Failed, however large" {
    var env: Env = undefined;
    try env.init(512, 2);
    defer env.deinit();

    const payload = try rx.image_payload(512, 1, 1, rx.consumer_type, 1);
    defer testing.allocator.free(payload);

    const last_ok: u32 = rx.page_count_max - 1;
    for ([_]u32{ rx.page_count_max, rx.page_count_max + 1, std.math.maxInt(u32) }) |id| {
        std.mem.writeInt(u32, payload[0..4], id, .little);
        try env.expect_apply_error(error.Failed, 10, payload);
    }
    try testing.expectEqual(@as(u32, 2), env.pm.page_count);
    try env.apply_image(last_ok, 4, 10); // The last page the limit allows.
    try testing.expectEqual(rx.page_count_max, env.pm.page_count);
}

test "redo: an I/O error on read, write or growth is Failed and the page stays as it was" {
    var env: Env = undefined;
    try env.init(512, 4);
    defer env.deinit();

    var reads: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&reads, testing.io, plan(.none, .canceled));
    const payload = try rx.image_payload(512, 2, 8, rx.consumer_type, 1);
    defer testing.allocator.free(payload);

    try env.put_page(2, 1, 5);
    const read_got = env.apply_with(reads.io(), .page_image, 9, payload);
    try testing.expectError(error.Failed, read_got);
    try env.expect_page(2, 1, 5);

    var writes: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&writes, testing.io, plan(.canceled, .none));
    const write_got = env.apply_with(writes.io(), .page_image, 9, payload);
    try testing.expectError(error.Failed, write_got);
    try env.expect_page(2, 1, 5);

    std.mem.writeInt(u32, payload[0..4], 6, .little); // Needs growth, whose page-0 write fails.
    const grow_got = env.apply_with(writes.io(), .page_image, 9, payload);
    try testing.expectError(error.Failed, grow_got);
    try testing.expectEqual(@as(u32, 4), env.pm.page_count);
    try fx.expect_page0_intact(&env.pm, 4);
    try env.expect_stats(0, 0, 0);
}

test "redo: a page inside the file is redone even when page_count_max is lower" {
    var env: Env = undefined;
    try env.init(512, 4);
    defer env.deinit();

    env.pm.page_count_max = 2; // As after a reopen with smaller options: the file is bigger.
    try env.apply_image(3, 7, 30);
    try env.expect_page(3, 7, 30);
    try env.expect_stats(1, 0, 0);

    const payload = try rx.image_payload(512, 4, 7, rx.consumer_type, 1);
    defer testing.allocator.free(payload);

    try env.expect_apply_error(error.Failed, 31, payload); // A page the file lacks meets it.
    try testing.expectEqual(@as(u32, 4), env.pm.page_count);
    std.mem.writeInt(u32, payload[0..4], std.math.maxInt(u32), .little);
    try env.expect_apply_error(error.Failed, 31, payload); // `id + 1` would overflow.
    try fx.expect_page0_intact(&env.pm, 4);
}

test "redo: init with no memory is OutOfMemory" {
    var env: Env = undefined;
    env.tmp = testing.tmpDir(.{});
    defer env.tmp.cleanup();

    try manager.PageManager.create(
        &env.pm,
        testing.io,
        env.tmp.dir,
        "oom.db",
        fx.opts(512),
    );
    defer env.pm.close(testing.io);

    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const got = redo.PageRedo.init(&env.redo, failing.allocator(), &env.pm);
    try testing.expectError(error.OutOfMemory, got);
}

test "redo: replaying the log twice leaves the page file as replaying it once" {
    for ([_]u32{ 512, 4096, 65536 }) |size| {
        var once: Env = undefined;
        try once.init(size, 1);
        defer once.deinit();

        const steps = [_]rx.Step{
            .record,
            .{ .image = .{ .id = 2, .seed = 1 } },
            .{ .image = .{ .id = 3, .seed = 2 } },
            .record,
            .{ .image = .{ .id = 2, .seed = 3 } },
        };
        var lsns: [steps.len]frame.Lsn = undefined;
        try rx.write_log(once.tmp.dir, size, &steps, &lsns);

        const last = try once.replay(once.tmp.dir);
        try testing.expectEqual(lsns[4], last.last_lsn);
        try once.expect_stats(3, 0, 2);
        try once.expect_page(2, 3, lsns[4]);
        try once.expect_page(3, 2, lsns[2]);

        var twice: Env = undefined;
        try twice.init(size, 1);
        defer twice.deinit();

        _ = try twice.replay(once.tmp.dir);
        const middle = try twice.snapshot();
        defer testing.allocator.free(middle);

        _ = try twice.replay(once.tmp.dir);
        try twice.expect_stats(3 + 0, 3, 4); // The second pass applied nothing.
        const first = try once.snapshot();
        defer testing.allocator.free(first);

        const second = try twice.snapshot();
        defer testing.allocator.free(second);

        try testing.expectEqualSlices(u8, first, middle);
        try testing.expectEqualSlices(u8, first, second);
    }
}
