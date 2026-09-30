//! LEB128 variable-length integers: unsigned `u64` and zigzag-mapped signed `i64`.
//!
//! Format: seven payload bits per byte, least-significant group first; the high bit of a byte is
//! set when another byte follows. A `u64` needs at most `encoded_size_max` (10) bytes.
//! Encoding is canonical — every value has exactly one encoding — so encoded bytes are stable
//! under checksums; the decoder rejects any other spelling as `error.Overlong`.
//! Allocation: none. Ownership: the caller owns every buffer; nothing is retained.
//! Errors: short or malformed input is returned as a typed error, never asserted (REALM.md).

const std = @import("std");
const assert = std.debug.assert;

/// A `u64` needs ceil(64 / 7) = 10 bytes at most.
pub const encoded_size_max: u32 = 10;

pub const EncodeError = error{BufferTooSmall};

pub const DecodeError = error{
    /// The buffer ended before a byte with a clear continuation bit.
    Truncated,
    /// More than ten bytes, a tenth byte that overflows `u64`, or a non-canonical spelling
    /// (a final zero byte after the first).
    Overlong,
};

pub const Unsigned = struct {
    value: u64,
    /// Bytes consumed from the front of the buffer, in `1...encoded_size_max`.
    size: u32,
};

pub const Signed = struct {
    value: i64,
    /// Bytes consumed from the front of the buffer, in `1...encoded_size_max`.
    size: u32,
};

comptime {
    assert(encoded_size_max * 7 >= 64);
    assert((encoded_size_max - 1) * 7 < 64);
}

/// Number of bytes `encode` writes for `value`, in `1...encoded_size_max`.
pub fn encoded_size(value: u64) u32 {
    const significant_bits: u32 = 64 - @clz(value | 1);
    const size = @divFloor(significant_bits + 6, 7);
    assert(size >= 1);
    assert(size <= encoded_size_max);
    return size;
}

/// Writes `value` at the front of `buffer` and returns the byte count. Bytes past the returned
/// count are untouched. Returns `error.BufferTooSmall` (buffer unmodified) if it would not fit.
pub fn encode(buffer: []u8, value: u64) EncodeError!u32 {
    const size = encoded_size(value);
    if (buffer.len < size) return error.BufferTooSmall;
    assert(size <= encoded_size_max);
    var rest = value;
    for (0..size - 1) |index| {
        buffer[index] = @as(u8, @truncate(rest)) | 0x80;
        rest >>= 7;
    }
    assert(rest < 0x80);
    buffer[size - 1] = @intCast(rest);
    // Postcondition: the last written byte ends the sequence.
    assert(buffer[size - 1] & 0x80 == 0);
    return size;
}

/// Reads one `u64` from the front of `buffer`. Trailing bytes are ignored.
/// Returns `error.Truncated` for an empty buffer or one that ends mid-sequence, and
/// `error.Overlong` for input `encode` could never have produced.
pub fn decode(buffer: []const u8) DecodeError!Unsigned {
    var value: u64 = 0;
    for (0..encoded_size_max) |index| {
        if (index >= buffer.len) return error.Truncated;
        assert(index < buffer.len);
        assert(index < encoded_size_max);
        const byte = buffer[index];
        const shift: u6 = @intCast(index * 7);
        if (index == encoded_size_max - 1 and byte > 1) return error.Overlong;
        value |= @as(u64, byte & 0x7F) << shift;
        if (byte & 0x80 == 0) {
            // A trailing zero group means a shorter encoding exists.
            if (index > 0 and byte == 0) return error.Overlong;
            const size: u32 = @intCast(index + 1);
            assert(size == encoded_size(value));
            return .{ .value = value, .size = size };
        }
    }
    // The tenth byte either returns `Overlong` (above one) or terminates the sequence (0 or 1,
    // no continuation bit), so the loop always returns.
    unreachable;
}

/// Maps signed to unsigned so small magnitudes stay small: 0, -1, 1, -2 → 0, 1, 2, 3.
pub fn zigzag_encode(value: i64) u64 {
    const encoded: u64 = @bitCast((value << 1) ^ (value >> 63));
    assert(zigzag_decode(encoded) == value);
    return encoded;
}

/// Inverse of `zigzag_encode`; total over every `u64`.
pub fn zigzag_decode(value: u64) i64 {
    const magnitude: i64 = @bitCast(value >> 1);
    const sign: i64 = -@as(i64, @intCast(value & 1));
    const decoded = magnitude ^ sign;
    assert(@as(u64, @bitCast((decoded << 1) ^ (decoded >> 63))) == value);
    return decoded;
}

/// Writes zigzag-mapped `value` like `encode`.
pub fn encode_signed(buffer: []u8, value: i64) EncodeError!u32 {
    const size = try encode(buffer, zigzag_encode(value));
    assert(size >= 1);
    assert(size <= encoded_size_max);
    return size;
}

/// Reads one zigzag-mapped `i64` like `decode`.
pub fn decode_signed(buffer: []const u8) DecodeError!Signed {
    const unsigned = try decode(buffer);
    assert(unsigned.size >= 1);
    assert(unsigned.size <= buffer.len);
    return .{ .value = zigzag_decode(unsigned.value), .size = unsigned.size };
}

const testing = std.testing;

const boundary_values = [_]u64{
    0,
    1,
    127,
    128,
    (1 << 14) - 1,
    1 << 14,
    (1 << 21) - 1,
    1 << 21,
    (1 << 63) - 1,
    1 << 63,
    std.math.maxInt(u64),
};

test "varint: boundary values round trip with the expected size" {
    const expected_sizes = [_]u32{ 1, 1, 1, 2, 2, 3, 3, 4, 9, 10, 10 };
    var buffer: [encoded_size_max]u8 = @splat(0);
    for (boundary_values, expected_sizes) |value, expected_size| {
        const written = try encode(&buffer, value);
        try testing.expectEqual(expected_size, written);
        try testing.expectEqual(expected_size, encoded_size(value));
        const decoded = try decode(buffer[0..written]);
        try testing.expectEqual(value, decoded.value);
        try testing.expectEqual(written, decoded.size);
    }
}

test "varint: known byte vectors" {
    var buffer: [encoded_size_max]u8 = @splat(0);
    try testing.expectEqual(@as(u32, 1), try encode(&buffer, 0));
    try testing.expectEqualSlices(u8, &.{0x00}, buffer[0..1]);
    try testing.expectEqual(@as(u32, 2), try encode(&buffer, 300));
    try testing.expectEqualSlices(u8, &.{ 0xAC, 0x02 }, buffer[0..2]);
    try testing.expectEqual(@as(u32, 10), try encode(&buffer, std.math.maxInt(u64)));
    try testing.expectEqualSlices(
        u8,
        &.{ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01 },
        buffer[0..10],
    );
}

test "varint: seeded model test against a bit-by-bit reference" {
    var prng = std.Random.DefaultPrng.init(0x7a41b17);
    const random = prng.random();
    var buffer: [encoded_size_max]u8 = @splat(0);
    for (0..2000) |_| {
        // Vary the magnitude so every encoded length is exercised.
        const bits: u6 = random.intRangeAtMost(u6, 0, 63);
        const value = random.int(u64) >> bits;
        const written = try encode(&buffer, value);
        // Independent reference encoder: emit seven bits at a time, low group first.
        var reference: [encoded_size_max]u8 = @splat(0);
        var reference_size: u32 = 0;
        var rest = value;
        while (rest >= 0x80) : (rest >>= 7) {
            reference[reference_size] = @as(u8, @truncate(rest & 0x7F)) | 0x80;
            reference_size += 1;
        }
        reference[reference_size] = @truncate(rest);
        reference_size += 1;
        try testing.expectEqual(reference_size, written);
        try testing.expectEqualSlices(u8, reference[0..reference_size], buffer[0..written]);
        const decoded = try decode(buffer[0..written]);
        try testing.expectEqual(value, decoded.value);
        try testing.expectEqual(written, decoded.size);
    }
}

test "varint: every strict prefix of a multi-byte encoding is Truncated" {
    var buffer: [encoded_size_max]u8 = @splat(0);
    for (boundary_values) |value| {
        const written = try encode(&buffer, value);
        for (0..written) |prefix_len| {
            try testing.expectError(error.Truncated, decode(buffer[0..prefix_len]));
        }
    }
}

test "varint: trailing bytes after the sequence are ignored" {
    const decoded = try decode(&.{ 0xAC, 0x02, 0xFF, 0xFF });
    try testing.expectEqual(@as(u64, 300), decoded.value);
    try testing.expectEqual(@as(u32, 2), decoded.size);
}

test "varint: eleven-byte and continuation-forever input is Overlong" {
    const endless: [encoded_size_max + 2]u8 = @splat(0x80);
    try testing.expectError(error.Overlong, decode(&endless));
    // Ten bytes all with the continuation bit: the tenth cannot continue.
    try testing.expectError(error.Overlong, decode(endless[0..encoded_size_max]));
}

test "varint: tenth byte above one overflows u64 and is Overlong" {
    var bytes: [encoded_size_max]u8 = @splat(0xFF);
    bytes[9] = 0x02;
    try testing.expectError(error.Overlong, decode(&bytes));
    bytes[9] = 0x7F;
    try testing.expectError(error.Overlong, decode(&bytes));
    bytes[9] = 0x01;
    try testing.expectEqual(std.math.maxInt(u64), (try decode(&bytes)).value);
}

test "varint: non-canonical trailing zero group is Overlong" {
    try testing.expectError(error.Overlong, decode(&.{ 0x80, 0x00 }));
    try testing.expectError(error.Overlong, decode(&.{ 0xFF, 0x80, 0x00 }));
    try testing.expectError(error.Overlong, decode(&.{ 0x81, 0x80, 0x00 }));
    // Ten bytes whose tenth is 0x00: the canonical check fires at the last index.
    var padded: [encoded_size_max]u8 = @splat(0x80);
    padded[9] = 0x00;
    try testing.expectError(error.Overlong, decode(&padded));
    // A tenth byte with the continuation bit set never terminates within the cap.
    padded[9] = 0x81;
    try testing.expectError(error.Overlong, decode(&padded));
    // A lone zero byte is the canonical zero.
    try testing.expectEqual(@as(u64, 0), (try decode(&.{0x00})).value);
}

test "varint: encode into a too-small buffer fails and leaves it untouched" {
    var buffer: [encoded_size_max]u8 = @splat(0xAA);
    try testing.expectError(error.BufferTooSmall, encode(buffer[0..0], 0));
    try testing.expectError(error.BufferTooSmall, encode(buffer[0..1], 128));
    try testing.expectError(error.BufferTooSmall, encode(buffer[0..9], std.math.maxInt(u64)));
    try testing.expectEqualSlices(u8, &@as([encoded_size_max]u8, @splat(0xAA)), &buffer);
    // Exactly enough succeeds.
    try testing.expectEqual(@as(u32, 10), try encode(buffer[0..10], std.math.maxInt(u64)));
}

test "varint: encode leaves bytes past the written count untouched" {
    var buffer: [encoded_size_max]u8 = @splat(0xAA);
    const written = try encode(&buffer, 5);
    try testing.expectEqual(@as(u32, 1), written);
    for (buffer[written..]) |byte| try testing.expectEqual(@as(u8, 0xAA), byte);
}

test "varint: zigzag maps small magnitudes to small codes" {
    try testing.expectEqual(@as(u64, 0), zigzag_encode(0));
    try testing.expectEqual(@as(u64, 1), zigzag_encode(-1));
    try testing.expectEqual(@as(u64, 2), zigzag_encode(1));
    try testing.expectEqual(@as(u64, 3), zigzag_encode(-2));
    try testing.expectEqual(std.math.maxInt(u64), zigzag_encode(std.math.minInt(i64)));
    try testing.expectEqual(std.math.maxInt(u64) - 1, zigzag_encode(std.math.maxInt(i64)));
}

test "varint: zigzag decode vectors" {
    try testing.expectEqual(@as(i64, 0), zigzag_decode(0));
    try testing.expectEqual(@as(i64, -1), zigzag_decode(1));
    try testing.expectEqual(@as(i64, 1), zigzag_decode(2));
    try testing.expectEqual(std.math.maxInt(i64), zigzag_decode(std.math.maxInt(u64) - 1));
    try testing.expectEqual(std.math.minInt(i64), zigzag_decode(std.math.maxInt(u64)));
}

test "varint: signed boundary values round trip" {
    const values = [_]i64{
        0,
        1,
        -1,
        63,
        -64,
        64,
        -65,
        std.math.maxInt(i64),
        std.math.minInt(i64),
    };
    var buffer: [encoded_size_max]u8 = @splat(0);
    for (values) |value| {
        const written = try encode_signed(&buffer, value);
        const decoded = try decode_signed(buffer[0..written]);
        try testing.expectEqual(value, decoded.value);
        try testing.expectEqual(written, decoded.size);
    }
    // -64 and 63 fit one byte; -65 and 64 need two.
    try testing.expectEqual(@as(u32, 1), try encode_signed(&buffer, -64));
    try testing.expectEqual(@as(u32, 1), try encode_signed(&buffer, 63));
    try testing.expectEqual(@as(u32, 2), try encode_signed(&buffer, -65));
    try testing.expectEqual(@as(u32, 2), try encode_signed(&buffer, 64));
}

test "varint: signed errors pass through from the unsigned decoder" {
    try testing.expectError(error.Truncated, decode_signed(&.{}));
    try testing.expectError(error.Truncated, decode_signed(&.{0x80}));
    try testing.expectError(error.Overlong, decode_signed(&.{ 0x80, 0x00 }));
    var tiny: [0]u8 = .{};
    try testing.expectError(error.BufferTooSmall, encode_signed(&tiny, -1));
}

test "varint: zigzag is a bijection over a seeded sample" {
    var prng = std.Random.DefaultPrng.init(0x21a2a9);
    const random = prng.random();
    for (0..1000) |_| {
        const value = random.int(i64);
        try testing.expectEqual(value, zigzag_decode(zigzag_encode(value)));
        const code = random.int(u64);
        try testing.expectEqual(code, zigzag_encode(zigzag_decode(code)));
    }
}
