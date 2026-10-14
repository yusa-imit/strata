//! WAL reader (ADR-0003 sections 1, 5 and 8): lists a log directory, checks that its segments
//! are contiguous and that their first LSNs fit together, then hands out the frames of all
//! segments in order, one `next` call at a time.
//!
//! Invariants: the live segments are the files named for a segment (`segment.parse_name`),
//! sorted by index; they have no index hole (a log may start above index 1 after reclaim) and
//! their header first LSNs strictly increase, each one inside the bytes of the segment before
//! it; the exact rule, `first_lsn == end LSN of the previous frames`, is checked when `next`
//! crosses the boundary, because a zero tail (section 8) hides the end until then. `Unwritten`
//! or `TornWrite` is legal only for the newest segment (highest index), which is then absent:
//! the log ends at its predecessor, or is empty if that is segment 1. `next` returns `null`
//! only at a clean end: the end of the newest segment's frames, or zeros up to its end. A bad
//! frame is `TornWrite` iff it is in the newest segment, is not intact (`frame.intact`) and no
//! intact frame starts at any later offset of that segment (the look-ahead); the only error a
//! recovery may truncate on. Otherwise it is `ChecksumMismatch` if the checksum failed, else
//! `Corrupted`. Every LSN handed to `frame.decode` is range-checked first, so corrupt headers
//! are typed errors, never assertion failures. After an error `next` must not be called again.
//! Allocation: `open` allocates once, from the `gpa` it is given: one `frame_bytes_max` frame
//! buffer and `segments_max` 16 byte directory entries. `next`, `position` and the look-ahead
//! allocate nothing (the look-ahead uses a 64 KiB stack window), and no allocator is stored:
//! `deinit` takes the same `gpa` back. `io` is passed per call (ADR-0001).
//! Cost sketch: `open` is one directory scan plus one open, lock, stat and 24 byte read per
//! segment, the segments closed again but the first, so it is linear in `segments_max` and does
//! not read frames. `next` is one read of at most `frame_bytes_max` bytes and one CRC per frame.
//! Only a failure in the newest segment runs the look-ahead, at most once: a pass over the rest
//! of that segment, at most `segment_bytes_limit` bytes, whose CRC runs only on LSN matches.
//! Locking: the reader holds the exclusive lock (`Segment.open`) of the segment it reads, from
//! `open` until the end of the log, an error or `deinit`, so a second reader or a writer on the
//! same directory fails with `WouldBlock` meanwhile.
//! Borrowing: a returned `Frame.payload` points into the reader's buffer and is valid only until
//! the next call of `next`. Not thread-safe.
//! Not here: seeking to a checkpoint's `from_lsn` and truncating a torn tail belong to recovery
//! (plan 004, item 7); `position` tells it where the log ended.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const file = @import("../file/file.zig");
const frame = @import("frame.zig");
const segment = @import("segment.zig");

pub const Lsn = frame.Lsn;

/// Where the cursor stands: the segment and byte offset of the next frame, and its LSN. An
/// empty log (no readable segment) is `{0, 0, 0}`. After a clean end this is where a writer
/// appends next (item 5).
pub const Position = struct { segment_index: u32, offset: u64, lsn: Lsn };

const IoError = file.OpenError || file.TryLockError || file.LengthError ||
    Io.File.ReadPositionalError;
/// What a segment header or a frame says about the bytes on disk, apart from a torn tail.
pub const FormatError = error{ ChecksumMismatch, Corrupted };
const EnterError = IoError || FormatError;
pub const OpenError = EnterError || Allocator.Error || Io.Dir.Iterator.Error ||
    error{SegmentLimit};
pub const NextError = EnterError || error{TornWrite};

/// Directory entries a scan may visit: a directory with more is not a WAL directory.
const dir_entries_max: u32 = 1 << 20;
/// The look-ahead reads the rest of the newest segment through a window of this size; windows
/// overlap by `frame_header_size - 1` bytes so a header at a window's end is seen whole.
const window_size: u32 = 65536;
const window_overlap: u32 = frame.frame_header_size - 1;
const window_stride: u32 = window_size - window_overlap;
const windows_max: u32 = @intCast(@divFloor(segment.segment_bytes_limit, window_stride) + 2);

comptime {
    assert(window_stride > 0);
    assert(window_size >= frame.frame_header_size);
    assert(@as(u64, windows_max) * window_stride >= segment.segment_bytes_limit);
    assert(frame.frame_bytes_max >= window_size); // The frame buffer doubles as scratch.
}

const Entry = struct { index: u32, first_lsn: Lsn };
const State = enum { reading, finished, failed };
const Probe = struct { first_lsn: Lsn, length: u64 };

fn entry_less(_: void, a: Entry, b: Entry) bool {
    assert(a.index != b.index); // File names are unique.
    return a.index < b.index;
}

/// Collects the indices of the segment files of `dir` into `entries`, sorted. `SegmentLimit`
/// when more than `options.segments_max` exist; `Corrupted` for a name with index 0.
fn list_segments(
    io: Io,
    dir: Io.Dir,
    entries: []Entry,
    options: segment.Options,
) (Io.Dir.Iterator.Error || error{ SegmentLimit, Corrupted })!u32 {
    assert(entries.len == options.segments_max);
    assert(options.segments_max >= 1);
    var count: u32 = 0;
    var it = dir.iterate();
    for (0..dir_entries_max) |_| {
        const entry = (try it.next(io)) orelse break;
        if (entry.name.len != segment.name_size) continue;
        const index = (try segment.parse_name(entry.name)) orelse continue;
        try segment.live_count_check(count + 1, options);
        entries[count] = .{ .index = index, .first_lsn = 0 };
        count += 1;
    } else return error.SegmentLimit; // Too many unrelated entries: not a WAL directory.
    assert(count <= entries.len);
    std.mem.sort(Entry, entries[0..count], {}, entry_less);
    return count;
}

/// Opens segment `index` just long enough to read its header and length.
fn probe(io: Io, dir: Io.Dir, index: u32, options: segment.Options) segment.OpenError!Probe {
    assert(index >= 1);
    assert(options.segments_max >= 1);
    const seg = try segment.Segment.open(io, dir, index, options);
    defer seg.close(io);

    const length = try seg.length(io);
    assert(length >= segment.segment_header_size); // `open` read a whole header.
    return .{ .first_lsn = seg.first_lsn, .length = length };
}

/// The next segment must start after the previous one and inside its bytes (it starts at the
/// end of the previous *frames*, which cannot lie beyond the previous file).
fn continuity_check(
    previous: Entry,
    previous_length: u64,
    upcoming_first: Lsn,
) error{Corrupted}!void {
    assert(previous_length >= segment.segment_header_size);
    assert(previous.first_lsn < frame.lsn_limit);
    if (upcoming_first <= previous.first_lsn) return error.Corrupted;
    const frame_bytes = previous_length - segment.segment_header_size;
    if (upcoming_first - previous.first_lsn > frame_bytes) return error.Corrupted;
}

/// Reads every header of the sorted `entries`, fills in their first LSNs and returns how many
/// are readable: all, or all but an `Unwritten`/`TornWrite` newest one. Index holes, first-LSN
/// discontinuities and unreadable non-newest headers are `Corrupted`.
fn validate(
    io: Io,
    dir: Io.Dir,
    entries: []Entry,
    options: segment.Options,
) (IoError || FormatError)!u32 {
    assert(entries.len <= options.segments_max);
    assert(options.segments_max >= 1);
    var previous_length: u64 = 0;
    for (entries, 0..) |*entry, i| {
        if (i > 0 and @as(u64, entries[i - 1].index) + 1 != entry.index) return error.Corrupted;
        const found = probe(io, dir, entry.index, options) catch |err| switch (err) {
            error.Unwritten, error.TornWrite => { // A segment that was being created.
                if (i + 1 != entries.len) return error.Corrupted;
                if (i == 0 and entry.index != 1) return error.Corrupted; // Predecessor missing.
                return @intCast(i);
            },
            else => |other| return other,
        };
        assert(found.first_lsn >= frame.lsn_first); // `decode_header` range-checked it.
        assert(found.first_lsn < frame.lsn_limit);
        if (i > 0) try continuity_check(entries[i - 1], previous_length, found.first_lsn);
        entry.first_lsn = found.first_lsn;
        previous_length = found.length;
    }
    return @intCast(entries.len);
}

/// Fills `buf` from `offset`; a file that ends first changed under us: `Corrupted`, never a
/// torn tail (truncating on a short read could cut committed frames).
fn read_exact(io: Io, seg: segment.Segment, buf: []u8, offset: u64) NextError!void {
    assert(offset <= segment.segment_bytes_limit);
    assert(buf.len <= frame.frame_bytes_max);
    seg.file.readAtAll(io, buf, offset) catch |err| switch (err) {
        error.UnexpectedEof => return error.Corrupted,
        else => |other| return other,
    };
}

/// The decode failure `err` as the error `next` reports; `torn` is the tail verdict.
fn decode_failure(err: frame.DecodeError, torn: bool) NextError {
    if (torn) return error.TornWrite;
    return switch (err) {
        error.ChecksumMismatch => error.ChecksumMismatch,
        error.TornWrite, error.Corrupted => error.Corrupted,
    };
}

/// Sequential reader over the segments of one log directory; see the file header.
pub const Reader = struct {
    dir: Io.Dir,
    options: segment.Options,
    /// Capacity `segments_max`; the first `file_count` are the segment files, sorted.
    entries: []Entry,
    file_count: u32,
    /// Segments with a readable header: `file_count`, or one less when the newest is absent.
    live_count: u32,
    buf: []u8,
    current: ?segment.Segment,
    /// Index into `entries` of `current` (0 for an empty log).
    pos: u32,
    /// Byte offset of the next frame in `current`, and the file length when it was entered.
    offset: u64,
    length: u64,
    /// LSN of the frame at `offset`.
    lsn: Lsn,
    state: State,

    /// Scans `dir` (opened with iteration), validates all segment headers and positions the
    /// reader at the first frame. `SegmentLimit` when more than `options.segments_max`
    /// segments exist; `Corrupted`, `ChecksumMismatch` as in the file header; `WouldBlock`
    /// when another handle holds a segment. On error nothing stays open or allocated.
    /// Preconditions: `options.segments_max >= 1`; `dir` allows iteration.
    pub fn open(
        target: *Reader,
        io: Io,
        gpa: Allocator,
        dir: Io.Dir,
        options: segment.Options,
    ) OpenError!void {
        assert(options.segments_max >= 1);
        assert(frame.frame_bytes_max >= frame.frame_header_size);
        const buf = try gpa.alloc(u8, frame.frame_bytes_max);
        errdefer gpa.free(buf);

        const entries = try gpa.alloc(Entry, options.segments_max);
        errdefer gpa.free(entries);

        const file_count = try list_segments(io, dir, entries, options);
        const live_count = try validate(io, dir, entries[0..file_count], options);
        target.* = .{
            .dir = dir,
            .options = options,
            .entries = entries,
            .file_count = file_count,
            .live_count = live_count,
            .buf = buf,
            .current = null,
            .pos = 0,
            .offset = 0,
            .length = 0,
            .lsn = 0,
            .state = if (live_count == 0) .finished else .reading,
        };
        if (live_count > 0) try target.enter(io, 0);
        target.check_invariants();
        assert(live_count <= file_count);
    }

    /// Closes the open segment, if any, and frees what `open` allocated; `gpa` must be the
    /// allocator given to `open`. The reader is invalid afterwards.
    pub fn deinit(self: *Reader, io: Io, gpa: Allocator) void {
        assert(self.buf.len == frame.frame_bytes_max);
        assert(self.entries.len >= 1);
        if (self.current) |seg| seg.close(io);
        gpa.free(self.buf);
        gpa.free(self.entries);
        self.* = undefined;
    }

    /// The next frame in LSN order, or `null` at a clean end of the log (sticky: every later
    /// call returns `null`). `TornWrite` means the newest segment ends in a torn frame at
    /// `position()`; `ChecksumMismatch` and `Corrupted` mean damage. The payload is valid until
    /// the next call. Precondition: no earlier call returned an error.
    pub fn next(self: *Reader, io: Io) NextError!?frame.Frame {
        assert(self.state != .failed);
        assert(self.live_count <= self.file_count);
        if (self.state == .finished) return null;
        errdefer self.state = .failed;

        for (0..self.live_count) |_| {
            if (try self.read_frame(io)) |decoded| return decoded;
            if (!try self.cross(io)) return null;
        }
        // Proof: each pass either returns or moves to the next of `live_count` segments, and
        // the last segment cannot be crossed, so the loop returns before its last pass ends.
        unreachable;
    }

    /// Where the cursor is; see `Position`.
    pub fn position(self: *const Reader) Position {
        assert(self.offset <= self.length);
        assert(self.pos < @max(self.live_count, 1));
        if (self.live_count == 0) return .{ .segment_index = 0, .offset = 0, .lsn = 0 };
        return .{
            .segment_index = self.entries[self.pos].index,
            .offset = self.offset,
            .lsn = self.lsn,
        };
    }

    /// Asserts internal consistency: counts, buffer, cursor and state agree.
    pub fn check_invariants(self: *const Reader) void {
        assert(self.live_count <= self.file_count);
        assert(self.file_count <= self.entries.len);
        assert(self.file_count - self.live_count <= 1);
        assert(self.buf.len == frame.frame_bytes_max);
        assert(self.offset <= self.length);
        assert(self.length <= segment.segment_bytes_limit);
        if (self.live_count == 0) assert(self.state == .finished);
        switch (self.state) {
            .reading => {
                assert(self.current != null);
                assert(self.pos < self.live_count);
                assert(self.offset >= segment.segment_header_size);
                assert(self.lsn >= frame.lsn_first);
            },
            .finished => assert(self.current == null),
            .failed => {},
        }
    }

    /// True when `current` is the segment with the highest index: the only one a crash may
    /// have left torn.
    fn is_newest(self: *const Reader) bool {
        assert(self.pos < self.live_count);
        return self.pos + 1 == self.file_count;
    }

    /// Opens live segment `pos` and puts the cursor on its first frame.
    fn enter(self: *Reader, io: Io, pos: u32) EnterError!void {
        assert(pos < self.live_count);
        assert(self.current == null);
        const entry = self.entries[pos];
        const seg = segment.Segment.open(io, self.dir, entry.index, self.options) catch |err| {
            switch (err) {
                // Its header was whole at `open`: a change since is damage, not a crash.
                error.Unwritten, error.TornWrite => return error.Corrupted,
                else => |other| return other,
            }
        };
        errdefer seg.close(io);

        if (seg.first_lsn != entry.first_lsn) return error.Corrupted;
        const length = try seg.length(io);
        if (length < segment.segment_header_size) return error.Corrupted;
        if (length > segment.segment_bytes_limit) return error.Corrupted;
        self.current = seg;
        self.pos = pos;
        self.offset = segment.segment_header_size;
        self.length = length;
        self.lsn = entry.first_lsn;
    }

    /// Leaves the segment that is at its end: moves to the next one (true) after checking that
    /// it starts exactly where these frames ended, or ends the log (false).
    fn cross(self: *Reader, io: Io) EnterError!bool {
        assert(self.current != null);
        assert(self.pos < self.live_count);
        if (self.pos + 1 == self.live_count) {
            self.current.?.close(io);
            self.current = null;
            self.state = .finished;
            return false;
        }
        const upcoming = self.entries[self.pos + 1];
        if (upcoming.first_lsn != self.lsn) return error.Corrupted;
        self.current.?.close(io);
        self.current = null;
        try self.enter(io, self.pos + 1);
        return true;
    }

    /// The frame at the cursor, or `null` when the current segment holds no more frames: its
    /// bytes end here, or are all zero from here (ADR-0003 section 8).
    fn read_frame(self: *Reader, io: Io) NextError!?frame.Frame {
        const seg = self.current.?;
        assert(self.offset <= self.length);
        const remaining = self.length - self.offset;
        if (remaining == 0) return null;

        const want: u32 = @intCast(@min(remaining, frame.frame_bytes_max));
        const image = self.buf[0..want];
        try read_exact(io, seg, image, self.offset);
        const head = image[0..@min(want, frame.frame_header_size)];
        if (std.mem.allEqual(u8, head, 0) and try self.zero_rest(io, seg)) return null;
        if (self.lsn >= frame.lsn_limit) return error.Corrupted; // `decode` asserts the range.

        const decoded = frame.decode(image, self.lsn) catch |err| {
            const torn = try self.tail_is_torn(io, seg, image);
            return decode_failure(err, torn);
        };
        const total = frame.frame_header_size + @as(u32, @intCast(decoded.payload.len));
        assert(total <= want);
        self.offset += total;
        self.lsn += total;
        return decoded;
    }

    /// True when every byte from the cursor to the end of the segment is zero.
    fn zero_rest(self: *const Reader, io: Io, seg: segment.Segment) NextError!bool {
        assert(self.offset < self.length);
        assert(self.length <= segment.segment_bytes_limit);
        return segment.zero_from(io, seg.file, self.offset, self.length) catch |err| switch (err) {
            error.TornWrite => return error.Corrupted, // The file ended under us.
            else => |other| return other,
        };
    }

    /// ADR-0003 section 8: a bad frame is a torn tail iff the segment is the newest, the bytes
    /// are not what a writer wrote at this position (`image` is the frame buffer) and no intact
    /// frame follows anywhere in the rest of the segment.
    fn tail_is_torn(
        self: *Reader,
        io: Io,
        seg: segment.Segment,
        image: []const u8,
    ) NextError!bool {
        assert(image.len <= frame.frame_bytes_max);
        assert(self.lsn < frame.lsn_limit);
        if (!self.is_newest()) return false;
        if (frame.intact(image, self.lsn)) return false; // Wrong by rule, not by a crash.
        return !(try self.intact_frame_after(io, seg));
    }

    /// True when some offset after the cursor in the current segment starts a frame that is
    /// intact for its position. Clobbers the frame buffer.
    fn intact_frame_after(self: *Reader, io: Io, seg: segment.Segment) NextError!bool {
        var window: [window_size]u8 = @splat(0);
        var base = self.offset + 1;
        for (0..windows_max) |_| {
            if (base + frame.frame_header_size > self.length) return false;
            const n: u32 = @intCast(@min(self.length - base, window_size));
            try read_exact(io, seg, window[0..n], base);
            if (try self.scan_window(io, seg, window[0..n], base)) return true;
            if (base + n == self.length) return false;
            base += window_stride;
        }
        // Proof: the segment is at most `segment_bytes_limit` long (`enter`), and `windows_max`
        // strides cover that many bytes (comptime-asserted), so `base` reaches the end first.
        unreachable;
    }

    /// Looks for an intact frame starting inside `bytes`, which holds the segment bytes from
    /// file offset `base`: a cheap stored-LSN match first, the checksum only on a match.
    fn scan_window(
        self: *Reader,
        io: Io,
        seg: segment.Segment,
        bytes: []const u8,
        base: u64,
    ) NextError!bool {
        assert(bytes.len >= frame.frame_header_size);
        assert(base > self.offset);
        const candidates: u32 = @intCast(bytes.len - window_overlap);
        for (0..candidates) |y| {
            const at = base + y;
            const lsn_at = self.lsn + (at - self.offset);
            if (lsn_at >= frame.lsn_limit) return false; // Later offsets are further out.
            if (std.mem.readInt(u64, bytes[y + 8 ..][0..8], .little) != lsn_at) continue;
            const len = std.mem.readInt(u32, bytes[y..][0..4], .little);
            if (len > frame.payload_bytes_max) continue;
            const total = frame.frame_header_size + len;
            if (at + total > self.length) continue; // Cut short: not a whole frame.
            try read_exact(io, seg, self.buf[0..total], at);
            if (frame.intact(self.buf[0..total], lsn_at)) return true;
        }
        return false;
    }
};

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("reader_test.zig");
    _ = @import("reader_tail_test.zig");
}
