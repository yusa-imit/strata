//! Durability tests for `file.zig` (plan 002 item 6, PRD 4.2): `sync` per `SyncPolicy`,
//! `preallocate` (never shrinks, zero-fills, existing bytes unchanged), and the advisory
//! `lock`/`tryLock`/`unlock` surface. Locks are flock-style, i.e. per open file description, so
//! two `File.open`s of one path in a single process contend; that is how every lock test here
//! provokes `error.WouldBlock`. Expected values are literals or come from `pattern`, never from
//! `File` itself. The seeded model test compares a real file against an in-memory reference
//! after every step. Test-only; I/O goes through `std.testing.io`, memory through
//! `std.testing.allocator`.
//!
//! Not covered by design: `tryLock`/`lock` with `Lock.none` and `preallocate` beyond
//! `offset_max` are asserted caller-contract violations (they panic, they do not return), and
//! `sync` with a policy other than `.none` on a read-only handle is platform-defined.

const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const Io = std.Io;
const testing = std.testing;
const fixtures = @import("file_fixtures.zig");
const file_mod = @import("file.zig");
const File = file_mod.File;
const SyncPolicy = file_mod.SyncPolicy;

const pattern = fixtures.pattern;
const create_rw = fixtures.create_rw;
const expect_length = fixtures.expect_length;

const policies = [_]SyncPolicy{ .none, .fdatasync, .fsync, .full_fsync };

/// Fails unless the file is exactly `total_len` bytes: `prefix` first, zeros after it.
fn expect_prefix_then_zeros(f: File, prefix: []const u8, total_len: usize) !void {
    assert(prefix.len <= total_len);
    assert(total_len <= file_mod.offset_max);
    const io = testing.io;
    const gpa = testing.allocator;
    const expected = try gpa.alloc(u8, total_len);
    defer gpa.free(expected);
    const actual = try gpa.alloc(u8, total_len);
    defer gpa.free(actual);
    @memset(expected, 0);
    @memcpy(expected[0..prefix.len], prefix);
    assert(expected.len == actual.len);

    try expect_length(f, total_len);
    try f.readAtAll(io, actual, 0);
    try testing.expectEqualSlices(u8, expected, actual);
}

// ---------------------------------------------------------------------------------------------
// sync
// ---------------------------------------------------------------------------------------------

test "sync: every policy returns ok and the data survives close and reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    var data: [1000]u8 = undefined;
    pattern(&data, 11);
    inline for (policies, 0..) |policy, i| {
        const name = std.fmt.comptimePrint("sync-{d}.bin", .{i});
        const f = try File.open(io, tmp.dir, name, .{ .create = true, .sync_policy = policy });
        try f.writeAtAll(io, &data, 0);
        try f.sync(io);
        try expect_length(f, data.len);
        f.close(io);

        const g = try File.open(io, tmp.dir, name, .{ .mode = .read_only });
        defer g.close(io);
        var back: [1000]u8 = undefined;
        try g.readAtAll(io, &back, 0);
        try testing.expectEqualSlices(u8, &data, &back);
        try expect_length(g, data.len);
    }
}

test "sync: an empty file syncs under every policy and stays empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    inline for (policies, 0..) |policy, i| {
        const name = std.fmt.comptimePrint("empty-{d}.bin", .{i});
        const f = try File.open(io, tmp.dir, name, .{ .create = true, .sync_policy = policy });
        defer f.close(io);
        try f.sync(io);
        try expect_length(f, 0);
        var probe: [1]u8 = undefined;
        try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &probe, 0));
    }
}

test "sync: repeated syncs interleaved with writes keep every write" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    inline for (policies, 0..) |policy, i| {
        const name = std.fmt.comptimePrint("repeat-{d}.bin", .{i});
        const f = try File.open(io, tmp.dir, name, .{ .create = true, .sync_policy = policy });
        defer f.close(io);
        try f.writeAtAll(io, "first", 0);
        try f.sync(io);
        try f.sync(io); // nothing dirty: still ok
        try f.writeAtAll(io, "second", 5);
        try f.sync(io);
        try f.setLength(io, 8); // metadata-only change followed by a sync
        try f.sync(io);

        var back: [8]u8 = undefined;
        try f.readAtAll(io, &back, 0);
        try testing.expectEqualSlices(u8, "firstsec", &back);
        try expect_length(f, 8);
    }
}

test "sync: a sparse file with a far write syncs and keeps hole and tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try File.open(io, tmp.dir, "sparse.bin", .{
        .create = true,
        .sync_policy = .full_fsync,
    });
    defer f.close(io);

    const far: u64 = 1 << 20;
    try f.writeAtAll(io, "tail", far);
    try f.sync(io);
    try expect_length(f, far + 4);
    var tail: [4]u8 = undefined;
    try f.readAtAll(io, &tail, far);
    try testing.expectEqualSlices(u8, "tail", &tail);
    var hole: [4]u8 = @splat(0xFF);
    try f.readAtAll(io, &hole, far - 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &hole);
}

/// Exhaustive `switch` over `SyncPolicy`: a new variant fails to compile here, which is the
/// reminder to teach `File.sync` about it (and to extend `policies` above).
fn policy_slot(comptime policy: SyncPolicy) u8 {
    const slot: u8 = switch (policy) {
        .none => 0,
        .fdatasync => 1,
        .fsync => 2,
        .full_fsync => 3,
    };
    comptime assert(slot == @intFromEnum(policy)); // the frozen discriminants line up
    comptime assert(slot < policies.len);
    return slot;
}

comptime {
    // A new variant fails here (length) and inside `policy_slot` (switch exhaustiveness).
    assert(@typeInfo(SyncPolicy).@"enum".fields.len == policies.len);
    for (policies) |policy| _ = policy_slot(policy);
}

test "sync: .none is a true no-op even on a read-only handle" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const seed = try create_rw(tmp.dir, "ro.bin");
    try seed.writeAtAll(io, "immutable", 0);
    seed.close(io);

    // Other policies on a read-only handle are platform-defined (fsync(2) accepts it on most
    // systems) and deliberately untested; `.none` must not touch the handle at all.
    const f = try File.open(io, tmp.dir, "ro.bin", .{
        .mode = .read_only,
        .sync_policy = .none,
    });
    defer f.close(io);
    try f.sync(io);
    try f.sync(io);
    var back: [9]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "immutable", &back);
    try expect_length(f, 9);
}

test "sync: .none never touches the handle, even an invalid one" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // No invalid-HANDLE sentinel.
    const io = testing.io;
    const never_opened: File = .{
        .handle = .{ .handle = -1, .flags = .{ .nonblocking = false } },
        .sync_policy = .none,
        .direct = false,
    };
    try never_opened.sync(io);
    try never_opened.sync(io);
    try testing.expectEqual(@as(Io.File.Handle, -1), never_opened.handle.handle);
}

test "sync: .none on a write-only handle leaves unsynced writes readable after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try File.open(io, tmp.dir, "wo.bin", .{
        .mode = .write_only,
        .create = true,
        .sync_policy = .none,
    });
    try f.writeAtAll(io, "abc", 0);
    try f.sync(io); // no durability is requested, but the page cache still serves the bytes
    f.close(io);

    const g = try File.open(io, tmp.dir, "wo.bin", .{ .mode = .read_only });
    defer g.close(io);
    var back: [3]u8 = undefined;
    try g.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "abc", &back);
}

// ---------------------------------------------------------------------------------------------
// preallocate
// ---------------------------------------------------------------------------------------------

test "preallocate: growing an empty file to 4096 yields 4096 zero bytes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "grow.bin");
    defer f.close(io);

    try f.preallocate(io, 4096);
    try expect_prefix_then_zeros(f, "", 4096);
}

test "preallocate: smaller than the current length never shrinks and keeps every byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "keep.bin");
    defer f.close(io);
    var data: [100]u8 = undefined;
    pattern(&data, 5);
    try f.writeAtAll(io, &data, 0);

    try f.preallocate(io, 10);
    try expect_prefix_then_zeros(f, &data, 100);
    try f.preallocate(io, 99); // one below the length
    try expect_prefix_then_zeros(f, &data, 100);
    try f.preallocate(io, 0);
    try expect_prefix_then_zeros(f, &data, 100);
}

test "preallocate: len equal to the current length is a no-op" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "equal.bin");
    defer f.close(io);
    var data: [512]u8 = undefined;
    pattern(&data, 9);
    try f.writeAtAll(io, &data, 0);

    try f.preallocate(io, 512);
    try expect_prefix_then_zeros(f, &data, 512);
}

test "preallocate: one byte past the length grows by exactly one zero byte" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "plus1.bin");
    defer f.close(io);
    try f.writeAtAll(io, "0123456789", 0);

    try f.preallocate(io, 11);
    try expect_prefix_then_zeros(f, "0123456789", 11);
}

test "preallocate: zero on an empty file leaves it empty" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "zero.bin");
    defer f.close(io);

    try f.preallocate(io, 0);
    try expect_length(f, 0);
    var probe: [1]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &probe, 0));
}

test "preallocate: growing a file with data keeps the data and zeros the rest" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "data.bin");
    defer f.close(io);
    var data: [300]u8 = undefined;
    pattern(&data, 21);
    try f.writeAtAll(io, &data, 0);

    try f.preallocate(io, 8192);
    try expect_prefix_then_zeros(f, &data, 8192);
}

test "preallocate: bytes shrunk away earlier come back as zeros, never as stale data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "stale.bin");
    defer f.close(io);
    const ones: [8]u8 = @splat(0xFF);
    try f.writeAtAll(io, &ones, 0);
    try f.setLength(io, 2);

    try f.preallocate(io, 8);
    try expect_prefix_then_zeros(f, &[_]u8{ 0xFF, 0xFF }, 8);
}

test "preallocate: boundary lengths around sector and page sizes on empty and non-empty files" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const lens = [_]usize{ 1, 511, 512, 513, 65536, 65537 };
    const seed_bytes = "abc";
    inline for (lens) |len| {
        const empty_name = std.fmt.comptimePrint("b-empty-{d}.bin", .{len});
        const empty = try create_rw(tmp.dir, empty_name);
        defer empty.close(io);
        try empty.preallocate(io, len);
        try expect_prefix_then_zeros(empty, "", len);

        const full_name = std.fmt.comptimePrint("b-full-{d}.bin", .{len});
        const full = try create_rw(tmp.dir, full_name);
        defer full.close(io);
        try full.writeAtAll(io, seed_bytes, 0);
        try full.preallocate(io, len);
        try expect_prefix_then_zeros(full, seed_bytes, @max(seed_bytes.len, len));
    }
}

test "preallocate: reserved space does not pin the length and writes land inside it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "pin.bin");
    defer f.close(io);

    try f.preallocate(io, 4096);
    try f.writeAtAll(io, "tail", 4092);
    try expect_length(f, 4096); // writing inside the reservation does not extend the file
    var tail: [4]u8 = undefined;
    try f.readAtAll(io, &tail, 4092);
    try testing.expectEqualSlices(u8, "tail", &tail);

    try f.setLength(io, 10); // truncation still works after preallocation
    try expect_length(f, 10);
    var probe: [1]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &probe, 10));
}

test "preallocate: repeated growth is monotonic and ends at the largest request" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "mono.bin");
    defer f.close(io);

    const requests = [_]u64{ 100, 50, 700, 700, 200, 4096, 1 };
    const lengths_after = [_]u64{ 100, 100, 700, 700, 700, 4096, 4096 }; // literal running max
    for (requests, lengths_after) |request, expected| {
        try f.preallocate(io, request);
        try expect_length(f, expected);
    }
    try expect_prefix_then_zeros(f, "", 4096);
}

test "preallocate: a read-only handle cannot grow the file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Windows reservation differs.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const seed = try create_rw(tmp.dir, "ro.bin");
    try seed.writeAtAll(io, "fixed", 0);
    seed.close(io);

    const f = try File.open(io, tmp.dir, "ro.bin", .{ .mode = .read_only });
    defer f.close(io);
    // The variant is platform-defined within the access-failure family; nothing may change.
    if (f.preallocate(io, 4096)) |_| {
        return error.TestUnexpectedResult;
    } else |err| switch (err) {
        error.AccessDenied, error.PermissionDenied, error.NonResizable => {},
        else => return err,
    }
    try expect_prefix_then_zeros(f, "fixed", 5);
}

// ---------------------------------------------------------------------------------------------
// preallocate: seeded model
// ---------------------------------------------------------------------------------------------

const model_cap: usize = 4096;
const model_op_max: usize = 256;
const model_steps: u32 = 300;
const model_seed: u64 = 0x57A7_A002_0006;

/// Reference model: a byte array whose bytes beyond `len` are always zero.
const Model = struct {
    bytes: []u8,
    len: usize,

    fn init(gpa: std.mem.Allocator) !Model {
        comptime assert(model_cap >= model_op_max * 2); // Room for an op at the highest offset.
        const bytes = try gpa.alloc(u8, model_cap);
        @memset(bytes, 0);
        assert(bytes.len == model_cap);
        return .{ .bytes = bytes, .len = 0 };
    }

    fn deinit(model: *Model, gpa: std.mem.Allocator) void {
        assert(model.len <= model_cap);
        assert(model.bytes.len == model_cap);
        gpa.free(model.bytes);
        model.* = undefined;
    }

    fn write(model: *Model, data: []const u8, offset: usize) void {
        assert(offset + data.len <= model_cap);
        if (data.len == 0) return; // a zero-byte write never extends the file
        @memcpy(model.bytes[offset..][0..data.len], data);
        model.len = @max(model.len, offset + data.len);
        assert(model.len >= offset + data.len);
    }

    fn set_length(model: *Model, new_len: usize) void {
        assert(new_len <= model_cap);
        if (new_len < model.len) @memset(model.bytes[new_len..model.len], 0);
        model.len = new_len;
        assert(model.len == new_len);
    }

    /// `preallocate` semantics: the length becomes `max(old, len)`; nothing else changes.
    fn preallocate(model: *Model, len: usize) void {
        assert(len <= model_cap);
        const before = model.len;
        model.len = @max(model.len, len);
        assert(model.len >= before); // never shrinks
        assert(model.len >= len);
    }
};

/// Whole-file comparison against the model; run after every step.
fn check_invariants(f: File, model: Model, scratch: []u8) !void {
    assert(model.len <= model_cap);
    assert(scratch.len >= model.len);
    assert(scratch.len >= 1);
    const io = testing.io;
    try testing.expectEqual(@as(u64, model.len), try f.length(io));
    try f.readAtAll(io, scratch[0..model.len], 0);
    try testing.expectEqualSlices(u8, model.bytes[0..model.len], scratch[0..model.len]);
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, scratch[0..1], model.len));
}

test "preallocate: seeded model — write/preallocate/setLength/sync match an in-memory reference" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const f = try create_rw(tmp.dir, "model.bin");
    defer f.close(io);

    var model: Model = try .init(gpa);
    defer model.deinit(gpa);
    const scratch = try gpa.alloc(u8, model_cap);
    defer gpa.free(scratch);

    var prng: std.Random.DefaultPrng = .init(model_seed);
    const random = prng.random();
    var prealloc_grew: u32 = 0; // the stream must actually exercise growth, not just no-ops
    var prealloc_noop: u32 = 0;
    var step: u32 = 0;
    while (step < model_steps) : (step += 1) {
        switch (random.uintLessThan(u8, 10)) {
            0...3 => {
                var data: [model_op_max]u8 = undefined;
                const data_len = random.uintAtMost(usize, model_op_max);
                pattern(data[0..data_len], step);
                const offset = random.uintAtMost(usize, model_cap - model_op_max);
                try f.writeAtAll(io, data[0..data_len], offset);
                model.write(data[0..data_len], offset);
            },
            4...6 => {
                const len = random.uintAtMost(usize, model_cap - model_op_max);
                if (len > model.len) prealloc_grew += 1 else prealloc_noop += 1;
                try f.preallocate(io, len);
                model.preallocate(len);
            },
            7, 8 => {
                const new_len = random.uintAtMost(usize, model_cap - model_op_max);
                try f.setLength(io, new_len);
                model.set_length(new_len);
            },
            9 => try f.sync(io),
            else => unreachable, // `uintLessThan(u8, 10)` yields 0..9, all covered above.
        }
        try check_invariants(f, model, scratch);
    }
    try testing.expect(prealloc_grew >= 10);
    try testing.expect(prealloc_noop >= 10);
}

// ---------------------------------------------------------------------------------------------
// locks
// ---------------------------------------------------------------------------------------------

test "lock: exclusive held by one open makes a second open's exclusive tryLock WouldBlock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "x.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "x.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
}

test "lock: shared locks coexist across opens" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "s.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "s.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .shared);
    try b.tryLock(io, .shared);
}

test "lock: shared held blocks an exclusive request, exclusive held blocks a shared one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "m.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "m.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .shared);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    a.unlock(io);

    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
}

test "lock: a failed tryLock does not leave the loser holding anything" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "f.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "f.lock", .{});
    defer b.close(io);
    const c = try File.open(io, tmp.dir, "f.lock", .{});
    defer c.close(io);

    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    a.unlock(io);
    try c.tryLock(io, .exclusive); // b's failed attempt must not have blocked c
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
}

test "lock: unlock releases so the other open can acquire, and the lock can be retaken" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "u.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "u.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    a.unlock(io);
    try b.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, a.tryLock(io, .exclusive));
    b.unlock(io);
    try a.tryLock(io, .exclusive); // a can take it again after b let go
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
}

test "lock: closing the holder releases its lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const b = try create_rw(tmp.dir, "c.lock");
    defer b.close(io);

    const a = try File.open(io, tmp.dir, "c.lock", .{});
    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    a.close(io);
    try b.tryLock(io, .exclusive);
}

test "lock: blocking lock uncontended returns and really holds the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "b.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "b.lock", .{});
    defer b.close(io);

    try a.lock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
    a.unlock(io);

    try a.lock(io, .shared); // unlock then lock again, in a different mode
    try b.tryLock(io, .shared);
    b.unlock(io); // b must not hold shared while it asks for exclusive
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
}

test "lock: blocking lock succeeds once the other open has unlocked" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "w.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "w.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .exclusive);
    a.unlock(io);
    try b.lock(io, .exclusive); // would deadlock the test if unlock had not released
    try testing.expectError(error.WouldBlock, a.tryLock(io, .shared));
}

test "lock: options.lock = .exclusive at open blocks another open's tryLock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try File.open(io, tmp.dir, "o.lock", .{ .create = true, .lock = .exclusive });
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "o.lock", .{ .mode = .read_only });
    defer b.close(io);

    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    try testing.expectError(error.WouldBlock, b.tryLock(io, .shared));
    a.unlock(io);
    try b.tryLock(io, .exclusive);
}

test "lock: lock state does not disturb reads and writes through either handle" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // Windows locks are mandatory.
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const a = try create_rw(tmp.dir, "io.lock");
    defer a.close(io);
    const b = try File.open(io, tmp.dir, "io.lock", .{});
    defer b.close(io);

    try a.tryLock(io, .exclusive);
    try testing.expectError(error.WouldBlock, b.tryLock(io, .exclusive));
    try a.writeAtAll(io, "locked-data", 0); // posix locks are advisory: they never gate I/O
    var back: [11]u8 = undefined;
    try b.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "locked-data", &back);
    try expect_length(b, 11);
}
