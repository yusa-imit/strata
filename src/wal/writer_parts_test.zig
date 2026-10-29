//! Contract tests for `Writer.append_parts` (plan 005 item 9): a gather append is the same as
//! `append` of the concatenated parts, byte for byte, error for error, rotation included. Two
//! logs get the same frame script, one through `append`, one through `append_parts`, and must
//! agree on every result, every writer position and every frame read back.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const frame = @import("frame.zig");
const fx = @import("writer_fixtures.zig");
const rfx = @import("reader_fixtures.zig");

const Writer = fx.Writer;

const segments_max: u32 = 64;
const segment_bytes_small: u64 = 4096;
const page_size: u32 = 512;
const frames_max: u32 = 64;

/// One scripted frame: its type and the parts of its payload.
const Case = struct { frame_type: frame.Type, parts: []const []const u8 };

/// A `page_images` payload for page 1 at `page_size`, in a fresh heap buffer. Owned.
fn images_payload() ![]u8 {
    assert(header.page_size_valid(page_size));
    assert(frame.images_prefix_size == 8);
    const payload = try testing.allocator.alloc(u8, 8 + 4 + page_size);
    @memset(payload, 0);
    std.mem.writeInt(u32, payload[0..4], 1, .little);
    std.mem.writeInt(u32, payload[4..8], page_size, .little);
    std.mem.writeInt(u32, payload[8..12], 1, .little);
    header.encode(payload[12..], @enumFromInt(1), .{ .page_type = .btree_leaf, .lsn = 1 });
    return payload;
}

/// Runs `cases` against two fresh logs and compares results, positions and read-back frames.
fn expect_same(segment_bytes_max: u64, cases: []const Case) !void {
    assert(cases.len >= 1);
    assert(cases.len <= frames_max);
    var tmp_whole = testing.tmpDir(.{ .iterate = true });
    defer tmp_whole.cleanup();

    var tmp_parts = testing.tmpDir(.{ .iterate = true });
    defer tmp_parts.cleanup();

    { // The writers hold the segment locks: close them before the readers open.
        var whole: Writer = undefined;
        try fx.open_ok(&whole, tmp_whole.dir, fx.opts(segments_max, segment_bytes_max));
        defer whole.deinit(testing.io, testing.allocator);

        var gather: Writer = undefined;
        try fx.open_ok(&gather, tmp_parts.dir, fx.opts(segments_max, segment_bytes_max));
        defer gather.deinit(testing.io, testing.allocator);

        for (cases) |case| {
            const joined = try std.mem.concat(testing.allocator, u8, case.parts);
            defer testing.allocator.free(joined);

            const want = whole.append(testing.io, case.frame_type, joined);
            const got = gather.append_parts(testing.io, case.frame_type, case.parts);
            if (want) |lsn| try testing.expectEqual(lsn, try got) else |err| {
                try testing.expectError(err, got);
            }
            try testing.expectEqual(whole.position(), gather.position());
            try testing.expectEqual(whole.last_lsn, gather.last_lsn);
            whole.check_invariants();
            gather.check_invariants();
        }
        try whole.sync(testing.io);
        try gather.sync(testing.io);
    }
    try expect_logs_equal(tmp_whole.dir, tmp_parts.dir);
}

fn expect_logs_equal(left: std.Io.Dir, right: std.Io.Dir) !void {
    assert(segments_max >= 1);
    assert(frames_max >= 1);
    var rd_left: rfx.Reader = undefined;
    try rfx.open_ok(&rd_left, left, segments_max);
    defer rd_left.deinit(testing.io, testing.allocator);

    var rd_right: rfx.Reader = undefined;
    try rfx.open_ok(&rd_right, right, segments_max);
    defer rd_right.deinit(testing.io, testing.allocator);

    for (0..frames_max) |_| {
        const a = try rd_left.next(testing.io);
        const b = try rd_right.next(testing.io);
        if (a == null) return try testing.expect(b == null);
        try testing.expectEqual(a.?.lsn, b.?.lsn);
        try testing.expectEqual(a.?.frame_type, b.?.frame_type);
        try testing.expectEqualSlices(u8, a.?.payload, b.?.payload);
    } else return error.TestUnexpectedResult; // The scripts are shorter than `frames_max`.
}

test "append_parts: records split at every boundary equal the concatenation" {
    const text = "alpha bravo charlie";
    const cases = [_]Case{
        .{ .frame_type = .record, .parts = &.{text} },
        .{ .frame_type = .record, .parts = &.{ "alpha", " bravo", " charlie" } },
        .{ .frame_type = .record, .parts = &.{ "", "alpha", "", "", "x", "" } },
        .{ .frame_type = .record, .parts = &.{ text[0..1], text[1..] } },
        .{ .frame_type = .record, .parts = &.{ text[0..18], text[18..] } },
        .{ .frame_type = .record, .parts = &.{fx.pa} },
    };
    try expect_same(1 << 20, &cases);
}

test "append_parts: no parts and only empty parts are an empty payload like append" {
    const cases = [_]Case{
        .{ .frame_type = .record, .parts = &.{} },
        .{ .frame_type = .record, .parts = &.{""} },
        .{ .frame_type = .record, .parts = &.{ "", "" } },
        .{ .frame_type = .page_image, .parts = &.{} }, // Invalid: needs a page size.
        .{ .frame_type = .page_images, .parts = &.{ "", "" } }, // Invalid: needs a prefix.
        .{ .frame_type = .record, .parts = &.{"after"} }, // The writer is unchanged by errors.
    };
    try expect_same(1 << 20, &cases);
}

test "append_parts: a page_images payload split anywhere is accepted, a broken one is not" {
    const payload = try images_payload();
    defer testing.allocator.free(payload);

    const broken = try testing.allocator.dupe(u8, payload);
    defer testing.allocator.free(broken);

    broken[8] = 0; // Page id 0.
    const images: frame.Type = .page_images;
    const cases = [_]Case{
        .{ .frame_type = images, .parts = &.{payload} },
        .{ .frame_type = images, .parts = &.{ payload[0..8], payload[8..12], payload[12..] } },
        .{ .frame_type = images, .parts = &.{ payload[0..3], payload[3..300], payload[300..] } },
        .{ .frame_type = images, .parts = &.{ broken[0..8], broken[8..] } },
        .{ .frame_type = images, .parts = &.{ payload[0 .. payload.len - 1], "" } },
        .{ .frame_type = .record, .parts = &.{ broken[0..8], broken[8..] } },
    };
    try expect_same(1 << 20, &cases);
}

test "append_parts: rotation and a payload over the limit behave like append" {
    const big = try testing.allocator.alloc(u8, frame.payload_bytes_max);
    defer testing.allocator.free(big);

    @memset(big, 0xA5);
    const part = fx.payload_of(3, 1000);
    const cases = [_]Case{
        .{ .frame_type = .record, .parts = &.{ part, part, part } },
        .{ .frame_type = .record, .parts = &.{ part, part, part } }, // Rotates here.
        .{ .frame_type = .record, .parts = &.{ part, part } },
        .{ .frame_type = .record, .parts = &.{ big[0..10], big[10..] } }, // The limit exactly.
        .{ .frame_type = .record, .parts = &.{ big, "x" } }, // One byte over: PayloadTooLarge.
        .{ .frame_type = .record, .parts = &.{ big, big } }, // Sum beyond the limit.
        .{ .frame_type = .record, .parts = &.{"end"} },
    };
    try expect_same(segment_bytes_small, &cases);
}

test "append_parts: a latched writer refuses before looking at the parts" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var w: Writer = undefined;
    try fx.open_ok(&w, tmp.dir, fx.opts(segments_max, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    w.failed = true;
    try testing.expectError(error.Failed, w.append_parts(testing.io, .record, &.{"x"}));
    try testing.expectError(error.Failed, w.append_parts(testing.io, .record, &.{}));
    try testing.expectEqual(@as(frame.Lsn, 0), w.last_lsn);
}
