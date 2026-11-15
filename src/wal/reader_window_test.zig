//! Contract tests for the read-ahead window of `Reader` (plan 006 item 11): sequential regular
//! frames are served from one window read instead of two positional reads each. A `FaultIo`
//! counts the positional reads `next` issues (the reader is opened through the plain testing
//! `Io`, so `open` reads are not counted); with `.short = 1` it counts bytes instead, which
//! proves that no byte is read twice. Frame `i` of a run carries the payload byte `i % 251`.
//! Shared helpers: `reader_fixtures.zig`, `segment_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const frame = @import("frame.zig");
const fault_io = @import("../testing/fault_io.zig");
const fx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");
const reader_mod = @import("reader.zig");

const Reader = fx.Reader;
const Lsn = frame.Lsn;
const header_size = fx.header_size;
const window_bytes = reader_mod.read_window_size;
const frame_bytes_per_window: u32 = 128;

/// Payload length that makes a frame `total` bytes long.
fn payload_for(total: u32) u32 {
    assert(total > frame.frame_header_size);
    assert(total <= frame.frame_bytes_max);
    return total - frame.frame_header_size;
}

/// `count` copies of `len`.
fn uniform(count: u32, len: u32) ![]u32 {
    assert(count >= 1);
    assert(len >= 1);
    const lens = try testing.allocator.alloc(u32, count);
    @memset(lens, len);
    return lens;
}

/// Writes segment `index` holding one frame per entry of `lens`, frame `i` (counted from
/// `seq`) filled with `(seq + i) % 251`; returns the end LSN. Fails the test on any error.
fn write_segment(dir: Io.Dir, index: u32, first_lsn: Lsn, seq: u32, lens: []const u32) !Lsn {
    assert(index >= 1);
    assert(lens.len >= 1);
    var total: usize = 0;
    for (lens) |len| total += len;
    const store = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(store);

    const payloads = try testing.allocator.alloc([]const u8, lens.len);
    defer testing.allocator.free(payloads);

    var at: usize = 0;
    for (lens, payloads, 0..) |len, *payload, i| {
        payload.* = store[at..][0..len];
        @memset(store[at..][0..len], @intCast((seq + i) % 251));
        at += len;
    }
    const size = header_size + total + lens.len * frame.frame_header_size;
    const image = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(image);

    const used = fx.build(image, index, first_lsn, payloads);
    try sfx.put_file(dir, index, image, used);
    return fx.end_lsn(first_lsn, used);
}

/// Reads the frames of `lens` back from `rd`, checking LSN and payload; returns the end LSN.
fn expect_frames(rd: *Reader, io: Io, first_lsn: Lsn, seq: u32, lens: []const u32) !Lsn {
    assert(first_lsn >= frame.lsn_first);
    assert(lens.len >= 1);
    var lsn = first_lsn;
    for (lens, 0..) |len, i| {
        const got = (try rd.next(io)).?;
        try testing.expectEqual(lsn, got.lsn);
        try testing.expectEqual(@as(usize, len), got.payload.len);
        const want: u8 = @intCast((seq + i) % 251);
        for (got.payload) |byte| try testing.expectEqual(want, byte);
        lsn += fx.frame_size(len);
    }
    return lsn;
}

/// One segment of `lens` read back through a counting `Io`; returns the reads `next` made
/// (bytes, with `.short = 1`) up to and including the clean end.
fn count_reads(lens: []const u32, read: fault_io.Fault) !u32 {
    assert(lens.len >= 1);
    assert(read != .canceled); // Reads must succeed: only counted or cut short.
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try write_segment(tmp.dir, 1, 1, 0, lens);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    var fio: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&fio, testing.io, .{ .write = .none, .read = read, .after_calls = 0 });
    const io = fio.io();
    try testing.expectEqual(end, try expect_frames(&rd, io, 1, 0, lens));
    try testing.expectEqual(@as(?frame.Frame, null), try rd.next(io));
    return fio.read_calls;
}

/// Reads of a segment of `lens` when every read is 1 byte: the bytes read, which must equal the
/// frame bytes of the segment (no byte twice, none beyond the end).
fn expect_bytes_exact(lens: []const u32) !void {
    assert(lens.len >= 1);
    assert(lens.len <= 4096);
    var want: u32 = 0;
    for (lens) |len| want += fx.frame_size(len);
    try testing.expectEqual(want, try count_reads(lens, .{ .short = 1 }));
}

fn reads_ceiling(bytes: u64, per_read: u64) u32 {
    assert(bytes >= 1);
    assert(per_read >= 1);
    return @intCast(@divFloor(bytes + per_read - 1, per_read));
}

test "reader window: a segment shorter than the window is one read" {
    const lens = [_]u32{ 111, 111, 111 };
    try testing.expectEqual(@as(u32, 1), try count_reads(&lens, .none));
}

test "reader window: frames ending exactly at the window end cost one read per window" {
    const per_window: u32 = @divExact(window_bytes, frame_bytes_per_window);
    const lens = try uniform(2 * per_window, 111);
    defer testing.allocator.free(lens);

    try testing.expectEqual(@as(u32, 2), try count_reads(lens, .none));
}

test "reader window: a straddling frame moves its tail, no byte is read twice" {
    const size = fx.frame_size(100);
    try testing.expect(window_bytes % size != 0); // Boundaries fall inside frames.
    const lens = try uniform(2000, 100);
    defer testing.allocator.free(lens);

    const bytes: u64 = 2000 * @as(u64, size);
    const reads = try count_reads(lens, .none);
    try testing.expect(reads >= reads_ceiling(bytes, window_bytes));
    try testing.expect(reads <= reads_ceiling(bytes, window_bytes - size + 1));
    try expect_bytes_exact(lens);
}

test "reader window: reads grow with bytes, not with frames" {
    const lens = try uniform(6000, 111); // 128 byte frames: 768 KB.
    defer testing.allocator.free(lens);

    const reads = try count_reads(lens, .none);
    try testing.expect(reads >= reads_ceiling(6000 * 128, window_bytes));
    try testing.expect(reads <= reads_ceiling(6000 * 128, window_bytes - 127));
}

test "reader window: a frame larger than the window is the window plus one read" {
    const lens = try uniform(2, window_bytes + 100);
    defer testing.allocator.free(lens);

    // Per frame: one window read, one read for the rest. Nothing is read twice.
    try testing.expectEqual(@as(u32, 4), try count_reads(lens, .none));
    try expect_bytes_exact(lens);
}

test "reader window: frames of exactly the window size and one byte more" {
    const exact = try uniform(3, payload_for(window_bytes));
    defer testing.allocator.free(exact);

    try testing.expectEqual(@as(u32, 3), try count_reads(exact, .none)); // One window each.
    try expect_bytes_exact(exact);

    const over = try uniform(2, payload_for(window_bytes + 1));
    defer testing.allocator.free(over);

    try testing.expectEqual(@as(u32, 4), try count_reads(over, .none)); // Window plus 1 byte.
    try expect_bytes_exact(over);
}

test "reader window: a header split across the window boundary is read whole" {
    // Frame 1 ends 8 bytes before the window end, so frame 2's 17 byte header straddles it.
    const lens = [_]u32{ payload_for(window_bytes - 8), 50, 50 };
    try testing.expectEqual(@as(u32, 2), try count_reads(&lens, .none));
    try expect_bytes_exact(&lens);
}

test "reader window: a file cut short after open is Corrupted at the refill, never torn" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const lens = [_]u32{ 111, 111, 111 };
    _ = try write_segment(tmp.dir, 1, 1, 0, &lens);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    const raw = try sfx.raw_open(tmp.dir, 1);
    defer raw.close(testing.io);

    try raw.setLength(testing.io, header_size + 200); // Less than the length `open` saw.
    try fx.expect_next_error(&rd, error.Corrupted);
}

test "reader window: a bad frame from the window is torn only if nothing intact follows" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const lens = [_]u32{ 40, 40, 40 };
    _ = try write_segment(tmp.dir, 1, 1, 0, &lens);

    const raw = try sfx.raw_open(tmp.dir, 1);
    defer raw.close(testing.io);

    const second = header_size + fx.frame_size(40);
    try sfx.flip_bit(raw, second + frame.frame_header_size + 3, 0);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    _ = try expect_frames(&rd, testing.io, 1, 0, lens[0..1]);
    try fx.expect_next_error(&rd, error.ChecksumMismatch); // Frame 3 is intact after it.
    rd.deinit(testing.io, testing.allocator);

    try sfx.flip_bit(raw, second + frame.frame_header_size + 3, 0); // Repair frame 2.
    try sfx.flip_bit(raw, second + fx.frame_size(40) + frame.frame_header_size + 3, 0);
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    _ = try expect_frames(&rd, testing.io, 1, 0, lens[0..2]);
    try fx.expect_next_error(&rd, error.TornWrite); // Nothing intact follows frame 3.
    try fx.expect_position(&rd, 1, second + fx.frame_size(40), 1 + 2 * fx.frame_size(40));
}

test "reader window: the window resets at a boundary between segments over 64 KiB" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const first = try uniform(900, 111); // 115 KB: crosses the window boundary.
    defer testing.allocator.free(first);

    const second = try uniform(700, 77);
    defer testing.allocator.free(second);

    const mid = try write_segment(tmp.dir, 1, 1, 0, first);
    const end = try write_segment(tmp.dir, 2, mid, 900, second);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 4);
    defer rd.deinit(testing.io, testing.allocator);

    var fio: fault_io.FaultIo = undefined;
    const plan: fault_io.Plan = .{ .write = .none, .read = .{ .short = 1 }, .after_calls = 0 };
    fault_io.FaultIo.init(&fio, testing.io, plan);
    const io = fio.io();
    try testing.expectEqual(mid, try expect_frames(&rd, io, 1, 0, first));
    try testing.expectEqual(end, try expect_frames(&rd, io, mid, 900, second));
    try testing.expectEqual(@as(?frame.Frame, null), try rd.next(io));
    // Every frame byte once, plus the header `enter` reads when it crosses into segment 2.
    try testing.expectEqual(end - 1 + header_size, fio.read_calls);
}
