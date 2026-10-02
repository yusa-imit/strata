//! strata.testing.fault_io — fault-injecting `std.Io` wrapper (plan 002).
//!
//! `FaultIo.io()` returns an `Io` with `userdata == &fio` and a vtable built from `Io.failing`
//! (every slot not listed below fails safely, or is a no-op, and never reads the `FaultIo` as
//! if it were inner state), then filled in with:
//!   - faulting hooks: `fileWritePositional`, `fileReadPositional`. From call number
//!     `after_calls` (0-based, counted per direction) each obeys the plan for its direction:
//!     capped to `short` bytes, zero bytes transferred, or `error.Canceled`. Earlier calls pass
//!     through; every call is counted.
//!   - forwarders to the inner `Io` with the inner userdata: `dirCreateFile`, `dirOpenFile`,
//!     `fileClose`, `fileSync`, `fileLength`, `fileSetLength`, `fileStat`, `fileLock`,
//!     `fileTryLock`, `fileUnlock`: everything `strata.file.File` uses.
//! Any other `Io` operation through the wrapper is not supported: use the inner `Io` directly.
//!
//! Allocation: none, ever. Ownership: nothing is owned; the inner `Io` is borrowed and must
//! outlive the wrapper. The `FaultIo` is initialised in place and must not move afterwards,
//! because the wrapped `Io` points into it. Not thread-safe: counters are plain integers, so
//! drive it from one thread at a time.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const File = std.Io.File;
const Dir = std.Io.Dir;

/// What a faulted positional call does.
pub const Fault = union(enum) {
    /// Pass through to the inner `Io`.
    none,
    /// Transfer at most this many bytes per call; `n >= 1`.
    short: u32,
    /// Transfer zero bytes.
    zero,
    /// Fail with `error.Canceled`.
    canceled,
};

/// Which fault applies to each direction, and from which call on.
pub const Plan = struct {
    write: Fault,
    read: Fault,
    /// Number of calls per direction (0-based count) that pass through before the fault starts.
    after_calls: u32,
};

/// A fault-injecting `Io` wrapper; see the file header for what is faulted and forwarded.
pub const FaultIo = struct {
    inner: Io,
    plan: Plan,
    write_calls: u32,
    read_calls: u32,
    vtable: Io.VTable,

    /// Builds the wrapper in place; counters start at zero.
    ///
    /// Precondition: `plan.write` and `plan.read` are not `.short = 0`; `target` stays at this
    /// address for as long as `io()` results are in use; `inner` outlives `target`. Only the
    /// slots named in the file header work through the wrapped `Io`; the rest are `Io.failing`.
    pub fn init(target: *FaultIo, inner: Io, plan: Plan) void {
        if (plan.write == .short) assert(plan.write.short >= 1);
        if (plan.read == .short) assert(plan.read.short >= 1);
        assert(inner.vtable != Io.failing.vtable); // Wrapping `failing` would fault nothing.
        target.* = .{
            .inner = inner,
            .plan = plan,
            .write_calls = 0,
            .read_calls = 0,
            .vtable = Io.failing.vtable.*,
        };
        target.vtable.fileWritePositional = write_positional;
        target.vtable.fileReadPositional = read_positional;
        target.vtable.dirCreateFile = forward_dir_create_file;
        target.vtable.dirOpenFile = forward_dir_open_file;
        target.vtable.fileClose = forward_file_close;
        target.vtable.fileSync = forward_file_sync;
        target.vtable.fileLength = forward_file_length;
        target.vtable.fileSetLength = forward_file_set_length;
        target.vtable.fileStat = forward_file_stat;
        target.vtable.fileLock = forward_file_lock;
        target.vtable.fileTryLock = forward_file_try_lock;
        target.vtable.fileUnlock = forward_file_unlock;
        assert(target.write_calls == 0);
        assert(target.read_calls == 0);
    }

    /// The faulting `Io`; valid while `self` stays at the same address.
    pub fn io(self: *FaultIo) Io {
        assert(self.inner.vtable != &self.vtable);
        assert(self.vtable.fileWritePositional == write_positional);
        return .{ .userdata = self, .vtable = &self.vtable };
    }

    /// Asserts internal consistency: hooks installed, no self-recursion, counters sane.
    pub fn check_invariants(self: *const FaultIo) void {
        assert(self.inner.vtable != &self.vtable);
        assert(self.vtable.fileWritePositional == write_positional);
        assert(self.vtable.fileReadPositional == read_positional);
        assert(self.vtable.fileSync == forward_file_sync);
        if (self.plan.write == .short) assert(self.plan.write.short >= 1);
        if (self.plan.read == .short) assert(self.plan.read.short >= 1);
    }
};

/// Recovers the wrapper from the userdata of the wrapped `Io`.
fn self_of(userdata: ?*anyopaque) *FaultIo {
    assert(userdata != null);
    const self: *FaultIo = @ptrCast(@alignCast(userdata));
    assert(self.inner.vtable != &self.vtable); // Forwarding to ourselves would recurse forever.
    return self;
}

fn forward_dir_create_file(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.CreateFileOptions,
) File.OpenError!File {
    const self = self_of(userdata);
    assert(sub_path.len > 0);
    return self.inner.vtable.dirCreateFile(self.inner.userdata, dir, sub_path, options);
}

fn forward_dir_open_file(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    options: Dir.OpenFileOptions,
) File.OpenError!File {
    const self = self_of(userdata);
    assert(sub_path.len > 0);
    return self.inner.vtable.dirOpenFile(self.inner.userdata, dir, sub_path, options);
}

fn forward_file_close(userdata: ?*anyopaque, files: []const File) void {
    const self = self_of(userdata);
    assert(files.len > 0);
    self.inner.vtable.fileClose(self.inner.userdata, files);
}

fn forward_file_sync(userdata: ?*anyopaque, file: File) File.SyncError!void {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileSync != forward_file_sync);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileSync(self.inner.userdata, file);
}

fn forward_file_length(userdata: ?*anyopaque, file: File) File.LengthError!u64 {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileLength != forward_file_length);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileLength(self.inner.userdata, file);
}

fn forward_file_set_length(
    userdata: ?*anyopaque,
    file: File,
    length: u64,
) File.SetLengthError!void {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileSetLength != forward_file_set_length);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileSetLength(self.inner.userdata, file, length);
}

fn forward_file_stat(userdata: ?*anyopaque, file: File) File.StatError!File.Stat {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileStat != forward_file_stat);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileStat(self.inner.userdata, file);
}

fn forward_file_lock(userdata: ?*anyopaque, file: File, kind: File.Lock) File.LockError!void {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileLock != forward_file_lock);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileLock(self.inner.userdata, file, kind);
}

fn forward_file_try_lock(userdata: ?*anyopaque, file: File, kind: File.Lock) File.LockError!bool {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileTryLock != forward_file_try_lock);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    return self.inner.vtable.fileTryLock(self.inner.userdata, file, kind);
}

fn forward_file_unlock(userdata: ?*anyopaque, file: File) void {
    const self = self_of(userdata);
    assert(self.inner.vtable.fileUnlock != forward_file_unlock);
    assert(self.inner.userdata != userdata); // Forward the inner userdata, never ours.
    self.inner.vtable.fileUnlock(self.inner.userdata, file);
}

/// Counts one call and returns the fault that applies to it: `.none` before `after_calls`.
/// The counter saturates, so a runaway test cannot overflow it.
fn fault_take(fault: Fault, calls: *u32, after_calls: u32) Fault {
    if (fault == .short) assert(fault.short >= 1);
    const index = calls.*;
    calls.* +|= 1;
    assert(calls.* > index or index == std.math.maxInt(u32)); // Saturating, never wrapping.
    if (index < after_calls) return .none;
    return fault;
}

fn write_positional(
    userdata: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const self = self_of(userdata);
    assert(self.vtable.fileWritePositional == write_positional);
    const fault = fault_take(self.plan.write, &self.write_calls, self.plan.after_calls);
    const vtable = self.inner.vtable;
    switch (fault) {
        .none => return vtable.fileWritePositional(
            self.inner.userdata,
            file,
            header,
            data,
            splat,
            offset,
        ),
        .zero => return 0,
        .canceled => return error.Canceled,
        .short => |cap| {
            // Forward only the first non-empty piece, trimmed to the cap: a legal short write
            // that never has to split a splat.
            const piece = write_piece(header, data, splat, cap);
            if (piece.len == 0) return 0;
            return vtable.fileWritePositional(
                self.inner.userdata,
                file,
                &.{},
                &.{piece},
                1,
                offset,
            );
        },
    }
}

/// First non-empty chunk of the write (header first), at most `cap` bytes; empty if none.
/// `splat == 0` omits the last data element, as `Io.VTable.fileWritePositional` defines.
fn write_piece(header: []const u8, data: []const []const u8, splat: usize, cap: u32) []const u8 {
    assert(cap >= 1);
    if (header.len != 0) return header[0..@min(header.len, cap)];
    const used = if (splat == 0 and data.len > 0) data.len - 1 else data.len;
    assert(used <= data.len);
    for (data[0..used]) |chunk| {
        if (chunk.len != 0) return chunk[0..@min(chunk.len, cap)];
    }
    return header;
}

fn read_positional(
    userdata: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    const self = self_of(userdata);
    assert(self.vtable.fileReadPositional == read_positional);
    const fault = fault_take(self.plan.read, &self.read_calls, self.plan.after_calls);
    const vtable = self.inner.vtable;
    switch (fault) {
        .none => return vtable.fileReadPositional(self.inner.userdata, file, data, offset),
        .zero => return 0,
        .canceled => return error.Canceled,
        .short => |cap| {
            const piece = read_piece(data, cap);
            if (piece.len == 0) return 0;
            return vtable.fileReadPositional(self.inner.userdata, file, &.{piece}, offset);
        },
    }
}

/// First non-empty buffer, at most `cap` bytes; empty if every buffer is empty.
fn read_piece(data: []const []u8, cap: u32) []u8 {
    assert(cap >= 1);
    for (data) |buffer| {
        if (buffer.len != 0) return buffer[0..@min(buffer.len, cap)];
    }
    assert(data.len == 0 or data[data.len - 1].len == 0); // Every buffer was empty.
    return &.{};
}
