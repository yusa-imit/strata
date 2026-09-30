//! Fixed-width little-endian integer codec: `u16`, `u32`, `u64` over caller-owned byte slices.
//!
//! Invariants: the byte order on disk is little-endian on every target, so encoded bytes never
//! depend on the host; every access is bounds-checked against the slice it is given.
//! Allocation: none. Ownership: the caller owns every buffer; nothing is retained.
//! Errors: a buffer shorter than the integer is `error.BufferTooSmall` — the caller's data was
//! short, not a programmer error, so it is returned rather than asserted (REALM.md).

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{BufferTooSmall};

/// Encoded width of `T` in bytes; `T` must be `u16`, `u32`, or `u64`.
pub fn size_of(comptime T: type) u32 {
    comptime assert(T == u16 or T == u32 or T == u64);
    comptime assert(@typeInfo(T).int.signedness == .unsigned);
    return @divExact(@typeInfo(T).int.bits, 8);
}

/// Reads a little-endian `T` (`u16`, `u32`, or `u64`) from the first `size_of(T)` bytes of
/// `buffer`. Extra trailing bytes are ignored. Returns `error.BufferTooSmall` if `buffer` is
/// shorter than `size_of(T)`.
pub fn read(comptime T: type, buffer: []const u8) Error!T {
    const size = comptime size_of(T);
    comptime assert(@sizeOf(T) == size); // No padding: wire width equals in-memory width.
    if (buffer.len < size) return error.BufferTooSmall;
    assert(buffer.len >= size);
    return std.mem.readInt(T, buffer[0..size], .little);
}

/// Writes `value` little-endian into the first `size_of(T)` bytes of `buffer`; later bytes are
/// untouched. Returns `error.BufferTooSmall` (buffer unmodified) if `buffer` is shorter than
/// `size_of(T)`.
pub fn write(comptime T: type, buffer: []u8, value: T) Error!void {
    const size = comptime size_of(T);
    comptime assert(@sizeOf(T) == size); // No padding: wire width equals in-memory width.
    if (buffer.len < size) return error.BufferTooSmall;
    assert(buffer.len >= size);
    std.mem.writeInt(T, buffer[0..size], value, .little);
    // Postcondition: the bytes just written decode back to `value`.
    assert(std.mem.readInt(T, buffer[0..size], .little) == value);
}

test "fixed: byte layout is little-endian" {
    var buffer: [8]u8 = @splat(0);
    try write(u16, &buffer, 0x0102);
    try std.testing.expectEqualSlices(u8, &.{ 0x02, 0x01 }, buffer[0..2]);
    try write(u32, &buffer, 0x01020304);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01 }, buffer[0..4]);
    try write(u64, &buffer, 0x0102030405060708);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01 },
        &buffer,
    );
}

test "fixed: size_of reports the encoded width" {
    try std.testing.expectEqual(@as(u32, 2), size_of(u16));
    try std.testing.expectEqual(@as(u32, 4), size_of(u32));
    try std.testing.expectEqual(@as(u32, 8), size_of(u64));
}

test "fixed: round trip at zero, one, and the integer maximum" {
    var buffer: [8]u8 = @splat(0);
    inline for (.{ u16, u32, u64 }) |T| {
        const values = [_]T{ 0, 1, std.math.maxInt(T) };
        for (values) |value| {
            try write(T, &buffer, value);
            try std.testing.expectEqual(value, try read(T, &buffer));
        }
    }
}

test "fixed: seeded round trip matches std.mem reference" {
    var prng = std.Random.DefaultPrng.init(0x5747a7a0);
    const random = prng.random();
    var buffer: [8]u8 = @splat(0);
    for (0..1000) |_| {
        const value = random.int(u64);
        try write(u64, &buffer, value);
        try std.testing.expectEqual(value, std.mem.readInt(u64, &buffer, .little));
        try std.testing.expectEqual(value, try read(u64, &buffer));
        const narrow: u32 = @truncate(value);
        try write(u32, &buffer, narrow);
        try std.testing.expectEqual(narrow, std.mem.readInt(u32, buffer[0..4], .little));
        try std.testing.expectEqual(narrow, try read(u32, &buffer));
    }
}

test "fixed: buffer of exactly the width works, one byte less is BufferTooSmall" {
    var buffer: [8]u8 = @splat(0xAA);
    try write(u16, buffer[0..2], 0xBEEF);
    try std.testing.expectEqual(@as(u16, 0xBEEF), try read(u16, buffer[0..2]));
    try std.testing.expectError(error.BufferTooSmall, write(u16, buffer[0..1], 0xBEEF));
    try std.testing.expectError(error.BufferTooSmall, write(u32, buffer[0..3], 1));
    try std.testing.expectError(error.BufferTooSmall, write(u64, buffer[0..7], 1));
    try std.testing.expectError(error.BufferTooSmall, read(u16, buffer[0..1]));
    try std.testing.expectError(error.BufferTooSmall, read(u32, buffer[0..3]));
    try std.testing.expectError(error.BufferTooSmall, read(u64, buffer[0..7]));
}

test "fixed: empty buffer is BufferTooSmall and a failed write leaves bytes untouched" {
    const empty: []const u8 = &.{};
    try std.testing.expectError(error.BufferTooSmall, read(u16, empty));
    try std.testing.expectError(error.BufferTooSmall, read(u32, empty));
    try std.testing.expectError(error.BufferTooSmall, read(u64, empty));
    var buffer: [7]u8 = @splat(0xAA);
    try std.testing.expectError(error.BufferTooSmall, write(u64, &buffer, 0));
    try std.testing.expectEqualSlices(u8, &@as([7]u8, @splat(0xAA)), &buffer);
}

test "fixed: write touches only the leading bytes" {
    var buffer: [8]u8 = @splat(0xAA);
    try write(u16, &buffer, 0);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA }, &buffer);
    try std.testing.expectEqual(@as(u16, 0), try read(u16, buffer[0..3]));
}
