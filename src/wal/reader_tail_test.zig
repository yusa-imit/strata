//! Contract tests for `Reader` (ADR-0003 section 8), frame half: the zero tail, the torn-tail
//! rule with its look-ahead, intact-but-invalid frames, `CrashSink` cut sweeps, the largest
//! frame, the no-allocation-after-open guarantee and injected read faults. Layout, continuity,
//! limits and locking are in `reader_test.zig`; shared helpers are in `reader_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const crash = @import("../testing/crash.zig");
const fault_io = @import("../testing/fault_io.zig");
const frame = @import("frame.zig");
const fx = @import("reader_fixtures.zig");
const segment = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");

const Reader = fx.Reader;
const Lsn = fx.Lsn;
const pa = fx.pa;
const pb = fx.pb;
const pc = fx.pc;
const header_size = fx.header_size;

/// Offsets of the frames of the 3-frame segment `[pa, pb, pc]` from first LSN 1.
const f2_offset: u32 = header_size + 22;
const f3_offset: u32 = f2_offset + 24;
const f3_end: u32 = f3_offset + 24;
const f2_lsn: Lsn = 1 + 22;
const f3_lsn: Lsn = f2_lsn + 24;

comptime {
    assert(f2_offset == header_size + 17 + pa.len);
    assert(f3_offset == f2_offset + 17 + pb.len);
    assert(f3_end == f3_offset + 17 + pc.len);
}

/// Reads `[pa, pb, pc]` in order from `rd`, all three intact.
fn expect_three(rd: *Reader) !void {
    assert(rd.entries.len >= 1);
    assert(f3_lsn == 47);
    try fx.expect_record(rd, 1, pa);
    try fx.expect_record(rd, f2_lsn, pb);
    try fx.expect_record(rd, f3_lsn, pc);
}

/// Opens the log, reads `pa` at LSN 1, expects `want` from the next call and closes.
fn expect_pa_then(dir: std.Io.Dir, want: anyerror) !void {
    assert(want != error.OutOfMemory);
    assert(want != error.WouldBlock); // Every earlier reader must be closed first.
    var rd: Reader = undefined;
    try fx.open_ok(&rd, dir, 4);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    try fx.expect_next_error(&rd, want);
}

test "reader: every crash cut of a 3-frame segment gives a prefix, then EOF or TornWrite" {
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    try testing.expectEqual(f3_end, len);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var storage: [256]u8 = undefined;
    var out: [256]u8 = undefined;
    var points = try crash.TruncationPoints.init(len, 200);
    while (points.next()) |n| {
        for ([_]crash.Cut{ .{ .truncate = n }, .{ .torn = n } }) |cut| {
            var sink: crash.CrashSink = undefined;
            try crash.CrashSink.init(&sink, &storage, cut, 0x5eed ^ n);
            try testing.expectEqual(@as(usize, len), try sink.writeAt(image[0..len], 0));
            sink.check_invariants();
            const persisted = try sink.persisted_into(&out);
            try sfx.put_file(tmp.dir, 1, persisted, persisted.len);
            try check_cut(tmp.dir, cut, n);
        }
    }
}

/// What a reader must do with the file left by `cut` at byte `n` of the 3-frame segment.
fn check_cut(dir: std.Io.Dir, cut: crash.Cut, n: u64) !void {
    assert(n <= f3_end);
    assert(f3_end < crash.sector_size); // One sector: a torn cut garbles everything after it.
    var rd: Reader = undefined;
    const opened = Reader.open(&rd, testing.io, testing.allocator, dir, fx.opts(2));
    // Garbage in the header is typed, never a panic. Torn at byte 0 is a sector boundary: the
    // whole sector is lost, so it leaves an empty file, like a truncation at 0.
    if (n > 0 and n < header_size and cut == .torn) {
        if (opened) |_| {
            rd.deinit(testing.io, testing.allocator);
            return error.TestExpectedOpenError;
        } else |err| switch (err) {
            error.Corrupted, error.ChecksumMismatch => return,
            else => return err,
        }
    }
    try opened;
    defer rd.deinit(testing.io, testing.allocator);

    const ends = [_]u64{ f2_offset, f3_offset, f3_end };
    var frames_whole: usize = 0;
    for (ends) |end| frames_whole += @intFromBool(n >= end);
    const payloads = [_][]const u8{ pa, pb, pc };
    var lsn: Lsn = 1;
    for (payloads[0..frames_whole]) |payload| {
        try fx.expect_record(&rd, lsn, payload);
        lsn += fx.frame_size(payload.len);
    }
    const boundary = n == header_size or n == f2_offset or n == f3_offset or n == f3_end;
    const clean = switch (cut) {
        .truncate => boundary or n < header_size,
        .torn => n == 0 or n >= f3_end, // Garbage starts at `n`, so nothing between is clean.
    };
    if (clean) {
        try fx.expect_eof(&rd);
    } else {
        try fx.expect_next_error(&rd, error.TornWrite);
    }
}

test "reader: a zero tail is clean EOF, whatever its size, and the cursor stops before it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });

    const tails = [_]u64{ 1, 5, 16, 17, 18, 100, 3 << 20 };
    for (tails) |tail| {
        try sfx.put_file(tmp.dir, 1, image[0..len], len + tail);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try expect_three(&rd);
        try fx.expect_eof(&rd);
        try fx.expect_eof(&rd);
        try fx.expect_position(&rd, 1, f3_end, 1 + (f3_end - header_size));
    }
}

test "reader: a zero tail below a newer segment crosses, a non-zero byte in it is not a log" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    const end = fx.end_lsn(1, len);
    _ = try fx.put_segment(tmp.dir, 2, end, &.{pa});

    try sfx.put_file(tmp.dir, 1, image[0..len], len + 100);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    try expect_three(&rd);
    try fx.expect_record(&rd, end, pa);
    try fx.expect_eof(&rd);
    rd.deinit(testing.io, testing.allocator);

    // The same bytes, but with a stray non-zero byte at the very end of the tail.
    for ([_]u32{ 0, 40, 99 }) |at| {
        var junk: [256]u8 = image;
        junk[len + at] = 1;
        try sfx.put_file(tmp.dir, 1, junk[0 .. len + at + 1], len + 100);
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try expect_three(&rd);
        try fx.expect_next_error(&rd, error.ChecksumMismatch);
    }
}

test "reader: a non-zero byte after zeros in the newest segment is a torn tail" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    image[len + 60] = 7;
    try sfx.put_file(tmp.dir, 1, image[0 .. len + 61], len + 61);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try expect_three(&rd);
    try fx.expect_next_error(&rd, error.TornWrite);
}

test "reader: bit rot with a valid frame behind it is ChecksumMismatch, never TornWrite" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });

    const flips = [_]u32{ f2_offset + 8, f2_offset + 17, f2_offset + 17 + 3, f2_offset + 4 };
    for (flips) |at| { // lsn field, first payload byte, payload byte, crc field
        image[at] ^= 0x10;
        try sfx.put_file(tmp.dir, 1, image[0..len], len);
        image[at] ^= 0x10;
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_next_error(&rd, error.ChecksumMismatch);
    }
    image[header_size + 17] ^= 1; // The first frame, two valid frames behind it.
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_next_error(&rd, error.ChecksumMismatch);
}

test "reader: damage to a run of frames is found by the look-ahead behind it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc, pa });
    image[f2_offset + 17] ^= 1; // frame 2 payload
    image[f3_offset + 17] ^= 1; // frame 3 payload
    try sfx.put_file(tmp.dir, 1, image[0..len], len);

    try expect_pa_then(tmp.dir, error.ChecksumMismatch);

    image[f3_end + 17] ^= 1; // The fourth frame too: nothing valid behind the run.
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try expect_pa_then(tmp.dir, error.TornWrite);
}

test "reader: the last frame damaged with nothing behind it is a torn tail" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    image[f3_offset + 17] ^= 1;
    try sfx.put_file(tmp.dir, 1, image[0..len], len);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    try fx.expect_record(&rd, f2_lsn, pb);
    try fx.expect_next_error(&rd, error.TornWrite);
}

test "reader: below a newer segment damage is never TornWrite" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    _ = try fx.put_segment(tmp.dir, 2, fx.end_lsn(1, len), &.{pa});

    image[f3_offset + 17] ^= 1; // the last frame of segment 1
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    try fx.expect_record(&rd, 1, pa);
    try fx.expect_record(&rd, f2_lsn, pb);
    try fx.expect_next_error(&rd, error.ChecksumMismatch);
    rd.deinit(testing.io, testing.allocator);

    image[f3_offset + 17] ^= 1;
    try sfx.put_file(tmp.dir, 1, image[0 .. len - 10], len - 10); // cut inside the last frame
    try fx.expect_open_error(error.Corrupted, tmp.dir, 2); // segment 2 starts past these bytes

    // Junk where a frame would start, short of a whole header, still inside the bytes.
    @memset(image[len..][0..9], 3);
    try sfx.put_file(tmp.dir, 1, image[0 .. len + 9], len + 9);
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try expect_three(&rd);
    try fx.expect_next_error(&rd, error.Corrupted);
}

test "reader: an intact frame that breaks a rule is Corrupted, even at the tail" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const base = fx.build(&image, 1, 1, &.{pa});
    const bad_types = [_]u8{ 0, 4, 127 };
    for (bad_types) |type_byte| {
        const n = fx.forge_frame(image[base..], f2_lsn, f2_lsn, type_byte, "x");
        try sfx.put_file(tmp.dir, 1, image[0 .. base + n], base + n);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_next_error(&rd, error.Corrupted);
    }
    const wrong_lsns = [_]Lsn{ 1, f2_lsn - 1, f2_lsn + 1, frame.lsn_limit - 1 };
    for (wrong_lsns) |stored| { // CRC valid for the position, stored LSN says otherwise
        const n = fx.forge_frame(image[base..], f2_lsn, stored, 1, "x");
        try sfx.put_file(tmp.dir, 1, image[0 .. base + n], base + n);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_next_error(&rd, error.Corrupted);
    }
}

test "reader: consumer frame types come back as they were written" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const base = fx.build(&image, 1, 1, &.{pa});
    const n = fx.forge_frame(image[base..], f2_lsn, f2_lsn, 200, "mine");
    try sfx.put_file(tmp.dir, 1, image[0 .. base + n], base + n);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    const got = (try rd.next(testing.io)).?;
    try testing.expectEqual(@as(u8, 200), @intFromEnum(got.frame_type));
    try testing.expectEqualSlices(u8, "mine", got.payload);
    try fx.expect_eof(&rd);
}

test "reader: an over-long len at the tail is torn in the newest segment, Corrupted below it" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const base = fx.build(&image, 1, 1, &.{pa});
    for ([_]u32{ frame.payload_bytes_max + 1, 0xffffffff }) |bad_len| {
        @memset(image[base..][0..40], 0x11);
        std.mem.writeInt(u32, image[base..][0..4], bad_len, .little);
        try sfx.put_file(tmp.dir, 1, image[0 .. base + 40], base + 40);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 2);
        try fx.expect_record(&rd, 1, pa);
        try fx.expect_next_error(&rd, error.TornWrite);
        rd.deinit(testing.io, testing.allocator);

        _ = try fx.put_segment(tmp.dir, 2, fx.end_lsn(1, base), &.{pb});
        try fx.open_ok(&rd, tmp.dir, 2);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_next_error(&rd, error.Corrupted);
        try tmp.dir.deleteFile(testing.io, &sfx.name_of(2));
    }
}

test "reader: the look-ahead covers the whole segment, across its 64 KiB windows" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try testing.allocator.alloc(u8, 200_000);
    defer testing.allocator.free(image);

    const zeros = try testing.allocator.alloc(u8, 70_000);
    defer testing.allocator.free(zeros);

    @memset(zeros, 0);
    for ([_]u32{ 1000, 65_502, 65_503, 65_504, 65_510, 65_519, 65_520, 65_521, 70_000 }) |size| {
        const middle = zeros[0..size];
        const len = fx.build(image, 1, 1, &.{ pa, middle, pc });
        image[f2_offset + 17 + 5] ^= 1; // Damage the big middle frame.
        try sfx.put_file(tmp.dir, 1, image[0..len], len);
        try expect_pa_then(tmp.dir, error.ChecksumMismatch);

        const without_tail = len - fx.frame_size(pc.len); // Nothing valid behind it: torn.
        try sfx.put_file(tmp.dir, 1, image[0..without_tail], without_tail);
        try expect_pa_then(tmp.dir, error.TornWrite);
    }
}

test "reader: a frame of frame_bytes_max reads back through the open-time buffer" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const image = try testing.allocator.alloc(u8, frame.frame_bytes_max + 4096);
    defer testing.allocator.free(image);

    const big = try testing.allocator.alloc(u8, frame.payload_bytes_max);
    defer testing.allocator.free(big);

    for (big, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    const len = fx.build(image, 1, 1, &.{ big, pa });
    try testing.expectEqual(header_size + frame.frame_bytes_max + 22, len);
    try sfx.put_file(tmp.dir, 1, image[0..len], len);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, big);
    try fx.expect_record(&rd, 1 + frame.frame_bytes_max, pa);
    try fx.expect_eof(&rd);
}

test "reader: open allocates a fixed amount and next, EOF and errors allocate nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    _ = try fx.put_segment(tmp.dir, 2, end, &.{pc});

    for (0..2) |fail_index| { // Both open-time allocations report OutOfMemory and leak nothing.
        const plan: testing.FailingAllocator.Config = .{ .fail_index = fail_index };
        var failing = testing.FailingAllocator.init(testing.allocator, plan);
        var rd: Reader = undefined;
        const got = Reader.open(&rd, testing.io, failing.allocator(), tmp.dir, fx.opts(4));
        try testing.expectError(error.OutOfMemory, got);
    }
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rd: Reader = undefined;
    try Reader.open(&rd, testing.io, failing.allocator(), tmp.dir, fx.opts(4));
    defer rd.deinit(testing.io, failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    try fx.expect_record(&rd, 1, pa);
    try fx.expect_record(&rd, 1 + fx.frame_size(pa.len), pb);
    try fx.expect_record(&rd, end, pc);
    try fx.expect_eof(&rd);
    try testing.expectEqual(allocs, failing.alloc_index);
}

test "reader: the look-ahead and error paths allocate nothing either" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    image[f2_offset + 17] ^= 1;
    try sfx.put_file(tmp.dir, 1, image[0..len], len);

    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var rd: Reader = undefined;
    try Reader.open(&rd, testing.io, failing.allocator(), tmp.dir, fx.opts(4));
    defer rd.deinit(testing.io, failing.allocator());

    failing.fail_index = failing.alloc_index;
    try fx.expect_record(&rd, 1, pa);
    try fx.expect_next_error(&rd, error.ChecksumMismatch);
    try testing.expectEqual(failing.fail_index, failing.alloc_index);
}

test "reader: injected read faults surface as typed errors, short reads change nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    _ = try fx.put_segment(tmp.dir, 2, end, &.{pc});

    const faults = [_]struct { read: fault_io.Fault, want: ?anyerror }{
        .{ .read = .canceled, .want = error.Canceled },
        .{ .read = .zero, .want = error.Corrupted }, // The file ended under us: fail closed.
        .{ .read = .{ .short = 3 }, .want = null },
        .{ .read = .{ .short = 1 }, .want = null },
    };
    for (faults) |case| {
        var fio: fault_io.FaultIo = undefined;
        const plan: fault_io.Plan = .{ .write = .none, .read = case.read, .after_calls = 0 };
        fault_io.FaultIo.init(&fio, testing.io, plan);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 4);
        defer rd.deinit(testing.io, testing.allocator);

        const io = fio.io();
        if (case.want) |want| {
            try testing.expectError(want, rd.next(io));
            continue;
        }
        for ([_][]const u8{ pa, pb, pc }, [_]Lsn{ 1, 23, end }) |payload, lsn| {
            const got = (try rd.next(io)).?;
            try testing.expectEqual(lsn, got.lsn);
            try testing.expectEqualSlices(u8, payload, got.payload);
        }
        try testing.expectEqual(@as(?frame.Frame, null), try rd.next(io));
    }
}

test "reader: a frame costs a read of exactly its own bytes, not of the rest of the segment" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb, pc });

    var fio: fault_io.FaultIo = undefined; // Reads of 1 byte: `read_calls` counts bytes.
    const plan: fault_io.Plan = .{ .write = .none, .read = .{ .short = 1 }, .after_calls = 0 };
    fault_io.FaultIo.init(&fio, testing.io, plan);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    const io = fio.io();
    for ([_][]const u8{ pa, pb, pc }) |payload| {
        const got = (try rd.next(io)).?;
        try testing.expectEqualSlices(u8, payload, got.payload);
    }
    try testing.expectEqual(@as(?frame.Frame, null), try rd.next(io));
    try testing.expectEqual(f3_end - header_size, fio.read_calls);
}

/// An `Io` that, at the first file close, tries to open the segment `probe_index` and records
/// whether that failed with `WouldBlock`, i.e. whether the reader already holds its lock.
const HandoffIo = struct {
    fio: fault_io.FaultIo,
    vtable: std.Io.VTable,
    dir: std.Io.Dir,
    probe_index: u32,
    probed: bool,
    probe_locked: bool,

    fn init(target: *HandoffIo, dir: std.Io.Dir, probe_index: u32) void {
        assert(probe_index >= 1);
        const plan: fault_io.Plan = .{ .write = .none, .read = .none, .after_calls = 0 };
        fault_io.FaultIo.init(&target.fio, testing.io, plan);
        target.vtable = target.fio.vtable;
        target.vtable.fileClose = close_probe;
        target.dir = dir;
        target.probe_index = probe_index;
        target.probed = false;
        target.probe_locked = false;
        assert(target.vtable.fileClose != target.fio.vtable.fileClose);
        assert(target.fio.read_calls == 0);
    }

    fn io(self: *HandoffIo) std.Io {
        assert(self.vtable.fileClose == close_probe);
        assert(self.vtable.fileReadPositional == self.fio.vtable.fileReadPositional);
        return .{ .userdata = &self.fio, .vtable = &self.vtable };
    }

    fn close_probe(userdata: ?*anyopaque, files: []const std.Io.File) void {
        const fio: *fault_io.FaultIo = @ptrCast(@alignCast(userdata));
        const self: *HandoffIo = @fieldParentPtr("fio", fio);
        assert(files.len > 0);
        assert(self.probe_index >= 1);
        if (!self.probed) {
            self.probed = true;
            const options = fx.opts(4);
            if (segment.Segment.open(testing.io, self.dir, self.probe_index, options)) |seg| {
                seg.close(testing.io);
            } else |err| self.probe_locked = err == error.WouldBlock;
        }
        fio.inner.vtable.fileClose(fio.inner.userdata, files);
    }
};

test "reader: crossing locks the next segment before it releases the previous one" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
    _ = try fx.put_segment(tmp.dir, 2, end, &.{pb});

    var handoff: HandoffIo = undefined;
    HandoffIo.init(&handoff, tmp.dir, 2);
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 4);
    defer rd.deinit(testing.io, testing.allocator);

    const io = handoff.io();
    try testing.expectEqualSlices(u8, pa, (try rd.next(io)).?.payload);
    try testing.expect(!handoff.probed); // Still inside the first segment.
    try testing.expectEqualSlices(u8, pb, (try rd.next(io)).?.payload);
    try testing.expect(handoff.probed);
    try testing.expect(handoff.probe_locked); // Segment 2 was held when segment 1 was closed.
    rd.check_invariants();
    try fx.expect_open_error(error.WouldBlock, tmp.dir, 4); // Still locked: no gap, no leak.
}

test "reader: an error from next releases the segment lock and leaves a valid reader" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{ pa, pb, pc });
    const cases = [_]struct { flip: u32, reads: u32, want: anyerror }{
        .{ .flip = f2_offset + 17, .reads = 1, .want = error.ChecksumMismatch },
        .{ .flip = f3_offset + 17, .reads = 2, .want = error.TornWrite },
    };
    for (cases) |case| {
        image[case.flip] ^= 1;
        try sfx.put_file(tmp.dir, 1, image[0..len], len);
        image[case.flip] ^= 1;
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 4);
        defer rd.deinit(testing.io, testing.allocator);

        for (0..case.reads) |_| _ = (try rd.next(testing.io)).?;
        try fx.expect_open_error(error.WouldBlock, tmp.dir, 4); // Held while reading.
        try fx.expect_next_error(&rd, case.want);
        rd.check_invariants();
        var other: Reader = undefined;
        try fx.open_ok(&other, tmp.dir, 4); // The failed reader no longer holds the lock.
        other.deinit(testing.io, testing.allocator);
    }
}

test "reader: a failed crossing releases the lock of the segment it left behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
    _ = try fx.put_segment(tmp.dir, 2, end - 1, &.{pb}); // Starts inside the first segment.

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 4);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    try fx.expect_next_error(&rd, error.Corrupted);
    rd.check_invariants();
    var other: Reader = undefined;
    try fx.open_ok(&other, tmp.dir, 4);
    other.deinit(testing.io, testing.allocator);
}
