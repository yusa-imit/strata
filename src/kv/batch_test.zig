//! Tests for `kv.WriteBatch` (ADR-0005 sections 7, 8 and 10): atomic commit of many ops as one
//! group (all `page_images` frames, then one `commit` frame), every limit error provoked at
//! record time and at commit time with the files unchanged, last write wins, reuse after a
//! commit, and a crash cut at every frame boundary (and inside a frame) of the group showing none
//! of it. A crash is `fx.crash_copy`; a cut shortens the log of such a copy.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const frame = @import("../wal/frame.zig");
const reader = @import("../wal/reader.zig");
const segment = @import("../wal/segment.zig");
const db_mod = @import("db.zig");
const batch = @import("batch.zig");
const fx = @import("db_fixtures.zig");

const Db = fx.Db;
const WriteBatch = batch.WriteBatch;
const BatchOp = db_mod.BatchOp;
const ops_max: u32 = 12; // More than the 7 worst-case ops one `page_images` frame holds at 4 KiB.
const log_name = "wal-00000001.log";
const frames_max: u32 = 32;

/// Options with room for `ops_max` ops. `tight` sets the byte bound to its floor (one key and one
/// value), so two maximal values overflow it long before the op bound.
fn options_of(page_size: u32, tight: bool) fx.Options {
    assert(page_size >= 512);
    var result = fx.options(page_size, .none);
    result.batch_ops_max = ops_max;
    result.batch_bytes_max = result.key_len_max + result.value_len_max;
    if (!tight) result.batch_bytes_max *= ops_max;
    assert(result.batch_bytes_max >= result.key_len_max + result.value_len_max);
    result.pool_frames_max = db_mod.pool_frames_min(result) + 32;
    return result;
}

/// A database in `tmp` for `page_size` with room for `ops_max` ops.
fn open_small(tmp: *testing.TmpDir, page_size: u32) !Db {
    assert(page_size >= 512);
    assert(ops_max > 7);
    const options = options_of(page_size, false);
    return Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
}

const Shape = struct { count: u32, types: [frames_max]frame.Type, lsns: [frames_max]frame.Lsn };

/// Every frame of the log of `<tmp>/<name>`, in order.
fn shape_of(dir: Io.Dir, name: []const u8) !Shape {
    assert(name.len >= 1);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wal", .{name});
    var wal = try dir.openDir(testing.io, path, .{ .iterate = true });
    defer wal.close(testing.io);

    var rd: reader.Reader = undefined;
    const segment_options: segment.Options = .{ .segments_max = 8, .sync_policy = .none };
    try reader.Reader.open(&rd, testing.io, testing.allocator, wal, segment_options);
    defer rd.deinit(testing.io, testing.allocator);

    var result: Shape = .{ .count = 0, .types = @splat(.record), .lsns = @splat(0) };
    while (try rd.next(testing.io)) |got| {
        try testing.expect(result.count < frames_max);
        result.types[result.count] = got.frame_type;
        result.lsns[result.count] = got.lsn;
        result.count += 1;
    }
    assert(result.count <= frames_max);
    return result;
}

/// The bytes of the one log segment of `<tmp>/<name>`; the caller frees them.
fn log_bytes(dir: Io.Dir, name: []const u8) ![]u8 {
    assert(name.len >= 1);
    assert(dir.handle >= 0);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wal/{s}", .{ name, log_name });
    return dir.readFileAlloc(testing.io, path, testing.allocator, .limited(64 << 20));
}

/// Sets the length of the log segment of `<tmp>/<name>`.
fn cut_log(dir: Io.Dir, name: []const u8, length: u64) !void {
    assert(name.len >= 1);
    assert(length >= segment.segment_header_size);
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wal/{s}", .{ name, log_name });
    var log = try dir.openFile(testing.io, path, .{ .mode = .read_write });
    defer log.close(testing.io);

    try log.setLength(testing.io, length);
}

/// The file offset of the frame at `lsn` in the first segment (an LSN counts log bytes).
fn offset_of(lsn: frame.Lsn) u64 {
    assert(lsn >= frame.lsn_first);
    assert(lsn < frame.lsn_limit);
    return segment.segment_header_size + (lsn - frame.lsn_first);
}

fn expect_value(db: *Db, key: []const u8, want: ?[]const u8) !void {
    assert(key.len >= 1);
    assert(key.len <= 8);
    const got = try db.get(key);
    if (want) |bytes| {
        try testing.expectEqualStrings(bytes, got.?);
    } else {
        try testing.expect(got == null);
    }
}

test "batch: init returns OutOfMemory at each allocation and leaves nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_small(&tmp, 512);
    defer db.close();

    for (0..2) |fail_index| { // The op table, then the byte arena.
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var target: WriteBatch = undefined;
        const gpa = failing.allocator();
        try testing.expectError(error.OutOfMemory, WriteBatch.init(&target, gpa, &db));
        try testing.expect(failing.allocated_bytes == failing.freed_bytes);
    }
    var target: WriteBatch = undefined;
    try WriteBatch.init(&target, testing.allocator, &db);
    defer target.deinit(testing.allocator);

    try testing.expectEqual(@as(u32, 0), target.ops_len);
}

test "batch: all ops visible after commit, and after a clean reopen (matrix)" {
    for (fx.sizes) |page_size| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const options = options_of(page_size, false);
        const scratch = try testing.allocator.alloc(u8, options.value_len_max);
        defer testing.allocator.free(scratch);

        var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
        var wb: WriteBatch = undefined;
        try WriteBatch.init(&wb, testing.allocator, &db);
        defer wb.deinit(testing.allocator);

        var key_buf: [8]u8 = undefined;
        for (0..ops_max) |n| { // More ops than one 4 KiB `page_images` frame holds.
            const value = fx.value_of(scratch, options.value_len_max, @intCast(n), 1);
            try wb.put(fx.key_of(&key_buf, @intCast(n)), value);
        }
        try testing.expectEqual(ops_max, wb.ops_len);
        try wb.commit();
        try testing.expectEqual(@as(u32, 0), wb.ops_len); // Cleared: reusable.
        try fx.check(&db, scratch, options.value_len_max, ops_max, 1, true);

        var n: u32 = 1; // The same batch object again: delete the odd keys.
        while (n < ops_max) : (n += 2) try wb.delete(fx.key_of(&key_buf, n));
        try wb.commit();
        try fx.check(&db, scratch, options.value_len_max, ops_max, 1, false);
        db.close();

        db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
        defer db.close();

        try fx.check(&db, scratch, options.value_len_max, ops_max, 1, false);
    }
}

test "batch: a group is one page_images frame per op and one commit frame" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = options_of(4096, false);
    var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    try db.put("z", "0");
    try fx.crash_copy(tmp.dir, fx.sub_path, "before");
    var key_buf: [8]u8 = undefined;
    for (0..ops_max) |n| try wb.put(fx.key_of(&key_buf, @intCast(n)), "v");
    try wb.commit();
    try fx.crash_copy(tmp.dir, fx.sub_path, "after");
    const before = try shape_of(tmp.dir, "before");
    const after = try shape_of(tmp.dir, "after");
    try testing.expectEqual(before.count + ops_max + 1, after.count);
    try testing.expectEqual(frame.Type.commit, after.types[after.count - 1]);
    for (before.count..after.count - 1) |at| {
        try testing.expectEqual(frame.Type.page_images, after.types[at]);
    }
}

test "batch: empty and absent-delete-only batches log nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_small(&tmp, 512);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    try db.put("a", "1");
    try fx.crash_copy(tmp.dir, fx.sub_path, "before");
    try wb.commit(); // Empty.
    try wb.delete("nope");
    try wb.delete("nada");
    try wb.commit(); // Deletes of absent keys are fine and log nothing.
    try fx.crash_copy(tmp.dir, fx.sub_path, "after");
    const one = try log_bytes(tmp.dir, "before");
    defer testing.allocator.free(one);

    const two = try log_bytes(tmp.dir, "after");
    defer testing.allocator.free(two);

    try testing.expectEqualSlices(u8, one, two);
    try expect_value(&db, "a", "1");
}

test "batch: last write wins and put then delete of one key leaves it absent" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_small(&tmp, 512);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    try db.put("d", "old");
    try wb.put("a", "1");
    try wb.put("a", "2");
    try wb.put("b", "x");
    try wb.delete("b");
    try wb.put("c", "1");
    try wb.delete("c");
    try wb.put("c", "3");
    try wb.delete("d");
    try wb.put("d", "new");
    try wb.delete("d");
    try wb.commit();
    try expect_value(&db, "a", "2");
    try expect_value(&db, "b", null);
    try expect_value(&db, "c", "3");
    try expect_value(&db, "d", null);
}

test "batch: ops past the bound are BatchTooLarge, the batch and the files unchanged" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_small(&tmp, 512);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    try db.put("a", "1");
    var key_buf: [8]u8 = undefined;
    for (0..ops_max) |n| try wb.put(fx.key_of(&key_buf, @intCast(n)), "v");
    const bytes_len = wb.bytes_len;
    try fx.crash_copy(tmp.dir, fx.sub_path, "before");
    try testing.expectError(error.BatchTooLarge, wb.put("extra", "v"));
    try testing.expectError(error.BatchTooLarge, wb.delete("extra"));
    try testing.expectEqual(ops_max, wb.ops_len);
    try testing.expectEqual(bytes_len, wb.bytes_len);

    var ops: [ops_max + 1]BatchOp = @splat(.{ .kind = .delete, .key = "k", .value = "" });
    try testing.expectError(error.BatchTooLarge, db.commit_ops(&ops)); // At commit time too.
    try fx.crash_copy(tmp.dir, fx.sub_path, "after");
    try expect_same_files(tmp.dir, "before", "after");
}

fn expect_same_files(dir: Io.Dir, one: []const u8, two: []const u8) !void {
    assert(one.len >= 1);
    assert(two.len >= 1);
    const pages_one = try fx.pages_bytes(dir, one);
    defer testing.allocator.free(pages_one);

    const pages_two = try fx.pages_bytes(dir, two);
    defer testing.allocator.free(pages_two);

    try testing.expectEqualSlices(u8, pages_one, pages_two);
    const log_one = try log_bytes(dir, one);
    defer testing.allocator.free(log_one);

    const log_two = try log_bytes(dir, two);
    defer testing.allocator.free(log_two);

    try testing.expectEqualSlices(u8, log_one, log_two);
}

test "batch: bytes past the bound are BatchTooLarge, the batch unchanged" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = options_of(512, true);
    var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    const big = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(big);

    @memset(big, 7);
    try wb.put("a", big);
    const bytes_len = wb.bytes_len;
    try testing.expectError(error.BatchTooLarge, wb.put("b", big));
    try testing.expectEqual(@as(u32, 1), wb.ops_len);
    try testing.expectEqual(bytes_len, wb.bytes_len);
    try fx.crash_copy(tmp.dir, fx.sub_path, "before");

    var ops = [_]BatchOp{
        .{ .kind = .put, .key = "a", .value = big },
        .{ .kind = .put, .key = "b", .value = big },
    };
    try testing.expectError(error.BatchTooLarge, db.commit_ops(&ops));
    try fx.crash_copy(tmp.dir, fx.sub_path, "after");
    try expect_same_files(tmp.dir, "before", "after");
    try wb.commit(); // The batch that fit still commits.
    try expect_value(&db, "a", big);
}

test "batch: key and value limits are errors at record time and at commit time" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = options_of(512, false);
    var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
    defer db.close();

    var wb: WriteBatch = undefined;
    try WriteBatch.init(&wb, testing.allocator, &db);
    defer wb.deinit(testing.allocator);

    const long_key = try testing.allocator.alloc(u8, db.key_len_max() + 1);
    defer testing.allocator.free(long_key);

    const long_value = try testing.allocator.alloc(u8, options.value_len_max + 1);
    defer testing.allocator.free(long_value);

    @memset(long_key, 'k');
    @memset(long_value, 'v');
    try testing.expectError(error.KeyTooLarge, wb.put(long_key, "v"));
    try testing.expectError(error.KeyTooLarge, wb.delete(long_key));
    try testing.expectError(error.ValueTooLarge, wb.put("k", long_value));
    try testing.expectEqual(@as(u32, 0), wb.ops_len);
    try db.put("a", "1");
    try fx.crash_copy(tmp.dir, fx.sub_path, "before");

    var ops = [_]BatchOp{
        .{ .kind = .put, .key = "x", .value = "1" },
        .{ .kind = .put, .key = long_key, .value = "v" },
    };
    try testing.expectError(error.KeyTooLarge, db.commit_ops(&ops));
    ops[1] = .{ .kind = .put, .key = "y", .value = long_value };
    try testing.expectError(error.ValueTooLarge, db.commit_ops(&ops));
    try fx.crash_copy(tmp.dir, fx.sub_path, "after"); // Nothing applied: "x" was first.
    try expect_same_files(tmp.dir, "before", "after");
    try expect_value(&db, "x", null);
}

test "batch: a crash cut at every frame boundary of the group shows none of it (matrix)" {
    for (fx.sizes) |page_size| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const options = options_of(page_size, false);
        var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
        var wb: WriteBatch = undefined;
        try WriteBatch.init(&wb, testing.allocator, &db);
        defer wb.deinit(testing.allocator);

        try db.put("z", "0");
        try wb.put("a", "1");
        try wb.put("b", "2");
        try wb.put("c", "3");
        try wb.commit();
        try fx.crash_copy(tmp.dir, fx.sub_path, "full");
        db.close();

        const shape = try shape_of(tmp.dir, "full");
        try testing.expectEqual(@as(u32, 6), shape.count); // z: image, commit; batch: 3, commit.
        const last = shape.count - 1;
        try testing.expectEqual(frame.Type.commit, shape.types[last]);
        const log = try log_bytes(tmp.dir, "full");
        defer testing.allocator.free(log);

        try testing.expectEqual(offset_of(shape.lsns[last]) + frame.frame_header_size + 8, log.len);
        for (2..shape.count) |at| { // Cut before frame `at`, and 9 bytes into it (torn).
            for ([_]u64{ 0, 9 }) |extra| {
                try expect_cut_shows_none(&tmp, options, offset_of(shape.lsns[at]) + extra);
            }
        }
        var rec = try Db.open(testing.io, testing.allocator, tmp.dir, "full", options);
        defer rec.close();

        for ([_][]const u8{ "z", "a", "b", "c" }, [_][]const u8{ "0", "1", "2", "3" }) |k, v| {
            try expect_value(&rec, k, v);
        }
    }
}

/// A copy of the crash image `full` with the log cut to `length` recovers to just `z`.
fn expect_cut_shows_none(tmp: *testing.TmpDir, options: fx.Options, length: u64) !void {
    assert(length > segment.segment_header_size);
    assert(options.batch_ops_max == ops_max);
    var name_buf: [32]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "cut{d}", .{length});
    try fx.crash_copy(tmp.dir, "full", name);
    try cut_log(tmp.dir, name, length);
    var rec = try Db.open(testing.io, testing.allocator, tmp.dir, name, options);
    defer rec.close();

    try expect_value(&rec, "z", "0");
    for ([_][]const u8{ "a", "b", "c" }) |key| try expect_value(&rec, key, null);
}
