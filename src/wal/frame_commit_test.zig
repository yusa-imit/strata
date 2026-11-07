//! Contract tests for the `commit` frame (ADR-0005 section 8): type 4, an 8-byte `first_lsn`
//! with `lsn_first <= first_lsn < lsn`. The golden bytes were derived outside the codec.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const f = @import("frame.zig");

const Lsn = f.Lsn;

/// A `commit` frame at LSN 41 whose group starts at LSN 24.
const golden_commit = [_]u8{
    0x08, 0x00, 0x00, 0x00, // len 8
    0x4d, 0x18, 0x1a, 0x67, // crc 0x671A184D (seed u64le 41)
    0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn 41
    0x04, // type commit
    0x18, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // first_lsn 24
};

fn forge(out: []u8, lsn: Lsn, payload: []const u8) u32 {
    assert(payload.len <= out.len - f.frame_header_size);
    const total: u32 = f.frame_header_size + @as(u32, @intCast(payload.len));
    std.mem.writeInt(u32, out[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u32, out[4..8], 0, .little);
    std.mem.writeInt(u64, out[8..16], lsn, .little);
    out[16] = @intFromEnum(f.Type.commit);
    assert(total <= out.len);
    @memcpy(out[f.frame_header_size..][0..payload.len], payload);
    std.mem.writeInt(u32, out[4..8], f.checksum(out[0..total], lsn), .little);
    return total;
}

test "commit frame: golden bytes decode and re-encode byte for byte" {
    try testing.expectEqual(@as(u8, 4), @intFromEnum(f.Type.commit));
    const got = try f.decode(&golden_commit, 41);
    try testing.expectEqual(f.Type.commit, got.frame_type);
    try testing.expectEqual(@as(Lsn, 24), f.commit_first_lsn(got.payload));
    try testing.expectEqual(@as(u32, 0x671A184D), f.checksum(&golden_commit, 41));

    var out: [32]u8 = undefined;
    const used = f.encode(&out, 41, .commit, &f.commit_payload(24));
    try testing.expectEqualSlices(u8, &golden_commit, out[0..used]);
}

test "commit frame: first_lsn must lie in [lsn_first, lsn)" {
    var out: [64]u8 = undefined;
    const lsn: Lsn = 500;
    for ([_]Lsn{ 1, 24, 499 }) |first| {
        const used = f.encode(&out, lsn, .commit, &f.commit_payload(first));
        const got = try f.decode(out[0..used], lsn);
        try testing.expectEqual(first, f.commit_first_lsn(got.payload));
    }
    for ([_]Lsn{ 0, 500, 501, std.math.maxInt(u64) }) |first| {
        var raw: [8]u8 = undefined;
        std.mem.writeInt(u64, &raw, first, .little);
        const used = forge(&out, lsn, &raw);
        try testing.expectError(error.Corrupted, f.decode(out[0..used], lsn));
        try testing.expect(f.intact(out[0..used], lsn)); // Never a crash artifact.
    }
}

test "commit frame: any payload length but 8 is Corrupted" {
    var out: [64]u8 = undefined;
    const nine = f.commit_payload(24) ++ [_]u8{0};
    for ([_][]const u8{ &.{}, nine[0..7], &nine }) |bad| {
        const used = forge(&out, 500, bad);
        try testing.expectError(error.Corrupted, f.decode(out[0..used], 500));
        try testing.expect(f.intact(out[0..used], 500));
    }
}

test "commit frame: the payload helper round trips" {
    var prng = std.Random.DefaultPrng.init(0xc0_0171);
    const random = prng.random();
    for (0..200) |_| {
        const first = f.lsn_first + random.uintLessThan(u64, f.lsn_limit - 100);
        const payload = f.commit_payload(first);
        try testing.expectEqual(first, f.commit_first_lsn(&payload));
        try testing.expect(f.payload_valid(4, first + 17, &payload));
        try testing.expect(!f.payload_valid(4, first, &payload));
    }
}
