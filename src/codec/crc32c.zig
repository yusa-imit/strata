//! CRC32C (Castagnoli, reflected polynomial `0x1EDC6F41`) over caller-owned byte slices.
//!
//! Two interchangeable paths produce the same value for the same bytes: a table-driven software
//! path, and a hardware path (x86_64 SSE4.2 `crc32`, AArch64 `crc32c*`) compiled in only when the
//! target CPU *feature set* contains the instruction (`hardware_available`). Selection is by CPU
//! feature, never by `builtin.os.tag`, so REALM.md's "platform branching only in `file/`" rule
//! holds. The choice is made at compile time from the target CPU (`-Dcpu=`); there is no runtime
//! cpuid probe, so a baseline-CPU build of either architecture runs the software path.
//!
//! Invariants: `checksum(b)` equals `std.hash.crc.Crc32Iscsi.hash(b)`; the software and hardware
//! paths agree for every input; `Hasher` fed any split of `b` yields `checksum(b)`.
//! Sketch: software is one table lookup per byte (1 KiB table, 16 cache lines); hardware folds
//! 8 bytes per instruction, latency-bound (~3 cycles each) by the serial dependency chain.
//! No allocation, no `io`, no errors: every byte string has a checksum.
//! Ownership: the caller owns every buffer; nothing is retained.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

/// True when the target CPU has a CRC32C instruction and `Path.hardware` is usable.
pub const hardware_available = switch (builtin.cpu.arch) {
    .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .sse4_2),
    .aarch64 => std.Target.aarch64.featureSetHas(builtin.cpu.features, .crc),
    else => false,
};

/// Which implementation computes a checksum. Both yield identical values; naming the path lets
/// tests and benchmarks compare them. `hardware` requires `hardware_available`.
pub const Path = enum { software, hardware };

/// The path `checksum` and `Hasher` use: hardware when the target CPU has it, else software.
pub const path_default: Path = if (hardware_available) .hardware else .software;

/// Reflected Castagnoli polynomial.
const polynomial_reflected: u32 = 0x82F63B78;

/// Register value before the first byte; `Hasher.final` inverts it, so empty input checksums 0.
const state_initial: u32 = 0xFFFF_FFFF;

const table: [256]u32 = table_build();

/// Checksum of `bytes` using the fastest path this target supports. Never fails.
pub fn checksum(bytes: []const u8) u32 {
    const result = checksum_path(path_default, bytes);
    // Postcondition: the dispatched path is indistinguishable from the always-available one.
    if (bytes.len <= 16) assert(result == checksum_path(.software, bytes));
    if (bytes.len == 0) assert(result == 0);
    return result;
}

/// Checksum of `bytes` using a named path. Precondition: `path == .hardware` only on a target
/// with `hardware_available`; violating it is a compile error, not a runtime surprise.
pub fn checksum_path(comptime path: Path, bytes: []const u8) u32 {
    if (path == .hardware) comptime assert(hardware_available);
    const result = ~update_raw(path, state_initial, bytes);
    if (bytes.len == 0) assert(result == 0);
    return result;
}

/// Incremental checksum: feed any split of the input to `update`, then read `final`.
pub const Hasher = struct {
    state: u32,

    /// A hasher over the empty input: `final` returns 0 until `update` is called. `state` is the
    /// raw register; treat it as private and only move it through `update`.
    pub fn init() Hasher {
        const hasher: Hasher = .{ .state = state_initial };
        assert(hasher.state == 0xFFFF_FFFF);
        assert(hasher.final() == 0);
        return hasher;
    }

    /// Appends `bytes`; may be called any number of times, including with an empty slice.
    pub fn update(hasher: *Hasher, bytes: []const u8) void {
        const before = hasher.state;
        hasher.state = update_raw(path_default, before, bytes);
        if (bytes.len == 0) assert(hasher.state == before);
        if (bytes.len <= 16) assert(hasher.state == update_raw(.software, before, bytes));
    }

    /// Checksum of everything appended so far. Does not consume the hasher: more `update`
    /// calls may follow and `final` then covers the longer input.
    pub fn final(hasher: Hasher) u32 {
        const result = ~hasher.state;
        assert(hasher.state != state_initial or result == 0);
        return result;
    }
};

fn table_build() [256]u32 {
    @setEvalBranchQuota(10_000);
    var result: [256]u32 = @splat(0);
    for (&result, 0..) |*entry, index| {
        var crc: u32 = @intCast(index);
        for (0..8) |_| {
            crc = if (crc & 1 == 1) (crc >> 1) ^ polynomial_reflected else crc >> 1;
        }
        entry.* = crc;
    }
    comptime assert(result.len == 256);
    assert(result[0] == 0);
    assert(result[1] == 0xF26B8303); // Known first-order entry of the Castagnoli table.
    return result;
}

/// Advances the raw (not inverted) register `state` over `bytes` on the named path.
fn update_raw(comptime path: Path, state: u32, bytes: []const u8) u32 {
    if (path == .hardware) comptime assert(hardware_available);
    var crc = state;
    var rest = bytes;
    if (path == .hardware) {
        while (rest.len >= 8) {
            crc = instruction(u64, crc, std.mem.readInt(u64, rest[0..8], .little));
            rest = rest[8..];
        }
        assert(rest.len < 8);
    }
    for (rest) |byte| {
        crc = if (path == .hardware)
            instruction(u8, crc, byte)
        else
            table[@as(u8, @truncate(crc)) ^ byte] ^ (crc >> 8);
    }
    return crc;
}

/// One CRC32C instruction folding `value` (`u64` or `u8`) into `crc`. Hardware targets only.
fn instruction(comptime T: type, crc: u32, value: T) u32 {
    comptime assert(T == u64 or T == u8);
    comptime assert(hardware_available);
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const wide = if (T == u64)
                asm ("crc32q %[value], %[crc]"
                    : [crc] "=r" (-> u64),
                    : [value] "r" (value),
                      [seed] "0" (@as(u64, crc)),
                )
            else
                @as(u64, asm ("crc32 %[value], %[crc]"
                    : [crc] "=r" (-> u32),
                    : [value] "r" (value),
                      [seed] "0" (crc),
                ));
            return @truncate(wide);
        },
        // Fixed registers because the assembler wants the `w` spelling of the 32-bit operands.
        .aarch64 => return if (T == u64)
            asm ("crc32cx w9, w9, %[value]"
                : [crc] "={w9}" (-> u32),
                : [seed] "{w9}" (crc),
                  [value] "r" (value),
            )
        else
            asm ("crc32cb w9, w9, w10"
                : [crc] "={w9}" (-> u32),
                : [seed] "{w9}" (crc),
                  [value] "{w10}" (@as(u32, value)),
            ),
        else => comptime unreachable,
    }
}

const reference = std.hash.crc.Crc32Iscsi;

test "crc32c: RFC 3720 B.4 vectors" {
    const zeros: [32]u8 = @splat(0x00);
    const ones: [32]u8 = @splat(0xFF);
    var ascending: [32]u8 = undefined;
    var descending: [32]u8 = undefined;
    for (&ascending, &descending, 0..) |*up, *down, index| {
        up.* = @intCast(index);
        down.* = @intCast(31 - index);
    }
    try std.testing.expectEqual(@as(u32, 0x8A9136AA), checksum(&zeros));
    try std.testing.expectEqual(@as(u32, 0x62A8AB43), checksum(&ones));
    try std.testing.expectEqual(@as(u32, 0x46DD794E), checksum(&ascending));
    try std.testing.expectEqual(@as(u32, 0x113FDB5C), checksum(&descending));
}

test "crc32c: check value and empty input" {
    try std.testing.expectEqual(@as(u32, 0xE3069283), checksum("123456789"));
    try std.testing.expectEqual(@as(u32, 0), checksum(""));
    try std.testing.expectEqual(@as(u32, 0xC1D04330), checksum("a"));
}

test "crc32c: software path matches std reference for lengths 0..256" {
    var prng = std.Random.DefaultPrng.init(0xC4C32C01);
    var buffer: [256]u8 = undefined;
    prng.random().bytes(&buffer);
    for (0..buffer.len + 1) |length| {
        const slice = buffer[0..length];
        try std.testing.expectEqual(reference.hash(slice), checksum_path(.software, slice));
    }
}

test "crc32c: hardware path matches software for lengths 0..256 at every alignment" {
    if (!hardware_available) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0xC4C32C02);
    var buffer: [264]u8 = undefined;
    prng.random().bytes(&buffer);
    for (0..8) |offset| {
        for (0..257) |length| {
            const slice = buffer[offset..][0..length];
            const software = checksum_path(.software, slice);
            try std.testing.expectEqual(software, checksum_path(.hardware, slice));
        }
    }
}

test "crc32c: hardware path matches software on random large buffers" {
    if (!hardware_available) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0xC4C32C03);
    const random = prng.random();
    var buffer: [8192]u8 = undefined;
    for (0..64) |_| {
        random.bytes(&buffer);
        const length = random.uintAtMost(usize, buffer.len);
        const slice = buffer[0..length];
        const software = checksum_path(.software, slice);
        try std.testing.expectEqual(software, checksum_path(.hardware, slice));
        try std.testing.expectEqual(reference.hash(slice), checksum(slice));
    }
}

test "crc32c: Hasher over every two-way split equals one-shot" {
    var prng = std.Random.DefaultPrng.init(0xC4C32C04);
    var buffer: [97]u8 = undefined;
    prng.random().bytes(&buffer);
    const expected = checksum(&buffer);
    for (0..buffer.len + 1) |split| {
        var hasher = Hasher.init();
        hasher.update(buffer[0..split]);
        hasher.update(buffer[split..]);
        try std.testing.expectEqual(expected, hasher.final());
    }
}

test "crc32c: Hasher byte-at-a-time, empty updates, and final is repeatable" {
    var hasher = Hasher.init();
    try std.testing.expectEqual(@as(u32, 0), hasher.final());
    hasher.update("");
    for ("123456789") |byte| {
        hasher.update(&.{byte});
        hasher.update("");
    }
    try std.testing.expectEqual(@as(u32, 0xE3069283), hasher.final());
    try std.testing.expectEqual(@as(u32, 0xE3069283), hasher.final());
    hasher.update("0");
    try std.testing.expectEqual(checksum("1234567890"), hasher.final());
}

test "crc32c: any single-bit flip changes the checksum (valid data becoming invalid)" {
    var prng = std.Random.DefaultPrng.init(0xC4C32C05);
    var buffer: [40]u8 = undefined;
    prng.random().bytes(&buffer);
    const original = checksum(&buffer);
    for (0..buffer.len) |byte_index| {
        for (0..8) |bit_index| {
            buffer[byte_index] ^= @as(u8, 1) << @intCast(bit_index);
            try std.testing.expect(checksum(&buffer) != original);
            buffer[byte_index] ^= @as(u8, 1) << @intCast(bit_index);
        }
    }
    try std.testing.expectEqual(original, checksum(&buffer));
}
