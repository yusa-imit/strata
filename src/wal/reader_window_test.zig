//! Contract tests for the read-ahead window of `Reader` (plan 006 item 11): sequential regular
//! frames are served from one window read instead of two positional reads each. A `FaultIo`
//! with no fault counts the positional reads `next` issues (the reader is opened through the
//! plain testing `Io`, so `open` reads are not counted). Shared helpers: `reader_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const frame = @import("frame.zig");
const fault_io = @import("../testing/fault_io.zig");
const fx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");
const reader_mod = @import("reader.zig");

const Reader = fx.Reader;
const header_size = fx.header_size;
const window_bytes = reader_mod.read_window_size;

/// Writes segment 1 with `count` frames of `payload_len` bytes (byte `i % 251` repeated), reads
/// them all back through a counting `Io` and returns the positional reads `next` made.
fn read_all_counted(payload_len: u32, count: u32) !u32 {
    assert(payload_len >= 1);
    assert(count >= 1);
    const store = try testing.allocator.alloc(u8, @as(usize, payload_len) * count);
    defer testing.allocator.free(store);

    const payloads = try testing.allocator.alloc([]const u8, count);
    defer testing.allocator.free(payloads);

    for (payloads, 0..) |*payload, i| {
        const bytes = store[i * payload_len ..][0..payload_len];
        @memset(bytes, @intCast(i % 251));
        payload.* = bytes;
    }
    const image = try testing.allocator.alloc(u8, header_size + count * fx.frame_size(payload_len));
    defer testing.allocator.free(image);

    const len = fx.build(image, 1, 1, payloads);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sfx.put_file(tmp.dir, 1, image, len);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    var fio: fault_io.FaultIo = undefined;
    const plan: fault_io.Plan = .{ .write = .none, .read = .none, .after_calls = 0 };
    fault_io.FaultIo.init(&fio, testing.io, plan);
    const io = fio.io();
    var lsn: frame.Lsn = 1;
    for (payloads) |payload| {
        const got = (try rd.next(io)).?;
        try testing.expectEqual(lsn, got.lsn);
        try testing.expectEqualSlices(u8, payload, got.payload);
        lsn += fx.frame_size(payload_len);
    }
    try testing.expectEqual(@as(?frame.Frame, null), try rd.next(io));
    try fx.expect_position(&rd, 1, len, lsn);
    return fio.read_calls;
}

fn reads_ceiling(bytes: u64) u32 {
    assert(bytes >= 1);
    assert(bytes <= 1 << 30);
    return @intCast(@divFloor(bytes + window_bytes - 1, window_bytes));
}

test "reader window: a segment shorter than the window is one read" {
    const reads = try read_all_counted(111, 3);
    try testing.expectEqual(@as(u32, 1), reads);
}

test "reader window: frames ending exactly at the window end cost one read per window" {
    // 128 byte frames: a whole number of them fill each window exactly.
    const per_window: u32 = @divExact(window_bytes, 128);
    const reads = try read_all_counted(111, 2 * per_window);
    try testing.expectEqual(@as(u32, 2), reads);
}

test "reader window: frames straddling window boundaries are read whole" {
    const count: u32 = 2000; // 117 byte frames: 234 KB, boundaries fall inside frames.
    try testing.expect(window_bytes % fx.frame_size(100) != 0);
    const reads = try read_all_counted(100, count);
    const bytes: u64 = @as(u64, count) * fx.frame_size(100);
    try testing.expect(reads >= reads_ceiling(bytes));
    try testing.expect(reads <= reads_ceiling(bytes) + 2);
}

test "reader window: reads grow with bytes, not with frames" {
    const count: u32 = 6000; // 128 byte frames: 768 KB.
    const reads = try read_all_counted(111, count);
    const bytes: u64 = @as(u64, count) * 128;
    try testing.expect(reads <= reads_ceiling(bytes) + 2);
    try testing.expect(reads < count / 8);
}

test "reader window: a frame larger than the window still reads exactly its own bytes" {
    const reads = try read_all_counted(window_bytes + 100, 2);
    try testing.expect(reads <= 6); // Header and body read separately, no window.
    try testing.expect(reads >= 2);
}
