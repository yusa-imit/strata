//! Tests for `durable.zig` and the durable mode of `FaultIo` (plan 006 item 9), written before
//! the implementation. Files are written through the wrapped `Io` (`File.writeAtAll`, `sync`) on
//! a tmpDir with `std.testing.io` as the inner `Io`; contents are always read back through the
//! inner `Io`, never through the wrapper under test.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const durable_mod = @import("durable.zig");
const fault_io = @import("fault_io.zig");
const file_mod = @import("../file/file.zig");

const Durable = durable_mod.Durable;
const Entry = durable_mod.Entry;
const FaultIo = fault_io.FaultIo;
const File = file_mod.File;

const entries_count: u32 = 16;
const bytes_count: u32 = 256;

/// A durable `FaultIo` over caller buffers; initialised in place (the `Io` points into it).
const Case = struct {
    entries: [entries_count]Entry,
    bytes: [bytes_count]u8,
    durable: Durable,
    fio: FaultIo,

    fn init(case: *Case, entries_len: u32, bytes_len: u32, sync_fail_after: ?u32) void {
        assert(entries_len <= entries_count);
        assert(bytes_len <= bytes_count);
        assert(entries_len >= 1);
        Durable.init(&case.durable, case.entries[0..entries_len], case.bytes[0..bytes_len]);
        FaultIo.init(&case.fio, testing.io, .{
            .write = .none,
            .read = .none,
            .after_calls = 0,
            .sync_fail_after = sync_fail_after,
            .durable = &case.durable,
        });
        case.durable.check_invariants();
        assert(case.durable.entries.len == entries_len);
        assert(case.fio.plan.durable != null);
    }

    fn open(case: *Case, dir: std.Io.Dir, name: []const u8) !File {
        assert(name.len > 0);
        assert(case.durable.entries_used <= case.durable.entries.len);
        assert(case.fio.plan.durable == &case.durable);
        const io = case.fio.io();
        return File.open(io, dir, name, .{ .create = true, .sync_policy = .fsync });
    }
};

/// Fails unless the file holds exactly `expected`; reads through the inner `Io` only.
fn expect_contents(f: File, expected: []const u8) !void {
    assert(expected.len <= 64);
    assert(!f.direct);
    assert(expected.len > 0);
    try testing.expectEqual(@as(u64, expected.len), try f.length(testing.io));
    var buf: [64]u8 = undefined;
    try f.readAtAll(testing.io, buf[0..expected.len], 0);
    try testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

test "durable: an unsynced write is reverted by crash to the old bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "oldold", 0); // inner Io: not recorded
    try f.writeAtAll(case.fio.io(), "NEW", 1);
    case.durable.check_invariants();
    try expect_contents(f, "oNEWld");
    try case.fio.crash();
    case.durable.check_invariants();
    try expect_contents(f, "oldold");
    try testing.expectEqual(@as(u32, 0), case.durable.entries_used);
}

test "durable: a synced write survives crash" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "oldold", 0);
    try f.writeAtAll(case.fio.io(), "NEW", 1);
    try f.sync(case.fio.io());
    case.durable.check_invariants();
    try testing.expectEqual(@as(u32, 0), case.durable.entries_used);
    try case.fio.crash();
    try expect_contents(f, "oNEWld");
}

test "durable: write, sync, write reverts only the second write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "oldold", 0);
    try f.writeAtAll(case.fio.io(), "AA", 0);
    try f.sync(case.fio.io());
    try f.writeAtAll(case.fio.io(), "BB", 0);
    try expect_contents(f, "BBdold");
    try case.fio.crash();
    try expect_contents(f, "AAdold");
}

test "durable: growing the file past its old length is undone, length included" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abcd", 0);
    try f.writeAtAll(case.fio.io(), "XYZW", 2); // overwrites 2 bytes, appends 2
    try f.writeAtAll(case.fio.io(), "Q", 10); // sparse: a hole, then one byte
    try expect_contents(f, "abXYZW\x00\x00\x00\x00Q");
    try case.fio.crash();
    try expect_contents(f, "abcd");
}

test "durable: two writes to the same range revert newest to oldest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "orig", 0);
    try f.writeAtAll(case.fio.io(), "one1", 0);
    try f.writeAtAll(case.fio.io(), "two2", 0);
    case.durable.check_invariants();
    try testing.expectEqual(@as(u32, 2), case.durable.entries_used);
    try case.fio.crash();
    try expect_contents(f, "orig");
}

test "durable: syncing file A does not drop file B's entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const a = try case.open(tmp.dir, "a.bin");
    defer a.close(testing.io);

    const b = try case.open(tmp.dir, "b.bin");
    defer b.close(testing.io);

    try a.writeAtAll(testing.io, "aaaa", 0);
    try b.writeAtAll(testing.io, "bbbb", 0);
    try a.writeAtAll(case.fio.io(), "AA", 0);
    try b.writeAtAll(case.fio.io(), "BB", 2);
    try a.writeAtAll(case.fio.io(), "cc", 2);
    try a.sync(case.fio.io());
    case.durable.check_invariants();
    try testing.expectEqual(@as(u32, 1), case.durable.entries_used);
    try case.fio.crash();
    try expect_contents(a, "AAcc");
    try expect_contents(b, "bbbb");
}

test "durable: a full log fails the write with InputOutput and crash reports UndoFull" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(2, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abcdef", 0);
    try f.writeAtAll(case.fio.io(), "1", 0);
    try f.writeAtAll(case.fio.io(), "2", 1);
    try testing.expectError(error.InputOutput, f.writeAtAll(case.fio.io(), "3", 2));
    try testing.expect(case.durable.overflowed);
    case.durable.check_invariants();
    try expect_contents(f, "12cdef"); // the refused write never reached the file
    try testing.expectError(error.UndoFull, case.fio.crash());
    try expect_contents(f, "abcdef"); // everything recorded was still restored
    try testing.expect(!case.durable.overflowed);
}

test "durable: a pre-image over the byte buffer is a full log too" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, 4, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abcdef", 0);
    try testing.expectError(error.InputOutput, f.writeAtAll(case.fio.io(), "12345", 0));
    try testing.expect(case.durable.overflowed);
    try expect_contents(f, "abcdef");
    try testing.expectError(error.UndoFull, case.fio.crash());
}

test "durable: a failed sync keeps the entries, so crash still reverts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, 0);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "oldold", 0);
    try f.writeAtAll(case.fio.io(), "NEW", 0);
    try testing.expectError(error.InputOutput, f.sync(case.fio.io()));
    case.durable.check_invariants();
    try testing.expectEqual(@as(u32, 1), case.durable.entries_used);
    try case.fio.crash();
    try expect_contents(f, "oldold");
}

test "durable: the short-write path records the bytes it overwrites" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    case.fio.plan.write = .{ .short = 2 };
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abcdef", 0);
    try f.writeAtAll(case.fio.io(), "123456", 0); // three 2-byte pieces
    try expect_contents(f, "123456");
    case.durable.check_invariants();
    try case.fio.crash();
    try expect_contents(f, "abcdef");
}

test "durable: a canceled write records nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    case.fio.plan.write = .canceled;
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abc", 0);
    try testing.expectError(error.Canceled, f.writeAtAll(case.fio.io(), "XYZ", 0));
    try testing.expectEqual(@as(u32, 0), case.durable.entries_used);
    try testing.expect(!case.durable.overflowed);
    try case.fio.crash();
    try expect_contents(f, "abc");
}

test "durable: reverted_bytes counts what crash restored" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");
    defer f.close(testing.io);

    try f.writeAtAll(testing.io, "abcd", 0);
    try f.writeAtAll(case.fio.io(), "XY", 1);
    try testing.expectEqual(@as(u64, 0), case.durable.reverted_bytes);
    try case.fio.crash();
    try testing.expectEqual(@as(u64, 2), case.durable.reverted_bytes);
}

test "durable: closing a file with unsynced entries makes crash refuse to guess" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");

    try f.writeAtAll(testing.io, "abc", 0);
    try f.writeAtAll(case.fio.io(), "X", 0);
    f.close(case.fio.io());
    try testing.expect(case.durable.closed_dirty);
    try testing.expectError(error.FileClosed, case.fio.crash());
    case.durable.check_invariants();
    try testing.expectEqual(@as(u32, 0), case.durable.entries_used);
}

test "durable: without a Durable, crash is a no-op and writes are not recorded" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, .{ .write = .none, .read = .none, .after_calls = 0 });
    const f = try File.open(fio.io(), tmp.dir, "a.bin", .{ .create = true });
    defer f.close(testing.io);

    try f.writeAtAll(fio.io(), "abc", 0);
    try fio.crash();
    try expect_contents(f, "abc");
}

test "durable: closing a synced file leaves closed_dirty false and crash restores nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const f = try case.open(tmp.dir, "a.bin");

    try f.writeAtAll(testing.io, "abc", 0);
    try f.writeAtAll(case.fio.io(), "X", 0);
    try f.sync(case.fio.io());
    f.close(case.fio.io());
    try testing.expect(!case.durable.closed_dirty);
    try testing.expectEqual(@as(u32, 0), case.durable.entries_used);
    try case.fio.crash(); // Nothing to undo, and no error.
    try testing.expectEqual(@as(u64, 0), case.durable.reverted_bytes);
    const again = try File.open(testing.io, tmp.dir, "a.bin", .{});
    defer again.close(testing.io);

    try expect_contents(again, "Xbc");
}

test "durable: a handle number reused after a clean close does not inherit the old entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var case: Case = undefined;
    case.init(entries_count, bytes_count, null);
    const first = try case.open(tmp.dir, "a.bin");

    try first.writeAtAll(testing.io, "abc", 0);
    try first.writeAtAll(case.fio.io(), "X", 0);
    try first.sync(case.fio.io());
    first.close(case.fio.io());
    try testing.expect(!case.durable.closed_dirty);
    const second = try case.open(tmp.dir, "b.bin"); // Typically the same descriptor number.
    defer second.close(testing.io);

    try second.writeAtAll(testing.io, "def", 0);
    try second.writeAtAll(case.fio.io(), "Y", 0);
    try testing.expectEqual(@as(u32, 1), case.durable.entries_used);
    try case.fio.crash();
    try expect_contents(second, "def"); // Only the new file's unsynced write is undone.
    const old = try File.open(testing.io, tmp.dir, "a.bin", .{});
    defer old.close(testing.io);

    try expect_contents(old, "Xbc"); // The synced write of the closed file stays.
    try testing.expect(!case.durable.closed_dirty);
}
