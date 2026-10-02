//! strata.file.file — positional file I/O over `std.Io`, with the sync policy carried as data.
//!
//! `File` is a copyable leaf value (`Io.File` handle + policy + flags). It never caches `io`
//! (ADR-0001): every call takes the caller's `Io` right after the receiver; `open` has no
//! receiver, so `io` comes first. Paths are never strings alone: `Io.Dir` plus `sub_path`.
//!
//! Contract (PRD 4.2, plan 002 items 5-6): `readAt` returns the short count (0 at or after EOF);
//! `readAtAll` fills the whole buffer or fails with `error.UnexpectedEof`; `writeAtAll` loops
//! until every byte is written; writing past EOF extends the file and the gap reads as zeros;
//! `setLength` zero-fills growth. `options.direct` is rejected with `error.UnsupportedDirectIo`
//! this cycle, before anything is created. `options.lock` is forwarded to the open call (so a
//! requested lock is never silently dropped).
//!
//! Durability: `sync` honors `sync_policy` (`none` touches nothing; `fdatasync`, `fsync` and
//! `full_fsync` flush as far as the platform allows, see `platform.zig`). It flushes the file,
//! not its directory entry: `sync` does not make a created file's name durable, callers fsync
//! the parent directory. `preallocate` reserves blocks best-effort and then guarantees
//! length == max(old, len): it never shrinks and new bytes read as zeros. `lock`, `tryLock`
//! and `unlock` are per open file description (flock-style); `unlock` is only legal while the
//! lock is held. Locks are advisory on posix; on Windows they are mandatory byte-range locks
//! (NtLockFile) that can fail other handles' reads and writes. Callers serialize `preallocate`
//! against other writers.
//! Ownership: the caller closes every `File` it opens; nothing is allocated.
//!
//! Status: core and durability landed; `direct`, `Mmap` and a cross-process lock file are later.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const platform = @import("platform.zig");

/// When a write reaches the platform's durable storage; chosen by the caller, never skipped.
pub const SyncPolicy = enum(u8) {
    none,
    fdatasync,
    fsync,
    /// macOS `F_FULLFSYNC`; behaves as `fsync` on platforms without it. On darwin a filesystem
    /// that does not support `F_FULLFSYNC` (network, FUSE) silently downgrades to `fsync` for
    /// that file; real I/O errors are returned, never downgraded.
    full_fsync,
};

pub const OpenOptions = struct {
    mode: Mode = .read_write,
    create: bool = false,
    truncate: bool = false,
    /// `O_DIRECT` / `F_NOCACHE`; unsupported this cycle (`error.UnsupportedDirectIo`).
    direct: bool = false,
    lock: Io.File.Lock = .none,
    sync_policy: SyncPolicy = .fdatasync,
};

pub const OpenError = Io.File.OpenError || Io.File.SetLengthError ||
    error{ UnsupportedDirectIo, PageSizeUnaligned };
pub const ReadError = Io.File.ReadPositionalError || error{UnexpectedEof};
pub const WriteError = Io.File.WritePositionalError || error{NoSpaceLeft};
pub const SetLengthError = Io.File.SetLengthError;
pub const LengthError = Io.File.LengthError;
pub const SyncError = Io.File.SyncError;
pub const PreallocateError = SetLengthError || LengthError || error{NoSpaceLeft};
pub const TryLockError = Io.File.LockError || error{WouldBlock};

/// Leaf value type: copyable, no `io` cached (ADR-0001).
pub const File = struct {
    handle: Io.File,
    sync_policy: SyncPolicy,
    direct: bool,

    /// Caller contract (asserted): `sub_path` is non-empty and a read-only open neither creates
    /// nor truncates. A `direct` request is a user-visible error, not a contract violation.
    /// A requested `lock` is blocking: `open` waits until the lock is available.
    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8, options: OpenOptions) OpenError!File {
        assert(sub_path.len > 0);
        assert(options.mode != .read_only or !(options.create or options.truncate));
        if (options.direct) return error.UnsupportedDirectIo; // Before any filesystem effect.

        const handle: Io.File = if (options.create)
            try dir.createFile(io, sub_path, .{
                .read = options.mode != .write_only,
                // Truncate only after the lock is held: `O_TRUNC` at open would destroy data
                // another process still holds a lock on.
                .truncate = false,
                .lock = options.lock,
            })
        else
            try dir.openFile(io, sub_path, .{
                .mode = options.mode,
                .allow_directory = false,
                .lock = options.lock,
            });
        errdefer handle.close(io);

        if (options.truncate) try handle.setLength(io, 0);
        const result: File = .{
            .handle = handle,
            .sync_policy = options.sync_policy,
            .direct = false,
        };
        assert(!result.direct);
        assert(result.sync_policy == options.sync_policy);
        return result;
    }

    /// Releases the handle; the value (and every copy of it) is invalid afterwards.
    pub fn close(self: File, io: Io) void {
        assert(!self.direct); // `direct` is rejected at `open` this cycle.
        assert(@intFromEnum(self.sync_policy) <= @intFromEnum(SyncPolicy.full_fsync));
        self.handle.close(io);
    }

    /// Returns the bytes read, clipped at EOF: 0 at or past it. `offset + buf.len` must fit i64.
    pub fn readAt(self: File, io: Io, buf: []u8, offset: u64) ReadError!usize {
        assert(offset <= offset_max);
        assert(buf.len <= offset_max - offset);
        if (buf.len == 0) return 0;

        const bufs = [_][]u8{buf};
        const n = try self.handle.readPositional(io, &bufs, offset);
        assert(n <= buf.len);
        return n;
    }

    /// Fills `buf` completely or fails with `error.UnexpectedEof`.
    pub fn readAtAll(self: File, io: Io, buf: []u8, offset: u64) ReadError!void {
        assert(offset <= offset_max);
        assert(buf.len <= offset_max - offset);

        // Every successful iteration consumes at least one byte, so `buf.len` iterations suffice.
        const iterations_max: usize = buf.len;
        var done: usize = 0;
        for (0..iterations_max) |_| {
            if (done == buf.len) break;
            const n = try self.readAt(io, buf[done..], offset + done);
            if (n == 0) return error.UnexpectedEof;
            done += n;
        }
        assert(done == buf.len);
    }

    /// Returns the bytes written (at most `data.len`; 0 only for empty `data`).
    pub fn writeAt(self: File, io: Io, data: []const u8, offset: u64) WriteError!usize {
        assert(offset <= offset_max);
        assert(data.len <= offset_max - offset);
        if (data.len == 0) return 0;

        const bufs = [_][]const u8{data};
        const n = try self.handle.writePositional(io, &bufs, offset);
        assert(n <= data.len);
        return n;
    }

    /// Writes all of `data`, looping over short writes. A write that accepts no bytes for
    /// non-empty data is reported as `error.NoSpaceLeft` instead of spinning.
    pub fn writeAtAll(self: File, io: Io, data: []const u8, offset: u64) WriteError!void {
        assert(offset <= offset_max);
        assert(data.len <= offset_max - offset);

        // Every successful iteration consumes at least one byte, so `data.len` iterations suffice.
        const iterations_max: usize = data.len;
        var done: usize = 0;
        for (0..iterations_max) |_| {
            if (done == data.len) break;
            const n = try self.writeAt(io, data[done..], offset + done);
            if (n == 0) return error.NoSpaceLeft;
            done += n;
        }
        assert(done == data.len);
    }

    /// Current end-of-file offset in bytes.
    pub fn length(self: File, io: Io) LengthError!u64 {
        assert(!self.direct);
        assert(@intFromEnum(self.sync_policy) <= @intFromEnum(SyncPolicy.full_fsync));
        const len = try self.handle.length(io);
        assert(len <= offset_max);
        return len;
    }

    /// Truncates or grows the file to `len`; growth reads as zeros. Precondition: the handle
    /// must be writable (File carries no mode, so this cannot be asserted); on filesystems
    /// without fallocate support a reservation degrades to a sparse extension and ENOSPC may
    /// surface on a later write.
    pub fn setLength(self: File, io: Io, len: u64) SetLengthError!void {
        assert(len <= offset_max);
        assert(!self.direct);
        try self.handle.setLength(io, len);
    }

    /// Flushes per `sync_policy`: `.none` returns without touching the handle.
    pub fn sync(self: File, io: Io) SyncError!void {
        assert(!self.direct);
        assert(@intFromEnum(self.sync_policy) <= @intFromEnum(SyncPolicy.full_fsync));
        switch (self.sync_policy) {
            .none => return,
            .fdatasync => try platform.sync_data(io, self.handle),
            .fsync => try self.handle.sync(io),
            .full_fsync => try platform.sync_full(io, self.handle),
        }
    }

    /// Reserves space (best-effort) and grows the file to `len` if shorter; never shrinks.
    /// Precondition: the handle must be writable (File carries no mode, so this cannot be
    /// asserted); on filesystems without fallocate support the reservation degrades to a sparse
    /// extension and ENOSPC may surface on a later write.
    pub fn preallocate(self: File, io: Io, len: u64) PreallocateError!void {
        assert(len <= offset_max);
        assert(!self.direct);
        const before = try self.length(io);
        try platform.reserve(self.handle, before, len);
        // Re-read: `setLength` must not shrink if the file grew meanwhile.
        if (try self.length(io) < len) try self.setLength(io, len);
        const after = try self.length(io);
        assert(after >= before);
        assert(after >= len);
    }

    /// Non-blocking lock (advisory on posix, mandatory byte-range on Windows);
    /// `error.WouldBlock` when another open holds a conflicting one.
    pub fn tryLock(self: File, io: Io, lock_kind: Io.File.Lock) TryLockError!void {
        assert(lock_kind != .none);
        assert(!self.direct);
        if (!try self.handle.tryLock(io, lock_kind)) return error.WouldBlock;
    }

    /// Blocking lock; the file must not already be locked through this handle.
    pub fn lock(self: File, io: Io, lock_kind: Io.File.Lock) Io.File.LockError!void {
        assert(lock_kind != .none);
        assert(!self.direct);
        try self.handle.lock(io, lock_kind);
    }

    /// Releases the lock taken by `lock` or `tryLock` (or `options.lock` at open).
    pub fn unlock(self: File, io: Io) void {
        assert(!self.direct);
        assert(@intFromEnum(self.sync_policy) <= @intFromEnum(SyncPolicy.full_fsync));
        self.handle.unlock(io);
    }
};

/// Largest offset or end-of-range the platform's positional calls accept (signed 64-bit).
pub const offset_max: u64 = std.math.maxInt(i64);

/// `Io.File.Mode` does not exist in 0.16; the mode enum lives on `Io.Dir.OpenFileOptions`.
pub const Mode = Io.Dir.OpenFileOptions.Mode;

// ---------------------------------------------------------------------------------------------
// Tests. Expected values are literals or come from `pattern`, never from `File` itself.
// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const fixtures = @import("file_fixtures.zig");
const pattern = fixtures.pattern;
const create_rw = fixtures.create_rw;
const expect_length = fixtures.expect_length;

test "file: SyncPolicy discriminants are frozen" {
    try testing.expectEqual(@as(u8, 0), @intFromEnum(SyncPolicy.none));
    try testing.expectEqual(@as(u8, 1), @intFromEnum(SyncPolicy.fdatasync));
    try testing.expectEqual(@as(u8, 2), @intFromEnum(SyncPolicy.fsync));
    try testing.expectEqual(@as(u8, 3), @intFromEnum(SyncPolicy.full_fsync));
    try testing.expectEqual(@as(usize, 1), @sizeOf(SyncPolicy));
}

test "file: OpenOptions defaults match PRD 4.2" {
    const options: OpenOptions = .{};
    try testing.expectEqual(Mode.read_write, options.mode);
    try testing.expect(!options.create);
    try testing.expect(!options.truncate);
    try testing.expect(!options.direct);
    try testing.expectEqual(Io.File.Lock.none, options.lock);
    try testing.expectEqual(SyncPolicy.fdatasync, options.sync_policy);
}

test "file: open stores sync_policy and clears direct" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const policies = [_]SyncPolicy{ .none, .fdatasync, .fsync, .full_fsync };
    for (policies, 0..) |policy, i| {
        var name_buf: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "p{d}.bin", .{i});
        const f = try File.open(io, tmp.dir, name, .{ .create = true, .sync_policy = policy });
        defer f.close(io);
        try testing.expectEqual(policy, f.sync_policy);
        try testing.expect(!f.direct);
    }
}

test "file: write then read round-trips at offset 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);

    var data: [100]u8 = undefined;
    pattern(&data, 7);
    try f.writeAtAll(io, &data, 0);
    try expect_length(f, 100);

    var back: [100]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, &data, &back);
}

test "file: round-trip at a non-zero offset leaves neighbours intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);

    const base: [64]u8 = @splat(0xAA);
    try f.writeAtAll(io, &base, 0);
    const mid = "strata-mid";
    try f.writeAtAll(io, mid, 20);

    var back: [64]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, &(base[0..20].*), back[0..20]);
    try testing.expectEqualSlices(u8, mid, back[20..30]);
    try testing.expectEqualSlices(u8, &(base[30..64].*), back[30..64]);
    try expect_length(f, 64);
}

test "file: overwrite replaces bytes in place without changing length" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);

    try f.writeAtAll(io, "0123456789", 0);
    try f.writeAtAll(io, "XY", 4);
    var back: [10]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "0123XY6789", &back);
    try expect_length(f, 10);
}

test "file: writeAt reports a positive count no larger than the data" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);

    const n = try f.writeAt(io, "hello", 0);
    try testing.expect(n >= 1 and n <= 5);
    var back: [5]u8 = undefined;
    try f.readAtAll(io, back[0..n], 0);
    try testing.expectEqualSlices(u8, "hello"[0..n], back[0..n]);
    try expect_length(f, n);
}

test "file: readAt returns the short count at the tail of the file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try f.writeAtAll(io, "0123456789", 0);

    var buf: [16]u8 = undefined;
    const n = try f.readAt(io, &buf, 4);
    try testing.expectEqual(@as(usize, 6), n);
    try testing.expectEqualSlices(u8, "456789", buf[0..n]);
}

test "file: readAt at and past EOF returns 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try f.writeAtAll(io, "0123456789", 0);

    var buf: [8]u8 = @splat(0x5A);
    try testing.expectEqual(@as(usize, 0), try f.readAt(io, &buf, 10)); // exactly EOF
    try testing.expectEqual(@as(usize, 0), try f.readAt(io, &buf, 11)); // one past
    try testing.expectEqual(@as(usize, 0), try f.readAt(io, &buf, 1 << 40)); // far past
    const untouched: [8]u8 = @splat(0x5A);
    try testing.expectEqualSlices(u8, &untouched, &buf);
}

test "file: readAt on an empty file returns 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "empty.bin");
    defer f.close(io);

    var buf: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try f.readAt(io, &buf, 0));
    try expect_length(f, 0);
}

test "file: readAtAll past EOF is UnexpectedEof" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try f.writeAtAll(io, "0123456789", 0);

    var buf: [4]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &buf, 10));
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &buf, 1 << 40));
}

test "file: readAtAll boundary — exact tail succeeds, one byte more is UnexpectedEof" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try f.writeAtAll(io, "0123456789", 0);

    var exact: [6]u8 = undefined;
    try f.readAtAll(io, &exact, 4);
    try testing.expectEqualSlices(u8, "456789", &exact);

    var over: [7]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &over, 4));
    var whole_plus_one: [11]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &whole_plus_one, 0));
}

test "file: writing past EOF extends the file and the gap reads as zeros" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);

    try f.writeAtAll(io, "ab", 0);
    try f.writeAtAll(io, "cd", 10);
    try expect_length(f, 12);

    var back: [12]u8 = @splat(0xFF);
    try f.readAtAll(io, &back, 0);
    const expected = "ab" ++ "\x00" ** 8 ++ "cd";
    try testing.expectEqualSlices(u8, expected, &back);
}

test "file: writing at offset 1<<40 makes a sparse file of that length" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "sparse.bin");
    defer f.close(io);

    const far: u64 = 1 << 40;
    try f.writeAtAll(io, "tail", far);
    try expect_length(f, far + 4);

    var tail: [4]u8 = undefined;
    try f.readAtAll(io, &tail, far);
    try testing.expectEqualSlices(u8, "tail", &tail);
    var hole: [4]u8 = @splat(0xFF);
    try f.readAtAll(io, &hole, far - 4);
    try testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, &hole);
}

test "file: zero-length read and write change nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try f.writeAtAll(io, "xyz", 0);

    try testing.expectEqual(@as(usize, 0), try f.writeAt(io, "", 1));
    try f.writeAtAll(io, "", 1);
    try f.writeAtAll(io, "", 100); // a zero-byte write past EOF must not extend the file
    try expect_length(f, 3);

    var empty: [0]u8 = .{};
    try testing.expectEqual(@as(usize, 0), try f.readAt(io, &empty, 0));
    try f.readAtAll(io, &empty, 0);
    try f.readAtAll(io, &empty, 3); // empty read exactly at EOF is not an EOF error

    var back: [3]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "xyz", &back);
}

test "file: length and setLength grow with zeros and shrink dropping the tail" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    try expect_length(f, 0);

    try f.writeAtAll(io, "0123456789", 0);
    try f.setLength(io, 16); // grow
    try expect_length(f, 16);
    var grown: [16]u8 = undefined;
    try f.readAtAll(io, &grown, 0);
    try testing.expectEqualSlices(u8, "0123456789" ++ "\x00" ** 6, &grown);

    try f.setLength(io, 4); // shrink
    try expect_length(f, 4);
    var kept: [4]u8 = undefined;
    try f.readAtAll(io, &kept, 0);
    try testing.expectEqualSlices(u8, "0123", &kept);
    var gone: [1]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, &gone, 4));

    try f.setLength(io, 8); // regrow: shrunk bytes must not come back
    var regrown: [8]u8 = undefined;
    try f.readAtAll(io, &regrown, 0);
    try testing.expectEqualSlices(u8, "0123" ++ "\x00" ** 4, &regrown);

    try f.setLength(io, 0);
    try expect_length(f, 0);
    try f.setLength(io, 0); // idempotent at the boundary
    try expect_length(f, 0);
}

test "file: open without create on a missing file is FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try testing.expectError(error.FileNotFound, File.open(io, tmp.dir, "missing.bin", .{}));
    // The failed open must not have created the file as a side effect.
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "missing.bin", .{}));
}

test "file: open with create makes an empty file that persists after close" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const f = try File.open(io, tmp.dir, "new.bin", .{ .create = true });
    try expect_length(f, 0);
    try f.writeAtAll(io, "durable?", 0);
    f.close(io);

    const g = try File.open(io, tmp.dir, "new.bin", .{ .mode = .read_only });
    defer g.close(io);
    var back: [8]u8 = undefined;
    try g.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "durable?", &back);
}

test "file: create on an existing file keeps its contents unless truncate is set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const first = try create_rw(tmp.dir, "a.bin");
    try first.writeAtAll(io, "keepme", 0);
    first.close(io);

    const again = try File.open(io, tmp.dir, "a.bin", .{ .create = true });
    defer again.close(io);
    try expect_length(again, 6);
    var back: [6]u8 = undefined;
    try again.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "keepme", &back);
}

test "file: truncate empties an existing file with and without create" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const seed = try create_rw(tmp.dir, "a.bin");
    try seed.writeAtAll(io, "to be dropped", 0);
    seed.close(io);

    const with_create = try File.open(io, tmp.dir, "a.bin", .{ .create = true, .truncate = true });
    try expect_length(with_create, 0);
    try with_create.writeAtAll(io, "second", 0);
    with_create.close(io);

    const no_create = try File.open(io, tmp.dir, "a.bin", .{ .truncate = true });
    defer no_create.close(io);
    try expect_length(no_create, 0);
    var buf: [6]u8 = undefined;
    try testing.expectError(error.UnexpectedEof, no_create.readAtAll(io, &buf, 0));
}

test "file: truncate on a missing file without create is FileNotFound" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const result = File.open(testing.io, tmp.dir, "nope.bin", .{ .truncate = true });
    try testing.expectError(error.FileNotFound, result);
}

test "file: read_only mode reads but a write is NotOpenForWriting" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const seed = try create_rw(tmp.dir, "a.bin");
    try seed.writeAtAll(io, "immutable", 0);
    seed.close(io);

    const f = try File.open(io, tmp.dir, "a.bin", .{ .mode = .read_only });
    defer f.close(io);
    var back: [9]u8 = undefined;
    try f.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "immutable", &back);

    try testing.expectError(error.NotOpenForWriting, f.writeAt(io, "x", 0));
    try testing.expectError(error.NotOpenForWriting, f.writeAtAll(io, "x", 0));
    try expect_length(f, 9);
    try f.readAtAll(io, &back, 0); // the rejected write left the bytes untouched
    try testing.expectEqualSlices(u8, "immutable", &back);
}

test "file: write_only mode writes but a read is NotOpenForReading" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    const f = try File.open(io, tmp.dir, "w.bin", .{ .mode = .write_only, .create = true });
    defer f.close(io);
    try f.writeAtAll(io, "abc", 0);
    try expect_length(f, 3);

    var buf: [3]u8 = undefined;
    try testing.expectError(error.NotOpenForReading, f.readAt(io, &buf, 0));
    try testing.expectError(error.NotOpenForReading, f.readAtAll(io, &buf, 0));
}

test "file: opening a directory for read_write is IsDir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    try tmp.dir.createDir(io, "sub", .default_dir);

    try testing.expectError(error.IsDir, File.open(io, tmp.dir, "sub", .{}));
}

test "file: a file used as a directory component is NotDir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const plain = try create_rw(tmp.dir, "plain.bin");
    plain.close(io);

    try testing.expectError(error.NotDir, File.open(io, tmp.dir, "plain.bin/child", .{}));
    const created = File.open(io, tmp.dir, "plain.bin/child", .{ .create = true });
    try testing.expectError(error.NotDir, created);
}

test "file: a name longer than the platform limit is NameTooLong" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const long_name: [300]u8 = @splat('n');

    const result = File.open(testing.io, tmp.dir, &long_name, .{ .create = true });
    try testing.expectError(error.NameTooLong, result);
}

test "file: direct is UnsupportedDirectIo and creates nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;

    try testing.expectError(
        error.UnsupportedDirectIo,
        File.open(io, tmp.dir, "d.bin", .{ .create = true, .direct = true }),
    );
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "d.bin", .{}));

    const existing = try create_rw(tmp.dir, "e.bin");
    try existing.writeAtAll(io, "intact", 0);
    existing.close(io);
    try testing.expectError(
        error.UnsupportedDirectIo,
        File.open(io, tmp.dir, "e.bin", .{ .truncate = true, .direct = true }),
    );
    const check = try File.open(io, tmp.dir, "e.bin", .{ .mode = .read_only });
    defer check.close(io);
    try expect_length(check, 6); // the rejected open must not have truncated
}

test "file: a copied File value operates on the same underlying file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try create_rw(tmp.dir, "a.bin");
    defer f.close(io);
    const copy = f;

    try f.writeAtAll(io, "shared", 0);
    var back: [6]u8 = undefined;
    try copy.readAtAll(io, &back, 0);
    try testing.expectEqualSlices(u8, "shared", &back);
    try testing.expectEqual(f.sync_policy, copy.sync_policy);
}

test "file: options.lock is held for the lifetime of the File and released on close" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const f = try File.open(io, tmp.dir, "l.bin", .{
        .create = true,
        .truncate = true,
        .lock = .exclusive,
    });

    // flock is per open file description: a second handle in this process contends too.
    const second = try tmp.dir.openFile(io, "l.bin", .{ .mode = .read_only });
    defer second.close(io);
    try testing.expect(!try second.tryLock(io, .shared));
    try testing.expect(!try second.tryLock(io, .exclusive));

    f.close(io);
    try testing.expect(try second.tryLock(io, .shared));
}

test "file: page-size matrix 512..65536 round-trips aligned and straddling reads" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    var size: usize = 512;
    while (size <= 65536) : (size *= 2) {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "pages-{d}.bin", .{size});
        const f = try create_rw(tmp.dir, name);
        defer f.close(io);

        const image = try gpa.alloc(u8, size * 3);
        defer gpa.free(image);
        const scratch = try gpa.alloc(u8, size * 3);
        defer gpa.free(scratch);
        for (0..3) |page| pattern(image[page * size ..][0..size], @intCast(page + size));

        // Write the pages out of order so extension and in-place overwrite both occur.
        const order = [_]usize{ 2, 0, 1 };
        for (order) |page| {
            try f.writeAtAll(io, image[page * size ..][0..size], page * size);
        }
        try expect_length(f, size * 3);

        for (0..3) |page| {
            try f.readAtAll(io, scratch[0..size], page * size);
            try testing.expectEqualSlices(u8, image[page * size ..][0..size], scratch[0..size]);
        }
        const half = size / 2; // a read straddling two page boundaries
        try f.readAtAll(io, scratch[0..size], half + size / 4);
        try testing.expectEqualSlices(
            u8,
            image[half + size / 4 ..][0..size],
            scratch[0..size],
        );
        const past = f.readAtAll(io, scratch[0..size], size * 2 + 1); // one byte short of a page
        try testing.expectError(error.UnexpectedEof, past);
    }
}

test "file: a multi-megabyte writeAtAll round-trips without leaks" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const f = try create_rw(tmp.dir, "big.bin");
    defer f.close(io);

    const len: usize = 4 << 20;
    const data = try gpa.alloc(u8, len);
    defer gpa.free(data);
    const back = try gpa.alloc(u8, len);
    defer gpa.free(back);
    pattern(data, 3);

    try f.writeAtAll(io, data, 13); // unaligned start
    try expect_length(f, len + 13);
    try f.readAtAll(io, back, 13);
    try testing.expectEqualSlices(u8, data, back);
    // readAt is allowed to be short, so a full-length readAt must report a sane count.
    const n = try f.readAt(io, back, 13);
    try testing.expect(n >= 1 and n <= len);
    try testing.expectEqualSlices(u8, data[0..n], back[0..n]);
}

test {
    _ = @import("file_model_test.zig"); // Seeded model-based tests live in their own file.
    _ = @import("file_durability_test.zig"); // Sync, preallocate and lock tests (item 6).
}
