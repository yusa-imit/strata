//! Shared fixtures for the `segment.zig` contract tests (`segment_test.zig`,
//! `segment_file_test.zig`): the golden header and segment from ADR-0003 section 11, header
//! images forged field by field with no validation, an independent re-derivation of the section
//! 4 checksum, and raw `file.File` helpers that never go through `Segment`. Test-only; I/O goes
//! through `std.testing.io`, memory through `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const codec = @import("../codec.zig");
const file_mod = @import("../file/file.zig");
const frame = @import("frame.zig");
const s = @import("segment.zig");

pub const File = file_mod.File;
pub const Lsn = frame.Lsn;
pub const Segment = s.Segment;
pub const header_size = s.segment_header_size;

/// ADR-0003 section 11: segment 1, `first_lsn` 1.
pub const golden_header = [header_size]u8{
    0x53, 0x54, 0x57, 0x4c, // magic "STWL"
    0x01, 0x00, 0x00, 0x00, // format_version 1, reserved 0
    0x01, 0x00, 0x00, 0x00, // index 1
    0x38, 0xe5, 0xd5, 0xf9, // checksum 0xF9D5E538 (seed u64le 1)
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // first_lsn 1
};

/// ADR-0003 section 11: the whole 72-byte segment (header, `record` "strata", `checkpoint`).
pub const golden_segment = golden_header ++ [_]u8{
    0x06, 0x00, 0x00, 0x00, 0x2f, 0xb8, 0xbd, 0xa7, // len 6, crc
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn 1
    0x01, 0x73, 0x74, 0x72, 0x61, 0x74, 0x61, // record "strata"
    0x08, 0x00, 0x00, 0x00, 0x27, 0xb8, 0xc6, 0x43, // len 8, crc
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn 24
    0x03, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // checkpoint, redo_lsn 24
};

pub const indices_sample = [_]u32{
    1, 2, 255, 256, 0x01020304, 0x7fffffff, 0x80000000, 0xffffffff,
};
pub const lsn_last: Lsn = (1 << 63) - 1;
pub const lsns_sample = [_]Lsn{ 1, 2, 24, 0xffffffff, 1 << 32, lsn_last };
pub const policies = [_]file_mod.SyncPolicy{ .none, .fdatasync, .fsync, .full_fsync };

/// Header fields as a test controls them: no validation, any value.
pub const Fields = struct {
    magic: [4]u8,
    version: u16,
    reserved: u16,
    index: u32,
    first_lsn: u64,
};

pub fn canonical(index: u32, first_lsn: Lsn) Fields {
    assert(index >= 1);
    assert(header_size == 24);
    return .{
        .magic = "STWL".*,
        .version = 1,
        .reserved = 0,
        .index = index,
        .first_lsn = first_lsn,
    };
}

/// Lays `fields` out at the ADR offsets with the checksum field zero.
pub fn raw_layout(fields: Fields) [header_size]u8 {
    var out: [header_size]u8 = @splat(0);
    @memcpy(out[0..4], &fields.magic);
    std.mem.writeInt(u16, out[4..6], fields.version, .little);
    std.mem.writeInt(u16, out[6..8], fields.reserved, .little);
    std.mem.writeInt(u32, out[8..12], fields.index, .little);
    std.mem.writeInt(u64, out[16..24], fields.first_lsn, .little);
    assert(std.mem.readInt(u32, out[12..16], .little) == 0);
    assert(std.mem.readInt(u64, out[16..24], .little) == fields.first_lsn);
    return out;
}

/// ADR section 4, by hand: `u64le(seed_index) ++ header` with bytes 12..16 read as zero.
pub fn reference_checksum(image: *const [header_size]u8, seed_index: u32) u32 {
    assert(seed_index >= 1);
    assert(image.len == header_size);
    var scratch: [8 + header_size]u8 = @splat(0);
    std.mem.writeInt(u64, scratch[0..8], seed_index, .little);
    @memcpy(scratch[8..], image);
    @memset(scratch[20..24], 0); // image bytes 12..16, the stored checksum
    return codec.crc32c.checksum(&scratch);
}

/// A header image for `fields` whose stored checksum is seeded with `seed_index`.
pub fn forge(fields: Fields, seed_index: u32) [header_size]u8 {
    var out = raw_layout(fields);
    assert(seed_index >= 1);
    const sum = reference_checksum(&out, seed_index);
    std.mem.writeInt(u32, out[12..16], sum, .little);
    assert(std.mem.readInt(u32, out[12..16], .little) == sum);
    return out;
}

pub fn header_of(index: u32, first_lsn: Lsn) [header_size]u8 {
    assert(index >= 1);
    assert(first_lsn >= frame.lsn_first);
    var out: [header_size]u8 = @splat(0xAA);
    s.encode_header(&out, .{ .index = index, .first_lsn = first_lsn });
    assert(std.mem.eql(u8, out[0..4], &s.magic));
    return out;
}

pub fn name_of(index: u32) [s.name_size]u8 {
    assert(index >= 1);
    var out: [s.name_size]u8 = @splat(0);
    s.format_name(index, &out);
    assert(out[out.len - 1] == 'g');
    return out;
}

pub fn opts(policy: file_mod.SyncPolicy) s.Options {
    const options: s.Options = .{ .segments_max = 8, .sync_policy = policy };
    assert(options.segments_max >= 1);
    assert(options.sync_policy == policy);
    return options;
}

// ---------------------------------------------------------------------------------------------
// File helpers. Raw bytes go through `File` directly, never through `Segment`.
// ---------------------------------------------------------------------------------------------

/// Writes `bytes` at offset 0 of segment file `index`, then sets the length to `len`.
pub fn put_file(dir: Io.Dir, index: u32, bytes: []const u8, len: u64) !void {
    assert(len >= bytes.len);
    assert(len <= file_mod.offset_max);
    const name = name_of(index);
    const f = try File.open(testing.io, dir, &name, .{ .create = true, .truncate = true });
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, bytes, 0);
    try f.setLength(testing.io, len);
}

pub fn raw_open(dir: Io.Dir, index: u32) !File {
    assert(index >= 1);
    const name = name_of(index);
    const f = try File.open(testing.io, dir, &name, .{});
    assert(!f.direct);
    return f;
}

pub fn flip_bit(f: File, offset: u64, bit: u3) !void {
    assert(offset < file_mod.offset_max);
    assert(!f.direct);
    var byte: [1]u8 = undefined;
    try f.readAtAll(testing.io, &byte, offset);
    const before = byte[0];
    byte[0] ^= @as(u8, 1) << bit;
    assert(byte[0] != before);
    try f.writeAtAll(testing.io, &byte, offset);
}

pub fn expect_length(f: File, want: u64) !void {
    assert(want <= file_mod.offset_max);
    assert(!f.direct);
    try testing.expectEqual(want, try f.length(testing.io));
}

pub fn expect_open_error(want: anyerror, dir: Io.Dir, index: u32) !void {
    assert(index >= 1);
    try testing.expectError(want, Segment.open(testing.io, dir, index, opts(.none)));
}

/// Opens, checks the header fields, closes: proves a file is accepted and its lock is free.
pub fn expect_open_ok(dir: Io.Dir, index: u32, first_lsn: Lsn) !void {
    assert(index >= 1);
    assert(first_lsn >= frame.lsn_first);
    const seg = try Segment.open(testing.io, dir, index, opts(.none));
    defer seg.close(testing.io);

    try testing.expectEqual(index, seg.index);
    try testing.expectEqual(first_lsn, seg.first_lsn);
}

pub fn expect_file_bytes(f: File, want: []const u8) !void {
    assert(want.len > 0);
    assert(!f.direct);
    try expect_length(f, want.len);
    const got = try testing.allocator.alloc(u8, want.len);
    defer testing.allocator.free(got);

    try f.readAtAll(testing.io, got, 0);
    try testing.expectEqualSlices(u8, want, got);
}
