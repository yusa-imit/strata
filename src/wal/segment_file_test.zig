//! Contract tests for `Segment` files (ADR-0003 sections 2, 8 and 9): create, open, append,
//! lock and error paths in `std.testing.tmpDir` through `std.testing.io`, and create/open under
//! `FaultIo`. Names, the header codec and limits are in `segment_test.zig`; shared helpers and
//! the golden bytes are in `segment_fixtures.zig`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const page_header = @import("../page/header.zig");
const fault_io = @import("../testing/fault_io.zig");
const frame = @import("frame.zig");
const fx = @import("segment_fixtures.zig");
const s = @import("segment.zig");

const File = fx.File;
const Lsn = fx.Lsn;
const Segment = fx.Segment;
const header_size = fx.header_size;
const golden_header = fx.golden_header;
const golden_segment = fx.golden_segment;
const policies = fx.policies;
const lsn_last = fx.lsn_last;
const header_of = fx.header_of;
const name_of = fx.name_of;
const opts = fx.opts;
const put_file = fx.put_file;
const raw_open = fx.raw_open;
const flip_bit = fx.flip_bit;
const expect_length = fx.expect_length;
const expect_open_error = fx.expect_open_error;
const expect_open_ok = fx.expect_open_ok;
const expect_file_bytes = fx.expect_file_bytes;

// ---------------------------------------------------------------------------------------------
// Segment files (ADR sections 2, 8 and 9).
// ---------------------------------------------------------------------------------------------

test "segment: create, close, open round-trips for every sync policy" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    for (policies, 0..) |policy, i| {
        const index: u32 = @intCast(i + 1);
        const first_lsn: Lsn = 1 + @as(Lsn, index) * 100;
        const seg = try Segment.create(io, tmp.dir, index, first_lsn, opts(policy));
        try testing.expectEqual(index, seg.index);
        try testing.expectEqual(first_lsn, seg.first_lsn);
        try testing.expectEqual(policy, seg.file.sync_policy);
        try expect_length(seg.file, header_size);
        seg.close(io);

        const again = try Segment.open(io, tmp.dir, index, opts(policy));
        defer again.close(io);

        try testing.expectEqual(index, again.index);
        try testing.expectEqual(first_lsn, again.first_lsn);
        try testing.expectEqual(policy, again.file.sync_policy);
        try expect_length(again.file, header_size);
    }
}

test "segment: the file on disk is exactly the header and sits under the ADR name" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.fsync));
    seg.close(io);
    const raw = try raw_open(tmp.dir, 1);
    defer raw.close(io);

    try expect_file_bytes(raw, &golden_header);
    const by_literal = try File.open(io, tmp.dir, "wal-00000001.log", .{});
    by_literal.close(io);
}

test "segment: index 1, index 2^32-1, first_lsn 1 and first_lsn 2^63-1 all round-trip" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const cases = [_]struct { index: u32, first_lsn: Lsn }{
        .{ .index = 1, .first_lsn = 1 },
        .{ .index = 1, .first_lsn = lsn_last },
        .{ .index = 0xffffffff, .first_lsn = 1 },
        .{ .index = 0xffffffff, .first_lsn = lsn_last },
    };
    for (cases) |case| {
        const seg = try Segment.create(io, tmp.dir, case.index, case.first_lsn, opts(.none));
        seg.close(io);
        try expect_open_ok(tmp.dir, case.index, case.first_lsn);
        if (case.index == 0xffffffff) {
            const by_literal = try File.open(io, tmp.dir, "wal-ffffffff.log", .{});
            by_literal.close(io);
        }
        try tmp.dir.deleteFile(io, &name_of(case.index));
    }
}

test "segment: append writes the golden segment byte for byte and survives reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.fdatasync));
    var image: [64]u8 = undefined;
    const first_len = frame.encode(&image, 1, .record, "strata");
    try seg.append(io, image[0..first_len], header_size);
    try expect_length(seg.file, header_size + first_len);

    var redo: [8]u8 = undefined;
    std.mem.writeInt(u64, &redo, 24, .little);
    const second_len = frame.encode(&image, 24, .checkpoint, &redo);
    try seg.append(io, image[0..second_len], header_size + first_len);
    try seg.sync(io);
    try testing.expectEqual(@as(u64, golden_segment.len), try seg.length(io));
    seg.close(io);

    const raw = try raw_open(tmp.dir, 1);
    defer raw.close(io);

    try expect_file_bytes(raw, &golden_segment);
    try expect_open_ok(tmp.dir, 1, 1);
}

test "segment: append is positional — a gap reads as zeros and an overwrite stays in place" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 7, 5, opts(.none));
    defer seg.close(io);

    try seg.append(io, "ab", header_size);
    try seg.append(io, "cd", header_size + 6);
    try testing.expectEqual(@as(u64, header_size + 8), try seg.length(io));
    try seg.append(io, "XY", header_size + 1);
    var body: [8]u8 = undefined;
    try seg.file.readAtAll(io, &body, header_size);
    try testing.expectEqualSlices(u8, "aXY\x00\x00\x00cd", body[0..8]);
    try testing.expectEqual(@as(u64, header_size + 8), try seg.length(io));
    const head = header_of(7, 5);
    var back: [header_size]u8 = undefined;
    try seg.file.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, &head, &back); // frames never touch the header
}

test "segment: a second open of a held segment is WouldBlock, and a close frees it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const first = try Segment.create(io, tmp.dir, 1, 1, opts(.none));
    try expect_open_error(error.WouldBlock, tmp.dir, 1);
    try expect_open_error(error.WouldBlock, tmp.dir, 1); // the failed open released its handle
    first.close(io);

    const second = try Segment.open(io, tmp.dir, 1, opts(.none));
    try expect_open_error(error.WouldBlock, tmp.dir, 1);
    second.close(io);
    try expect_open_ok(tmp.dir, 1, 1);
}

test "segment: create is exclusive — an existing segment is PathAlreadyExists and untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 3, 77, opts(.none));
    try seg.append(io, "frame bytes", header_size);
    const before = try seg.length(io);
    try testing.expectError(
        error.PathAlreadyExists,
        Segment.create(io, tmp.dir, 3, 99, opts(.none)),
    );
    seg.close(io);
    try testing.expectError(
        error.PathAlreadyExists,
        Segment.create(io, tmp.dir, 3, 99, opts(.none)),
    );

    const raw = try raw_open(tmp.dir, 3);
    defer raw.close(io);

    try expect_length(raw, before);
    try expect_open_ok(tmp.dir, 3, 77); // first_lsn 77 survived both attempts
}

test "segment: open of a missing segment is FileNotFound and creates nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect_open_error(error.FileNotFound, tmp.dir, 1);
    try expect_open_error(error.FileNotFound, tmp.dir, 0xffffffff);
    const raw = tmp.dir.openFile(testing.io, "wal-00000001.log", .{});
    try testing.expectError(error.FileNotFound, raw);
}

test "segment: a foreign file under a segment name is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const text = "this is not a write-ahead log segment, just some text";
    try put_file(tmp.dir, 1, text, text.len);
    try expect_open_error(error.Corrupted, tmp.dir, 1);

    var page: [page_header.page_size_min]u8 = undefined;
    page_header.encode_file_header(&page, .{
        .page_size = page_header.page_size_min,
        .page_count = 1,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    try put_file(tmp.dir, 2, &page, page.len);
    try expect_open_error(error.Corrupted, tmp.dir, 2); // a page file, magic STRA, is not STWL
    try expect_open_error(error.Corrupted, tmp.dir, 2); // and the lock was released each time

    const ones: [header_size]u8 = @splat(0xff);
    try put_file(tmp.dir, 3, &ones, ones.len);
    try expect_open_error(error.Corrupted, tmp.dir, 3);
}

test "segment: zero-length, all-zero and short files are Unwritten or TornWrite" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try put_file(tmp.dir, 1, "", 0);
    try expect_open_error(error.Unwritten, tmp.dir, 1); // zero length
    try put_file(tmp.dir, 1, "", 1);
    try expect_open_error(error.Unwritten, tmp.dir, 1); // one zero byte, still "all zero"
    try put_file(tmp.dir, 1, "", header_size);
    try expect_open_error(error.Unwritten, tmp.dir, 1);
    try put_file(tmp.dir, 1, "", 3 * 4096 + 17);
    try expect_open_error(error.Unwritten, tmp.dir, 1); // preallocated: zeros up to the end

    const good = header_of(1, 1);
    for ([_]usize{ 1, 4, 12, 16, 23 }) |n| {
        try put_file(tmp.dir, 2, good[0..n], n);
        try expect_open_error(error.TornWrite, tmp.dir, 2);
    }
    const whole = header_of(2, 1);
    try put_file(tmp.dir, 2, &whole, whole.len);
    try expect_open_ok(tmp.dir, 2, 1); // the full 24 bytes are accepted
    try expect_open_error(error.Unwritten, tmp.dir, 1); // and file 1 is still unwritten
}

test "segment: an unwritten header followed by any non-zero byte is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const len: u64 = 10_001;
    const positions = [_]u64{ 24, 25, 100, 4095, 4096, 4097, 8191, 8192, 10_000 };
    for (positions) |at| {
        try put_file(tmp.dir, 1, "", len);
        const raw = try raw_open(tmp.dir, 1);
        defer raw.close(io);

        try raw.writeAtAll(io, "\x01", at);
        try expect_open_error(error.Corrupted, tmp.dir, 1);
        try raw.writeAtAll(io, "\x00", at);
        try expect_open_error(error.Unwritten, tmp.dir, 1);
    }
}

test "segment: a bit flip at any header byte of the file is a typed error" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 9, 1234, opts(.none));
    try seg.append(io, "payload", header_size);
    seg.close(io);
    const raw = try raw_open(tmp.dir, 9);
    defer raw.close(io);

    for (0..header_size) |byte| {
        for (0..8) |bit| {
            try flip_bit(raw, byte, @intCast(bit));
            const want: anyerror = if (byte < 6) error.Corrupted else error.ChecksumMismatch;
            try expect_open_error(want, tmp.dir, 9);
            try flip_bit(raw, byte, @intCast(bit)); // restored: must open again, lock released
        }
        try expect_open_ok(tmp.dir, 9, 1234);
    }
}

test "segment: a renamed segment is a ChecksumMismatch, never an accepted open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.none));
    seg.close(io);
    const raw = try raw_open(tmp.dir, 1);
    defer raw.close(io);

    var copy: [header_size]u8 = undefined;
    try raw.readAtAll(io, &copy, 0);
    for ([_]u32{ 2, 3, 0x10000, 0x80000001, 0xffffffff }) |other| {
        try put_file(tmp.dir, other, &copy, copy.len);
        try expect_open_error(error.ChecksumMismatch, tmp.dir, other);
    }
    try expect_open_ok(tmp.dir, 1, 1);
}

test "segment: a file longer than segment_bytes_limit is Corrupted, exactly the limit is not" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.none));
    try seg.file.setLength(io, s.segment_bytes_limit);
    seg.close(io);
    try expect_open_ok(tmp.dir, 1, 1);

    const raw = try raw_open(tmp.dir, 1);
    defer raw.close(io);

    try raw.setLength(io, s.segment_bytes_limit + 1);
    try expect_open_error(error.Corrupted, tmp.dir, 1);
    try raw.setLength(io, s.segment_bytes_limit);
    try expect_open_ok(tmp.dir, 1, 1);

    try put_file(tmp.dir, 2, "", s.segment_bytes_limit + 1); // zeros, but over the limit
    try expect_open_error(error.Corrupted, tmp.dir, 2);
}

test "segment: append reports a write error through the segment" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.none));
    seg.close(io);
    const name = name_of(1);
    const read_only = try File.open(io, tmp.dir, &name, .{ .mode = .read_only });
    defer read_only.close(io);

    const view: Segment = .{ .file = read_only, .index = 1, .first_lsn = 1 };
    try testing.expectError(error.NotOpenForWriting, view.append(io, "x", header_size));
    try expect_length(read_only, header_size); // nothing was written
}

// ---------------------------------------------------------------------------------------------
// Faults (FaultIo): create order and error paths.
// ---------------------------------------------------------------------------------------------

/// Builds `fio` in place over `std.testing.io` with the fault from call 0 on; `fio` must not move.
fn arm(fio: *fault_io.FaultIo, write: fault_io.Fault, read: fault_io.Fault) Io {
    fault_io.FaultIo.init(fio, testing.io, .{ .write = write, .read = read, .after_calls = 0 });
    assert(fio.write_calls == 0);
    assert(fio.read_calls == 0);
    return fio.io();
}

test "segment: a failed header write fails create and leaves an Unwritten file behind" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    const io = arm(&fio, .canceled, .none);

    const result = Segment.create(io, tmp.dir, 1, 1, opts(.fsync));
    try testing.expectError(error.Canceled, result);
    try testing.expectEqual(@as(u32, 1), fio.write_calls);
    try expect_open_error(error.Unwritten, tmp.dir, 1); // ADR section 8: crash during creation
    try testing.expectError(
        error.PathAlreadyExists,
        Segment.create(testing.io, tmp.dir, 1, 1, opts(.none)),
    );
}

test "segment: a write that accepts no bytes is NoSpaceLeft from create and from append" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    const io_zero = arm(&fio, .zero, .none);
    try testing.expectError(error.NoSpaceLeft, Segment.create(io_zero, tmp.dir, 1, 1, opts(.none)));

    const seg = try Segment.create(testing.io, tmp.dir, 2, 1, opts(.none));
    defer seg.close(testing.io);

    var gated: fault_io.FaultIo = undefined;
    const io_gated = arm(&gated, .zero, .none);
    try testing.expectError(error.NoSpaceLeft, seg.append(io_gated, "frame", header_size));
    try expect_length(seg.file, header_size);
}

test "segment: one-byte writes still produce the canonical header and golden frames" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: fault_io.FaultIo = undefined;
    const io = arm(&fio, .{ .short = 1 }, .none);

    const seg = try Segment.create(io, tmp.dir, 1, 1, opts(.none));
    defer seg.close(io);

    try testing.expectEqual(@as(u32, header_size), fio.write_calls);
    const body = golden_segment[header_size..];
    try seg.append(io, body, header_size);
    try seg.sync(io);
    try expect_file_bytes(seg.file, &golden_segment);
}

test "segment: a failed header read fails open with the error and releases the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const seg = try Segment.create(testing.io, tmp.dir, 1, 1, opts(.none));
    seg.close(testing.io);

    var fio: fault_io.FaultIo = undefined;
    const io = arm(&fio, .none, .canceled);
    try testing.expectError(error.Canceled, Segment.open(io, tmp.dir, 1, opts(.none)));
    try testing.expectEqual(@as(u32, 1), fio.read_calls);
    try expect_open_ok(tmp.dir, 1, 1);
}

test "segment: a zero-progress header read is TornWrite, never a hang" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const seg = try Segment.create(testing.io, tmp.dir, 1, 1, opts(.none));
    seg.close(testing.io);

    var fio: fault_io.FaultIo = undefined;
    const io = arm(&fio, .none, .zero);
    const result = Segment.open(io, tmp.dir, 1, opts(.none));
    try testing.expectError(error.TornWrite, result);
    try expect_open_ok(tmp.dir, 1, 1);
}
