//! Tests for `kv.Db` create, put, get, delete, flush and close (ADR-0005 sections 1 to 3, 5 to
//! 7): round trips at three page sizes, reopen after a clean close, no allocation after `open`,
//! `OutOfMemory` at every allocation of `open`, the key and value limit edges, the directory
//! layout and the errors that name a half-created or foreign directory.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const writer_mod = @import("../wal/writer.zig");
const node = @import("../btree/node.zig");
const fx = @import("db_fixtures.zig");

const Db = fx.Db;

fn open_in(tmp: *testing.TmpDir, options: fx.Options) !Db {
    assert(options.page_size >= 512);
    assert(options.batch_ops_max >= 1);
    return Db.open(testing.io, testing.allocator, tmp.dir, fx.sub_path, options);
}

fn exercise(page_size: u32) !void {
    assert(page_size >= 512);
    assert(page_size <= 65536);
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(page_size, .none);
    const count = fx.key_count(page_size);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    try fx.fill(&db, scratch, options.value_len_max, count, 0);
    try fx.check(&db, scratch, options.value_len_max, count, 0, true);
    try fx.delete_odd(&db, count);
    try fx.check(&db, scratch, options.value_len_max, count, 0, false);
    try db.flush();
    db.close();

    db = try open_in(&tmp, options); // Clean close: every key is there without a replay.
    try fx.check(&db, scratch, options.value_len_max, count, 0, false);
    try fx.fill(&db, scratch, options.value_len_max, count, 1); // Overwrite and re-insert.
    db.close();

    db = try open_in(&tmp, options);
    defer db.close();

    try fx.check(&db, scratch, options.value_len_max, count, 1, true);
}

test "db: round trip, delete and reopen at 512 B" {
    try exercise(512);
}

test "db: round trip, delete and reopen at 4 KiB" {
    try exercise(4096);
}

test "db: round trip, delete and reopen at 64 KiB" {
    try exercise(65536);
}

test "db: round trip under every sync policy" {
    const policies = [_]@import("../file/file.zig").SyncPolicy{ .fdatasync, .fsync, .full_fsync };
    for (policies) |policy| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        const options = fx.options(4096, policy);
        var db = try open_in(&tmp, options);
        try db.put("alpha", "one");
        try db.put("beta", "two");
        db.close();

        db = try open_in(&tmp, options);
        defer db.close();

        try testing.expectEqualStrings("one", (try db.get("alpha")).?);
        try testing.expectEqualStrings("two", (try db.get("beta")).?);
    }
}

test "db: no allocation after open" {
    for (fx.sizes) |page_size| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        var failing = testing.FailingAllocator.init(testing.allocator, .{});
        const options = fx.options(page_size, .none);
        const scratch = try testing.allocator.alloc(u8, options.value_len_max);
        defer testing.allocator.free(scratch);

        var db = try Db.open(testing.io, failing.allocator(), tmp.dir, fx.sub_path, options);
        failing.fail_index = failing.alloc_index; // Every allocation from here on fails.
        const count = fx.key_count(page_size);
        try fx.fill(&db, scratch, options.value_len_max, count, 0);
        try fx.delete_odd(&db, count);
        try db.flush();
        try fx.check(&db, scratch, options.value_len_max, count, 0, false);
        db.close(); // Frees only: `close` never allocates.
        try testing.expectEqual(failing.alloc_index, failing.fail_index);
    }
}

test "db: OutOfMemory at every allocation of open leaves nothing behind" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(4096, .none);
    var succeeded = false;
    for (0..64) |fail_at| { // Bound: `open` makes far fewer than 64 allocations.
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_at });
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "oom{d}", .{fail_at});
        var db = Db.open(testing.io, failing.allocator(), tmp.dir, name, options) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            try expect_unlocked(tmp.dir, name); // The page file lock is released.
            continue;
        };
        db.close();
        succeeded = true;
        break;
    }
    try testing.expect(succeeded);
}

fn expect_unlocked(dir: Io.Dir, name: []const u8) !void {
    assert(name.len >= 1);
    assert(dir.handle >= 0);
    var sub = dir.openDir(testing.io, name, .{ .iterate = true }) catch |err| {
        try testing.expectEqual(error.FileNotFound, err); // Failed before the directory existed.
        return;
    };
    defer sub.close(testing.io);

    var pm: manager.PageManager = undefined;
    const options: manager.Options = .{
        .page_size = 4096,
        .page_count_max = 8192,
        .sync_policy = .none,
    };
    manager.PageManager.open(&pm, testing.io, sub, "pages.db", options) catch |err| {
        try testing.expectEqual(error.FileNotFound, err); // Failed before the page file existed.
        return;
    };
    pm.close(testing.io);
}

test "db: key limit is clamped per page size and its edges are exact" {
    const edges = [_]struct { page_size: u32, key_len_max: u32 }{
        .{ .page_size = 512, .key_len_max = 108 },
        .{ .page_size = 4096, .key_len_max = 1004 },
    };
    for (edges) |edge| {
        var tmp = testing.tmpDir(.{ .iterate = true });
        defer tmp.cleanup();

        var db = try open_in(&tmp, fx.options(edge.page_size, .none));
        defer db.close();

        try testing.expectEqual(edge.key_len_max, db.key_len_max());
        try testing.expectEqual(node.key_len_max(edge.page_size), db.key_len_max());
        var key: [1100]u8 = undefined;
        @memset(&key, 'x');
        const at_max = key[0..edge.key_len_max];
        const over = key[0 .. edge.key_len_max + 1];
        try db.put(at_max, "v");
        try testing.expectEqualStrings("v", (try db.get(at_max)).?);
        try testing.expectError(error.KeyTooLarge, db.put(over, "v"));
        try testing.expectError(error.KeyTooLarge, db.get(over));
        try testing.expectError(error.KeyTooLarge, db.delete(over));
        try testing.expect(try db.delete(at_max));
    }
}

test "db: options key_len_max below the page limit wins" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var options = fx.options(4096, .none);
    options.key_len_max = 16;
    var db = try open_in(&tmp, options);
    defer db.close();

    try testing.expectEqual(@as(u32, 16), db.key_len_max());
    try db.put("0123456789abcdef", "v");
    try testing.expectError(error.KeyTooLarge, db.put("0123456789abcdefg", "v"));
}

test "db: value limit edge" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    var db = try open_in(&tmp, options);
    defer db.close();

    const big = try testing.allocator.alloc(u8, options.value_len_max + 1);
    defer testing.allocator.free(big);

    @memset(big, 7);
    try db.put("k", big[0..options.value_len_max]);
    try testing.expectEqual(options.value_len_max, (try db.get("k")).?.len);
    try testing.expectError(error.ValueTooLarge, db.put("k", big));
    try testing.expectEqual(options.value_len_max, (try db.get("k")).?.len); // Unchanged.
}

test "db: get and delete of a missing key" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_in(&tmp, fx.options(512, .none));
    defer db.close();

    try testing.expect((try db.get("nothing")) == null);
    try testing.expect(!(try db.delete("nothing")));
    try db.put("a", "1");
    try testing.expect(try db.delete("a"));
    try testing.expect(!(try db.delete("a")));
    try testing.expect((try db.get("a")) == null);
    try db.put("", "empty key"); // A zero-length key is a key.
    try testing.expectEqualStrings("empty key", (try db.get("")).?);
}

test "db: create leaves exactly pages.db and wal/wal-00000001.log" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var db = try open_in(&tmp, fx.options(4096, .none));
    defer db.close();

    var sub = try tmp.dir.openDir(testing.io, fx.sub_path, .{ .iterate = true });
    defer sub.close(testing.io);

    var seen: u32 = 0;
    var it = sub.iterate();
    while (try it.next(testing.io)) |entry| {
        seen += 1;
        const ok = std.mem.eql(u8, entry.name, "pages.db") or std.mem.eql(u8, entry.name, "wal");
        try testing.expect(ok);
    }
    try testing.expectEqual(@as(u32, 2), seen);
    var wal = try sub.openDir(testing.io, "wal", .{ .iterate = true });
    defer wal.close(testing.io);

    var wal_it = wal.iterate();
    const only = (try wal_it.next(testing.io)).?;
    try testing.expectEqualStrings("wal-00000001.log", only.name);
    try testing.expect((try wal_it.next(testing.io)) == null);
}

test "db: an existing empty directory is created into" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, fx.sub_path, .default_dir);
    var db = try open_in(&tmp, fx.options(512, .none));
    defer db.close();

    try db.put("k", "v");
    try testing.expectEqualStrings("v", (try db.get("k")).?);
}

test "db: a second open of a held database is WouldBlock" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    var db = try open_in(&tmp, options);
    try db.put("k", "v");
    try testing.expectError(error.WouldBlock, open_in(&tmp, options));
    try testing.expectEqualStrings("v", (try db.get("k")).?); // Still usable.
    db.close();

    db = try open_in(&tmp, options); // Released by close.
    db.close();
}

test "db: a foreign non-empty directory is Corrupted and untouched" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, fx.sub_path, .default_dir);
    var sub = try tmp.dir.openDir(testing.io, fx.sub_path, .{ .iterate = true });
    defer sub.close(testing.io);

    try sub.writeFile(testing.io, .{ .sub_path = "notes.txt", .data = "foreign bytes" });
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
    var buf: [32]u8 = undefined;
    const got = try sub.readFile(testing.io, "notes.txt", &buf);
    try testing.expectEqualStrings("foreign bytes", got);
    var count: u32 = 0;
    var it = sub.iterate();
    while (try it.next(testing.io)) |_| count += 1;
    try testing.expectEqual(@as(u32, 1), count);
}

fn create_closed(tmp: *testing.TmpDir, options: fx.Options) !void {
    assert(options.page_size >= 512);
    assert(options.wal_segments_max >= 2);
    var db = try open_in(tmp, options);
    try db.put("k", "v");
    db.close();
}

fn sub_dir(tmp: *testing.TmpDir) !Io.Dir {
    assert(tmp.dir.handle >= 0);
    assert(fx.sub_path.len >= 1);
    return tmp.dir.openDir(testing.io, fx.sub_path, .{ .iterate = true });
}

test "db: a page file of another page size is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try create_closed(&tmp, fx.options(512, .none));
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(4096, .none)));
}

test "db: a damaged page 0 is ChecksumMismatch" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try create_closed(&tmp, fx.options(512, .none));
    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    var pages = try sub.openFile(testing.io, "pages.db", .{ .mode = .read_write });
    defer pages.close(testing.io);

    var byte: [1]u8 = undefined;
    _ = try pages.readPositionalAll(testing.io, &byte, 100);
    byte[0] ^= 0xff;
    try pages.writePositionalAll(testing.io, &byte, 100);
    try testing.expectError(error.ChecksumMismatch, open_in(&tmp, fx.options(512, .none)));
}

test "db: a missing or emptied wal directory is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try create_closed(&tmp, fx.options(512, .none));
    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    try sub.deleteFile(testing.io, "wal/wal-00000001.log");
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
    try sub.deleteDir(testing.io, "wal");
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
}

test "db: a page file with no root page is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.createDir(testing.io, fx.sub_path, .default_dir);
    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    var pm: manager.PageManager = undefined;
    const pm_options: manager.Options = .{
        .page_size = 512,
        .page_count_max = 64,
        .sync_policy = .none,
    };
    try manager.PageManager.create(&pm, testing.io, sub, "pages.db", pm_options);
    pm.close(testing.io);
    try sub.createDir(testing.io, "wal", .default_dir);
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
}

test "db: a root page that is not a tree node is Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try create_closed(&tmp, fx.options(512, .none));
    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    var pages = try sub.openFile(testing.io, "pages.db", .{ .mode = .read_write });
    defer pages.close(testing.io);

    const zeros = [_]u8{0} ** 512;
    try pages.writePositionalAll(testing.io, &zeros, 512); // Page 1 becomes `Unwritten`.
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
}

test "db: a log with frames past the last checkpoint needs replay (item 5): Corrupted" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try create_closed(&tmp, fx.options(512, .none));
    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    var wal = try sub.openDir(testing.io, "wal", .{ .iterate = true });
    defer wal.close(testing.io);

    var writer: writer_mod.Writer = undefined;
    const writer_options: writer_mod.Options = .{
        .segments_max = 8,
        .sync_policy = .none,
        .segment_bytes_max = 1 << 21,
    };
    try writer_mod.Writer.init(&writer, testing.io, testing.allocator, wal, writer_options);
    _ = try writer.append(testing.io, .record, "late");
    writer.deinit(testing.io, testing.allocator);
    try testing.expectError(error.Corrupted, open_in(&tmp, fx.options(512, .none)));
}

test "db: NoSpaceLeft at the page_count_max growth limit, and the Db stays usable" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var options = fx.options(512, .none);
    options.page_count_max = 24;
    var db = try open_in(&tmp, options);
    defer db.close();

    var key_buf: [8]u8 = undefined;
    var failed_at: ?u32 = null;
    for (0..400) |n| {
        const key = fx.key_of(&key_buf, @intCast(n));
        db.put(key, "0123456789012345678901234567890123456789") catch |err| {
            try testing.expectEqual(error.NoSpaceLeft, err);
            failed_at = @intCast(n);
            break;
        };
    }
    try testing.expect(failed_at != null);
    try testing.expect(failed_at.? >= 1);
    const first = fx.key_of(&key_buf, 0);
    const stored = (try db.get(first)).?;
    try testing.expectEqualStrings("0123456789012345678901234567890123456789", stored);
    try testing.expect(try db.delete(first));
}

test "db: the log stays bounded by checkpoints under many writes" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var options = fx.options(512, .none);
    options.wal_segments_max = 3;
    options.wal_segment_bytes_max = 64 * 1024;
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    try fx.fill(&db, scratch, options.value_len_max, 400, 0); // Far more than 3 segments.
    try fx.fill(&db, scratch, options.value_len_max, 400, 1);
    try fx.check(&db, scratch, options.value_len_max, 400, 1, true);
    db.close();

    db = try open_in(&tmp, options);
    defer db.close();

    try fx.check(&db, scratch, options.value_len_max, 400, 1, true);
}

test "db: close frees the pages a delete left pending" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const options = fx.options(512, .none);
    const scratch = try testing.allocator.alloc(u8, options.value_len_max);
    defer testing.allocator.free(scratch);

    var db = try open_in(&tmp, options);
    try fx.fill(&db, scratch, options.value_len_max, 400, 0);
    try db.flush();
    var key_buf: [8]u8 = undefined;
    var n: u32 = 0;
    while (db.pending_frees() == 0) : (n += 1) { // Stop at the first delete that unlinks pages.
        try testing.expect(n < 400);
        try testing.expect(try db.delete(fx.key_of(&key_buf, n)));
    }
    try testing.expect(db.pending_frees() > 0);
    db.close();

    var sub = try sub_dir(&tmp);
    defer sub.close(testing.io);

    var pm: manager.PageManager = undefined;
    try manager.PageManager.open(&pm, testing.io, sub, "pages.db", .{
        .page_size = 512,
        .page_count_max = options.page_count_max,
        .sync_policy = .none,
    });
    const freed = pm.freelist_head != null; // Nothing was freed before close did.
    const count_before = pm.page_count;
    pm.close(testing.io); // Releases the database lock.
    try testing.expect(freed);

    db = try open_in(&tmp, options);
    defer db.close();

    try testing.expectEqual(@as(u32, 0), db.pending_frees());
    try fx.fill(&db, scratch, options.value_len_max, 8, 1);
    try testing.expect(count_before >= 2);
}
