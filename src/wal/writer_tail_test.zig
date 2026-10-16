//! Contract tests for `Writer.init` on logs that already exist (ADR-0003 sections 8 and 9): the
//! torn-tail refusal (`RecoveryRequired`), `CrashSink` cut sweeps, a newest segment that was
//! being created, damage that must not be mistaken for a torn tail, and a zero tail. Behaviour,
//! rotation and limits are in `writer_test.zig`; shared helpers are in `writer_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const crash = @import("../testing/crash.zig");
const writer_mod = @import("writer.zig");
const fx = @import("writer_fixtures.zig");
const rfx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");

const Writer = fx.Writer;
const Lsn = fx.Lsn;
const pa = fx.pa;
const pb = fx.pb;
const pc = fx.pc;
const header_size = fx.header_size;

/// Offsets and LSNs of the frames of the 3-frame segment `[pa, pb, pc]` from first LSN 1.
const f2_offset: u32 = header_size + 22;
const f3_offset: u32 = f2_offset + 24;
const f3_end: u32 = f3_offset + 24;
const f2_lsn: Lsn = 1 + 22;
const f3_lsn: Lsn = f2_lsn + 24;

comptime {
    assert(f3_end == header_size + 17 + pa.len + 17 + pb.len + 17 + pc.len);
    assert(f3_lsn == 47);
}

test "writer: every crash cut of a 3-frame segment continues cleanly or needs recovery" {
    var image: [256]u8 = undefined;
    const len = rfx.build(&image, 1, 1, &.{ pa, pb, pc });
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
            const persisted = try sink.persisted_into(&out);
            try sfx.put_file(tmp.dir, 1, persisted, persisted.len);
            try check_cut(tmp.dir, cut, n);
        }
    }
}

/// What `Writer.init` must do with the file left by `cut` at byte `n` of the 3-frame segment.
fn check_cut(dir: Io.Dir, cut: crash.Cut, n: u64) !void {
    assert(n <= f3_end);
    assert(f3_end < crash.sector_size); // One sector: a torn cut garbles everything after it.
    const options = fx.opts(2, 1 << 20);
    if (n > 0 and n < header_size) { // A partial header: never silently rewritten.
        switch (cut) {
            .truncate => return fx.expect_open_error(error.RecoveryRequired, dir, options),
            .torn => return expect_open_error_in(dir, options, &.{
                error.Corrupted,
                error.ChecksumMismatch,
            }),
        }
    }
    const ends = [_]u64{ f2_offset, f3_offset, f3_end };
    const lsns = [_]Lsn{ f2_lsn, f3_lsn, f3_lsn + 24 };
    var frames_whole: usize = 0;
    for (ends) |end| frames_whole += @intFromBool(n >= end);
    const boundary = n == header_size or n == f2_offset or n == f3_offset or n == f3_end;
    const clean = switch (cut) {
        .truncate => boundary or n == 0,
        .torn => n == 0 or n >= f3_end,
    };
    if (!clean) return fx.expect_open_error(error.RecoveryRequired, dir, options);

    const next_lsn: Lsn = if (frames_whole == 0) 1 else lsns[frames_whole - 1];
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, dir, options);
        defer w.deinit(testing.io, testing.allocator);

        const offset = if (n == 0) header_size else offset_of(frames_whole);
        try fx.expect_position(&w, 1, offset, next_lsn);
        try testing.expectEqual(durable_of(frames_whole), w.durable_lsn);
        try testing.expectEqual(next_lsn, try fx.append_ok(&w, pa));
    }
    const all = [_]Lsn{ 1, f2_lsn, f3_lsn };
    const payloads = [_][]const u8{ pa, pb, pc };
    var want_lsns: [4]Lsn = undefined;
    var want: [4][]const u8 = undefined;
    @memcpy(want_lsns[0..frames_whole], all[0..frames_whole]);
    @memcpy(want[0..frames_whole], payloads[0..frames_whole]);
    want_lsns[frames_whole] = next_lsn;
    want[frames_whole] = pa;
    try fx.expect_log(dir, 2, want_lsns[0 .. frames_whole + 1], want[0 .. frames_whole + 1]);
}

fn durable_of(frames_whole: usize) Lsn {
    assert(frames_whole <= 3);
    assert(f3_lsn > f2_lsn);
    const last = [_]Lsn{ 0, 1, f2_lsn, f3_lsn };
    return last[frames_whole];
}

fn offset_of(frames_whole: usize) u64 {
    assert(frames_whole <= 3);
    assert(f3_end > f3_offset);
    const ends = [_]u64{ header_size, f2_offset, f3_offset, f3_end };
    return ends[frames_whole];
}

/// `Writer.init` fails with one of `wanted`.
fn expect_open_error_in(
    dir: Io.Dir,
    options: writer_mod.Options,
    wanted: []const anyerror,
) !void {
    assert(wanted.len >= 1);
    assert(options.segments_max >= 1);
    var w: Writer = undefined;
    if (Writer.init(&w, testing.io, testing.allocator, dir, options)) |_| {
        w.deinit(testing.io, testing.allocator);
        return error.TestExpectedOpenError;
    } else |err| {
        for (wanted) |want| if (err == want) return;
        return err;
    }
}

test "writer: an Unwritten newest segment is rewritten where the log ends" {
    for ([_]u64{ 0, 24, 100, 5000 }) |zeros| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        const second = try rfx.put_segment(tmp.dir, 1, 1, &.{pa});
        try sfx.put_file(tmp.dir, 2, "", zeros);
        {
            var w: Writer = undefined;
            try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
            defer w.deinit(testing.io, testing.allocator);

            try fx.expect_position(&w, 2, header_size, second);
            try testing.expectEqual(@as(Lsn, 1), w.durable_lsn); // pa, read back, is durable.
            try testing.expectEqual(second, try fx.append_ok(&w, pb));
        }
        try fx.expect_log(tmp.dir, 4, &.{ 1, second }, &.{ pa, pb });
        try sfx.expect_open_ok(tmp.dir, 2, second);
    }
}

test "writer: an Unwritten segment 1 is rewritten at LSN 1" {
    for ([_]u64{ 0, 24, 777 }) |zeros| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        try sfx.put_file(tmp.dir, 1, "", zeros);
        {
            var w: Writer = undefined;
            try fx.open_ok(&w, tmp.dir, fx.opts(1, 1 << 20));
            defer w.deinit(testing.io, testing.allocator);

            try fx.expect_position(&w, 1, header_size, 1);
            try testing.expectEqual(@as(Lsn, 1), try fx.append_ok(&w, pa));
        }
        try fx.expect_log(tmp.dir, 1, &.{1}, &.{pa});
    }
}

test "writer: a torn newest header is RecoveryRequired and the file is left as it was" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const second = try rfx.put_segment(tmp.dir, 1, 1, &.{pa});
    const header = sfx.header_of(2, second);
    for ([_]u64{ 1, 10, 23 }) |cut| {
        try sfx.put_file(tmp.dir, 2, header[0..cut], cut);
        try fx.expect_open_error(error.RecoveryRequired, tmp.dir, fx.opts(4, 1 << 20));
        const f = try sfx.raw_open(tmp.dir, 2);
        defer f.close(testing.io);

        try sfx.expect_length(f, cut);
        try fx.expect_open_error(error.RecoveryRequired, tmp.dir, fx.opts(4, 1 << 20));
    }
    try sfx.put_file(tmp.dir, 2, "", 0); // The same log with the segment emptied recovers.
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(4, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, 2, header_size, second);
}

test "writer: a hole before an unwritten newest segment is Corrupted, not rewritten" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try rfx.put_segment(tmp.dir, 1, 1, &.{pa});
    try sfx.put_file(tmp.dir, 3, "", 100);
    try fx.expect_open_error(error.Corrupted, tmp.dir, fx.opts(4, 1 << 20));
    try sfx.put_file(tmp.dir, 3, "", 0);
    try fx.expect_open_error(error.Corrupted, tmp.dir, fx.opts(4, 1 << 20));
}

test "writer: damage that is not a torn tail is a typed error, never RecoveryRequired" {
    var image: [256]u8 = undefined;
    const len = rfx.build(&image, 1, 1, &.{ pa, pb, pc });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const options = fx.opts(4, 1 << 20);

    image[f2_offset + 17] ^= 1; // A bad frame with a valid one after it: lost committed data.
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try fx.expect_open_error(error.ChecksumMismatch, tmp.dir, options);
    image[f2_offset + 17] ^= 1;
    image[8] ^= 1; // The segment header's index field.
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try fx.expect_open_error(error.ChecksumMismatch, tmp.dir, options);
    image[8] ^= 1;

    const second = rfx.end_lsn(1, f2_offset); // A torn frame in a segment that is not the newest.
    try sfx.put_file(tmp.dir, 1, image[0 .. f2_offset + 5], f2_offset + 5);
    _ = try rfx.put_segment(tmp.dir, 2, second, &.{pc});
    try fx.expect_open_error(error.Corrupted, tmp.dir, options);
    try tmp.dir.deleteFile(testing.io, &sfx.name_of(2));
    try sfx.put_file(tmp.dir, 1, image[0..len], len); // Healed: opens.
    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, options);
    defer w.deinit(testing.io, testing.allocator);

    try fx.expect_position(&w, 1, f3_end, f3_lsn + 24);
}

test "writer: a zero tail is unwritten space, appends overwrite it in place" {
    var image: [256]u8 = undefined;
    const len = rfx.build(&image, 1, 1, &.{ pa, pb, pc });
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const tail: u64 = 1000;
    try sfx.put_file(tmp.dir, 1, image[0..len], len + tail);
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, 1, f3_end, f3_lsn + 24);
        try testing.expectEqual(f3_lsn, w.durable_lsn);
        try testing.expectEqual(f3_lsn + 24, try fx.append_ok(&w, pa));
        try testing.expectEqual(f3_lsn, w.durable_lsn); // Written, not yet synced.
    }
    const f = try sfx.raw_open(tmp.dir, 1);
    defer f.close(testing.io);

    try sfx.expect_length(f, len + tail); // The file did not grow: the frame fit in the zeros.
    try fx.expect_log(tmp.dir, 2, &.{ 1, f2_lsn, f3_lsn, f3_lsn + 24 }, &.{ pa, pb, pc, pa });
}

test "writer: a zero tail too short for the next frame extends the file" {
    var image: [256]u8 = undefined;
    const len = rfx.build(&image, 1, 1, &.{pa});
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sfx.put_file(tmp.dir, 1, image[0..len], len + 5);
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(2, 1 << 20));
        defer w.deinit(testing.io, testing.allocator);

        _ = try fx.append_ok(&w, pb);
    }
    const f = try sfx.raw_open(tmp.dir, 1);
    defer f.close(testing.io);

    try sfx.expect_length(f, len + 24);
    try fx.expect_log(tmp.dir, 2, &.{ 1, 23 }, &.{ pa, pb });
}

test "writer: reopening with a smaller segment_bytes_max than the newest segment rotates" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var lsns: [11]Lsn = undefined;
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, 4096));
        defer w.deinit(testing.io, testing.allocator);

        for (0..10) |i| lsns[i] = try fx.append_ok(&w, fx.payload_of(i, 100));
    }
    {
        var w: Writer = undefined;
        try fx.open_ok(&w, tmp.dir, fx.opts(4, header_size + 117)); // Segment 1 is far past this.
        defer w.deinit(testing.io, testing.allocator);

        try fx.expect_position(&w, 1, header_size + 10 * 117, 1 + 10 * 117);
        lsns[10] = try fx.append_ok(&w, fx.payload_of(10, 100));
        try fx.expect_position(&w, 2, header_size + 117, 1 + 11 * 117);
        try testing.expectEqual(@as(Lsn, 1 + 10 * 117), lsns[10]);
    }
    var records: [11][]const u8 = undefined;
    for (&records, 0..) |*record, i| record.* = fx.payload_of(i, 100);
    try fx.expect_log(tmp.dir, 4, &lsns, &records);
}
