//! Shared fixtures for the `reader.zig` contract tests (`reader_test.zig`,
//! `reader_tail_test.zig`): hand-built segment images (header plus `record` frames), forged
//! frames whose checksum is valid for the position but whose other fields are not, and thin
//! wrappers that read frames back and compare. Raw file helpers come from
//! `segment_fixtures.zig`. Test-only; I/O goes through `std.testing.io`, memory through
//! `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const frame = @import("frame.zig");
const reader_mod = @import("reader.zig");
const fx = @import("segment_fixtures.zig");
const s = @import("segment.zig");

pub const Reader = reader_mod.Reader;
pub const Lsn = frame.Lsn;
pub const header_size = s.segment_header_size;

pub const pa = "alpha";
pub const pb = "bravo!!";
pub const pc = "charlie";
/// Size of the frame `record` with an `n` byte payload occupies.
pub fn frame_size(n: usize) u32 {
    assert(n <= frame.payload_bytes_max);
    return frame.frame_header_size + @as(u32, @intCast(n));
}

pub fn opts(segments_max: u32) s.Options {
    assert(segments_max >= 1);
    return .{ .segments_max = segments_max, .sync_policy = .none };
}

/// LSN one past the last byte of a segment image of `len` bytes that starts at `first_lsn`.
pub fn end_lsn(first_lsn: Lsn, len: u64) Lsn {
    assert(len >= header_size);
    assert(first_lsn >= frame.lsn_first);
    return first_lsn + (len - header_size);
}

/// Header plus one `record` frame per payload, LSNs counted from `first_lsn`; returns the image
/// length. `out` must be large enough.
pub fn build(out: []u8, index: u32, first_lsn: Lsn, payloads: []const []const u8) u32 {
    assert(index >= 1);
    assert(out.len >= header_size);
    @memset(out, 0);
    s.encode_header(out[0..header_size], .{ .index = index, .first_lsn = first_lsn });
    var used: u32 = header_size;
    var lsn = first_lsn;
    for (payloads) |payload| {
        const n = frame.encode(out[used..], lsn, .record, payload);
        used += n;
        lsn += n;
    }
    assert(used == header_size + total_size(payloads));
    return used;
}

fn total_size(payloads: []const []const u8) u32 {
    var total: u32 = 0;
    for (payloads) |payload| total += frame_size(payload.len);
    assert(total <= 4 << 20);
    return total;
}

/// Writes a built segment as file `index`; returns the end LSN, the next segment's `first_lsn`.
pub fn put_segment(
    dir: Io.Dir,
    index: u32,
    first_lsn: Lsn,
    payloads: []const []const u8,
) !Lsn {
    assert(index >= 1);
    assert(first_lsn >= frame.lsn_first);
    var image: [4096]u8 = undefined;
    const len = build(&image, index, first_lsn, payloads);
    try fx.put_file(dir, index, image[0..len], len);
    return end_lsn(first_lsn, len);
}

/// A `len + checksum + lsn + type + payload` frame at the start of `out`. The checksum is the
/// valid one for `expected_lsn`, so the frame is intact there whatever else it says.
pub fn forge_frame(
    out: []u8,
    expected_lsn: Lsn,
    stored_lsn: Lsn,
    type_byte: u8,
    payload: []const u8,
) u32 {
    const total = frame_size(payload.len);
    assert(out.len >= total);
    assert(expected_lsn >= frame.lsn_first);
    assert(expected_lsn < frame.lsn_limit);
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u64, out[8..16], stored_lsn, .little);
    out[16] = type_byte;
    @memcpy(out[frame.frame_header_size..][0..payload.len], payload);
    std.mem.writeInt(u32, out[4..8], frame.checksum(out[0..total], expected_lsn), .little);
    assert(frame.intact(out[0..total], expected_lsn));
    return total;
}

pub fn open_ok(rd: *Reader, dir: Io.Dir, segments_max: u32) !void {
    assert(segments_max >= 1);
    assert(segments_max <= 1024);
    try Reader.open(rd, testing.io, testing.allocator, dir, opts(segments_max));
    rd.check_invariants();
}

pub fn expect_open_error(want: anyerror, dir: Io.Dir, segments_max: u32) !void {
    assert(segments_max >= 1);
    assert(want != error.OutOfMemory);
    var rd: Reader = undefined;
    const got = Reader.open(&rd, testing.io, testing.allocator, dir, opts(segments_max));
    try testing.expectError(want, got);
}

pub fn expect_record(rd: *Reader, lsn: Lsn, payload: []const u8) !void {
    assert(lsn >= frame.lsn_first);
    assert(payload.len <= frame.payload_bytes_max);
    const got = (try rd.next(testing.io)) orelse return error.TestUnexpectedEof;
    try testing.expectEqual(lsn, got.lsn);
    try testing.expectEqual(frame.Type.record, got.frame_type);
    try testing.expectEqualSlices(u8, payload, got.payload);
    rd.check_invariants();
}

pub fn expect_eof(rd: *Reader) !void {
    assert(rd.entries.len >= 1);
    const got = try rd.next(testing.io);
    try testing.expectEqual(@as(?frame.Frame, null), got);
    rd.check_invariants();
}

pub fn expect_next_error(rd: *Reader, want: anyerror) !void {
    assert(rd.entries.len >= 1);
    assert(rd.state != .failed);
    assert(want != error.TestUnexpectedEof);
    try testing.expectError(want, rd.next(testing.io));
}

pub fn expect_position(rd: *const Reader, index: u32, offset: u64, lsn: Lsn) !void {
    assert(offset == 0 or offset >= header_size);
    assert(index != 0 or lsn == 0);
    const got = rd.position();
    try testing.expectEqual(index, got.segment_index);
    try testing.expectEqual(offset, got.offset);
    try testing.expectEqual(lsn, got.lsn);
}
