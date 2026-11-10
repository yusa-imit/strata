//! strata.testing.durable — undo log behind the durable mode of `FaultIo` (plan 006 item 9).
//!
//! A `Durable` remembers, for every positional write that went through a durable `FaultIo`, the
//! bytes it overwrote (the pre-image) and the file length before it. `drop_file` forgets one
//! file's entries (its sync made them durable); `restore` puts every remaining pre-image back,
//! newest first, and cuts the files back to their old lengths, so what was never synced is
//! genuinely gone. A crash model for the durable boundary, not for torn sectors: use `CrashSink`
//! for those.
//!
//! Not modeled: file creation and deletion, and directory entries. Only the bytes and the length
//! of files that were already open through the wrapper are undone. A file closed with unsynced
//! entries cannot be restored through a stale handle, so it latches `closed_dirty` and `restore`
//! reports `error.FileClosed` instead of guessing. Sync the file before closing it, or crash
//! before closing.
//!
//! Allocation: none, ever; the caller gives the entry and pre-image buffers. A write whose
//! pre-image does not fit is refused (the `FaultIo` fails it with `error.InputOutput`) and
//! latches `overflowed`, which `restore` reports as `error.UndoFull` after it restored every
//! entry it did record. Not thread-safe.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;

/// One recorded write: the bytes it overwrote and the file length before it.
pub const Entry = struct {
    file: Io.File,
    /// Where the write started, in the file.
    offset: u64,
    /// The file's length before the write.
    length_before: u64,
    /// Pre-image bytes held, `<=` the write's length (clamped to `length_before`).
    len: u32,
    /// Where the pre-image starts in the byte buffer.
    bytes_offset: u32,
};

/// Why a write could not be recorded: the inner `Io` failed or was canceled, or the log is full
/// (reported as `InputOutput`, with `overflowed` latched).
pub const CaptureError = error{ InputOutput, Canceled };

/// Why `restore` did not leave the files exactly as they were at their last syncs.
pub const RestoreError = error{ UndoFull, FileClosed, InputOutput, Canceled };

pub const Durable = struct {
    entries: []Entry,
    pre_images: []u8,
    entries_used: u32,
    bytes_used: u32,
    /// A write was refused for want of room: the undo log is incomplete.
    overflowed: bool,
    /// A file was closed with unsynced entries.
    closed_dirty: bool,
    /// Bytes `restore` has put back (pre-images, plus length it cut off), over all crashes.
    reverted_bytes: u64,

    /// Precondition: both buffers fit `u32` indexes. `entries` and `pre_images` must outlive
    /// the `Durable`.
    pub fn init(target: *Durable, entries: []Entry, pre_images: []u8) void {
        assert(entries.len <= std.math.maxInt(u32));
        assert(pre_images.len <= std.math.maxInt(u32));
        target.* = .{
            .entries = entries,
            .pre_images = pre_images,
            .entries_used = 0,
            .bytes_used = 0,
            .overflowed = false,
            .closed_dirty = false,
            .reverted_bytes = 0,
        };
        target.check_invariants();
    }

    /// Appends an entry and returns its pre-image slice (`len` bytes) for the caller to fill.
    /// `error.UndoFull` when the entry or byte buffer has no room; `overflowed` is latched.
    pub fn record(
        self: *Durable,
        file: Io.File,
        offset: u64,
        length_before: u64,
        len: u32,
    ) error{UndoFull}![]u8 {
        assert(self.entries_used <= self.entries.len);
        assert(self.bytes_used <= self.pre_images.len);
        const room = self.pre_images.len - self.bytes_used;
        if (self.entries_used == self.entries.len or len > room) {
            self.overflowed = true;
            return error.UndoFull;
        }
        self.entries[self.entries_used] = .{
            .file = file,
            .offset = offset,
            .length_before = length_before,
            .len = len,
            .bytes_offset = self.bytes_used,
        };
        const slice = self.pre_images[self.bytes_used..][0..len];
        self.entries_used += 1;
        self.bytes_used += len;
        assert(slice.len == len);
        assert(self.bytes_used <= self.pre_images.len);
        return slice;
    }

    /// Removes the newest entry (its pre-image could not be read). Precondition: one exists.
    pub fn pop_last(self: *Durable) void {
        assert(self.entries_used >= 1);
        assert(self.bytes_used >= self.entries[self.entries_used - 1].len);
        self.entries_used -= 1;
        self.bytes_used = self.entries[self.entries_used].bytes_offset;
        assert(self.bytes_used <= self.pre_images.len);
    }

    /// Reads the pre-image of a write of `write_len` bytes at `offset` through `inner` and
    /// records it. Call it before the write reaches `inner`. A full log is `InputOutput`.
    pub fn capture(
        self: *Durable,
        inner: Io,
        file: Io.File,
        offset: u64,
        write_len: u64,
    ) CaptureError!void {
        assert(write_len >= 1);
        assert(offset <= std.math.maxInt(u64) - write_len);
        const length = file.length(inner) catch |err| return inner_failed(err);
        const pre_len: u64 = if (offset >= length) 0 else @min(write_len, length - offset);
        if (pre_len > std.math.maxInt(u32)) {
            self.overflowed = true;
            return error.InputOutput;
        }
        const slice = self.record(file, offset, length, @intCast(pre_len)) catch {
            return error.InputOutput; // Full: `record` latched `overflowed`.
        };
        errdefer self.pop_last();

        var filled: usize = 0;
        for (0..slice.len) |_| {
            if (filled == slice.len) break;
            const buffers: [1][]u8 = .{slice[filled..]};
            const n = file.readPositional(inner, &buffers, offset + filled) catch |err| {
                return inner_failed(err);
            };
            if (n == 0) return error.InputOutput; // The file shrank under us.
            filled += n;
        }
        assert(filled == slice.len);
    }

    /// Forgets every entry of `file`, keeping the others in order (its sync made them durable).
    pub fn drop_file(self: *Durable, file: Io.File) void {
        assert(self.entries_used <= self.entries.len);
        var kept: u32 = 0;
        var bytes_kept: u32 = 0;
        for (self.entries[0..self.entries_used]) |entry| {
            if (entry.file.handle == file.handle) continue;
            const from = self.pre_images[entry.bytes_offset..][0..entry.len];
            const to = self.pre_images[bytes_kept..][0..entry.len];
            std.mem.copyForwards(u8, to, from);
            self.entries[kept] = entry;
            self.entries[kept].bytes_offset = bytes_kept;
            kept += 1;
            bytes_kept += entry.len;
        }
        self.entries_used = kept;
        self.bytes_used = bytes_kept;
        self.check_invariants();
    }

    /// Latches `closed_dirty` when `file` is closed while it still has unsynced entries.
    pub fn note_close(self: *Durable, file: Io.File) void {
        assert(self.entries_used <= self.entries.len);
        for (self.entries[0..self.entries_used]) |entry| {
            if (entry.file.handle == file.handle) self.closed_dirty = true;
        }
        assert(self.closed_dirty or self.entries_used <= self.entries.len);
        assert(self.bytes_used <= self.pre_images.len);
    }

    /// Puts every pre-image back through `inner`, newest first, cuts grown files back to their
    /// old length, and clears the log and its latches. Reports `FileClosed` (nothing restored)
    /// or `UndoFull` (everything recorded was restored) after clearing. The files must still be
    /// open.
    pub fn restore(self: *Durable, inner: Io) RestoreError!void {
        self.check_invariants();
        const closed = self.closed_dirty;
        const overflowed = self.overflowed;
        defer self.clear();

        if (!closed) {
            var index: u32 = self.entries_used;
            for (0..self.entries.len) |_| {
                if (index == 0) break;
                index -= 1;
                try self.restore_one(inner, self.entries[index]);
            }
            assert(index == 0);
        }
        if (closed) return error.FileClosed;
        if (overflowed) return error.UndoFull;
    }

    fn restore_one(self: *Durable, inner: Io, entry: Entry) RestoreError!void {
        assert(entry.bytes_offset + entry.len <= self.bytes_used);
        const length = entry.file.length(inner) catch |err| return inner_failed(err);
        if (length > entry.length_before) {
            entry.file.setLength(inner, entry.length_before) catch |err| {
                return inner_failed(err);
            };
            self.reverted_bytes += length - entry.length_before;
        }
        if (entry.len == 0) return;
        const bytes = self.pre_images[entry.bytes_offset..][0..entry.len];
        entry.file.writePositionalAll(inner, bytes, entry.offset) catch |err| {
            return inner_failed(err);
        };
        self.reverted_bytes += entry.len;
    }

    fn clear(self: *Durable) void {
        self.entries_used = 0;
        self.bytes_used = 0;
        self.overflowed = false;
        self.closed_dirty = false;
        assert(self.entries_used == 0);
        assert(self.bytes_used == 0);
        assert(!self.overflowed);
    }

    /// Asserts the log is consistent: pre-images are packed in entry order and in bounds.
    pub fn check_invariants(self: *const Durable) void {
        assert(self.entries_used <= self.entries.len);
        assert(self.bytes_used <= self.pre_images.len);
        var bytes: u32 = 0;
        for (self.entries[0..self.entries_used]) |entry| {
            assert(entry.bytes_offset == bytes);
            assert(entry.len <= entry.length_before or entry.len == 0);
            bytes += entry.len;
        }
        assert(bytes == self.bytes_used);
    }
};

/// Every inner failure but cancelation is an I/O failure of the undo log; callers see only the
/// two codes a positional write can already return.
fn inner_failed(err: anyerror) error{ InputOutput, Canceled } {
    assert(err != error.OutOfMemory); // Nothing here allocates.
    return switch (err) {
        error.Canceled => error.Canceled,
        else => error.InputOutput,
    };
}
