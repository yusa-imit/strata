//! Shared test helpers for `file.zig` and `file_model_test.zig`: deterministic bytes, a one-line
//! "create a read-write file" constructor, and a length check. Test-only; nothing here is part
//! of the public API and every I/O goes through `std.testing.io` (ADR-0001).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const file_mod = @import("file.zig");
const File = file_mod.File;

/// Deterministic, position-dependent bytes: `buf[i] = (i * 131 + seed) mod 251`. 251 is prime
/// and coprime to every power-of-two page size, so neighbouring pages differ and no shifted
/// read can alias the expected data.
pub fn pattern(buf: []u8, seed: u32) void {
    assert(buf.len <= std.math.maxInt(u32)); // `i` is truncated to u32 below.
    comptime assert(251 <= std.math.maxInt(u8)); // Every residue fits a byte.
    for (buf, 0..) |*byte, i| {
        const mixed: u32 = @as(u32, @truncate(i)) *% 131 +% seed;
        byte.* = @intCast(mixed % 251);
    }
    assert(buf.len == 0 or buf[0] == seed % 251);
}

/// Opens `sub_path` read-write, creating it if missing, through the production `File.open`.
pub fn create_rw(dir: Io.Dir, sub_path: []const u8) !File {
    assert(sub_path.len > 0);
    const f = try File.open(std.testing.io, dir, sub_path, .{ .create = true });
    assert(!f.direct);
    return f;
}

/// Fails the calling test unless `f.length` is exactly `expected`.
pub fn expect_length(f: File, expected: u64) !void {
    assert(expected <= file_mod.offset_max);
    assert(!f.direct);
    try std.testing.expectEqual(expected, try f.length(std.testing.io));
}
