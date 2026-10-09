//! Page manager (ADR-0002 §5): owns one `file.File` of fixed-size, checksummed pages and
//! moves whole pages between a caller buffer and the file. Item 5 scope: `create`, `open`,
//! `read`, `write`; page allocation, the freelist and growth arrive with plan 003 item 6.
//!
//! Invariants: page 0 holds the file header and is owned by the manager (callers address pages
//! `1 ..< page_count`); `page_size` is a valid power of two and equals the file header's; the
//! file is at least `page_count * page_size` bytes and exclusively locked from `create`/`open`
//! until `close`; every page write stamps the id-seeded CRC32C, every read verifies it.
//! Allocation: none. `create` and `open` use a `page_size_max` stack scratch for page 0, so
//! no method allocates and none stores an allocator. The file handle is a leaf value and `io`
//! is passed per call (ADR-0001). `read`/`write` never sync; durability is the caller's call.
//! Errors: bad bytes on disk are typed (`Corrupted`, `ChecksumMismatch`, `Unwritten`,
//! `TornWrite`); wrong ids, buffer lengths or options are caller contract violations (asserted).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const file = @import("../file/file.zig");
const header = @import("header.zig");
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

    fn page_offset(self: *const PageManager, id: Id) u64 {
        assert(@intFromEnum(id) < self.page_count);
        assert(header.page_size_valid(self.page_size));
        return @as(u64, self.page_size) * @intFromEnum(id);
    }
};

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
}
