//! Tests for recovery on `kv.Db.open` and `Db.checkpoint` (ADR-0005 sections 4, 7 and 11, item
//! "Recovery on open"). A crash is `fx.crash_copy`: the page file and the log as they are on
//! disk while the `Db` is open and nothing was flushed, which is what a killed process leaves.
//! Covered: replay at three page sizes, replay twice equals replay once, replay starting at the
//! checkpoint (the older segments are gone), a bounded log, a missing or emptied log beside
//! `wal_lsn` 0 and not 0, a crafted wrong-type root, a torn log tail, and no allocation after a
//! recovering `open`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const fx = @import("db_fixtures.zig");

const Db = fx.Db;
const crash_name = "crash";

fn open_named(tmp: *testing.TmpDir, name: []const u8, options: fx.Options) !Db {
    assert(name.len >= 1);
    assert(options.page_size >= 512);
    return Db.open(testing.io, testing.allocator, tmp.dir, name, options);
}

/// The `wal_lsn` of the page file in `<tmp>/<name>`; the database must not be open.
fn wal_lsn_of(tmp: *testing.TmpDir, name: []const u8, options: fx.Options) !u64 {
    assert(name.len >= 1);
    assert(options.page_size >= 512);
    var sub = try tmp.dir.openDir(testing.io, name, .{ .iterate = true });
    defer sub.close(testing.io);

    var pm: manager.PageManager = undefined;
    try manager.PageManager.open(&pm, testing.io, sub, "pages.db", .{
        .page_size = options.page_size,
        .page_count_max = options.page_count_max,
        .sync_policy = .none,
    });
    defer pm.close(testing.io);

    return pm.wal_lsn;
}

fn crash_and_recover(page_size: u32) !void {
    assert(page_size >= 512);
    assert(page_size <= 65536);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(page_size, .none);
    const count = fx.key_count(page_size);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    try fx.fill(&db, scratch, options.value_len_max, count, 0);
    try fx.delete_odd(&db, count);
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name); // No flush: the pages are not on disk.
    db.close();

    try testing.expectEqual(@as(u64, 0), try wal_lsn_of(&tmp, crash_name, options));
    var rec = try open_named(&tmp, crash_name, options);
    try fx.check(&rec, scratch, options.value_len_max, count, 0, false);
    try fx.fill(&rec, scratch, options.value_len_max, count, 1); // The log continues past it.
    rec.close();

    rec = try open_named(&tmp, crash_name, options);
    defer rec.close();

    try fx.check(&rec, scratch, options.value_len_max, count, 1, true);
}

test "recover: a crash without flush replays every put and delete at 512 B" {
    try crash_and_recover(512);
}

test "recover: a crash without flush replays every put and delete at 4 KiB" {
    try crash_and_recover(4096);
}

test "recover: a crash without flush replays every put and delete at 64 KiB" {
    try crash_and_recover(65536);
}

fn replay_twice(page_size: u32) !void {
    assert(page_size >= 512);
    assert(page_size <= 65536);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(page_size, .none);
    const count = fx.key_count(page_size);
    assert(count >= 2); // The odd keys are deleted: there must be some.
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    try fx.fill(&db, scratch, options.value_len_max, count, 0);
    try fx.delete_odd(&db, count);
    try fx.crash_copy(tmp.dir, fx.sub_path, "once");
    db.close();

    var once = try open_named(&tmp, "once", options); // Replays, then crashes again at once:
    try fx.crash_copy(tmp.dir, "once", "twice"); // `twice` is replayed pages plus the same log.
    once.close();

    var twice = try open_named(&tmp, "twice", options); // Replays the same frames again.
    try fx.check(&twice, scratch, options.value_len_max, count, 0, false);
    twice.close();

    const bytes_once = try fx.pages_bytes(tmp.dir, "once");
    defer testing.allocator.free(bytes_once);

    const bytes_twice = try fx.pages_bytes(tmp.dir, "twice");
    defer testing.allocator.free(bytes_twice);

    try testing.expectEqualSlices(u8, bytes_once, bytes_twice);
    var again = try open_named(&tmp, "once", options); // Clean now: nothing changes.
    again.close();

    const bytes_again = try fx.pages_bytes(tmp.dir, "once");
    defer testing.allocator.free(bytes_again);

    try testing.expectEqualSlices(u8, bytes_once, bytes_again);
}

test "recover: replaying twice equals replaying once at 512 B" {
    try replay_twice(512);
}

test "recover: replaying twice equals replaying once at 4 KiB" {
    try replay_twice(4096);
}

test "recover: replaying twice equals replaying once at 64 KiB" {
    try replay_twice(65536);
}

fn small_log_options() fx.Options {
    var options = fx.options(512, .none);
    options.wal_segments_max = 8;
    options.wal_segment_bytes_max = 64 * 1024;
    assert(options.wal_segments_max >= 2);
    return options;
}

test "recover: after a checkpoint replay starts at it and the older segments are gone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = small_log_options();
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    try fx.fill(&db, scratch, options.value_len_max, 400, 0);
    const segments_before = try fx.wal_count(tmp.dir, fx.sub_path);
    try testing.expect(segments_before >= 2);
    try db.checkpoint();
    try testing.expectEqual(@as(u32, 1), try fx.wal_count(tmp.dir, fx.sub_path));
    try fx.fill(&db, scratch, options.value_len_max, 100, 1); // Frames past the checkpoint.
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    db.close();

    try testing.expect(try wal_lsn_of(&tmp, crash_name, options) != 0);
    var rec = try open_named(&tmp, crash_name, options);
    defer rec.close();

    var key_buf: [8]u8 = undefined;
    for (0..400) |n| { // 0 ..< 100 are generation 1, the rest generation 0.
        const gen: u32 = if (n < 100) 1 else 0;
        const want = fx.value_of(scratch, options.value_len_max, @intCast(n), gen);
        const got = (try rec.get(fx.key_of(&key_buf, @intCast(n)))).?;
        try testing.expectEqualSlices(u8, want, got);
    }
}

test "recover: checkpoint keeps the log bounded, a clean one is a no-op" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = small_log_options();
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    try db.checkpoint(); // Fresh and clean: nothing to do.
    try testing.expectEqual(@as(u32, 1), try fx.wal_count(tmp.dir, fx.sub_path));
    for (0..4) |round| {
        try fx.fill(&db, scratch, options.value_len_max, 400, @intCast(round));
        const live = try fx.wal_count(tmp.dir, fx.sub_path);
        try testing.expect(live >= 2);
        try testing.expect(live < options.wal_segments_max);
        try db.checkpoint();
        try testing.expectEqual(@as(u32, 1), try fx.wal_count(tmp.dir, fx.sub_path));
    }
    const before = try fx.pages_bytes(tmp.dir, fx.sub_path);
    defer testing.allocator.free(before);

    try db.checkpoint(); // Clean again: not even a checkpoint frame.
    const after = try fx.pages_bytes(tmp.dir, fx.sub_path);
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name); // A crash right after a checkpoint.
    db.close();

    var rec = try open_named(&tmp, crash_name, options);
    defer rec.close();

    try fx.check(&rec, scratch, options.value_len_max, 400, 3, true);
}

test "recover: checkpoint frees the page ids a delete left pending" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    defer db.close();

    try fx.fill(&db, scratch, options.value_len_max, 400, 0);
    try db.checkpoint();
    var key_buf: [8]u8 = undefined;
    var n: u32 = 0;
    while (db.pending_frees() == 0) : (n += 1) {
        try testing.expect(n < 400);
        try testing.expect(try db.delete(fx.key_of(&key_buf, n)));
    }
    try db.checkpoint();
    try testing.expectEqual(@as(u32, 0), db.pending_frees());
    try testing.expect((try db.get(fx.key_of(&key_buf, 399))) != null);
}

fn emptied_log(flush_first: bool, remove_dir: bool) !void {
    assert(crash_name.len >= 1);
    assert(!std.mem.eql(u8, crash_name, fx.sub_path));
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    var db = try open_named(&tmp, fx.sub_path, options);
    try db.put("alpha", "one");
    if (flush_first) try db.flush(); // `wal_lsn` is not 0 then.
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    db.close();

    const wal_lsn = try wal_lsn_of(&tmp, crash_name, options);
    try testing.expectEqual(flush_first, wal_lsn != 0);
    var sub = try tmp.dir.openDir(testing.io, crash_name, .{ .iterate = true });
    defer sub.close(testing.io);

    const before = try fx.pages_bytes(tmp.dir, crash_name);
    defer testing.allocator.free(before);

    try sub.deleteFile(testing.io, "wal/wal-00000001.log");
    if (remove_dir) try sub.deleteDir(testing.io, "wal");
    try testing.expectError(error.Corrupted, open_named(&tmp, crash_name, options));
    const after = try fx.pages_bytes(tmp.dir, crash_name);
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after); // Nothing was replayed or repaired.
}

test "recover: an emptied wal is Corrupted beside wal_lsn 0 and not 0, pages unchanged" {
    try emptied_log(false, false);
    try emptied_log(true, false);
}

test "recover: a deleted wal directory is Corrupted beside wal_lsn 0 and not 0" {
    try emptied_log(false, true);
    try emptied_log(true, true);
}

test "recover: a sealed page 1 of another type is Corrupted" {
    const types = [_]header.Type{ .free_trunk, .btree_overflow };
    for (types) |page_type| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const options = fx.options(512, .none);
        var db = try open_named(&tmp, fx.sub_path, options);
        try db.put("k", "v");
        db.close();

        var sub = try tmp.dir.openDir(testing.io, fx.sub_path, .{ .iterate = true });
        defer sub.close(testing.io);

        var pm: manager.PageManager = undefined;
        try manager.PageManager.open(&pm, testing.io, sub, "pages.db", .{
            .page_size = 512,
            .page_count_max = options.page_count_max,
            .sync_policy = .none,
        });
        var page: [512]u8 = @splat(0);
        try pm.write(testing.io, @enumFromInt(1), &page, .{ .page_type = page_type, .lsn = 0 });
        try pm.sync(testing.io);
        pm.close(testing.io);
        try testing.expectError(error.Corrupted, open_named(&tmp, fx.sub_path, options));
    }
}

test "recover: a torn log tail is repaired and the last put is lost" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    var db = try open_named(&tmp, fx.sub_path, options);
    try db.put("a", "1");
    try db.put("b", "2");
    try db.put("c", "3");
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    db.close();

    var sub = try tmp.dir.openDir(testing.io, crash_name, .{ .iterate = true });
    defer sub.close(testing.io);

    var segment = try sub.openFile(testing.io, "wal/wal-00000001.log", .{ .mode = .read_write });
    const size = try segment.length(testing.io);
    try segment.setLength(testing.io, size - 3); // The last frame loses its tail.
    segment.close(testing.io);

    var rec = try open_named(&tmp, crash_name, options);
    try testing.expectEqualStrings("1", (try rec.get("a")).?);
    try testing.expectEqualStrings("2", (try rec.get("b")).?);
    try testing.expect((try rec.get("c")) == null);
    try rec.put("d", "4"); // The writer continues at the repaired tail.
    rec.close();

    rec = try open_named(&tmp, crash_name, options);
    defer rec.close();

    try testing.expectEqualStrings("2", (try rec.get("b")).?);
    try testing.expectEqualStrings("4", (try rec.get("d")).?);
    try testing.expect((try rec.get("c")) == null);
}

test "recover: no allocation after a recovering open, checkpoint included" {
    for (fx.sizes) |page_size| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const options = fx.options(page_size, .none);
        const count = fx.key_count(page_size);
        const scratch = try testing.allocator.alloc(u8, options.value_len_max);
        defer testing.allocator.free(scratch);

        var db = try open_named(&tmp, fx.sub_path, options);
        try fx.fill(&db, scratch, options.value_len_max, count, 0);
        try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
        db.close();

        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        var rec = try Db.open(testing.io, failing.allocator(), tmp.dir, crash_name, options);
        failing.fail_index = failing.alloc_index; // Replay's scratch is freed by now.
        try fx.check(&rec, scratch, options.value_len_max, count, 0, true);
        try fx.delete_odd(&rec, count);
        try rec.checkpoint();
        try fx.fill(&rec, scratch, options.value_len_max, count, 1);
        rec.close();
        try testing.expectEqual(failing.alloc_index, failing.fail_index);
    }
}

test "recover: OutOfMemory at every allocation of a recovering open leaves it replayable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_named(&tmp, fx.sub_path, options);
    try fx.fill(&db, scratch, options.value_len_max, 100, 0);
    try fx.crash_copy(tmp.dir, fx.sub_path, crash_name);
    db.close();

    var succeeded = false;
    for (0..64) |fail_at| { // Bound: `open` makes far fewer than 64 allocations.
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        const gpa = failing.allocator();
        var rec = Db.open(testing.io, gpa, tmp.dir, crash_name, options) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        try fx.check(&rec, scratch, options.value_len_max, 100, 0, true);
        rec.close();
        succeeded = true;
        break;
    }
    try testing.expect(succeeded);
}
