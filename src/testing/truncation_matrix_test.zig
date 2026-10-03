//! Truncation matrix over a checksummed record (plan 002, "Truncation matrix").
//!
//! Proves the crash harness catches corruption: a `codec`-checksummed record is written through
//! a `CrashSink`, and at every truncation point `0..=len`, once as a clean `.truncate` cut and
//! once as a `.torn` cut, the surviving image must either decode to exactly the original
//! payload (only when the whole record persisted) or fail with a typed `TornWrite` or
//! `ChecksumMismatch`. Silent acceptance of a damaged prefix is `error.AcceptedCorruptPrefix`;
//! a panic is a test failure by construction.
//!
//! The record frame is test-only: `[u32 LE payload_len][payload][u32 LE crc32c of the first two
//! fields]`. The matrix takes its decoder at comptime so the same sweep also proves it can fail:
//! a decoder that skips the checksum must make the sweep return `AcceptedCorruptPrefix`.
//!
//! Allocation: each sweep allocates a record and a payload buffer, plus two record-sized sink
//! buffers inside `run_matrix`, and frees all of them before returning. Limits: records up to
//! `record_size_max` bytes, so a sweep is at most 65 537 points.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const codec = @import("../codec.zig");
const crash = @import("crash.zig");

const CrashSink = crash.CrashSink;
const Cut = crash.Cut;
const TruncationPoints = crash.TruncationPoints;

const RecordError = error{ TornWrite, ChecksumMismatch };
const Decode = fn (image: []const u8) RecordError![]const u8;

/// Bytes of framing around a payload: the length prefix and the checksum trailer.
const overhead: u32 = 8;
const record_size_max: u32 = 65536;

/// Outcome counts of one sweep; every cut lands in exactly one bucket.
const Tally = struct {
    torn_write: u32 = 0,
    checksum_mismatch: u32 = 0,
    accepted: u32 = 0,
};

/// Sink storage and image scratch, both exactly one record long.
const Buffers = struct { storage: []u8, scratch: []u8 };

/// Writes `[len][payload][crc]` into `out` and returns the record; `out` must be exactly
/// `payload.len + overhead` bytes.
fn encode_record(out: []u8, payload: []const u8) []u8 {
    assert(payload.len <= record_size_max - overhead);
    assert(out.len == payload.len + overhead);
    const payload_len: u32 = @intCast(payload.len);
    codec.fixed.write(u32, out, payload_len) catch |err| switch (err) {
        error.BufferTooSmall => unreachable, // `out` holds at least `overhead` bytes.
    };
    @memcpy(out[4..][0..payload.len], payload);
    const crc = codec.crc32c.checksum(out[0 .. 4 + payload.len]);
    codec.fixed.write(u32, out[4 + payload.len ..], crc) catch |err| switch (err) {
        error.BufferTooSmall => unreachable, // The trailer is the last four bytes of `out`.
    };
    return out;
}

/// Frame checks shared by both decoders: whole-frame length consistency, no checksum.
fn frame_payload(image: []const u8) RecordError![]const u8 {
    assert(image.len <= record_size_max);
    if (image.len < overhead) return error.TornWrite;
    const payload_len = codec.fixed.read(u32, image) catch |err| switch (err) {
        error.BufferTooSmall => return error.TornWrite,
    };
    const frame_len: u64 = @as(u64, payload_len) + overhead;
    if (frame_len > image.len) return error.TornWrite;
    // More bytes present than the length prefix claims: the prefix itself is damaged.
    if (frame_len < image.len) return error.ChecksumMismatch;
    assert(frame_len == image.len);
    return image[4..][0..payload_len];
}

fn decode_checked(image: []const u8) RecordError![]const u8 {
    const payload = try frame_payload(image);
    assert(image.len == payload.len + overhead);
    const stored = codec.fixed.read(u32, image[4 + payload.len ..]) catch |err| switch (err) {
        error.BufferTooSmall => return error.TornWrite,
    };
    if (stored != codec.crc32c.checksum(image[0 .. 4 + payload.len])) {
        return error.ChecksumMismatch;
    }
    assert(payload.len <= record_size_max - overhead);
    return payload;
}

/// Deliberately broken: trusts the length prefix and skips the checksum.
fn decode_unchecked(image: []const u8) RecordError![]const u8 {
    const payload = try frame_payload(image);
    assert(image.len == payload.len + overhead);
    return payload;
}

/// Position-dependent, never-zero payload bytes.
fn fill_payload(payload: []u8, tag: u32) void {
    assert(payload.len <= record_size_max);
    for (payload, 0..) |*byte, i| {
        const mixed: u32 = @as(u32, @truncate(i)) *% 131 +% tag;
        byte.* = @intCast(1 + mixed % 251);
    }
    assert(payload.len == 0 or payload[0] != 0);
}

/// Replays `record` into a fresh sink under `cut` and classifies the surviving image.
fn check_cut(
    comptime decode: Decode,
    record: []const u8,
    cut: Cut,
    seed: u64,
    buffers: Buffers,
    tally: *Tally,
) !void {
    assert(record.len >= overhead);
    assert(buffers.storage.len == record.len);
    assert(buffers.scratch.len == record.len);
    var sink: CrashSink = undefined;
    try sink.init(buffers.storage, cut, seed);
    // The second half first: the persisted image must not depend on write order.
    const half = record.len / 2;
    const second = try sink.writeAt(record[half..], half);
    const first = try sink.writeAt(record[0..half], 0);
    try testing.expectEqual(record.len - half, second);
    try testing.expectEqual(half, first);
    sink.check_invariants();

    const image = try sink.persisted_into(buffers.scratch);
    const point = switch (cut) {
        .truncate => |n| n,
        .torn => |n| n,
    };
    if (decode(image)) |payload| {
        if (point < record.len) return error.AcceptedCorruptPrefix;
        try testing.expectEqualSlices(u8, record, image);
        try testing.expectEqualSlices(u8, record[4 .. record.len - 4], payload);
        tally.accepted += 1;
    } else |err| {
        if (point >= record.len) return error.RejectedIntactRecord;
        switch (err) {
            error.TornWrite => tally.torn_write += 1,
            error.ChecksumMismatch => tally.checksum_mismatch += 1,
        }
    }
}

/// Sweeps every truncation point of `record` with both cut kinds.
fn run_matrix(
    gpa: std.mem.Allocator,
    comptime decode: Decode,
    record: []const u8,
    seed: u64,
) !Tally {
    assert(record.len >= overhead);
    assert(record.len <= record_size_max);
    const storage = try gpa.alloc(u8, record.len);
    defer gpa.free(storage);

    const scratch = try gpa.alloc(u8, record.len);
    defer gpa.free(scratch);

    var tally: Tally = .{};
    var points = try TruncationPoints.init(record.len, record_size_max + 1);
    while (points.next()) |point| {
        const buffers: Buffers = .{ .storage = storage, .scratch = scratch };
        try check_cut(decode, record, .{ .truncate = point }, seed, buffers, &tally);
        try check_cut(decode, record, .{ .torn = point }, seed, buffers, &tally);
    }
    return tally;
}

/// Builds a record of exactly `size` bytes on the heap and sweeps it with `decode_checked`.
fn sweep_checked(size: u32, seed: u64) !Tally {
    assert(size >= overhead);
    assert(size <= record_size_max);
    const record = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(record);

    const payload = try testing.allocator.alloc(u8, size - overhead);
    defer testing.allocator.free(payload);

    fill_payload(payload, @truncate(seed));
    _ = encode_record(record, payload);
    return run_matrix(testing.allocator, decode_checked, record, seed);
}

test "record: valid data round-trips and each flipped byte is rejected" {
    var record: [40]u8 = undefined;
    var payload: [32]u8 = undefined;
    fill_payload(&payload, 7);
    _ = encode_record(&record, &payload);
    try testing.expectEqualSlices(u8, &payload, try decode_checked(&record));

    for (0..record.len) |index| {
        record[index] ^= 0x01;
        defer record[index] ^= 0x01;
        // A flipped length byte may read as a torn or over-long frame; never accepted.
        if (index < 4) {
            try testing.expect(std.meta.isError(decode_checked(&record)));
        } else {
            try testing.expectError(error.ChecksumMismatch, decode_checked(&record));
        }
    }
}

test "record: a maximal length prefix is torn, not an overflow" {
    var image: [16]u8 = undefined;
    @memset(&image, 0xFF);
    try testing.expectError(error.TornWrite, decode_checked(&image));
    try testing.expectError(error.TornWrite, decode_unchecked(&image));
}

test "record: empty, short and over-long images are typed errors" {
    var record: [8]u8 = undefined;
    _ = encode_record(&record, &.{});
    try testing.expectEqual(@as(usize, 0), (try decode_checked(&record)).len);

    try testing.expectError(error.TornWrite, decode_checked(&.{}));
    try testing.expectError(error.TornWrite, decode_checked(record[0..7]));
    var long: [9]u8 = undefined;
    @memcpy(long[0..8], &record);
    long[8] = 0;
    try testing.expectError(error.ChecksumMismatch, decode_checked(&long));
}

test "matrix: every prefix of records around sector sizes is rejected" {
    // 8 is the empty payload; 511/512/513 straddle one sector; 1025 spans three.
    const sizes = [_]u32{ 8, 9, 511, 512, 513, 1025, 4095, 4096, 4097, 32768 };
    for (sizes) |size| {
        const tally = try sweep_checked(size, 0x5eed_0001);
        try testing.expectEqual(@as(u32, 2), tally.accepted);
        try testing.expectEqual(2 * size, tally.torn_write + tally.checksum_mismatch);
        // Every clean truncation keeps the full length prefix, so it is always torn.
        try testing.expect(tally.torn_write >= size);
        // Truncating to nothing is torn. A torn cut inside the final sector leaves a full-length
        // image with garbage, a checksum failure; but when the record is one byte past a sector
        // boundary the only cut in that sector is the aligned one, which is a clean truncation.
        try testing.expect(tally.torn_write >= 1);
        if ((size - 1) % 512 != 0) try testing.expect(tally.checksum_mismatch >= 1);
    }
}

test "matrix: other seeds change the garbage but never the verdict" {
    for ([_]u64{ 1, 2, 0xdead_beef, std.math.maxInt(u64) }) |seed| {
        const tally = try sweep_checked(600, seed);
        try testing.expectEqual(@as(u32, 2), tally.accepted);
        try testing.expectEqual(@as(u32, 1200), tally.torn_write + tally.checksum_mismatch);
    }
}

test "matrix: a 64 KiB record is rejected at every prefix" {
    const tally = try sweep_checked(record_size_max, 0x5eed_0002);
    try testing.expectEqual(@as(u32, 2), tally.accepted);
    try testing.expectEqual(2 * record_size_max, tally.torn_write + tally.checksum_mismatch);
    try testing.expect(tally.checksum_mismatch >= 1);
}

fn decode_always_torn(image: []const u8) RecordError![]const u8 {
    assert(image.len <= record_size_max);
    assert(record_size_max == 65536);
    return error.TornWrite;
}

test "matrix: a decoder that rejects the intact record fails the sweep" {
    var record: [16]u8 = undefined;
    _ = encode_record(&record, &.{ 1, 2, 3, 4, 5, 6, 7, 8 });
    try testing.expectError(
        error.RejectedIntactRecord,
        run_matrix(testing.allocator, decode_always_torn, &record, 0x5eed_0004),
    );
}

test "matrix: a decoder that skips the checksum fails the sweep" {
    var record: [512]u8 = undefined;
    var payload: [504]u8 = undefined;
    fill_payload(&payload, 3);
    _ = encode_record(&record, &payload);
    // A torn cut inside the last sector leaves a full-length image with garbage bytes.
    try testing.expectError(
        error.AcceptedCorruptPrefix,
        run_matrix(testing.allocator, decode_unchecked, &record, 0x5eed_0003),
    );
    // The checked decoder passes the very same record.
    const tally = try run_matrix(testing.allocator, decode_checked, &record, 0x5eed_0003);
    try testing.expectEqual(@as(u32, 2), tally.accepted);
}
