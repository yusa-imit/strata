//! Tests for the commit frame and commit-bounded recovery of `kv.Db` (ADR-0005 sections 4, 7
//! and 8): a `put` or `delete` logs its `page_images` frame and then one `commit` frame, an
//! absent-key `delete` logs nothing, a log that ends in frames after the last commit point
//! shows the state before that group and is cut back, and recovering twice equals once.
//! A crash is `fx.crash_copy`; an unfinished group is a crash image whose last `commit` frame
//! was cut off the file.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const frame = @import("../wal/frame.zig");
const reader = @import("../wal/reader.zig");
const fx = @import("db_fixtures.zig");

const Db = fx.Db;
const crash_name = "crash";
const second_name = "crash2";
const third_name = "crash3";
const log_name = "wal-00000001.log";
const frames_max: u32 = 32;
const commit_frame_len: u64 = frame.frame_header_size + 8;

const Shape = struct {
    count: u32,
    types: [frames_max]frame.Type,
    lsns: [frames_max]frame.Lsn,
    firsts: [frames_max]frame.Lsn,
};

/// Every frame of the log of `<tmp>/<name>`, in order (`firsts` is set for commit frames).
fn shape_of(dir: Io.Dir, name: []const u8) !Shape {
    assert(name.len >= 1);
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/wal", .{name});
    var wal = try dir.openDir(testing.io, path, .{ .iterate = true });
    defer wal.close(testing.io);

    var rd: reader.Reader = undefined;
    const segment_options: @import("../wal/segment.zig").Options = .{
        .segments_max = 8,
        .sync_policy = .none,
    };
    try reader.Reader.open(&rd, testing.io, testing.allocator, wal, segment_options);
    defer rd.deinit(testing.io, testing.allocator);

    var result: Shape = .{
        .count = 0,
        .types = @splat(.record),
        .lsns = @splat(0),
        .firsts = @splat(0),
    };
    while (try rd.next(testing.io)) |got| {
        try testing.expect(result.count < frames_max);
        result.types[result.count] = got.frame_type;
        result.lsns[result.count] = got.lsn;
        if (got.frame_type == .commit) {
            result.firsts[result.count] = frame.commit_first_lsn(got.payload);
        }
        result.count += 1;
    }
    assert(result.count <= frames_max);
    assert(result.count == 0 or result.lsns[result.count - 1] >= frame.lsn_first);
    return result;
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

/// Three puts in a fresh database, crashed (no flush) into `crash_name`; `db` is closed.
fn three_puts_crashed(tmp: *testing.TmpDir, options: fx.Options) !void {
    assert(options.page_size >= 512);
    assert(options.batch_ops_max >= 1);
    var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    db.close();
}

test "commit: a put logs page_images then a commit frame, an absent delete logs nothing" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    var db = try Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
    defer db.close();

    try db.put("a", "1");
    try db.put("b", "2");
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    try testing.expect(!(try db.delete("zz"))); // Absent: no frame, no commit point.
    try fx.crash_copy(tmp.dir, fx.sub_path, second_name);
    const shape = try shape_of(tmp.dir, crash_name);
    try testing.expectEqual(@as(u32, 4), shape.count);
    for ([_]u32{ 0, 2 }) |at| {
        try testing.expectEqual(frame.Type.page_images, shape.types[at]);
        try testing.expectEqual(frame.Type.commit, shape.types[at + 1]);
        try testing.expectEqual(shape.lsns[at], shape.firsts[at + 1]); // The group's first frame.
    }
    const after = try shape_of(tmp.dir, second_name);
    try testing.expectEqual(shape.count, after.count);
}

test "commit: a crash after the commit frame shows the put" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    try three_puts_crashed(&tmp, options);
    var rec = try Db.open(testing.io, testing.allocator, tmp.dir, crash_name, options);
    defer rec.close();

    try expect_value(&rec, "a", "1");
    try expect_value(&rec, "c", "3");
}

/// Cuts the commit frame of the last put off the log of `crash_name`.
fn cut_last_commit(tmp: *testing.TmpDir) !u64 {
    assert(commit_frame_len == 25);
    assert(crash_name.len >= 1);
    var sub = try tmp.dir.openDir(testing.io, crash_name, .{ .iterate = true });
    defer sub.close(testing.io);

    var wal = try sub.openDir(testing.io, "wal", .{ .iterate = true });
    defer wal.close(testing.io);

    var log = try wal.openFile(testing.io, log_name, .{ .mode = .read_write });
    defer log.close(testing.io);

    const size = try log.length(testing.io);
    try testing.expect(size > commit_frame_len);
    try log.setLength(testing.io, size - commit_frame_len);
    return size - commit_frame_len;
}

test "commit: page_images frames after the last commit are not applied and are cut" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    try three_puts_crashed(&tmp, options);
    const cut_size = try cut_last_commit(&tmp);
    const before = try shape_of(tmp.dir, crash_name);
    try testing.expectEqual(frame.Type.page_images, before.types[before.count - 1]);

    var rec = try Db.open(testing.io, testing.allocator, tmp.dir, crash_name, options);
    try expect_value(&rec, "a", "1");
    try expect_value(&rec, "b", "2");
    try expect_value(&rec, "c", null); // The unfinished group is not visible.
    try fx.crash_copy(tmp.dir, crash_name, second_name); // The log as recovery left it.
    try rec.put("d", "4"); // Appends past the truncated tail.
    rec.close();

    const after = try shape_of(tmp.dir, second_name);
    try testing.expectEqual(before.count - 1, after.count);
    try testing.expectEqual(frame.Type.commit, after.types[after.count - 1]);
    try testing.expect(after.lsns[after.count - 1] < before.lsns[before.count - 1]);
    try testing.expect(cut_size > 0);
    rec = try Db.open(testing.io, testing.allocator, tmp.dir, crash_name, options);
    defer rec.close();

    try expect_value(&rec, "d", "4");
    try expect_value(&rec, "c", null);
}

test "commit: recovering twice equals recovering once" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    try three_puts_crashed(&tmp, options);
    _ = try cut_last_commit(&tmp);
    var once = try Db.open(testing.io, testing.allocator, tmp.dir, crash_name, options);
    try fx.crash_copy(tmp.dir, crash_name, second_name); // Right after the first recovery.
    once.close();

    const first_bytes = try fx.pages_bytes(tmp.dir, second_name);
    defer testing.allocator.free(first_bytes);

    const first_shape = try shape_of(tmp.dir, second_name);
    var twice = try Db.open(testing.io, testing.allocator, tmp.dir, second_name, options);
    try fx.crash_copy(tmp.dir, second_name, third_name); // Right after the second.
    twice.close();

    const second_bytes = try fx.pages_bytes(tmp.dir, third_name);
    defer testing.allocator.free(second_bytes);

    try testing.expectEqualSlices(u8, first_bytes, second_bytes);
    const second_shape = try shape_of(tmp.dir, third_name);
    try testing.expectEqual(first_shape.count, second_shape.count);
    const last = first_shape.count - 1;
    try testing.expectEqual(first_shape.lsns[last], second_shape.lsns[last]);
}
