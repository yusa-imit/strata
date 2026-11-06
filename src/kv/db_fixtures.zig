//! Shared test support for the `kv.Db` tests: options per page size that satisfy the pool floor,
//! deterministic keys and values, and read-back checks. Test code only; I/O goes through
//! `std.testing.io`, memory through the caller's allocator.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const file_mod = @import("../file/file.zig");
const db_mod = @import("db.zig");

pub const Db = db_mod.Db;
pub const Options = db_mod.Options;

pub const sizes = [_]u32{ 512, 4096, 65536 };
pub const sub_path = "kvdb";

/// Options for one page size: small batch bounds (one op), a pool just above its floor, so
/// eviction is exercised, and values up to `2 * page_size` (an overflow chain) capped at 40 KB.
pub fn options(page_size: u32, policy: file_mod.SyncPolicy) Options {
    assert(page_size >= 512);
    var result: Options = .{
        .engine = .btree,
        .sync_policy = policy,
        .page_size = page_size,
        .page_count_max = 8192,
        .pool_frames_max = 0,
        .key_len_max = 1024,
        .value_len_max = @min(2 * page_size, 40_000),
        .batch_ops_max = 1,
        .batch_bytes_max = 0,
        .wal_segments_max = 8,
        .wal_segment_bytes_max = 1 << 21,
    };
    result.batch_bytes_max = result.key_len_max + result.value_len_max;
    result.pool_frames_max = db_mod.pool_frames_min(result) + 32;
    return result;
}

/// Keys written for a page size: enough to split at 512 B, few at 64 KiB (big pages are slow).
pub fn key_count(page_size: u32) u32 {
    assert(page_size >= 512);
    assert(page_size <= 65536);
    return switch (page_size) {
        512 => 400,
        4096 => 200,
        else => 40,
    };
}

pub fn key_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 6);
    assert(n < 100_000);
    buf[0] = 'k';
    var rest = n;
    for (1..6) |step| { // Five digits, least significant last.
        buf[6 - step] = '0' + @as(u8, @intCast(rest % 10));
        rest = @divTrunc(rest, 10);
    }
    assert(rest == 0);
    return buf[0..6];
}

/// The value of key `n` in generation `gen`: length and bytes are a pure function of both.
pub fn value_of(buf: []u8, value_len_max: u32, n: u32, gen: u32) []const u8 {
    assert(buf.len >= value_len_max);
    assert(n < 100_000);
    const len: u32 = @intCast((@as(u64, n) * 37 + gen * 11) % (@as(u64, value_len_max) + 1));
    for (buf[0..len], 0..) |*byte, index| byte.* = @truncate(index + n + gen);
    return buf[0..len];
}

/// Writes keys `0 ..< count` (generation `gen`) to `db`.
pub fn fill(db: *Db, scratch: []u8, value_len_max: u32, count: u32, gen: u32) !void {
    assert(count >= 1);
    assert(scratch.len >= value_len_max);
    var key_buf: [8]u8 = undefined;
    for (0..count) |n| {
        const key = key_of(&key_buf, @intCast(n));
        try db.put(key, value_of(scratch, value_len_max, @intCast(n), gen));
    }
}

/// Every key `0 ..< count` reads back as generation `gen`, except the odd ones when
/// `odd_present` is false (they must be absent).
pub fn check(
    db: *Db,
    scratch: []u8,
    value_len_max: u32,
    count: u32,
    gen: u32,
    odd_present: bool,
) !void {
    assert(count >= 1);
    assert(scratch.len >= value_len_max);
    var key_buf: [8]u8 = undefined;
    for (0..count) |n| {
        const key = key_of(&key_buf, @intCast(n));
        const got = try db.get(key);
        if (n % 2 == 1 and !odd_present) {
            try testing.expect(got == null);
            continue;
        }
        const want = value_of(scratch, value_len_max, @intCast(n), gen);
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, want, got.?);
    }
}

/// The on-disk state of an open database at this instant, as a new database directory `to`:
/// `pages.db` and every `wal` segment, byte for byte. Every write that returned is in the OS
/// already, so this is what a process crash leaves (no flush, no close, no checkpoint).
pub fn crash_copy(dir: Io.Dir, from: []const u8, to: []const u8) !void {
    assert(from.len >= 1);
    assert(!std.mem.eql(u8, from, to));
    const io = testing.io;
    var src = try dir.openDir(io, from, .{ .iterate = true });
    defer src.close(io);

    try dir.createDir(io, to, .default_dir);
    var dst = try dir.openDir(io, to, .{ .iterate = true });
    defer dst.close(io);

    try src.copyFile("pages.db", dst, "pages.db", io, .{});
    try dst.createDir(io, "wal", .default_dir);
    var src_wal = try src.openDir(io, "wal", .{ .iterate = true });
    defer src_wal.close(io);

    var dst_wal = try dst.openDir(io, "wal", .{ .iterate = true });
    defer dst_wal.close(io);

    var it = src_wal.iterate();
    var copied: u32 = 0;
    while (try it.next(io)) |entry| : (copied += 1) {
        try testing.expect(copied < 1024); // Bound: a test log has a handful of segments.
        try src_wal.copyFile(entry.name, dst_wal, entry.name, io, .{});
    }
}

/// How many entries `<sub>/wal` has.
pub fn wal_count(dir: Io.Dir, sub: []const u8) !u32 {
    assert(sub.len >= 1);
    assert(dir.handle >= 0);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wal", .{sub});
    var wal = try dir.openDir(testing.io, path, .{ .iterate = true });
    defer wal.close(testing.io);

    var it = wal.iterate();
    var count: u32 = 0;
    while (try it.next(testing.io)) |_| count += 1;
    return count;
}

/// The bytes of `<sub>/pages.db`; the caller frees them.
pub fn pages_bytes(dir: Io.Dir, sub: []const u8) ![]u8 {
    assert(sub.len >= 1);
    assert(dir.handle >= 0);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/pages.db", .{sub});
    return dir.readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20));
}

/// Deletes the odd keys `0 ..< count`; each was present.
pub fn delete_odd(db: *Db, count: u32) !void {
    assert(count >= 2);
    assert(count < 100_000);
    var key_buf: [8]u8 = undefined;
    var n: u32 = 1;
    while (n < count) : (n += 2) {
        try testing.expect(try db.delete(key_of(&key_buf, n)));
    }
}
