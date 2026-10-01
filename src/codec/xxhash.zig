//! xxhash64 over caller-owned byte slices, with a frozen on-disk digest spelling.
//!
//! Wraps `std.hash.XxHash64` (the XXH64 algorithm) and pins down what the standard library does
//! not promise: the digest is stored as 8 little-endian bytes via `codec.fixed`, on every host,
//! and the seed is part of the format. A structure that persists hashes (bloom filter, bucket
//! index) records its seed in its own header; reading it back with a different seed yields
//! different bits, which is why `seed` has no default and is always passed by the caller.
//!
//! Invariants: `hash(b, s)` equals the XXH64 specification value for `(b, s)`; a `Hasher` fed any
//! split of `b` yields `hash(b, s)`; `digest_read(digest_write(h)) == h`.
//! Sketch: XXH64 consumes 32 bytes per round with four independent lanes, so it is bandwidth-
//! bound (several GB/s) rather than latency-bound; the tail costs at most 3 multiplies per 8
//! bytes. No allocation, no `io`; the only error is a digest buffer shorter than 8 bytes.
//! Ownership: the caller owns every buffer; nothing is retained.

const std = @import("std");
const assert = std.debug.assert;
const fixed = @import("fixed.zig");
const reference = @import("xxhash_reference.zig");

pub const Error = error{BufferTooSmall};

/// Encoded width of a digest in bytes.
pub const digest_size: u32 = 8;

/// Bytes XXH64 folds per round (four 8-byte lanes); the streaming state buffers fewer.
const stripe_size: usize = 32;

/// XXH64 of the empty input at seed 0, as published by the xxHash project.
const hash_empty_seed_zero: u64 = 0xEF46DB3751D8E999;

/// xxhash64 of `bytes` under `seed`. Never fails: every byte string has a hash.
pub fn hash(bytes: []const u8, seed: u64) u64 {
    comptime assert(@sizeOf(u64) == digest_size); // A hash fills exactly one digest.
    const result = std.hash.XxHash64.hash(seed, bytes);
    // Postcondition: the published empty-input value. Deeper parity (streaming, the spec
    // reference) lives in tests, since `hash` is the hot path of bloom filters and bucketing.
    if (seed == 0) assert(bytes.len != 0 or result == hash_empty_seed_zero);
    return result;
}

/// Writes `value` as 8 little-endian bytes into `buffer`. Returns `error.BufferTooSmall`
/// (buffer unmodified) if `buffer` holds fewer than `digest_size` bytes.
pub fn digest_write(buffer: []u8, value: u64) Error!void {
    comptime assert(digest_size == fixed.size_of(u64));
    try fixed.write(u64, buffer, value);
    assert(buffer.len >= digest_size);
}

/// Reads a digest written by `digest_write`; trailing bytes are ignored. Returns
/// `error.BufferTooSmall` if `buffer` holds fewer than `digest_size` bytes.
pub fn digest_read(buffer: []const u8) Error!u64 {
    comptime assert(digest_size == fixed.size_of(u64));
    const value = try fixed.read(u64, buffer);
    assert(buffer.len >= digest_size);
    return value;
}

/// Incremental hash: feed any split of the input to `update`, then read `final`.
pub const Hasher = struct {
    inner: std.hash.XxHash64,

    /// A hasher over the empty input under `seed`.
    pub fn init(seed: u64) Hasher {
        const hasher: Hasher = .{ .inner = std.hash.XxHash64.init(seed) };
        assert(hasher.appended() == 0);
        assert(hasher.inner.seed == seed);
        return hasher;
    }

    /// Appends `bytes`; may be called any number of times, including with an empty slice.
    pub fn update(hasher: *Hasher, bytes: []const u8) void {
        const before = hasher.appended();
        hasher.inner.update(bytes);
        assert(hasher.appended() == before + bytes.len);
        assert(hasher.inner.buf_len < stripe_size); // A full stripe is always folded in.
    }

    /// Hash of everything appended so far. Does not consume the hasher: more `update` calls
    /// may follow and `final` then covers the longer input.
    pub fn final(hasher: *const Hasher) u64 {
        // std's `final` takes `*XxHash64` and currently only reads; hashing a copy keeps this
        // method non-consuming even if a later std release starts mutating there.
        var copy = hasher.*;
        const result = copy.inner.final();
        assert(copy.appended() == hasher.appended());
        if (hasher.inner.byte_count == 0) {
            // Nothing folded yet: the whole input is the buffered tail, so one-shot must agree.
            const tail = copy.inner.buf[0..copy.inner.buf_len];
            assert(result == std.hash.XxHash64.hash(hasher.inner.seed, tail));
        }
        return result;
    }

    /// Total bytes appended so far, folded plus buffered.
    fn appended(hasher: *const Hasher) usize {
        assert(hasher.inner.buf_len < stripe_size);
        assert(hasher.inner.byte_count % stripe_size == 0); // Only whole stripes are folded.
        return hasher.inner.byte_count + hasher.inner.buf_len;
    }
};

test "xxhash: published vectors" {
    // Values from the xxHash project's published XXH64 results.
    try std.testing.expectEqual(@as(u64, 0xEF46DB3751D8E999), hash("", 0));
    try std.testing.expectEqual(@as(u64, 0xD24EC4F1A98C6E5B), hash("a", 0));
    try std.testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), hash("abc", 0));
}

test "xxhash: matches the specification reference for lengths 0..130 under several seeds" {
    var bytes: [130]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_0001);
    prng.random().bytes(&bytes);
    const seeds = [_]u64{ 0, 1, 0x9E37_79B9_7F4A_7C15, std.math.maxInt(u64) };
    for (seeds) |seed| {
        for (0..bytes.len + 1) |len| {
            const expected = reference.hash(bytes[0..len], seed);
            try std.testing.expectEqual(expected, hash(bytes[0..len], seed));
        }
    }
}

test "xxhash: the reference itself reproduces the published vectors" {
    try std.testing.expectEqual(hash_empty_seed_zero, reference.hash("", 0));
    try std.testing.expectEqual(@as(u64, 0xD24EC4F1A98C6E5B), reference.hash("a", 0));
    try std.testing.expectEqual(@as(u64, 0x44BC2CF5AD770999), reference.hash("abc", 0));
}

test "xxhash: matches the reference across std's unrolled-loop boundaries" {
    var bytes: [4096 + 7]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_0004);
    prng.random().bytes(&bytes);
    const lengths = [_]usize{ 1023, 1024, 1025, 2048 + 31, 4096, 4096 + 7 };
    for (lengths) |len| {
        const expected = reference.hash(bytes[0..len], 77);
        try std.testing.expectEqual(expected, hash(bytes[0..len], 77));
    }
}

test "xxhash: the seed changes the hash and the hash is deterministic" {
    try std.testing.expect(hash("strata", 0) != hash("strata", 1));
    try std.testing.expectEqual(hash("strata", 7), hash("strata", 7));
}

test "xxhash: Hasher with large and odd chunk sizes equals one-shot" {
    var bytes: [4096 + 7]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_0005);
    prng.random().bytes(&bytes);
    const expected = hash(&bytes, 5);
    const chunks = [_]usize{ 1, 31, 32, 33, 1024, 1500 };
    for (chunks) |chunk| {
        var hasher = Hasher.init(5);
        var rest: []const u8 = &bytes;
        while (rest.len > 0) {
            const take = @min(chunk, rest.len);
            hasher.update(rest[0..take]);
            rest = rest[take..];
        }
        try std.testing.expectEqual(expected, hasher.final());
    }
}

test "xxhash: Hasher over every two-way split equals one-shot" {
    var bytes: [100]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_0002);
    prng.random().bytes(&bytes);
    const expected = hash(&bytes, 42);
    for (0..bytes.len + 1) |split| {
        var hasher = Hasher.init(42);
        hasher.update(bytes[0..split]);
        hasher.update(bytes[split..]);
        try std.testing.expectEqual(expected, hasher.final());
    }
}

test "xxhash: Hasher byte-at-a-time, empty updates, and final is repeatable" {
    const bytes = "the quick brown fox jumps over the lazy dog, twice over: the quick brown fox";
    var hasher = Hasher.init(9);
    try std.testing.expectEqual(hash("", 9), hasher.final());
    for (bytes) |byte| {
        hasher.update(&.{byte});
        hasher.update("");
    }
    try std.testing.expectEqual(hash(bytes, 9), hasher.final());
    try std.testing.expectEqual(hash(bytes, 9), hasher.final());
    hasher.update("!");
    try std.testing.expectEqual(hash(bytes ++ "!", 9), hasher.final());
}

test "xxhash: digest is eight little-endian bytes" {
    var buffer: [10]u8 = @splat(0xAA);
    try digest_write(&buffer, 0x0102_0304_0506_0708);
    try std.testing.expectEqualSlices(u8, &.{ 8, 7, 6, 5, 4, 3, 2, 1, 0xAA, 0xAA }, &buffer);
    try std.testing.expectEqual(@as(u64, 0x0102_0304_0506_0708), try digest_read(&buffer));
}

test "xxhash: digest round-trips a hash" {
    var buffer: [digest_size]u8 = undefined;
    const value = hash("round trip", 3);
    try digest_write(&buffer, value);
    try std.testing.expectEqual(value, try digest_read(&buffer));
}

test "xxhash: short digest buffers are BufferTooSmall and left unmodified" {
    const untouched: [digest_size]u8 = @splat(0x55);
    var buffer = untouched;
    const short = digest_size - 1;
    try std.testing.expectError(error.BufferTooSmall, digest_write(buffer[0..short], 1));
    try std.testing.expectEqualSlices(u8, &untouched, &buffer);
    try std.testing.expectError(error.BufferTooSmall, digest_read(buffer[0..short]));
    try std.testing.expectError(error.BufferTooSmall, digest_read(&.{}));
}

test "xxhash: any single-bit flip changes the hash (valid data becoming invalid)" {
    var bytes: [48]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5eed_0003);
    prng.random().bytes(&bytes);
    const original = hash(&bytes, 0);
    // A flip colliding is possible in principle; the fixed PRNG seed pins this to a pass.
    for (0..bytes.len * 8) |bit| {
        bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
        try std.testing.expect(hash(&bytes, 0) != original);
        bytes[bit / 8] ^= @as(u8, 1) << @intCast(bit % 8);
    }
    try std.testing.expectEqual(original, hash(&bytes, 0));
}
