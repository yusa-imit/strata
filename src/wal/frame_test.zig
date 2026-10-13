//! Contract tests for `frame.zig` (ADR-0003 sections 3, 4, 6, 7 and 11), kept in their own file
//! like `page/header_test.zig`.
//!
//! Every expected value is derived independently of the codec: `reference_checksum` rebuilds the
//! ADR section 4 byte string by hand, `raw_frame` writes frames field by field without any
//! validation (so invalid-but-well-checksummed frames can be forged), and the golden frames are
//! committed hex literals copied from ADR section 11.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const codec = @import("../codec.zig");
const f = @import("frame.zig");

const Lsn = f.Lsn;
const Type = f.Type;
const frame_header_size = f.frame_header_size;
const frame_bytes_max = f.frame_bytes_max;
const payload_bytes_max = f.payload_bytes_max;

/// ADR-0003 section 11, frame 1: `record` "strata" at LSN 1.
const golden_record = [_]u8{
    0x06, 0x00, 0x00, 0x00, // len 6
    0x2f, 0xb8, 0xbd, 0xa7, // crc 0xA7BDB82F (seed u64le 1)
    0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn 1
    0x01, // type record
    0x73, 0x74, 0x72, 0x61, 0x74, 0x61, // "strata"
};

/// ADR-0003 section 11, frame 2: `checkpoint` with redo_lsn 24 at LSN 24.
const golden_checkpoint = [_]u8{
    0x08, 0x00, 0x00, 0x00, // len 8
    0x27, 0xb8, 0xc6, 0x43, // crc 0x43C6B827 (seed u64le 24)
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn 24
    0x03, // type checkpoint
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // redo_lsn 24
};

/// Independent re-derivation of ADR section 4: `u64le(lsn_seed) ++ frame` with the stored
/// checksum field (frame bytes 4..8) zeroed, hashed in one shot.
fn reference_checksum(gpa: std.mem.Allocator, frame: []const u8, lsn_seed: Lsn) !u32 {
    assert(frame.len >= frame_header_size);
    assert(frame.len <= frame_bytes_max);
    const scratch = try gpa.alloc(u8, 8 + frame.len);
    defer gpa.free(scratch);

    std.mem.writeInt(u64, scratch[0..8], lsn_seed, .little);
    @memcpy(scratch[8..], frame);
    @memset(scratch[12..16], 0);
    return codec.crc32c.checksum(scratch);
}

/// Stores the reference checksum of `frame` under `lsn_seed` in bytes 4..8.
fn restamp(gpa: std.mem.Allocator, frame: []u8, lsn_seed: Lsn) !void {
    assert(frame.len >= frame_header_size);
    const sum = try reference_checksum(gpa, frame, lsn_seed);
    std.mem.writeInt(u32, frame[4..8], sum, .little);
    assert(std.mem.readInt(u32, frame[4..8], .little) == sum);
}

/// Forges a frame field by field with no validation: stored `lsn_stored`, raw `type_byte`, and
/// a checksum seeded with `lsn_seed`. Returns the byte count used in `out`.
fn raw_frame(
    gpa: std.mem.Allocator,
    out: []u8,
    lsn_stored: Lsn,
    lsn_seed: Lsn,
    type_byte: u8,
    payload: []const u8,
) !u32 {
    assert(payload.len <= payload_bytes_max);
    const total: u32 = frame_header_size + @as(u32, @intCast(payload.len));
    assert(out.len >= total);
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u64, out[8..16], lsn_stored, .little);
    out[16] = type_byte;
    @memcpy(out[frame_header_size..][0..payload.len], payload);
    try restamp(gpa, out[0..total], lsn_seed);
    return total;
}

/// Position-dependent, never-zero payload bytes.
fn fill_payload(payload: []u8, tag: u32) void {
    assert(payload.len <= payload_bytes_max);
    for (payload, 0..) |*byte, i| {
        const mixed: u32 = @as(u32, @truncate(i)) *% 131 +% tag;
        byte.* = @intCast(1 + mixed % 251);
    }
    assert(payload.len == 0 or payload[0] != 0);
}

fn redo_payload(redo_lsn: Lsn) [8]u8 {
    var bytes: [8]u8 = undefined;
    assert(bytes.len == 8);
    std.mem.writeInt(u64, &bytes, redo_lsn, .little);
    assert(std.mem.readInt(u64, &bytes, .little) == redo_lsn);
    return bytes;
}

test "frame: golden record decodes and re-encodes byte for byte" {
    const frame = try f.decode(&golden_record, 1);
    try testing.expectEqual(@as(Lsn, 1), frame.lsn);
    try testing.expectEqual(Type.record, frame.frame_type);
    try testing.expectEqualSlices(u8, "strata", frame.payload);
    try testing.expectEqual(@as(u32, 0xA7BDB82F), f.checksum(&golden_record, 1));
    const reference = try reference_checksum(testing.allocator, &golden_record, 1);
    try testing.expectEqual(@as(u32, 0xA7BDB82F), reference);

    var out: [64]u8 = @splat(0xAA);
    const used = f.encode(&out, 1, .record, "strata");
    try testing.expectEqual(@as(u32, golden_record.len), used);
    try testing.expectEqualSlices(u8, &golden_record, out[0..used]);
    try testing.expect(std.mem.allEqual(u8, out[used..], 0xAA)); // Nothing past the frame.
}

test "frame: golden checkpoint decodes and re-encodes byte for byte" {
    const frame = try f.decode(&golden_checkpoint, 24);
    try testing.expectEqual(@as(Lsn, 24), frame.lsn);
    try testing.expectEqual(Type.checkpoint, frame.frame_type);
    try testing.expectEqualSlices(u8, &redo_payload(24), frame.payload);
    try testing.expectEqual(@as(u32, 0x43C6B827), f.checksum(&golden_checkpoint, 24));

    var out: [64]u8 = undefined;
    const used = f.encode(&out, 24, .checkpoint, &redo_payload(24));
    try testing.expectEqualSlices(u8, &golden_checkpoint, out[0..used]);
}

test "frame: decode consumes exactly one frame of a longer image" {
    // ADR section 11: LSN 1 + 17 + 6 = 24 is where the second frame starts.
    const image = golden_record ++ golden_checkpoint;
    const first = try f.decode(&image, 1);
    try testing.expectEqual(@as(usize, 6), first.payload.len);
    const rest = image[frame_header_size + first.payload.len ..];
    try testing.expectEqualSlices(u8, &golden_checkpoint, rest);
    const second = try f.decode(rest, 1 + frame_header_size + 6);
    try testing.expectEqual(Type.checkpoint, second.frame_type);
}

test "frame: golden negative pins, frame 1 under LSN 2" {
    // Frame 1's bytes verified under seed 2 give 0x2E5419B8 (derived with an independent CRC).
    try testing.expectEqual(@as(u32, 0x2E5419B8), f.checksum(&golden_record, 2));
    const reference = try reference_checksum(testing.allocator, &golden_record, 2);
    try testing.expectEqual(@as(u32, 0x2E5419B8), reference);
    // ADR section 11's 0x86C71EBB is the crc of the same record *written* at LSN 2: stored lsn
    // 2 and seed 2. It differs from the stale frame above, and it is not frame 1 either.
    var at_two: [golden_record.len]u8 = undefined;
    _ = f.encode(&at_two, 2, .record, "strata");
    try testing.expectEqual(@as(u32, 0x86C71EBB), std.mem.readInt(u32, at_two[4..8], .little));
    try testing.expect(!std.mem.eql(u8, &at_two, &golden_record));
    try testing.expectError(error.ChecksumMismatch, f.decode(&golden_record, 2));
    try testing.expect(!f.intact(&golden_record, 2));
    try testing.expect(f.intact(&golden_record, 1));
}

test "frame: checksum matches the independent reference over seeded frames" {
    var prng = std.Random.DefaultPrng.init(0x57a7a_0004);
    const random = prng.random();
    var payload: [300]u8 = undefined;
    var out: [320]u8 = undefined;
    for (0..200) |_| {
        const len = random.uintLessThan(u32, payload.len + 1);
        const lsn = 1 + random.uintLessThan(u64, f.lsn_limit - 1);
        random.bytes(payload[0..len]);
        const used = f.encode(&out, lsn, .record, payload[0..len]);
        try testing.expectEqual(frame_header_size + len, used);
        const frame = out[0..used];
        const expected = try reference_checksum(testing.allocator, frame, lsn);
        try testing.expectEqual(expected, f.checksum(frame, lsn));
        const decoded = try f.decode(frame, lsn);
        try testing.expectEqual(lsn, decoded.lsn);
        try testing.expectEqualSlices(u8, payload[0..len], decoded.payload);
    }
}

test "frame: every single-bit flip of a 64-byte-payload frame is rejected" {
    var payload: [64]u8 = undefined;
    fill_payload(&payload, 11);
    var frame: [frame_header_size + 64]u8 = undefined;
    const lsn: Lsn = 4096;
    const used = f.encode(&frame, lsn, .record, &payload);
    try testing.expectEqual(@as(u32, frame.len), used);
    _ = try f.decode(&frame, lsn);

    for (0..frame.len) |index| {
        for (0..8) |bit| {
            const mask: u8 = @as(u8, 1) << @intCast(bit);
            frame[index] ^= mask;
            defer frame[index] ^= mask;

            try testing.expect(!f.intact(&frame, lsn));
            if (index < 4) {
                // A damaged length reads as torn, over-long, or a checksum failure; never ok.
                try testing.expect(std.meta.isError(f.decode(&frame, lsn)));
            } else {
                try testing.expectError(error.ChecksumMismatch, f.decode(&frame, lsn));
            }
        }
    }
}

test "frame: decoding under another expected LSN fails, for LSN +-1 and far away" {
    var payload: [40]u8 = undefined;
    fill_payload(&payload, 5);
    var frame: [frame_header_size + 40]u8 = undefined;
    const lsn: Lsn = 1000;
    _ = f.encode(&frame, lsn, .record, &payload);
    for ([_]Lsn{ lsn - 1, lsn + 1, 1, lsn + 17, lsn ^ (1 << 40), f.lsn_limit - 1 }) |other| {
        try testing.expectError(error.ChecksumMismatch, f.decode(&frame, other));
        try testing.expect(!f.intact(&frame, other));
    }
    try testing.expect(f.intact(&frame, lsn));
}

test "frame: a forged CRC over a wrong stored LSN is Corrupted, and still intact" {
    var out: [64]u8 = undefined;
    // Stored lsn 5, checksum seeded with the expected lsn 7: steps 1-4 pass, step 5 fails.
    const used = try raw_frame(testing.allocator, &out, 5, 7, 1, "payload");
    try testing.expectError(error.Corrupted, f.decode(out[0..used], 7));
    try testing.expect(f.intact(out[0..used], 7));
    // Honest frame at 5 read at 7: the seed differs, so the CRC catches it first.
    const honest = f.encode(&out, 5, .record, "payload");
    try testing.expectError(error.ChecksumMismatch, f.decode(out[0..honest], 7));
}

test "frame: every proper prefix of a frame is TornWrite" {
    var payload: [48]u8 = undefined;
    fill_payload(&payload, 9);
    var frame: [frame_header_size + 48]u8 = undefined;
    _ = f.encode(&frame, 77, .record, &payload);
    for (0..frame.len) |cut| {
        try testing.expectError(error.TornWrite, f.decode(frame[0..cut], 77));
        try testing.expect(!f.intact(frame[0..cut], 77));
    }
    try testing.expect(f.intact(&frame, 77));
}

test "frame: len is checked before any read sized by it" {
    var image: [frame_header_size]u8 = @splat(0xFF); // len = 0xFFFFFFFF, no u32 overflow.
    try testing.expectError(error.Corrupted, f.decode(&image, 1));
    std.mem.writeInt(u32, image[0..4], payload_bytes_max + 1, .little);
    try testing.expectError(error.Corrupted, f.decode(&image, 1));
    try testing.expect(!f.intact(&image, 1));
    // A short image with an in-range len is torn, not corrupt.
    std.mem.writeInt(u32, image[0..4], payload_bytes_max, .little);
    try testing.expectError(error.TornWrite, f.decode(&image, 1));
}

test "frame: a maximal frame round-trips and one byte less is torn" {
    const image = try testing.allocator.alloc(u8, frame_bytes_max);
    defer testing.allocator.free(image);

    const payload = try testing.allocator.alloc(u8, payload_bytes_max);
    defer testing.allocator.free(payload);

    fill_payload(payload, 3);
    const used = f.encode(image, 9, .record, payload);
    try testing.expectEqual(frame_bytes_max, used);
    const frame = try f.decode(image, 9);
    try testing.expectEqualSlices(u8, payload, frame.payload);
    try testing.expectError(error.TornWrite, f.decode(image[0 .. image.len - 1], 9));
    // One over the limit, well-checksummed: still Corrupted by the len rule alone.
    const big = try testing.allocator.alloc(u8, frame_bytes_max);
    defer testing.allocator.free(big);

    @memcpy(big, image);
    std.mem.writeInt(u32, big[0..4], payload_bytes_max + 1, .little);
    try testing.expectError(error.Corrupted, f.decode(big, 9));
}

test "frame: empty record payload is a valid 17-byte frame" {
    var out: [32]u8 = undefined;
    const used = f.encode(&out, 3, .record, &.{});
    try testing.expectEqual(frame_header_size, used);
    const frame = try f.decode(out[0..used], 3);
    try testing.expectEqual(@as(usize, 0), frame.payload.len);
    try testing.expectEqual(Type.record, frame.frame_type);
}

test "frame: type 0 and the reserved ranges are Corrupted after the checksum" {
    var out: [64]u8 = undefined;
    for ([_]u8{ 0, 4, 5, 15, 16, 64, 126, 127 }) |type_byte| {
        const used = try raw_frame(testing.allocator, &out, 10, 10, type_byte, "xy");
        try testing.expectError(error.Corrupted, f.decode(out[0..used], 10));
        try testing.expect(f.intact(out[0..used], 10)); // Never a crash artifact.
    }
    // A flip of the type byte alone is a checksum failure, not a type verdict.
    const used = f.encode(&out, 10, .record, "xy");
    out[16] = 0;
    try testing.expectError(error.ChecksumMismatch, f.decode(out[0..used], 10));
}

test "frame: consumer types 128..255 carry opaque payloads like record" {
    var out: [64]u8 = undefined;
    for ([_]u8{ 128, 129, 200, 255 }) |type_byte| {
        const used = try raw_frame(testing.allocator, &out, 10, 10, type_byte, "abc");
        const frame = try f.decode(out[0..used], 10);
        try testing.expectEqual(type_byte, @intFromEnum(frame.frame_type));
        try testing.expectEqualSlices(u8, "abc", frame.payload);

        var again: [64]u8 = undefined;
        const used_again = f.encode(&again, 10, frame.frame_type, "abc");
        try testing.expectEqualSlices(u8, out[0..used], again[0..used_again]);
    }
}

test "frame: page_image payload is a page id then a valid page size" {
    const gpa = testing.allocator;
    const sizes = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
    const image = try gpa.alloc(u8, frame_header_size + 4 + 131072 + 8);
    defer gpa.free(image);

    const payload = try gpa.alloc(u8, 4 + 131072 + 8);
    defer gpa.free(payload);

    fill_payload(payload, 1);
    for (sizes) |size| {
        const len = 4 + size;
        const used = f.encode(image, 50, .page_image, payload[0..len]);
        try testing.expectEqual(frame_header_size + len, used);
        const frame = try f.decode(image[0..used], 50);
        try testing.expectEqual(Type.page_image, frame.frame_type);
        try testing.expectEqualSlices(u8, payload[0..len], frame.payload);
    }
    // Invalid page sizes behind a valid checksum: len - 4 is 0, 3000, 511, 1000, 256 and 131072
    // (powers of two just outside 512..65536), 65537, 65540, and len < 4.
    for ([_]u32{ 0, 1, 3, 4, 3004, 515, 1004, 260, 4 + 131072, 65541, 65544 }) |len| {
        const used = try raw_frame(gpa, image, 50, 50, 2, payload[0..len]);
        try testing.expectError(error.Corrupted, f.decode(image[0..used], 50));
        try testing.expect(f.intact(image[0..used], 50));
    }
}

test "frame: checkpoint needs len 8 and 1 <= redo_lsn <= lsn" {
    var out: [64]u8 = undefined;
    const lsn: Lsn = 500;
    for ([_]Lsn{ 1, 499, 500 }) |redo| {
        const used = f.encode(&out, lsn, .checkpoint, &redo_payload(redo));
        const frame = try f.decode(out[0..used], lsn);
        try testing.expectEqualSlices(u8, &redo_payload(redo), frame.payload);
    }
    for ([_]Lsn{ 0, 501, std.math.maxInt(u64) }) |redo| {
        const used = try raw_frame(testing.allocator, &out, lsn, lsn, 3, &redo_payload(redo));
        try testing.expectError(error.Corrupted, f.decode(out[0..used], lsn));
        try testing.expect(f.intact(out[0..used], lsn));
    }
    const nine = redo_payload(lsn) ++ [_]u8{0};
    for ([_][]const u8{ &.{}, nine[0..7], &nine }) |bad| {
        const used = try raw_frame(testing.allocator, &out, lsn, lsn, 3, bad);
        try testing.expectError(error.Corrupted, f.decode(out[0..used], lsn));
    }
}

test "frame: encode touches only the frame's own bytes" {
    var out: [64]u8 = @splat(0xCD);
    const used = f.encode(out[8..], 31, .record, "abcdef");
    try testing.expectEqual(frame_header_size + 6, used);
    try testing.expect(std.mem.allEqual(u8, out[0..8], 0xCD));
    try testing.expect(std.mem.allEqual(u8, out[8 + used ..], 0xCD));
    const frame = try f.decode(out[8..][0..used], 31);
    try testing.expectEqualSlices(u8, "abcdef", frame.payload);
}

test "frame: seeded round trip over all three types and many sizes" {
    var prng = std.Random.DefaultPrng.init(0x57a7a_0042);
    const random = prng.random();
    var payload: [600]u8 = undefined;
    var out: [640]u8 = undefined;
    for (0..300) |_| {
        const lsn = 24 + random.uintLessThan(u64, f.lsn_limit - 24);
        const len = random.uintLessThan(u32, 500);
        random.bytes(payload[0..len]);
        const used = f.encode(&out, lsn, .record, payload[0..len]);
        const frame = try f.decode(out[0..used], lsn);
        try testing.expectEqual(lsn, frame.lsn);
        try testing.expectEqualSlices(u8, payload[0..len], frame.payload);
        const redo = 1 + random.uintLessThan(u64, lsn);
        const cp = f.encode(&out, lsn, .checkpoint, &redo_payload(redo));
        try testing.expectEqual(frame_header_size + 8, cp);
        _ = try f.decode(out[0..cp], lsn);
    }
}
