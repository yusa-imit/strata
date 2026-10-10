//! Page manager (ADR-0002 §5, §7): owns one `file.File` of fixed-size, checksummed pages, moves
//! whole pages between a caller buffer and the file, and hands out page ids through the trunk
//! freelist: `allocate` pops (or grows the file, bounded by `Options.page_count_max`), `free`
//! pushes, `sync` makes completed writes durable per the file's `SyncPolicy`.
//!
//! Invariants: page 0 holds the file header and is owned by the manager (callers address pages
//! `1 ..< page_count`); `page_size` is a valid power of two and equals the file header's; the
//! file is at least `page_count * page_size` bytes and exclusively locked from `create`/`open`
//! until `close`; every page write stamps the id-seeded CRC32C, every read verifies it.
//! Allocation: none. `create`, `open`, `allocate` and `free` use `page_size_max` stack scratch
//! buffers, so no method allocates and none stores an allocator. The file handle is a leaf value
//! and `io` is passed per call (ADR-0001). `read`/`write` never sync; durability is the
//! caller's call.
//! Freelist updates are issued trunk first, then page 0 (file growth precedes page 0); a crash
//! between them then leaks a page rather than corrupting the list, but only if the OS persisted
//! the writes in that order, which `.none` and unsynced policies do not promise. Ordering across
//! a crash is the WAL's job (plan 004); callers needing it call `sync` between operations.
//! In-memory state changes only after every write of an operation succeeded.
//! Errors: bad bytes on disk are typed (`Corrupted`, `ChecksumMismatch`, `Unwritten`,
//! `TornWrite`); wrong ids, buffer lengths or options are caller contract violations (asserted).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const file = @import("../file/file.zig");
const header = @import("header.zig");
const freelist = @import("freelist.zig");
const Id = header.Id;

pub const Options = struct {
    /// A power of two in `[header.page_size_min, header.page_size_max]`.
    page_size: u32,
    /// Growth limit in pages, including page 0 (enforced by `allocate`).
    page_count_max: u32,
    sync_policy: file.SyncPolicy,
};

pub const CreateError = file.OpenError || file.WriteError || file.SyncError ||
    file.TryLockError || file.LengthError || error{AlreadyExists};
pub const OpenError = file.OpenError || file.ReadError || file.TryLockError ||
    file.LengthError || error{ Corrupted, ChecksumMismatch };
pub const ReadError = file.ReadError || header.DecodeError || error{TornWrite};
pub const WriteError = file.WriteError;
pub const AllocateError = file.ReadError || file.WriteError || file.PreallocateError ||
    error{ Corrupted, ChecksumMismatch, TornWrite };
pub const FreeError = file.ReadError || file.WriteError ||
    error{ Corrupted, ChecksumMismatch, TornWrite };
pub const SyncError = file.SyncError;
const TrunkReadError = file.ReadError || error{Corrupted};

pub const PageManager = struct {
    file: file.File,
    page_size: u32,
    page_count: u32,
    freelist_head: ?Id,
    wal_lsn: u64,
    page_count_max: u32,

    /// Creates a new file holding only page 0, synced per `options.sync_policy`, and locks it
    /// exclusively. A file that already has bytes is `AlreadyExists` and left untouched.
    /// Preconditions: `options.page_size` valid, `options.page_count_max >= 1`, `sub_path`
    /// non-empty. On error nothing stays open or locked.
    pub fn create(
        target: *PageManager,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        options: Options,
    ) CreateError!void {
        assert(header.page_size_valid(options.page_size));
        assert(options.page_count_max >= 1);
        const handle = try file.File.open(io, dir, sub_path, .{
            .create = true,
            .sync_policy = options.sync_policy,
        });
        errdefer handle.close(io);

        try handle.tryLock(io, .exclusive);
        errdefer handle.unlock(io);

        if (try handle.length(io) != 0) return error.AlreadyExists;
        var scratch = [_]u8{0} ** header.page_size_max;
        const page = scratch[0..options.page_size];
        const file_header: header.FileHeader = .{
            .page_size = options.page_size,
            .page_count = 1,
            .freelist_head = null,
            .wal_lsn = 0,
        };
        header.encode_file_header(page, file_header);
        try handle.writeAtAll(io, page, 0);
        try handle.sync(io);
        target.* = .{
            .file = handle,
            .page_size = options.page_size,
            .page_count = 1,
            .freelist_head = null,
            .wal_lsn = 0,
            .page_count_max = options.page_count_max,
        };
        assert(target.page_size == options.page_size);
        assert(target.freelist_head == null);
    }

    /// Opens an existing file per ADR-0002 §5: lock, peek the page size from the first 512
    /// bytes, require it to equal `options.page_size`, decode page 0 in full, and require the
    /// file to cover `page_count` pages (a longer file is allowed). Every violation, including
    /// a file too short to hold page 0, is `Corrupted`; a bad page-0 checksum is
    /// `ChecksumMismatch`; a locked file is `WouldBlock`. Preconditions as for `create`.
    pub fn open(
        target: *PageManager,
        io: Io,
        dir: Io.Dir,
        sub_path: []const u8,
        options: Options,
    ) OpenError!void {
        assert(header.page_size_valid(options.page_size));
        assert(options.page_count_max >= 1);
        const handle = try file.File.open(io, dir, sub_path, .{
            .sync_policy = options.sync_policy,
        });
        errdefer handle.close(io);

        try handle.tryLock(io, .exclusive);
        errdefer handle.unlock(io);

        const file_header = try open_file_header(io, handle, options.page_size);
        const length = try handle.length(io);
        if (length < @as(u64, file_header.page_count) * file_header.page_size) {
            return error.Corrupted;
        }
        target.* = .{
            .file = handle,
            .page_size = file_header.page_size,
            .page_count = file_header.page_count,
            .freelist_head = file_header.freelist_head,
            .wal_lsn = file_header.wal_lsn,
            .page_count_max = options.page_count_max,
        };
        assert(target.page_size == options.page_size);
        assert(target.page_count >= 1);
    }

    /// Unlocks and closes the file; the manager is invalid afterwards. Does not sync.
    pub fn close(self: *PageManager, io: Io) void {
        assert(self.page_count >= 1);
        assert(header.page_size_valid(self.page_size));
        self.file.unlock(io);
        self.file.close(io);
    }

    /// Reads page `id` into `buf` and verifies it. `TornWrite` when the file ends inside the
    /// page; `Unwritten`, `Corrupted` and `ChecksumMismatch` come from the header decode.
    /// Preconditions: `buf.len == page_size` and `0 < id < page_count`. `buf` is unspecified
    /// after an error.
    pub fn read(self: *PageManager, io: Io, id: Id, buf: []u8) ReadError!header.Header {
        assert(buf.len == self.page_size);
        assert(@intFromEnum(id) >= 1);
        assert(@intFromEnum(id) < self.page_count);
        self.file.readAtAll(io, buf, self.page_offset(id)) catch |err| switch (err) {
            error.UnexpectedEof => return error.TornWrite,
            else => |other| return other,
        };
        return header.decode(buf, id);
    }

    /// Stamps `page_header` and the checksum into `buf`'s first 24 bytes (payload untouched)
    /// and writes the whole page. Same preconditions as `read`; `page_header.page_type` must
    /// be legal at `id` (see `header.encode`).
    pub fn write(
        self: *PageManager,
        io: Io,
        id: Id,
        buf: []u8,
        page_header: header.Header,
    ) WriteError!void {
        assert(buf.len == self.page_size);
        assert(@intFromEnum(id) >= 1);
        assert(@intFromEnum(id) < self.page_count);
        header.encode(buf, id, page_header);
        try self.file.writeAtAll(io, buf, self.page_offset(id));
    }

    /// Returns an id no live page uses: the most recently freed page, or a new page at the end
    /// of the file. A reused page still holds its old bytes (a trunk image at most) until the
    /// caller writes it; a grown page reads as `Unwritten`. Growth past `page_count_max` is
    /// `NoSpaceLeft`; a freelist that names a page outside the file, or whose head trunk is
    /// unwritten or malformed, is `Corrupted`. On error the manager is unchanged.
    pub fn allocate(self: *PageManager, io: Io) AllocateError!Id {
        assert(self.page_count >= 1);
        assert(header.page_size_valid(self.page_size));
        var head_buf = [_]u8{0} ** header.page_size_max;
        const head_page = self.head_slice(&head_buf);
        if (head_page) |page| try self.read_trunk_raw(io, self.freelist_head.?, page);
        const popped = freelist.allocate(self.freelist_head, head_page, self.wal_lsn) catch |err| {
            return trunk_error(err);
        };

        const id = popped.id orelse return self.allocate_grow(io, &head_buf);
        if (@intFromEnum(id) >= self.page_count) return error.Corrupted;
        if (popped.head) |next| {
            if (@intFromEnum(next) >= self.page_count) return error.Corrupted;
        }
        if (popped.head_dirty) try self.write_raw(io, self.freelist_head.?, head_page.?);
        if (popped.head != self.freelist_head) {
            try self.write_file_header(io, &head_buf, self.page_count, popped.head);
        }
        self.freelist_head = popped.head;
        assert(@intFromEnum(id) >= 1);
        assert(@intFromEnum(id) < self.page_count);
        return id;
    }

    /// Returns page `id` to the freelist. The page's contents are dead from here on. Preconditions:
    /// `0 < id < page_count`; the page is live (not already free: a double free of the head or
    /// of a page in the head trunk is asserted, one deeper in the list is not detectable here).
    /// Never needs new space. Errors: the head trunk is unwritten or malformed (`Corrupted`,
    /// `ChecksumMismatch`). On error the manager is unchanged.
    pub fn free(self: *PageManager, io: Io, id: Id) FreeError!void {
        assert(@intFromEnum(id) >= 1);
        assert(@intFromEnum(id) < self.page_count);
        var head_buf = [_]u8{0} ** header.page_size_max;
        var freed_buf = [_]u8{0} ** header.page_size_max;
        const head_page = self.head_slice(&head_buf);
        if (head_page) |page| try self.read_trunk_raw(io, self.freelist_head.?, page);
        const freed_page = freed_buf[0..self.page_size];
        const released = freelist.free(
            self.freelist_head,
            head_page,
            id,
            freed_page,
            self.wal_lsn,
        ) catch |err| return trunk_error(err);

        switch (released.written) {
            .head_page => try self.write_raw(io, self.freelist_head.?, head_page.?),
            .freed_page => try self.write_raw(io, id, freed_page),
        }
        if (released.head != self.freelist_head) {
            try self.write_file_header(io, &freed_buf, self.page_count, released.head);
        }
        self.freelist_head = released.head;
        assert(self.freelist_head != null);
    }

    /// Makes every completed write durable per the file's `SyncPolicy` (a no-op for `.none`).
    pub fn sync(self: *PageManager, io: Io) SyncError!void {
        assert(self.page_count >= 1);
        assert(header.page_size_valid(self.page_size));
        try self.file.sync(io);
    }

    fn head_slice(self: *const PageManager, buf: *[header.page_size_max]u8) ?[]u8 {
        assert(header.page_size_valid(self.page_size));
        assert((self.freelist_head == null) or (self.page_count >= 2));
        return if (self.freelist_head != null) buf[0..self.page_size] else null;
    }

    /// Grows the file by one page: reserve the space, then publish it in page 0.
    fn allocate_grow(
        self: *PageManager,
        io: Io,
        scratch: *[header.page_size_max]u8,
    ) AllocateError!Id {
        assert(self.freelist_head == null);
        assert(self.page_count >= 1);
        if (self.page_count >= self.page_count_max) return error.NoSpaceLeft;
        const new_count = self.page_count + 1;
        assert(new_count <= self.page_count_max);
        try self.file.preallocate(io, @as(u64, new_count) * self.page_size);
        try self.write_file_header(io, scratch, new_count, null);
        const id: Id = @enumFromInt(self.page_count);
        self.page_count = new_count;
        assert(@intFromEnum(id) == self.page_count - 1);
        return id;
    }

    /// Reads the head trunk's raw bytes; decoding is `freelist`'s, so the checksum is verified
    /// once. A head outside the file or a short read is corruption of the list.
    fn read_trunk_raw(self: *PageManager, io: Io, head: Id, page: []u8) TrunkReadError!void {
        assert(page.len == self.page_size);
        assert(@intFromEnum(head) >= 1);
        if (@intFromEnum(head) >= self.page_count) return error.Corrupted;
        self.file.readAtAll(io, page, self.page_offset(head)) catch |err| switch (err) {
            error.UnexpectedEof => return error.Corrupted,
            else => |other| return other,
        };
    }

    fn write_raw(self: *PageManager, io: Io, id: Id, page: []const u8) file.WriteError!void {
        assert(page.len == self.page_size);
        assert(@intFromEnum(id) >= 1);
        try self.file.writeAtAll(io, page, self.page_offset(id));
    }

    /// Writes page 0 using the first `page_size` bytes of `scratch` (overwritten entirely).
    fn write_file_header(
        self: *PageManager,
        io: Io,
        scratch: *[header.page_size_max]u8,
        page_count: u32,
        freelist_head: ?Id,
    ) file.WriteError!void {
        assert(page_count >= self.page_count);
        assert(page_count <= self.page_count_max or page_count == self.page_count);
        const page = scratch[0..self.page_size];
        header.encode_file_header(page, .{
            .page_size = self.page_size,
            .page_count = page_count,
            .freelist_head = freelist_head,
            .wal_lsn = self.wal_lsn,
        });
        try self.file.writeAtAll(io, page, 0);
    }

    fn page_offset(self: *const PageManager, id: Id) u64 {
        assert(@intFromEnum(id) < self.page_count);
        assert(header.page_size_valid(self.page_size));
        return @as(u64, self.page_size) * @intFromEnum(id);
    }
};

/// A head trunk that fails its decode: an unwritten page cannot be a trunk, so it is corrupt.
fn trunk_error(err: header.DecodeError) error{ Corrupted, ChecksumMismatch } {
    return switch (err) {
        error.Unwritten, error.Corrupted => error.Corrupted,
        error.ChecksumMismatch => error.ChecksumMismatch,
    };
}

/// Open steps 1-3: read the 512-byte prefix, check the page size it claims, then read and
/// decode all of page 0. A short file is `Corrupted` (not a strata file), never `UnexpectedEof`.
fn open_file_header(io: Io, handle: file.File, page_size: u32) OpenError!header.FileHeader {
    assert(header.page_size_valid(page_size));
    assert(page_size >= header.page_size_min);
    var scratch = [_]u8{0} ** header.page_size_max;
    const prefix = scratch[0..header.page_size_min];
    handle.readAtAll(io, prefix, 0) catch |err| switch (err) {
        error.UnexpectedEof => return error.Corrupted,
        else => |other| return other,
    };
    const claimed = header.peek_page_size(prefix) catch |err| switch (err) {
        error.Unwritten, error.Corrupted, error.ChecksumMismatch => return error.Corrupted,
    };
    if (claimed != page_size) return error.Corrupted;

    const page = scratch[0..claimed];
    handle.readAtAll(io, page, 0) catch |err| switch (err) {
        error.UnexpectedEof => return error.Corrupted,
        else => |other| return other,
    };
    return header.decode_file_header(page) catch |err| switch (err) {
        error.Unwritten, error.Corrupted => return error.Corrupted,
        error.ChecksumMismatch => return error.ChecksumMismatch,
    };
}

test {
    _ = @import("manager_test.zig"); // Contract tests live in their own files (800-line limit).
    _ = @import("manager_alloc_test.zig");
}
