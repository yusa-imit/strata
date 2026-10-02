//! strata.file.platform — OS-specific durability primitives behind `file.File`. This is the only
//! file in the library allowed to branch on `builtin.os.tag` (PRD 4.2); callers see one shape.
//!
//! Allocation contract: none. Every function is a bounded sequence of syscalls over an
//! `Io.File` handle; interrupted calls (`EINTR`) are retried at most `intr_retries_max` times.
//!
//! - `sync_data`: Linux `fdatasync(2)`; every other OS falls back to `Io.File.sync`.
//! - `sync_full`: macOS/darwin `fcntl(F_FULLFSYNC)` (std's fsync does not flush the drive
//!   cache there). Only a filesystem that does not support it (`NOTSUP`, `OPNOTSUPP`, `NOTTY`,
//!   `INVAL`, `NODEV`) downgrades to `Io.File.sync`; real failures (`EIO`, `ENOSPC`, ...) are
//!   returned, never swallowed. Every other OS uses `Io.File.sync`.
//! - `reserve`: best-effort block reservation (Linux `fallocate(2)` with `KEEP_SIZE`, darwin
//!   `F_PREALLOCATE`), only for growth beyond the current length. An unsupported filesystem
//!   or OS is not an error; running out of space is.
//!
//! Raw syscalls here are not cancelation points except `sync_data`, which checks cancelation
//! once up front; `fdatasync` itself bypasses `Io`. `error.Canceled` otherwise comes only from
//! the `Io.File.sync` fallbacks, which already propagate it.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;

const is_linux = builtin.os.tag == .linux;
const is_darwin = builtin.os.tag.isDarwin();

/// Bound on consecutive `EINTR` results before a primitive gives up on retrying.
const intr_retries_max: u32 = 16;

const offset_max = @import("file.zig").offset_max;

// `<fcntl.h>` on darwin: `fstore.fst_flags` and `fst_posmode` values (std.c.F has the commands).
const f_allocatecontig: u32 = 0x2;
const f_allocateall: u32 = 0x4;
const f_peofposmode: i32 = 3;

/// `struct fstore` from `<fcntl.h>` (the `F_PREALLOCATE` argument).
const Fstore = extern struct {
    flags: u32,
    posmode: i32,
    offset: i64,
    length: i64,
    bytesalloc: i64,
};

comptime {
    assert(@sizeOf(Fstore) == 32);
    assert(@offsetOf(Fstore, "length") == 16);
    assert(@offsetOf(Fstore, "bytesalloc") == 24);
}

/// Errors `reserve` surfaces; everything else about reservation is silently best-effort.
pub const ReserveError = error{
    NoSpaceLeft,
    AccessDenied,
    PermissionDenied,
    FileTooBig,
    InputOutput,
};

/// `fdatasync` where the OS has it (Linux); `Io.File.sync` elsewhere.
pub fn sync_data(io: Io, handle: Io.File) Io.File.SyncError!void {
    comptime assert(intr_retries_max > 0);
    if (comptime !is_linux) {
        return handle.sync(io);
    } else {
        assert(handle.handle >= 0);
        try io.checkCancel(); // The raw syscall below is not a cancelation point.
        for (0..intr_retries_max) |_| {
            const errno = linux.errno(linux.fdatasync(handle.handle));
            switch (errno) {
                .SUCCESS => return,
                .INTR => continue,
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                else => return posix.unexpectedErrno(errno),
            }
        }
        // Interrupted every time: `Io.File.sync` retries with cancelation checks.
        return handle.sync(io);
    }
}

/// `F_FULLFSYNC` on darwin, downgrading to `Io.File.sync` only where the filesystem does not
/// support it; `Io.File.sync` elsewhere.
pub fn sync_full(io: Io, handle: Io.File) Io.File.SyncError!void {
    comptime assert(intr_retries_max > 0);
    if (comptime is_darwin) {
        assert(handle.handle >= 0);
        for (0..intr_retries_max) |_| {
            const result = std.c.fcntl(handle.handle, std.c.F.FULLFSYNC, @as(c_int, 0));
            const errno = posix.errno(result);
            switch (errno) {
                .SUCCESS => return,
                .INTR => continue,
                // Filesystem without F_FULLFSYNC (network, FUSE, some images): plain fsync.
                .OPNOTSUPP, .NOTTY, .INVAL, .NODEV => return handle.sync(io),
                .IO => return error.InputOutput,
                .NOSPC => return error.NoSpaceLeft,
                .DQUOT => return error.DiskQuota,
                else => return posix.unexpectedErrno(errno),
            }
        }
    }
    // Non-darwin, or interrupted every time: `Io.File.sync` retries with cancelation checks.
    return handle.sync(io);
}

/// Reserves blocks so the file can hold `len` bytes beyond `length_now`. Never changes the
/// visible length: the caller sets it afterwards. `length_now` is the current length; there is
/// nothing to reserve when `len <= length_now`. A handle not open for writing fails with
/// `error.AccessDenied` on the OSes that reserve.
pub fn reserve(handle: Io.File, length_now: u64, len: u64) ReserveError!void {
    assert(len <= offset_max);
    assert(length_now <= offset_max);
    if (len <= length_now) return; // No growth: nothing to reserve (also covers len == 0).
    if (comptime is_linux) {
        return reserve_linux(handle, length_now, len);
    } else if (comptime is_darwin) {
        return reserve_darwin(handle, length_now, len);
    }
    // Other OSes: nothing to reserve; `setLength` extends and any shortage surfaces there.
}

/// `FALLOC_FL_KEEP_SIZE`: reserve blocks without touching the file length.
const falloc_keep_size: i32 = 1;

fn reserve_linux(handle: Io.File, length_now: u64, len: u64) ReserveError!void {
    assert(len > length_now);
    assert(len <= offset_max);
    const grow: i64 = @intCast(len - length_now);
    for (0..intr_retries_max) |_| {
        const result = linux.fallocate(handle.handle, falloc_keep_size, @intCast(length_now), grow);
        const errno = linux.errno(result);
        switch (errno) {
            .SUCCESS => return,
            .INTR => continue,
            .NOSPC, .DQUOT => return error.NoSpaceLeft,
            .BADF => return error.AccessDenied, // Not open for writing.
            .FBIG => return error.FileTooBig,
            .IO => return error.InputOutput,
            .PERM => return error.PermissionDenied,
            // INVAL, OPNOTSUPP, NODEV, NOSYS, ...: no reservation here; `setLength` extends.
            else => return,
        }
    }
}

fn reserve_darwin(handle: Io.File, length_now: u64, len: u64) ReserveError!void {
    assert(len > length_now);
    assert(len <= offset_max);

    // Contiguous first, then any layout: contiguity is a preference, not a requirement.
    const flag_sets = [_]u32{ f_allocatecontig | f_allocateall, f_allocateall };
    var last: posix.E = .SUCCESS;
    for (flag_sets) |flags| {
        var store: Fstore = .{
            .flags = flags,
            .posmode = f_peofposmode,
            .offset = 0,
            .length = @intCast(len - length_now),
            .bytesalloc = 0,
        };
        last = fcntl_prealloc(handle.handle, &store);
        if (last == .SUCCESS or last == .BADF) break;
    }
    switch (last) {
        .SUCCESS => {},
        .BADF => return error.AccessDenied, // Not open for writing.
        .NOSPC, .DQUOT => return error.NoSpaceLeft,
        .FBIG => return error.FileTooBig,
        .IO => return error.InputOutput,
        .PERM => return error.PermissionDenied,
        else => {}, // ENOTSUP and friends: no reservation here; `setLength` extends.
    }
}

fn fcntl_prealloc(fd: posix.fd_t, store: *Fstore) posix.E {
    assert(fd >= 0);
    assert(store.length > 0);
    for (0..intr_retries_max) |_| {
        const errno = posix.errno(std.c.fcntl(fd, std.c.F.PREALLOCATE, store));
        if (errno != .INTR) return errno;
    }
    return .INTR;
}
