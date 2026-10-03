//! Tests for `fault_io.zig` (plan 002, "testing/crash.zig" item), written before the
//! implementation. Faults are provoked through the real `File` (`writeAtAll` / `readAtAll`),
//! the code they exist to prove, on a tmpDir with `std.testing.io` as the inner `Io`. File
//! contents are always checked through the inner `Io`, never through the wrapper under test.
//! Expected call counts are ceilings computed by hand from the cap, not read from the wrapper.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("fault_io.zig");
const file_mod = @import("../file/file.zig");
const fixtures = @import("../file/file_fixtures.zig");

const Fault = fault_io.Fault;
const FaultIo = fault_io.FaultIo;
const Plan = fault_io.Plan;
const File = file_mod.File;

const none_plan: Plan = .{ .write = .none, .read = .none, .after_calls = 0 };

fn plan_of(write: Fault, read: Fault, after_calls: u32) Plan {
    assert(after_calls <= std.math.maxInt(u32));
    assert(write != .short or write.short >= 1);
    return .{ .write = write, .read = read, .after_calls = after_calls };
}

/// Opens case file `index` read-write through the real `File.open` on the inner `Io`.
fn open_case(dir: std.Io.Dir, index: usize) !File {
    assert(index < 1000);
    var name_buf: [16]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "case{d}.bin", .{index});
    assert(name.len > 0);
    return fixtures.create_rw(dir, name);
}

/// Fails unless the file holds exactly `expected`; reads through the inner `Io` only.
fn expect_contents(f: File, expected: []const u8) !void {
    assert(expected.len <= 4096);
    assert(!f.direct);
    try fixtures.expect_length(f, expected.len);
    var buf: [4096]u8 = undefined;
    try f.readAtAll(testing.io, buf[0..expected.len], 0);
    try testing.expectEqualSlices(u8, expected, buf[0..expected.len]);
}

fn seed_file(f: File, data: []const u8) !void {
    assert(data.len > 0);
    assert(!f.direct);
    try f.writeAtAll(testing.io, data, 0); // inner Io: never faulted
}

test "fault_io: init zeroes both call counters over dirty memory" {
    var fio: FaultIo = undefined;
    @memset(std.mem.asBytes(&fio), 0xAA);
    FaultIo.init(&fio, testing.io, none_plan);

    try testing.expectEqual(@as(u32, 0), fio.write_calls);
    try testing.expectEqual(@as(u32, 0), fio.read_calls);
    fio.check_invariants();
}

test "fault_io: io() carries the FaultIo as userdata over its own failing-based vtable" {
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, none_plan);
    const wrapped = fio.io();
    const inner = testing.io;

    try testing.expectEqual(@intFromPtr(&fio), @intFromPtr(wrapped.userdata));
    try testing.expect(wrapped.vtable != inner.vtable);
    try testing.expect(wrapped.vtable != std.Io.failing.vtable);
    try testing.expect(wrapped.vtable.fileWritePositional != inner.vtable.fileWritePositional);
    try testing.expect(wrapped.vtable.fileReadPositional != inner.vtable.fileReadPositional);
    // Slots that are not forwarded stay the `Io.failing` ones, never the inner ones.
    try testing.expect(wrapped.vtable.dirCreateDir == std.Io.failing.vtable.dirCreateDir);
    try testing.expect(wrapped.vtable.dirCreateDir != inner.vtable.dirCreateDir);
    try testing.expect(wrapped.vtable.fileSync != std.Io.failing.vtable.fileSync);
    fio.check_invariants();
}

test "fault_io: checkCancel is forwarded, so raw-syscall paths can poll cancelation" {
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, none_plan);
    const wrapped = fio.io();

    // `Io.failing.checkCancel` is `unreachable`; Linux `sync_data` calls it before fdatasync.
    try testing.expect(wrapped.vtable.checkCancel != std.Io.failing.vtable.checkCancel);
    try wrapped.checkCancel();
    try testing.expectEqual(@as(u32, 0), fio.write_calls);
    fio.check_invariants();
}

test "fault_io: a slot that is not forwarded fails safely instead of reading FaultIo" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, none_plan);
    const io = fio.io();

    try testing.expectError(error.NoSpaceLeft, tmp.dir.createDir(io, "nope", .default_dir));
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "nope", .{}));
    try testing.expectEqual(@as(u32, 0), fio.write_calls);
    fio.check_invariants();
}

test "fault_io: splat 0 omits the last chunk and splat 3 repeats it, with a header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, none_plan);
    const slot = fio.io().vtable.fileWritePositional;
    const chunks = [_][]const u8{ "bb", "cc" };

    try testing.expectEqual(@as(usize, 4), try slot(&fio, f.handle, "hh", &chunks, 0, 0));
    try expect_contents(f, "hhbb");
    try testing.expectEqual(@as(usize, 10), try slot(&fio, f.handle, "hh", &chunks, 3, 0));
    try expect_contents(f, "hhbbcccccc");

    var short: FaultIo = undefined;
    FaultIo.init(&short, testing.io, plan_of(.{ .short = 3 }, .none, 0));
    const short_slot = short.io().vtable.fileWritePositional;
    try testing.expectEqual(@as(usize, 2), try short_slot(&short, f.handle, "ZZ", &chunks, 0, 0));
    try testing.expectEqual(@as(usize, 2), try short_slot(&short, f.handle, "", &chunks, 0, 2));
    try testing.expectEqual(@as(usize, 0), try short_slot(&short, f.handle, "", &.{"cc"}, 0, 4));
    try expect_contents(f, "ZZbbcccccc");
}

test "fault_io: none is a pure passthrough that still counts one call per transfer" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, none_plan);
    var data: [100]u8 = undefined;
    fixtures.pattern(&data, 5);

    try f.writeAtAll(fio.io(), &data, 0);
    try testing.expectEqual(@as(u32, 1), fio.write_calls);
    try testing.expectEqual(@as(u32, 0), fio.read_calls);
    try expect_contents(f, &data);

    var back: [100]u8 = undefined;
    try f.readAtAll(fio.io(), &back, 0);
    try testing.expectEqual(@as(u32, 1), fio.read_calls);
    try testing.expectEqualSlices(u8, &data, &back);
    fio.check_invariants();
}

test "fault_io: writeAtAll under short caps still writes every byte, one call per chunk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var data: [100]u8 = undefined;
    fixtures.pattern(&data, 9);

    const Case = struct { cap: u32, calls: u32 };
    const cases = [_]Case{
        .{ .cap = 1, .calls = 100 },
        .{ .cap = 7, .calls = 15 }, // ceil(100 / 7)
        .{ .cap = 50, .calls = 2 },
        .{ .cap = 99, .calls = 2 }, // one byte over the cap needs a second call
        .{ .cap = 100, .calls = 1 },
        .{ .cap = 101, .calls = 1 },
    };
    for (cases, 0..) |c, i| {
        const f = try open_case(tmp.dir, i);
        defer f.close(testing.io);
        var fio: FaultIo = undefined;
        FaultIo.init(&fio, testing.io, plan_of(.{ .short = c.cap }, .none, 0));

        try f.writeAtAll(fio.io(), &data, 0);
        try testing.expectEqual(c.calls, fio.write_calls);
        try expect_contents(f, &data);
        fio.check_invariants();
    }
}

test "fault_io: short writes advance the offset, including from a non-zero start" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.{ .short = 3 }, .none, 0));

    try f.writeAtAll(fio.io(), "0123456789", 0);
    try f.writeAtAll(fio.io(), "XYZ", 4); // overwrite in place, exactly one capped call
    try testing.expectEqual(@as(u32, 4 + 1), fio.write_calls);
    try expect_contents(f, "0123XYZ789");
}

test "fault_io: a zero write makes writeAtAll fail with NoSpaceLeft after one call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.zero, .none, 0));

    try testing.expectError(error.NoSpaceLeft, f.writeAtAll(fio.io(), "payload", 0));
    try testing.expectEqual(@as(u32, 1), fio.write_calls); // no spinning on a stuck device
    try expect_contents(f, ""); // nothing reached the inner Io

    try f.writeAtAll(fio.io(), "", 0); // empty data never reaches the Io, so never faults
    try testing.expectEqual(@as(u32, 1), fio.write_calls);
    fio.check_invariants();
}

test "fault_io: a canceled write surfaces error.Canceled and writes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.canceled, .none, 0));

    try testing.expectError(error.Canceled, f.writeAtAll(fio.io(), "payload", 0));
    try testing.expectError(error.Canceled, f.writeAt(fio.io(), "payload", 0));
    try testing.expectEqual(@as(u32, 2), fio.write_calls);
    try expect_contents(f, "");
    fio.check_invariants();
}

test "fault_io: readAtAll under short caps fills the buffer, one call per chunk" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");

    const Case = struct { cap: u32, calls: u32 };
    const cases = [_]Case{
        .{ .cap = 1, .calls = 10 },
        .{ .cap = 3, .calls = 4 }, // ceil(10 / 3)
        .{ .cap = 9, .calls = 2 },
        .{ .cap = 10, .calls = 1 },
        .{ .cap = 11, .calls = 1 },
    };
    for (cases) |c| {
        var fio: FaultIo = undefined;
        FaultIo.init(&fio, testing.io, plan_of(.none, .{ .short = c.cap }, 0));
        var back: [10]u8 = @splat(0xEE);

        try f.readAtAll(fio.io(), &back, 0);
        try testing.expectEqual(c.calls, fio.read_calls);
        try testing.expectEqualSlices(u8, "0123456789", &back);
        fio.check_invariants();
    }
}

test "fault_io: readAt under short returns the capped count with the right bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.none, .{ .short = 3 }, 0));

    var back: [10]u8 = @splat(0xEE);
    try testing.expectEqual(@as(usize, 3), try f.readAt(fio.io(), &back, 2));
    try testing.expectEqualSlices(u8, "234", back[0..3]);
    try testing.expectEqual(@as(u8, 0xEE), back[3]); // nothing written past the capped count
    try testing.expectEqual(@as(usize, 2), try f.readAt(fio.io(), back[0..2], 8)); // below the cap
    try testing.expectEqual(@as(usize, 0), try f.readAt(fio.io(), &back, 10)); // EOF stays 0
    try testing.expectEqual(@as(u32, 3), fio.read_calls);
}

test "fault_io: a zero read makes readAtAll fail with UnexpectedEof after one call" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.none, .zero, 0));

    var back: [4]u8 = @splat(0xEE);
    try testing.expectError(error.UnexpectedEof, f.readAtAll(fio.io(), &back, 0));
    try testing.expectEqual(@as(u32, 1), fio.read_calls);
    try testing.expectEqual(@as(usize, 0), try f.readAt(fio.io(), &back, 0));
    const untouched: [4]u8 = @splat(0xEE);
    try testing.expectEqualSlices(u8, &untouched, &back);
    try f.readAtAll(fio.io(), back[0..0], 0); // empty read never reaches the Io
    try testing.expectEqual(@as(u32, 2), fio.read_calls);
    fio.check_invariants();
}

test "fault_io: a canceled read surfaces error.Canceled and reads nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.none, .canceled, 0));

    var back: [4]u8 = @splat(0xEE);
    try testing.expectError(error.Canceled, f.readAtAll(fio.io(), &back, 0));
    try testing.expectError(error.Canceled, f.readAt(fio.io(), &back, 0));
    try testing.expectEqual(@as(u32, 2), fio.read_calls);
    const untouched: [4]u8 = @splat(0xEE);
    try testing.expectEqualSlices(u8, &untouched, &back);
}

test "fault_io: after_calls leaves the first N writes untouched, then zero applies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const chunks = [_][]const u8{ "ab", "cd", "ef", "gh" };

    for ([_]u32{ 0, 1, 2 }, 0..) |after, i| {
        const f = try open_case(tmp.dir, i);
        defer f.close(testing.io);
        var fio: FaultIo = undefined;
        FaultIo.init(&fio, testing.io, plan_of(.zero, .none, after));

        for (chunks, 0..) |chunk, k| {
            const accepted = try f.writeAt(fio.io(), chunk, k * 2);
            try testing.expectEqual(@as(usize, if (k < after) 2 else 0), accepted);
        }
        try testing.expectEqual(@as(u32, 4), fio.write_calls); // passthrough calls count too
        try expect_contents(f, "abcdefgh"[0 .. 2 * after]);
        fio.check_invariants();
    }
}

test "fault_io: after_calls leaves the first N reads untouched, then zero applies" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");

    for ([_]u32{ 0, 1, 2 }) |after| {
        var fio: FaultIo = undefined;
        FaultIo.init(&fio, testing.io, plan_of(.none, .zero, after));
        for (0..4) |k| {
            var back: [2]u8 = @splat(0xEE);
            const got = try f.readAt(fio.io(), &back, k * 2);
            try testing.expectEqual(@as(usize, if (k < after) 2 else 0), got);
            if (k < after) try testing.expectEqualSlices(u8, "0123456789"[k * 2 ..][0..2], &back);
        }
        try testing.expectEqual(@as(u32, 4), fio.read_calls);
    }
}

test "fault_io: a canceled write fault is persistent from after_calls on" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.canceled, .none, 1));

    try testing.expectEqual(@as(usize, 2), try f.writeAt(fio.io(), "ab", 0));
    try testing.expectError(error.Canceled, f.writeAt(fio.io(), "cd", 2));
    try testing.expectError(error.Canceled, f.writeAt(fio.io(), "cd", 2));
    try testing.expectEqual(@as(u32, 3), fio.write_calls);
    try expect_contents(f, "ab");
}

test "fault_io: short applies only from after_calls; earlier calls move full buffers" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.{ .short = 1 }, .none, 2));

    try testing.expectEqual(@as(usize, 5), try f.writeAt(fio.io(), "hello", 0));
    try testing.expectEqual(@as(usize, 5), try f.writeAt(fio.io(), "world", 5));
    try testing.expectEqual(@as(usize, 1), try f.writeAt(fio.io(), "!!", 10));
    try testing.expectEqual(@as(u32, 3), fio.write_calls);
    try expect_contents(f, "helloworld!");
}

test "fault_io: an after_calls beyond any call count never faults" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.canceled, .zero, std.math.maxInt(u32)));

    try f.writeAtAll(fio.io(), "intact", 0);
    var back: [6]u8 = undefined;
    try f.readAtAll(fio.io(), &back, 0);
    try testing.expectEqualSlices(u8, "intact", &back);
    try testing.expectEqual(@as(u32, 1), fio.write_calls);
    try testing.expectEqual(@as(u32, 1), fio.read_calls);
}

test "fault_io: a write fault leaves reads alone and a read fault leaves writes alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    try seed_file(f, "0123456789");
    var back: [10]u8 = undefined;

    var write_faulty: FaultIo = undefined;
    FaultIo.init(&write_faulty, testing.io, plan_of(.canceled, .none, 0));
    try f.readAtAll(write_faulty.io(), &back, 0);
    try testing.expectEqualSlices(u8, "0123456789", &back);
    try testing.expectEqual(@as(u32, 1), write_faulty.read_calls);
    try testing.expectEqual(@as(u32, 0), write_faulty.write_calls);

    var read_faulty: FaultIo = undefined;
    FaultIo.init(&read_faulty, testing.io, plan_of(.none, .canceled, 0));
    try f.writeAtAll(read_faulty.io(), "ABCDEFGHIJ", 0);
    try testing.expectEqual(@as(u32, 1), read_faulty.write_calls);
    try testing.expectEqual(@as(u32, 0), read_faulty.read_calls);
    try expect_contents(f, "ABCDEFGHIJ");
}

test "fault_io: open, sync, setLength, length, lock and close really work through the wrapper" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.canceled, .canceled, 0));
    const io = fio.io();

    const f = try File.open(io, tmp.dir, "fwd.bin", .{ .create = true }); // dirCreateFile
    try f.setLength(io, 16); // fileSetLength
    try testing.expectEqual(@as(u64, 16), try f.length(io)); // fileLength
    try f.sync(io); // fileSync (default policy is fdatasync)
    try f.lock(io, .exclusive); // fileLock
    f.unlock(io); // fileUnlock
    try testing.expect(try f.handle.tryLock(io, .shared)); // fileTryLock
    f.unlock(io);
    f.close(io); // fileClose

    const again = try File.open(io, tmp.dir, "fwd.bin", .{}); // dirOpenFile
    defer again.close(io);
    try testing.expectEqual(@as(u64, 16), try again.length(io));
    try expect_contents(again, &([_]u8{0} ** 16)); // the real file, seen via the inner Io
    try testing.expectEqual(@as(u32, 0), fio.write_calls); // none of the above is a transfer
    try testing.expectEqual(@as(u32, 0), fio.read_calls);
    fio.check_invariants();
}

test "fault_io: a 64 KiB transfer with short caps round-trips at an unaligned offset" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const gpa = testing.allocator;
    const f = try open_case(tmp.dir, 0);
    defer f.close(testing.io);
    const len: usize = 64 * 1024;
    const data = try gpa.alloc(u8, len);
    defer gpa.free(data);

    const back = try gpa.alloc(u8, len);
    defer gpa.free(back);

    fixtures.pattern(data, 21);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, plan_of(.{ .short = 4096 }, .{ .short = 1000 }, 0));

    try f.writeAtAll(fio.io(), data, 13);
    try testing.expectEqual(@as(u32, 16), fio.write_calls); // 65536 / 4096
    try f.readAtAll(fio.io(), back, 13);
    try testing.expectEqual(@as(u32, 66), fio.read_calls); // ceil(65536 / 1000)
    try testing.expectEqualSlices(u8, data, back);
    fio.check_invariants();
}
