//! Tests for `Db.scan` and `Iterator` (ADR-0005 section 9): every range shape equals a sorted
//! model at three page sizes, a 1 MiB overflow value comes back whole, the key limit applies to
//! both bounds, `deinit` is idempotent, a scan may follow a scan, and the generation counter
//! moves on every write kind.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const iterator = @import("iterator.zig");
const fx = @import("db_fixtures.zig");
const db_mod = @import("db.zig");

const Db = fx.Db;
const Range = iterator.Range;

/// A key count coprime with the stride, so the insert order below is a permutation.
const stride: u32 = 37;

fn open_in(tmp: *testing.TmpDir, options: fx.Options) !Db {
    assert(options.page_size >= 512);
    assert(options.batch_ops_max >= 1);
    return Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
}

/// Inserts keys `0 ..< count` in a scrambled order.
fn fill_scrambled(db: *Db, scratch: []u8, value_len_max: u32, count: u32) !void {
    assert(count >= 1);
    assert(count % stride != 0);
    var key_buf: [8]u8 = undefined;
    for (0..count) |i| {
        const n: u32 = @intCast((i * stride) % count);
        const key = fx.key_of(&key_buf, n);
        try db.put(key, fx.value_of(scratch, value_len_max, n, 0));
    }
}

/// The scan of `range` yields exactly keys `lo ..< hi` (model indexes) with their values.
fn expect_scan(db: *Db, scratch: []u8, vmax: u32, range: Range, lo: u32, hi: u32) !void {
    assert(lo <= hi);
    assert(scratch.len >= vmax);
    var it = try db.scan(range);
    defer it.deinit();

    var key_buf: [8]u8 = undefined;
    var n = lo;
    while (try it.next()) |entry| : (n += 1) {
        try testing.expect(n < hi);
        try testing.expectEqualSlices(u8, fx.key_of(&key_buf, n), entry.key);
        try testing.expectEqualSlices(u8, fx.value_of(scratch, vmax, n, 0), entry.value);
    }
    try testing.expectEqual(hi, n);
    try testing.expect(try it.next() == null); // Exhausted stays exhausted.
}

fn ranges(db: *Db, scratch: []u8, vmax: u32, count: u32) !void {
    assert(count >= 20);
    assert(scratch.len >= vmax);
    var a: [8]u8 = undefined;
    var b: [8]u8 = undefined;
    const k = fx.key_of;
    const mid = count / 2;
    try expect_scan(db, scratch, vmax, .{ .start = "", .end = null }, 0, count);
    try expect_scan(db, scratch, vmax, .{ .start = "", .end = "zzzz" }, 0, count);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 0), .end = k(&b, 1) }, 0, 1);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 3), .end = null }, 3, count);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 5), .end = k(&b, mid) }, 5, mid);
    try expect_scan(db, scratch, vmax, .{ .start = "zzzz", .end = null }, 0, 0);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, count), .end = null }, 0, 0);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 7), .end = k(&b, 7) }, 0, 0);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 9), .end = k(&b, 4) }, 0, 0);
    try expect_scan(db, scratch, vmax, .{ .start = k(&a, 4), .end = "" }, 0, 0);
    _ = k(&a, 10); // A bound between two keys: "k00010!" sorts after k00010, before k00011.
    a[6] = '!';
    try expect_scan(db, scratch, vmax, .{ .start = a[0..7], .end = null }, 11, count);
    try expect_scan(db, scratch, vmax, .{ .start = "", .end = a[0..7] }, 0, 11);
}

fn exercise(page_size: u32) !void {
    assert(page_size >= 512);
    assert(page_size <= 65536);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(page_size, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    defer db.close();

    const vmax = options.value_len_max;
    try expect_scan(&db, scratch, vmax, .{ .start = "", .end = null }, 0, 0); // Empty db.
    try fill_scrambled(&db, scratch, vmax, 1);
    try expect_scan(&db, scratch, vmax, .{ .start = "", .end = null }, 0, 1); // One key.
    try db.put("k00000", fx.value_of(scratch, vmax, 0, 0));
    const count = fx.key_count(page_size);
    try fill_scrambled(&db, scratch, vmax, count);
    try ranges(&db, scratch, vmax, count);
}

test "scan: ranges equal the sorted model at 512 B" {
    try exercise(512);
}

test "scan: ranges equal the sorted model at 4 KiB" {
    try exercise(4096);
}

test "scan: ranges equal the sorted model at 64 KiB" {
    try exercise(65536);
}

test "scan: a 1 MiB overflow value comes back whole" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var options = fx.options(4096, .none);
    options.value_len_max = 1 << 20;
    options.batch_bytes_max = options.key_len_max + options.value_len_max;
    options.pool_frames_max = db_mod.pool_frames_min(options) + 32;
    options.wal_segment_bytes_max = 1 << 23;
    var db = try open_in(&tmp, options);
    defer db.close();

    const big = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(big);

    for (big, 0..) |*byte, index| byte.* = @truncate(index *% 31 +% 7);
    try db.put("a", "small");
    try db.put("b", big);
    try db.put("c", "tail");
    var it = try db.scan(.{ .start = "", .end = null });
    defer it.deinit();

    try testing.expectEqualStrings("small", (try it.next()).?.value);
    const second = (try it.next()).?;
    try testing.expectEqualStrings("b", second.key);
    try testing.expectEqual(@as(usize, 1 << 20), second.value.len);
    try testing.expectEqualSlices(u8, big, second.value);
    try testing.expectEqualStrings("tail", (try it.next()).?.value);
    try testing.expect(try it.next() == null);
}

test "scan: a bound over the key limit is KeyTooLarge" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var options = fx.options(4096, .none);
    options.key_len_max = 16;
    options.batch_bytes_max = options.key_len_max + options.value_len_max;
    options.pool_frames_max = db_mod.pool_frames_min(options) + 32;
    var db = try open_in(&tmp, options);
    defer db.close();

    const long = "0123456789abcdefX"; // 17 bytes
    try testing.expectEqual(@as(u32, 16), db.key_len_max());
    try testing.expectError(error.KeyTooLarge, db.scan(.{ .start = long, .end = null }));
    try testing.expectError(error.KeyTooLarge, db.scan(.{ .start = "", .end = long }));
    try testing.expectError(error.KeyTooLarge, db.scan(.{ .start = long, .end = "" }));
    var it = try db.scan(.{ .start = long[0..16], .end = long[0..16] }); // At the limit: fine.
    defer it.deinit();

    try testing.expect(try it.next() == null);
}

test "scan: deinit is idempotent, a scan follows a scan, a write between scans is fine" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    defer db.close();

    const vmax = options.value_len_max;
    try fill_scrambled(&db, scratch, vmax, 60);
    var it = try db.scan(.{ .start = "", .end = null });
    try testing.expect(try it.next() != null);
    it.deinit(); // Abandoned mid-scan: releases the pin.
    it.deinit();
    try testing.expectEqual(@as(u32, 0), db.state.pool.pinned_count());

    try db.put("k00061", "x"); // Between scans.
    _ = try db.delete("k00061");
    var again = try db.scan(.{ .start = "", .end = null });
    defer again.deinit();

    var n: u32 = 0;
    while (try again.next()) |_| n += 1;
    try testing.expectEqual(@as(u32, 60), n);
    try testing.expectEqual(@as(u32, 0), db.state.pool.pinned_count()); // Null released the pin.
    again.deinit();
    again.deinit();
    try expect_scan(&db, scratch, vmax, .{ .start = "k00010", .end = "k00012" }, 10, 12);
}

test "scan: get during a live scan leaves the scan intact" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    defer db.close();

    try fill_scrambled(&db, scratch, options.value_len_max, 60);
    var it = try db.scan(.{ .start = "", .end = null });
    defer it.deinit();

    try testing.expectEqualStrings("k00000", (try it.next()).?.key);
    try testing.expect(try db.get("k00030") != null);
    try testing.expectEqualStrings("k00001", (try it.next()).?.key);
}

test "scan: the generation counter moves on every write kind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_in(&tmp, fx.options(512, .none));
    defer db.close();

    var last = db.generation();
    try db.put("a", "1");
    try testing.expect(db.generation() > last);
    last = db.generation();
    _ = try db.delete("a");
    try testing.expect(db.generation() > last);
    last = db.generation();
    const ops = [_]db_mod.BatchOp{.{ .kind = .put, .key = "b", .value = "2" }};
    try db.commit_ops(&ops);
    try testing.expect(db.generation() > last);
    last = db.generation();
    try db.checkpoint();
    try testing.expect(db.generation() > last);
    last = db.generation();
    try db.flush();
    try testing.expect(db.generation() > last);
    last = db.generation();
    _ = try db.get("b"); // A read does not move it.
    var it = try db.scan(.{ .start = "", .end = null });
    it.deinit();
    try testing.expectEqual(last, db.generation());
}
