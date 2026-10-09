//! Shared fixtures for the `manager.zig` contract tests (`manager_test.zig`,
//! `manager_page_test.zig`, `manager_model_test.zig`): one construction path for `Options`, for
//! crafted raw files, and for checking page bytes through the raw `file.File` layer rather than
//! through the manager under test. Test-only; I/O goes through `std.testing.io`, memory through
//! `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const file_mod = @import("../file/file.zig");
const fixtures = @import("../file/file_fixtures.zig");
const header = @import("header.zig");
const manager = @import("manager.zig");

const File = file_mod.File;
const Id = header.Id;
const PageManager = manager.PageManager;

pub const page_count_max: u32 = 64;
pub const consumer_type: header.Type = @enumFromInt(130);
pub const sizes_all = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
pub const sizes_three = [_]u32{ 512, 4096, 65536 };
pub const policies = [_]file_mod.SyncPolicy{ .none, .fdatasync, .fsync, .full_fsync };

// ---------------------------------------------------------------------------------------------
// Helpers. One construction path: `opts_with` for options, `craft` for raw files, `open_crafted`
// for a manager over a crafted file.
// ---------------------------------------------------------------------------------------------

pub fn opts_with(page_size: u32, policy: file_mod.SyncPolicy) manager.Options {
    assert(header.page_size_valid(page_size));
    assert(page_count_max >= 4);
    return .{ .page_size = page_size, .page_count_max = page_count_max, .sync_policy = policy };
}

pub fn opts(page_size: u32) manager.Options {
    assert(header.page_size_valid(page_size));
    assert(policies.len == 4);
    return opts_with(page_size, .none);
}

pub fn id_of(raw: u32) Id {
    assert(raw >= 1);
    assert(raw < page_count_max);
    return @enumFromInt(raw);
}

pub fn fh_of(page_size: u32, page_count: u32) header.FileHeader {
    assert(header.page_size_valid(page_size));
    assert(page_count >= 1);
    return .{
        .page_size = page_size,
        .page_count = page_count,
        .freelist_head = null,
        .wal_lsn = 0,
    };
}

/// Creates `name` through the raw file layer: `bytes` at offset 0, then the length set to `len`
/// (growth reads as zeros, a shorter `len` is not allowed).
pub fn write_file(dir: Io.Dir, name: []const u8, bytes: []const u8, len: u64) !void {
    assert(name.len > 0);
    assert(len >= bytes.len);
    const f = try File.open(testing.io, dir, name, .{ .create = true, .truncate = true });
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, bytes, 0);
    try f.setLength(testing.io, len);
}

/// Crafts a file whose page 0 is the codec image of `fh` and whose length is `len_bytes`.
pub fn craft(dir: Io.Dir, name: []const u8, fh: header.FileHeader, len_bytes: u64) !void {
    assert(header.page_size_valid(fh.page_size));
    assert(len_bytes >= fh.page_size);
    const page = try testing.allocator.alloc(u8, fh.page_size);
    defer testing.allocator.free(page);

    header.encode_file_header(page, fh);
    try write_file(dir, name, page, len_bytes);
}

/// Crafts a `count`-page file (all pages beyond 0 never written) and opens it.
pub fn open_crafted(pm: *PageManager, dir: Io.Dir, name: []const u8, size: u32, count: u32) !void {
    assert(count >= 1);
    assert(count <= page_count_max);
    try craft(dir, name, fh_of(size, count), @as(u64, size) * count);
    try PageManager.open(pm, testing.io, dir, name, opts(size));
    try testing.expectEqual(count, pm.page_count);
    try testing.expectEqual(size, pm.page_size);
}

pub fn raw_open(dir: Io.Dir, name: []const u8) !File {
    assert(name.len > 0);
    const f = try File.open(testing.io, dir, name, .{});
    assert(!f.direct);
    return f;
}

pub fn flip_byte(f: File, offset: u64) !void {
    assert(offset < file_mod.offset_max);
    var byte: [1]u8 = undefined;
    try f.readAtAll(testing.io, &byte, offset);
    byte[0] ^= 0x01;
    try f.writeAtAll(testing.io, &byte, offset);
    var back: [1]u8 = undefined;
    try f.readAtAll(testing.io, &back, offset);
    assert(back[0] == byte[0]);
}

pub fn zero_range(f: File, size: u32, id: u32, from: u32, to: u32) !void {
    const zeros: [4096]u8 = @splat(0);
    assert(from < to);
    assert(to <= size and to <= zeros.len);
    try f.writeAtAll(testing.io, zeros[0 .. to - from], @as(u64, size) * id + from);
}

pub fn expect_open_error(expected: anyerror, dir: Io.Dir, name: []const u8, size: u32) !void {
    assert(name.len > 0);
    assert(header.page_size_valid(size));
    var pm: PageManager = undefined;
    try testing.expectError(expected, PageManager.open(&pm, testing.io, dir, name, opts(size)));
}

pub fn expect_create_error(expected: anyerror, dir: Io.Dir, name: []const u8, size: u32) !void {
    assert(name.len > 0);
    assert(header.page_size_valid(size));
    var pm: PageManager = undefined;
    try testing.expectError(expected, PageManager.create(&pm, testing.io, dir, name, opts(size)));
}

/// Opens, checks the page count, closes: proves a file is accepted and its lock is free.
pub fn expect_open_ok(dir: Io.Dir, name: []const u8, size: u32, count: u32) !void {
    assert(count >= 1);
    assert(header.page_size_valid(size));
    var pm: PageManager = undefined;
    try PageManager.open(&pm, testing.io, dir, name, opts(size));
    defer pm.close(testing.io);

    try testing.expectEqual(count, pm.page_count);
    try testing.expectEqual(size, pm.page_size);
}

pub fn expect_fresh(pm: *PageManager, size: u32) !void {
    assert(header.page_size_valid(size));
    assert(page_count_max > 1);
    try testing.expectEqual(size, pm.page_size);
    try testing.expectEqual(@as(u32, 1), pm.page_count);
    try testing.expectEqual(@as(?Id, null), pm.freelist_head);
    try testing.expectEqual(@as(u64, 0), pm.wal_lsn);
    try testing.expectEqual(page_count_max, pm.page_count_max);
    try testing.expectEqual(@as(u64, size), try pm.file.length(testing.io));
}

/// The bytes on disk after `create` are exactly the canonical codec image of a fresh file.
pub fn expect_disk_fresh(dir: Io.Dir, name: []const u8, size: u32) !void {
    const gpa = testing.allocator;
    assert(header.page_size_valid(size));
    assert(name.len > 0);
    const want = try gpa.alloc(u8, size);
    defer gpa.free(want);

    const got = try gpa.alloc(u8, size);
    defer gpa.free(got);

    header.encode_file_header(want, fh_of(size, 1));
    const raw = try raw_open(dir, name);
    defer raw.close(testing.io);

    try testing.expectEqual(@as(u64, size), try raw.length(testing.io));
    try raw.readAtAll(testing.io, got, 0);
    try testing.expectEqualSlices(u8, want, got);
}

/// Fills the payload with `pattern(seed)`, poisons the header bytes, writes page `id`.
pub fn write_pattern(pm: *PageManager, id: u32, buf: []u8, seed: u32, lsn: u64) !void {
    assert(buf.len == pm.page_size);
    assert(id >= 1);
    @memset(buf[0..header.header_size], 0xCC); // `write` must overwrite stale header bytes.
    fixtures.pattern(buf[header.header_size..], seed);
    try pm.write(testing.io, id_of(id), buf, .{ .page_type = consumer_type, .lsn = lsn });
}

/// Reads page `id` through the manager and compares against `pattern(seed)` and `lsn`.
pub fn expect_pattern(pm: *PageManager, id: u32, seed: u32, lsn: u64) !void {
    const gpa = testing.allocator;
    assert(id >= 1 and id < pm.page_count);
    assert(pm.page_size >= header.page_size_min);
    const got = try gpa.alloc(u8, pm.page_size);
    defer gpa.free(got);

    const want = try gpa.alloc(u8, pm.page_size);
    defer gpa.free(want);

    fixtures.pattern(want[header.header_size..], seed);
    const h = try pm.read(testing.io, id_of(id), got);
    try testing.expectEqual(consumer_type, h.page_type);
    try testing.expectEqual(lsn, h.lsn);
    try testing.expectEqualSlices(u8, want[header.header_size..], got[header.header_size..]);
}

pub fn expect_read_error(pm: *PageManager, id: u32, expected: anyerror) !void {
    const gpa = testing.allocator;
    assert(id >= 1);
    assert(pm.page_size >= header.page_size_min);
    const buf = try gpa.alloc(u8, pm.page_size);
    defer gpa.free(buf);

    try testing.expectError(expected, pm.read(testing.io, id_of(id), buf));
}

/// The page on disk (read raw) equals `want` byte for byte and decodes under `id`.
pub fn expect_disk_equals(pm: *PageManager, id: u32, want: []const u8) !void {
    const gpa = testing.allocator;
    assert(want.len == pm.page_size);
    assert(id >= 1);
    const got = try gpa.alloc(u8, want.len);
    defer gpa.free(got);

    try pm.file.readAtAll(testing.io, got, @as(u64, pm.page_size) * id);
    try testing.expectEqualSlices(u8, want, got);
    _ = try header.decode(got, id_of(id));
}

/// Page 0 on disk still decodes to a file header with `count` pages: writes never touch it.
pub fn expect_page0_intact(pm: *PageManager, count: u32) !void {
    const gpa = testing.allocator;
    assert(count >= 1);
    assert(pm.page_size >= header.page_size_min);
    const page = try gpa.alloc(u8, pm.page_size);
    defer gpa.free(page);

    try pm.file.readAtAll(testing.io, page, 0);
    const fh = try header.decode_file_header(page);
    try testing.expectEqual(count, fh.page_count);
    try testing.expectEqual(pm.page_size, fh.page_size);
}

pub fn expect_flip_open(
    raw: File,
    dir: Io.Dir,
    name: []const u8,
    size: u32,
    at: u64,
    want: anyerror,
) !void {
    assert(at < size);
    assert(name.len > 0);
    try flip_byte(raw, at);
    try expect_open_error(want, dir, name, size);
    try flip_byte(raw, at); // Restored: the same open must now succeed (lock was released too).
    try expect_open_ok(dir, name, size, 3);
}

pub fn expect_flip_read(pm: *PageManager, raw: File, id: u32, at: u64, want: anyerror) !void {
    assert(at < pm.page_size);
    assert(id >= 1);
    const base = @as(u64, pm.page_size) * id;
    try flip_byte(raw, base + at);
    try expect_read_error(pm, id, want);
    try flip_byte(raw, base + at);
    try expect_pattern(pm, id, id * 11, 500 + id);
}
