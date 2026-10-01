//! Test-only XXH64 written straight from the specification (xxHash `doc/xxhash_spec.md`), with
//! no `std.hash` involved, so `codec/xxhash.zig` is checked against more than itself.
//!
//! Invariants: `hash(b, s)` is the XXH64 value for `(b, s)`. Slow and simple on purpose.
//! Allocation: none. Ownership: the caller owns every buffer; nothing is retained.

const std = @import("std");
const assert = std.debug.assert;

const prime_1: u64 = 11400714785074694791;
const prime_2: u64 = 14029467366897019727;
const prime_3: u64 = 1609587929392839161;
const prime_4: u64 = 9650029242287828579;
const prime_5: u64 = 2870177450012600261;

const stripe_size: usize = 32;
const lane_size: usize = 8;

/// XXH64 of `bytes` under `seed`.
pub fn hash(bytes: []const u8, seed: u64) u64 {
    var rest = bytes;
    var acc: u64 = seed +% prime_5;
    if (bytes.len >= stripe_size) {
        acc = hash_stripes(&rest, seed);
        assert(rest.len < stripe_size);
    }
    acc +%= bytes.len;
    while (rest.len >= lane_size) : (rest = rest[lane_size..]) {
        acc ^= round(0, std.mem.readInt(u64, rest[0..8], .little));
        acc = std.math.rotl(u64, acc, 27) *% prime_1 +% prime_4;
    }
    if (rest.len >= 4) {
        acc ^= @as(u64, std.mem.readInt(u32, rest[0..4], .little)) *% prime_1;
        acc = std.math.rotl(u64, acc, 23) *% prime_2 +% prime_3;
        rest = rest[4..];
    }
    for (rest) |byte| {
        acc ^= @as(u64, byte) *% prime_5;
        acc = std.math.rotl(u64, acc, 11) *% prime_1;
    }
    assert(rest.len < 4);
    return avalanche(acc);
}

/// Consumes whole 32-byte stripes from `rest` (advancing it) and returns the merged accumulator.
fn hash_stripes(rest: *[]const u8, seed: u64) u64 {
    assert(rest.len >= stripe_size);
    var lanes = [4]u64{ seed +% prime_1 +% prime_2, seed +% prime_2, seed, seed -% prime_1 };
    while (rest.len >= stripe_size) : (rest.* = rest.*[stripe_size..]) {
        for (&lanes, 0..) |*lane, index| {
            const word = std.mem.readInt(u64, rest.*[index * lane_size ..][0..8], .little);
            lane.* = round(lane.*, word);
        }
    }
    var acc = std.math.rotl(u64, lanes[0], 1) +% std.math.rotl(u64, lanes[1], 7) +%
        std.math.rotl(u64, lanes[2], 12) +% std.math.rotl(u64, lanes[3], 18);
    for (lanes) |lane| acc = (acc ^ round(0, lane)) *% prime_1 +% prime_4;
    assert(rest.len < stripe_size);
    return acc;
}

fn round(acc: u64, lane: u64) u64 {
    // Odd multipliers make each round a bijection on the accumulator.
    comptime assert(prime_1 & 1 == 1);
    comptime assert(prime_2 & 1 == 1);
    return std.math.rotl(u64, acc +% lane *% prime_2, 31) *% prime_1;
}

fn avalanche(value: u64) u64 {
    comptime assert(prime_2 & 1 == 1);
    comptime assert(prime_3 & 1 == 1);
    var acc = value;
    acc ^= acc >> 33;
    acc *%= prime_2;
    acc ^= acc >> 29;
    acc *%= prime_3;
    acc ^= acc >> 32;
    // Zero is a fixed point of every xor-shift and multiply above.
    assert(value != 0 or acc == 0);
    return acc;
}
