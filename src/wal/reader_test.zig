//! Contract tests for `Reader` (ADR-0003 sections 1, 5 and 8), layout half: listing, index and
//! first-LSN continuity, header handling per segment position, limits and locking. Frame-level
//! damage, the look-ahead, crash cuts, allocation and faults are in `reader_tail_test.zig`;
//! shared helpers are in `reader_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const frame = @import("frame.zig");
const fx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");

const Reader = fx.Reader;
const Lsn = fx.Lsn;
const pa = fx.pa;
const pb = fx.pb;
const pc = fx.pc;
const header_size = fx.header_size;
const lsn_last = sfx.lsn_last;

test "reader: the golden segment reads back, then clean EOF forever" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sfx.put_file(tmp.dir, 1, &sfx.golden_segment, sfx.golden_segment.len);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, "strata");
    const second = (try rd.next(testing.io)).?;
    try testing.expectEqual(@as(Lsn, 24), second.lsn);
    try testing.expectEqual(frame.Type.checkpoint, second.frame_type);
    try testing.expectEqual(@as(usize, 8), second.payload.len);
    try testing.expectEqual(@as(u64, 24), std.mem.readInt(u64, second.payload[0..8], .little));
    try fx.expect_eof(&rd);
    try fx.expect_eof(&rd); // EOF is sticky.
    try fx.expect_position(&rd, 1, sfx.golden_segment.len, 49);
}

test "reader: frames come back in order across rotation boundaries" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const second_lsn = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    const third_lsn = try fx.put_segment(tmp.dir, 2, second_lsn, &.{pc});
    const end = try fx.put_segment(tmp.dir, 3, third_lsn, &.{ pa, pc });

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    var lsn: Lsn = 1;
    for ([_][]const u8{ pa, pb, pc, pa, pc }) |payload| {
        try fx.expect_record(&rd, lsn, payload);
        lsn += fx.frame_size(payload.len);
    }
    try testing.expectEqual(end, lsn);
    try fx.expect_eof(&rd);
    const len: u64 = header_size + fx.frame_size(pa.len) + fx.frame_size(pc.len);
    try fx.expect_position(&rd, 3, len, end);
}

test "reader: a non-newest segment without frames is Corrupted, its first LSN does not grow" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const next_lsn = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
    const end = try fx.put_segment(tmp.dir, 2, next_lsn, &.{});
    _ = try fx.put_segment(tmp.dir, 3, end, &.{pb});
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);

    try tmp.dir.deleteFile(testing.io, &sfx.name_of(3)); // As the newest it is just a log end.
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    try fx.expect_eof(&rd);
    try fx.expect_position(&rd, 2, header_size, next_lsn);
}

test "reader: an empty directory is an empty log and other names are ignored" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 1);
    try fx.expect_eof(&rd);
    try fx.expect_position(&rd, 0, 0, 0);
    rd.deinit(testing.io, testing.allocator);

    const strays = [_][]const u8{ "notes.txt", "wal-0000000A.log", "wal-0001.log", "x.log.tmp" };
    for (strays) |name| (try tmp.dir.createFile(testing.io, name, .{})).close(testing.io);
    try fx.open_ok(&rd, tmp.dir, 1); // Strays do not count against `segments_max`.
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_eof(&rd);
    try fx.expect_position(&rd, 0, 0, 0);
}

test "reader: a single segment with no frames is clean EOF at its first LSN" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try fx.put_segment(tmp.dir, 1, 7, &.{});

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 1);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_eof(&rd);
    try fx.expect_position(&rd, 1, header_size, 7);
}

test "reader: a log may start above segment 1 after reclaim" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const next_lsn = try fx.put_segment(tmp.dir, 5, 1000, &.{pa});
    _ = try fx.put_segment(tmp.dir, 6, next_lsn, &.{pb});

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 2);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1000, pa);
    try fx.expect_record(&rd, next_lsn, pb);
    try fx.expect_eof(&rd);
}

test "reader: a hole in the segment indices is Corrupted, however it is shaped" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const next_lsn = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
    _ = try fx.put_segment(tmp.dir, 3, next_lsn, &.{pb});
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);

    _ = try fx.put_segment(tmp.dir, 2, next_lsn, &.{}); // Fill the hole: now it opens.
    _ = try fx.put_segment(tmp.dir, 5, next_lsn, &.{pb}); // A new hole at 4.
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
}

test "reader: newest segment Unwritten or torn is absent, anywhere else it is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    const len: u64 = header_size + fx.frame_size(pa.len) + fx.frame_size(pb.len);

    var torn_header: [10]u8 = undefined;
    @memcpy(&torn_header, sfx.golden_header[0..10]);
    const newest_cases = [_][]const u8{ &.{}, &torn_header };
    for (newest_cases, 0..) |bytes, i| {
        try sfx.put_file(tmp.dir, 2, bytes, if (i == 0) 0 else bytes.len);
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 8);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_record(&rd, 1 + fx.frame_size(pa.len), pb);
        try fx.expect_eof(&rd);
        try fx.expect_position(&rd, 1, len, end);
    }
    try sfx.put_file(tmp.dir, 2, &.{}, 4096); // Zero through and through: still Unwritten.
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    rd.deinit(testing.io, testing.allocator);

    // The same files below a valid segment are damage, not a crash artefact.
    _ = try fx.put_segment(tmp.dir, 3, end, &.{pc});
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
    try sfx.put_file(tmp.dir, 2, &torn_header, torn_header.len);
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
}

test "reader: an absent newest segment above 1 needs its predecessor" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try sfx.put_file(tmp.dir, 2, &.{}, 0);
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
    try sfx.put_file(tmp.dir, 2, sfx.golden_header[0..10], 10);
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);

    try sfx.put_file(tmp.dir, 1, &.{}, 0); // Segment 1 alone is an empty log...
    try tmp.dir.deleteFile(testing.io, &sfx.name_of(2));
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_eof(&rd);
    try fx.expect_position(&rd, 0, 0, 0);
}

test "reader: header damage is typed at open, newest or not" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [4096]u8 = undefined;
    const len = fx.build(&image, 1, 1, &.{pa});

    image[20] ^= 1; // first_lsn byte: checksum no longer matches
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try fx.expect_open_error(error.ChecksumMismatch, tmp.dir, 8);
    image[20] ^= 1;

    image[0] ^= 1; // magic
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
    image[0] ^= 1;

    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    _ = try fx.put_segment(tmp.dir, 2, fx.end_lsn(1, len), &.{pb});
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    rd.deinit(testing.io, testing.allocator);

    image[13] ^= 0x80; // the damaged header is now a non-newest one
    try sfx.put_file(tmp.dir, 1, image[0..len], len);
    try fx.expect_open_error(error.ChecksumMismatch, tmp.dir, 8);
}

test "reader: first LSN must increase and fit the bytes of the previous segment" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 100, &.{ pa, pb });
    const len: u64 = header_size + fx.frame_size(pa.len) + fx.frame_size(pb.len);
    try testing.expectEqual(fx.end_lsn(100, len), end);

    const bad_starts = [_]Lsn{ 1, 99, 100, end + 1, end + 100_000, lsn_last };
    for (bad_starts) |first_lsn| {
        _ = try fx.put_segment(tmp.dir, 2, first_lsn, &.{pc});
        try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
    }
}

test "reader: a first LSN that is not the end of the previous frames is Corrupted on crossing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const end = try fx.put_segment(tmp.dir, 1, 1, &.{ pa, pb });
    const wrong_starts = [_]Lsn{ 24, end - 1 }; // Both lie inside the first segment's bytes.
    for (wrong_starts) |first_lsn| {
        _ = try fx.put_segment(tmp.dir, 2, first_lsn, &.{pc});
        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, 8);
        defer rd.deinit(testing.io, testing.allocator);

        try fx.expect_record(&rd, 1, pa);
        try fx.expect_record(&rd, 1 + fx.frame_size(pa.len), pb);
        try fx.expect_next_error(&rd, error.Corrupted);
    }
    _ = try fx.put_segment(tmp.dir, 2, end, &.{pc}); // The right start crosses cleanly.
    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, 1, pa);
    try fx.expect_record(&rd, 1 + fx.frame_size(pa.len), pb);
    try fx.expect_record(&rd, end, pc);
}

test "reader: a header first_lsn of 0 or 2^63 is Corrupted at open, first segment or later" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const bad_lsns = [_]Lsn{ 0, frame.lsn_limit, std.math.maxInt(u64) };
    for (bad_lsns) |first_lsn| {
        const first = sfx.forge(sfx.canonical(1, first_lsn), 1);
        try sfx.put_file(tmp.dir, 1, &first, first.len);
        try fx.expect_open_error(error.Corrupted, tmp.dir, 8);

        _ = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
        const second = sfx.forge(sfx.canonical(2, first_lsn), 2);
        try sfx.put_file(tmp.dir, 2, &second, second.len);
        try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
        try tmp.dir.deleteFile(testing.io, &sfx.name_of(2));
    }
}

test "reader: an LSN that reaches 2^63 inside a segment is Corrupted, not a crash" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var image: [256]u8 = undefined;
    const len = fx.build(&image, 1, lsn_last, &.{pa});
    @memset(image[len..][0..40], 0x5a); // Junk where the frame at LSN 2^63 + 21 would start.
    try sfx.put_file(tmp.dir, 1, image[0 .. len + 40], len + 40);

    var rd: Reader = undefined;
    try fx.open_ok(&rd, tmp.dir, 8);
    defer rd.deinit(testing.io, testing.allocator);

    try fx.expect_record(&rd, lsn_last, pa);
    try fx.expect_next_error(&rd, error.Corrupted);
}

test "reader: segments_max boundary, max opens and max + 1 is SegmentLimit" {
    for ([_]u32{ 1, 2, 3 }) |segments_max| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();
        var lsn: Lsn = 1;
        for (1..segments_max + 1) |index| {
            lsn = try fx.put_segment(tmp.dir, @intCast(index), lsn, &.{pa});
        }

        var rd: Reader = undefined;
        try fx.open_ok(&rd, tmp.dir, segments_max);
        for (0..segments_max) |_| _ = (try rd.next(testing.io)).?;
        try fx.expect_eof(&rd);
        rd.deinit(testing.io, testing.allocator);

        _ = try fx.put_segment(tmp.dir, segments_max + 1, lsn, &.{pa});
        try fx.expect_open_error(error.SegmentLimit, tmp.dir, segments_max);
        try fx.expect_open_error(error.SegmentLimit, tmp.dir, 1);
    }
}

test "reader: a segment name with index 0 is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try fx.put_segment(tmp.dir, 1, 1, &.{pa});
    (try tmp.dir.createFile(testing.io, "wal-00000000.log", .{})).close(testing.io);
    try fx.expect_open_error(error.Corrupted, tmp.dir, 8);
}

test "reader: the open reader holds the segment lock until EOF or deinit" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    _ = try fx.put_segment(tmp.dir, 1, 1, &.{pa});

    var first: Reader = undefined;
    try fx.open_ok(&first, tmp.dir, 8);
    try fx.expect_open_error(error.WouldBlock, tmp.dir, 8);
    try fx.expect_record(&first, 1, pa);
    try fx.expect_open_error(error.WouldBlock, tmp.dir, 8);
    try fx.expect_eof(&first); // Clean EOF releases the file.

    var second: Reader = undefined;
    try fx.open_ok(&second, tmp.dir, 8);
    try fx.expect_open_error(error.WouldBlock, tmp.dir, 8);
    second.deinit(testing.io, testing.allocator);
    first.deinit(testing.io, testing.allocator);

    var third: Reader = undefined;
    try fx.open_ok(&third, tmp.dir, 8);
    third.deinit(testing.io, testing.allocator);
}
