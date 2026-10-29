//! Full-page-image redo (ADR-0003 section 10, ADR-0002 section 6): an `Apply` target for
//! `Recovery.replay` that repairs torn or stale pages from `page_image` frames.
//!
//! Frame rule: a `page_image` payload is `page_id: u32` (little-endian) and then the page bytes
//! as they were in memory. Other frame types (`record`, `checkpoint`, consumer types) are not
//! this target's business and are ignored (counted in `Stats.ignored`). Validation comes first
//! and never touches the file: a payload under 4 bytes, an image whose length differs from the
//! manager's page size, `page_id` 0 (page 0 has no torn-write repair, ADR-0003 Open question
//! 2: `PageManager.write` owns it), an image without the page magic, or a type byte not legal
//! at `page_id` is `Corrupted`. The image's own checksum may be stale (`poke_lsn`) and is not
//! checked: its page type is kept, the lsn is replaced by `frame.lsn`, and `PageManager.write`
//! stamps a fresh checksum.
//!
//! Apply rule (idempotent redo): the page is read through `PageManager.read`. The image is
//! written iff the read fails with `TornWrite`, `Unwritten`, `Corrupted` or `ChecksumMismatch`
//! (a torn or never-written page) or the page's lsn is below `frame.lsn`; otherwise it is
//! skipped. The page is re-stamped through `PageManager.write` with `lsn = frame.lsn`, so a
//! second replay of the same frame sees equality and skips. A page lsn above `frame.lsn` is a
//! newer page and is left alone. The write is not synced: durability of redo is the caller's
//! `PageManager.sync` after replay.
//!
//! `page_images` frames (frame type 16, ADR-0004 section 9) hold many images. The whole frame is
//! validated first (`frame.payload_valid`: count, page size, strictly ascending ids, magic,
//! legal types; and the page size equals the manager's), so a bad entry is `Corrupted` before
//! anything is grown or written. The file is then grown once to cover the last id (`Failed`
//! before any write), and each image is redone under the rules above. `Stats` count per image.
//! An I/O error midway leaves the images already written in place, as for any redo.
//!
//! Growth: a `page_id` at or past `page_count` first grows the file with
//! `PageManager.ensure_page_count`, so the file covers the id (pages in between read as
//! `Unwritten` and are not on the freelist). Only a page the file lacks meets `page_count_max`:
//! growth past it is `Failed`, while a page already inside `page_count` is redone even if the
//! limit is lower than the file (a reopened `Options`).
//!
//! Precedence: a malformed image is `Corrupted` before any limit or I/O `Failed` is possible.
//! Errors: `Corrupted` for a bad image (the log said something the format forbids); `Failed`
//! for every I/O error and for the file limit. Both stop `Recovery.replay` and leave the log
//! untouched. Allocation: one page-sized buffer from `gpa` in `init`, freed in `deinit`;
//! `apply` allocates nothing. No loops, no recursion. Single-threaded: the manager is borrowed
//! and must outlive the `PageRedo`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");

const PageManager = manager.PageManager;

/// How many frames of each outcome this target has seen.
pub const Stats = struct {
    /// Images (from `page_image` and `page_images` frames) written to the page file.
    applied: u64 = 0,
    /// Images skipped because the page was already at or past the frame's lsn.
    skipped: u64 = 0,
    /// Frames of any other type.
    ignored: u64 = 0,
};

/// Fields of a validated image.
const Image = struct { id: header.Id, page_type: header.Type, bytes: []const u8 };

const payload_id_size: u32 = 4;

pub const PageRedo = struct {
    pm: *PageManager,
    buf: []u8,
    stats: Stats,

    const vtable: recovery.Apply.VTable = .{ .apply = apply_fn };

    /// Allocates the one page-sized buffer. `pm` must outlive `target` and stay unmoved.
    pub fn init(target: *PageRedo, gpa: Allocator, pm: *PageManager) Allocator.Error!void {
        assert(header.page_size_valid(pm.page_size));
        assert(pm.page_count >= 1);
        const buf = try gpa.alloc(u8, pm.page_size);
        target.* = .{ .pm = pm, .buf = buf, .stats = .{} };
        assert(target.buf.len == pm.page_size);
    }

    /// Frees the buffer; the same `gpa` as `init`.
    pub fn deinit(self: *PageRedo, gpa: Allocator) void {
        assert(self.buf.len == self.pm.page_size);
        assert(header.page_size_valid(self.pm.page_size));
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// The `Apply` target for `Recovery.replay`; valid while `self` stays at this address.
    pub fn apply_target(self: *PageRedo) recovery.Apply {
        assert(self.buf.len == self.pm.page_size);
        assert(self.pm.page_count >= 1);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn apply_fn(ptr: *anyopaque, io: Io, f: frame.Frame) recovery.ApplyError!void {
        const self: *PageRedo = @ptrCast(@alignCast(ptr));
        assert(self.buf.len == self.pm.page_size);
        assert(f.lsn >= frame.lsn_first);
        switch (f.frame_type) {
            .page_image => try self.redo_image(io, try self.parse(f.payload), f.lsn),
            .page_images => try self.apply_images(io, f),
            .record, .checkpoint, _ => self.stats.ignored += 1,
        }
    }

    /// Applies one validated image: grows the file to cover it, then writes it if the page needs
    /// redo. Counts `applied` or `skipped`.
    fn redo_image(self: *PageRedo, io: Io, image: Image, lsn: frame.Lsn) recovery.ApplyError!void {
        assert(self.buf.len == self.pm.page_size);
        assert(lsn >= frame.lsn_first);
        const id_raw: u32 = @intFromEnum(image.id);
        if (id_raw >= self.pm.page_count) { // Only a page the file lacks meets the limit.
            const count = std.math.add(u32, id_raw, 1) catch return error.Failed;
            self.pm.ensure_page_count(io, count) catch return error.Failed;
        }
        if (!try self.needs_redo(io, image.id, lsn)) {
            self.stats.skipped += 1;
            return;
        }
        @memcpy(self.buf, image.bytes);
        const page_header: header.Header = .{ .page_type = image.page_type, .lsn = lsn };
        self.pm.write(io, image.id, self.buf, page_header) catch return error.Failed;
        self.stats.applied += 1;
    }

    /// A `page_images` frame (ADR-0004 section 9): validate every entry first (`Corrupted`
    /// before any growth or write), grow the file once to cover the last id (`Failed` before any
    /// write), then redo each image under the `page_image` rules, counting per image.
    fn apply_images(self: *PageRedo, io: Io, f: frame.Frame) recovery.ApplyError!void {
        assert(self.buf.len == self.pm.page_size);
        assert(f.frame_type == .page_images);
        const count = try self.parse_images(f);
        assert(count >= 1);
        assert(count <= frame.images_count_max);
        const entry_size: u32 = payload_id_size + self.pm.page_size;
        const last_offset = frame.images_prefix_size + (count - 1) * entry_size;
        const last_id = std.mem.readInt(u32, f.payload[last_offset..][0..4], .little);
        if (last_id >= self.pm.page_count) {
            const grown = std.math.add(u32, last_id, 1) catch return error.Failed;
            self.pm.ensure_page_count(io, grown) catch return error.Failed;
        }
        var offset: u32 = frame.images_prefix_size;
        for (0..count) |_| {
            const image = try self.parse(f.payload[offset..][0..entry_size]);
            try self.redo_image(io, image, f.lsn);
            offset += entry_size;
        }
        assert(offset == f.payload.len);
    }

    /// Validates a whole `page_images` payload (the frame rules of `frame.payload_valid`, and the
    /// manager's page size) and returns the image count. Touches no file.
    fn parse_images(self: *const PageRedo, f: frame.Frame) recovery.ApplyError!u32 {
        assert(self.buf.len == self.pm.page_size);
        assert(f.payload.len <= frame.payload_bytes_max);
        const type_byte: u8 = @intFromEnum(frame.Type.page_images);
        if (!frame.payload_valid(type_byte, f.lsn, f.payload)) return error.Corrupted;
        const page_size = std.mem.readInt(u32, f.payload[4..8], .little);
        if (page_size != self.pm.page_size) return error.Corrupted;
        const count = std.mem.readInt(u32, f.payload[0..4], .little);
        assert(count >= 1); // `payload_valid` proved the layout.
        return count;
    }

    /// Validates a `page_image` payload against the manager's page size; touches no file.
    fn parse(self: *const PageRedo, payload: []const u8) recovery.ApplyError!Image {
        assert(self.buf.len == self.pm.page_size);
        assert(payload.len <= frame.payload_bytes_max);
        if (payload.len < payload_id_size) return error.Corrupted;
        const id_raw = std.mem.readInt(u32, payload[0..payload_id_size], .little);
        if (id_raw == 0) return error.Corrupted; // Open question 2: page 0 has no image path.
        const bytes = payload[payload_id_size..];
        if (bytes.len != self.pm.page_size) return error.Corrupted;
        if (!std.mem.eql(u8, bytes[0..header.magic.len], &header.magic)) return error.Corrupted;
        const id: header.Id = @enumFromInt(id_raw);
        const peeked = header.peek(bytes); // Unverified: the checksum may be stale.
        if (!header.type_valid(id, @intFromEnum(peeked.page_type))) return error.Corrupted;
        return .{ .id = id, .page_type = peeked.page_type, .bytes = bytes };
    }

    /// True when the page is torn, unwritten or older than `lsn`. Needs `id < page_count`.
    fn needs_redo(
        self: *PageRedo,
        io: Io,
        id: header.Id,
        lsn: frame.Lsn,
    ) recovery.ApplyError!bool {
        assert(@intFromEnum(id) >= 1);
        assert(@intFromEnum(id) < self.pm.page_count);
        const page_header = self.pm.read(io, id, self.buf) catch |err| switch (err) {
            error.TornWrite,
            error.Unwritten,
            error.Corrupted,
            error.ChecksumMismatch,
            => return true,
            // Every I/O error stops the replay; listed so a new variant breaks the build.
            error.InputOutput,
            error.SystemResources,
            error.IsDir,
            error.WouldBlock,
            error.AccessDenied,
            error.LockViolation,
            error.Unseekable,
            error.NotOpenForReading,
            error.Canceled,
            error.Unexpected,
            error.UnexpectedEof,
            => return error.Failed,
        };
        return page_header.lsn < lsn;
    }
};

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("redo_test.zig");
    _ = @import("redo_images_test.zig");
}
