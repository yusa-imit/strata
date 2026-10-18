//! WAL writer (ADR-0003 sections 5, 8 and 9): finds the end of a log directory through the
//! `Reader`, then appends frames at that end, one `append` call at a time, rotating to a new
//! segment when the next frame would not fit, and making them durable on `sync`.
//!
//! Invariants: the writer owns the exclusive lock (`Segment`) of the newest segment from `init`
//! until `deinit`; `next_lsn` is the LSN of the next frame and equals the current segment's
//! `first_lsn` plus its bytes after the header, `offset` being where that frame goes (the
//! file may be longer: a zero tail is unwritten space and is overwritten in place);
//! `last_lsn` is the LSN of the last frame appended or found at `init` (0 for none) and
//! `durable_lsn <= last_lsn` the LSN of the last frame known durable, inclusive and prefix
//! closed (section 9): it moves only after a `File.sync` of the segment returned, or after a
//! rotation synced the segment it left, or after `init` synced the newest segment it opened
//! (unless the policy is `.none`): a frame read back may never have been synced, so `init` of a
//! non-empty log syncs once before it counts the frames it found as durable.
//! `next_lsn < 2^63` always (`error.LsnExhausted` otherwise).
//! Rotation (section 9): before an `n` byte frame, if the segment already holds a frame and
//! `offset + n > segment_bytes_max`, the writer syncs the segment, creates `index + 1` with
//! `first_lsn = next_lsn`, syncs the new file and then the directory, and only then writes the
//! frame; a lone frame may exceed the option. The next segment is created, and so locked,
//! before the previous one is closed, so there is no gap in the lock. `SegmentLimit` and
//! `SegmentIndexExhausted` are refused before any side effect and do not latch the writer.
//! Latch: an I/O failure after validation (a write, a sync, a rotation step) sets `failed`, and
//! every later `append` and `sync` returns `error.Failed` without touching the files. A failed
//! sync is never retried (the kernel may have dropped the dirty pages, section 9), and a
//! failed write may have left a partial frame; reopening the log is the way out. A caller that
//! uses `append` after `LsnExhausted`, `PayloadTooLarge`, `InvalidFrame` or a segment limit
//! error finds the writer unchanged.
//! Opening: `init` reads the whole log through `Reader` (no `from_lsn` until recovery, item 7)
//! to learn the last LSN. A torn tail is `error.RecoveryRequired`: truncating it is recovery's
//! job, so the writer never repairs data. The one thing it rewrites is a newest segment that
//! `Reader` calls `Unwritten` (empty or all zero, section 8): the crash happened while it was
//! being created and no frame was ever written to it, so it is deleted and created again with
//! the first LSN the log ends at; a newest segment with a partial non-zero header is
//! `RecoveryRequired` like any torn tail. Damage elsewhere is the reader's `Corrupted` or
//! `ChecksumMismatch`, passed through. Between the reader closing the log and the writer
//! locking its newest segment another process could append; one writer per directory is a
//! contract (the lock only makes a second concurrent writer fail with `WouldBlock`).
//! Allocation: `init` allocates the frame buffer (`frame_bytes_max`, one frame at a time; the
//! group commit item grows it into a batch) from the `gpa` it is given, plus the reader's
//! temporary allocations, freed before `init` returns. `append`, `sync` and `position` allocate
//! nothing, and no allocator is stored: `deinit` takes the same `gpa` back. `io` is per call
//! (ADR-0001). Thread-safety: `commit` calls may overlap each other (group commit, see
//! `group_commit.zig`); `append`, `sync` and `deinit` are for one caller and must not overlap a
//! `commit`. `commit` allocates nothing and has no batch buffer: `append` writes through, so
//! `group_commit_bytes_max` bounds the pending bytes a leader waits for, not a buffer.
//! Cost sketch: `init` reads the log once (see `reader.zig`); `append` is one CRC32C pass and
//! one positional write of the frame, plus a rotation (two syncs and a directory sync) once per
//! segment; `sync` is one file sync, or nothing when the log is already durable.
//! Directory durability (ADR-0003 section 2 and open question 4): after every `Segment.create`
//! the directory is synced through `platform.sync_dir`, a free function in `file/` rather than
//! a `File` method, so a durable segment is also durable by name. Under `SyncPolicy.none`
//! nothing is synced, the directory included. Reclaim: the writer never deletes a segment;
//! `checkpoint.zig` does, and tells the writer through `segments_reclaimed` so `live_count`
//! (and so `segments_max`) counts only live ones. The live segments are the contiguous indices
//! `oldest_index() .. current.index`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const file = @import("../file/file.zig");
const platform = @import("../file/platform.zig");
const frame = @import("frame.zig");
const group_commit = @import("group_commit.zig");
const reader = @import("reader.zig");
const segment = @import("segment.zig");

pub const Lsn = frame.Lsn;
/// Where the next frame goes: segment index, byte offset in it, and its LSN.
pub const Position = reader.Position;

pub const Options = struct {
    /// Most live segments a log may hold, at least 1 (ADR-0003 section 1).
    segments_max: u32,
    /// One `durable_lsn` must mean one thing, so it is chosen once per log (section 9).
    sync_policy: file.SyncPolicy,
    /// A segment that already holds a frame takes no frame that would end past this size.
    /// In `(segment_header_size, segment_bytes_limit - frame_bytes_max]`.
    segment_bytes_max: u64,
    /// How long the first committer of a batch waits for more committers before it syncs.
    /// Zero syncs at once.
    group_commit_window: Io.Duration = .zero,
    /// Pending bytes (`next_lsn - durable_lsn`) at which the leader skips the window. At least
    /// `frame_bytes_max`, so one full frame never waits.
    group_commit_bytes_max: u32 = frame.frame_bytes_max,
};

const LogError = file.OpenError || file.TryLockError || file.LengthError ||
    Io.File.ReadPositionalError || file.SyncError || file.WriteError || Io.Dir.DeleteFileError;
/// Everything `init` can return. Never `TornWrite` or `Unwritten`: those become
/// `RecoveryRequired` or a rewrite.
pub const InitError = LogError || reader.OpenError || error{RecoveryRequired};
pub const AppendError = error{ Failed, PayloadTooLarge, InvalidFrame, LsnExhausted } ||
    segment.LimitError || segment.CreateError || file.WriteError || file.SyncError;
pub const SyncError = error{Failed} || file.SyncError;
/// `commit`: `Failed` when the writer is latched, the leader's sync error for its batch,
/// `Canceled` (part of `file.SyncError`) when the wait or the window was canceled.
pub const CommitError = group_commit.Error;
pub const Stats = group_commit.Stats;

/// Frames are at least a header, so a log of `segments_max` full segments holds at most this
/// many: the bound of the tail scan in `init`.
const frames_per_segment_max: u64 = segment.segment_bytes_limit / frame.frame_header_size + 1;

const Tail = struct {
    position: Position,
    last_lsn: Lsn,
    file_count: u32,
    live_count: u32,
    newest_index: u32,
};

const Opened = struct { current: segment.Segment, offset: u64, live_count: u32 };

fn options_check(options: Options) void {
    assert(options.segments_max >= 1);
    assert(options.segment_bytes_max > segment.segment_header_size);
    assert(options.segment_bytes_max <= segment.segment_bytes_limit - frame.frame_bytes_max);
    assert(options.group_commit_bytes_max >= frame.frame_bytes_max);
    assert(options.group_commit_window.nanoseconds >= 0);
}

fn segment_options(options: Options) segment.Options {
    options_check(options);
    return .{ .segments_max = options.segments_max, .sync_policy = options.sync_policy };
}

/// Reads the log to its end: the cursor position, the last frame's LSN and the segment counts.
/// `RecoveryRequired` when the reader finds a torn tail. The reader is closed again before this
/// returns, so its locks are released.
fn find_tail(io: Io, gpa: Allocator, dir: Io.Dir, options: segment.Options) InitError!Tail {
    assert(options.segments_max >= 1);
    var rd: reader.Reader = undefined;
    try reader.Reader.open(&rd, io, gpa, dir, options);
    defer rd.deinit(io, gpa);

    const frames_max = @as(u64, options.segments_max) * frames_per_segment_max;
    var last_lsn: Lsn = 0;
    for (0..frames_max) |_| {
        const found = rd.next(io) catch |err| switch (err) {
            error.TornWrite => return error.RecoveryRequired,
            else => |other| return other,
        };
        const got = found orelse break;
        last_lsn = got.lsn;
    } else return error.Corrupted; // Unreachable for a sane log: the bound exceeds its frames.
    const newest = if (rd.file_count == 0) 0 else rd.entries[rd.file_count - 1].index;
    assert(rd.live_count <= rd.file_count);
    return .{
        .position = rd.position(),
        .last_lsn = last_lsn,
        .file_count = rd.file_count,
        .live_count = rd.live_count,
        .newest_index = newest,
    };
}

/// Creates a segment and makes its name durable (section 2: the directory sync comes before
/// the first frame). On error nothing stays open; the file may remain, whole or not.
fn create_segment(
    io: Io,
    dir: Io.Dir,
    index: u32,
    first_lsn: Lsn,
    options: Options,
) (segment.CreateError || file.SyncError)!segment.Segment {
    assert(index >= 1);
    assert(first_lsn >= frame.lsn_first);
    const seg = try segment.Segment.create(io, dir, index, first_lsn, segment_options(options));
    errdefer seg.close(io);

    if (options.sync_policy != .none) try platform.sync_dir(io, dir);
    return seg;
}

/// Deletes the newest segment `index`, which the reader found unreadable, if it is `Unwritten`
/// (no frame was ever written to it). A partial header is `RecoveryRequired`.
fn discard_unwritten(io: Io, dir: Io.Dir, index: u32, options: segment.Options) InitError!void {
    assert(index >= 1);
    assert(options.segments_max >= 1);
    if (segment.Segment.open(io, dir, index, options)) |seg| {
        seg.close(io);
        return error.Corrupted; // It was unreadable a moment ago: it changed under us.
    } else |err| switch (err) {
        error.Unwritten => {},
        error.TornWrite => return error.RecoveryRequired,
        else => |other| return other,
    }
    var name: [segment.name_size]u8 = @splat(0);
    segment.format_name(index, &name);
    try dir.deleteFile(io, &name);
}

/// The newest segment, ready to append to: opened where the reader stopped, or (re)created when
/// the log is empty or its newest segment was `Unwritten`.
fn open_tail(io: Io, dir: Io.Dir, tail: Tail, options: Options) InitError!Opened {
    assert(tail.live_count <= tail.file_count);
    const seg_options = segment_options(options);
    if (tail.file_count == 0) { // An empty directory: segment 1 at the first LSN.
        const created = try create_segment(io, dir, 1, frame.lsn_first, options);
        return .{ .current = created, .offset = segment.segment_header_size, .live_count = 1 };
    }
    if (tail.live_count < tail.file_count) { // The newest segment was being created.
        try discard_unwritten(io, dir, tail.newest_index, seg_options);
        const first_lsn = if (tail.live_count == 0) frame.lsn_first else tail.position.lsn;
        const created = try create_segment(io, dir, tail.newest_index, first_lsn, options);
        const offset = segment.segment_header_size;
        return .{ .current = created, .offset = offset, .live_count = tail.file_count };
    }
    const seg = segment.Segment.open(io, dir, tail.position.segment_index, seg_options) catch |err|
        switch (err) {
            // Its header was whole when the reader looked: a change since is damage.
            error.Unwritten, error.TornWrite => return error.Corrupted,
            else => |other| return other,
        };
    errdefer seg.close(io);

    const length = try seg.length(io);
    if (length < tail.position.offset) return error.Corrupted; // Shorter than the frames read.
    const frame_bytes = tail.position.offset - segment.segment_header_size;
    if (seg.first_lsn + frame_bytes != tail.position.lsn) return error.Corrupted;
    return .{ .current = seg, .offset = tail.position.offset, .live_count = tail.live_count };
}

/// Appender over one log directory; see the file header.
pub const Writer = struct {
    dir: Io.Dir,
    options: Options,
    /// One frame's image, `frame_bytes_max` bytes, allocated at `init`.
    buf: []u8,
    current: segment.Segment,
    /// Live segments, the current one included.
    live_count: u32,
    /// Where the next frame is written in `current`.
    offset: u64,
    /// LSN of the next frame.
    next_lsn: Lsn,
    /// LSN of the last frame appended, or 0.
    last_lsn: Lsn,
    /// LSN of the last frame known durable, or 0; never above `last_lsn`.
    durable_lsn: Lsn,
    failed: bool,
    /// Leader/follower state of `commit`.
    group: group_commit.Group,
    stats: Stats,

    /// Finds the end of the log in `dir` (opened with iteration) and takes its newest segment,
    /// creating segment 1 in an empty directory. `RecoveryRequired` for a torn tail;
    /// `WouldBlock` when another handle holds a segment; `SegmentLimit`, `Corrupted`,
    /// `ChecksumMismatch` and I/O errors from the reader, and the sync error when the tail of a
    /// non-empty log cannot be made durable (not retried, section 9). On error nothing stays
    /// open or allocated. Preconditions: `options` is coherent (`segments_max >= 1`,
    /// `segment_bytes_max` above the segment header and at most
    /// `segment_bytes_limit - frame_bytes_max`).
    pub fn init(
        target: *Writer,
        io: Io,
        gpa: Allocator,
        dir: Io.Dir,
        options: Options,
    ) InitError!void {
        options_check(options);
        assert(frame.frame_bytes_max >= frame.frame_header_size);
        const buf = try gpa.alloc(u8, frame.frame_bytes_max);
        errdefer gpa.free(buf);

        const tail = try find_tail(io, gpa, dir, segment_options(options));
        const opened = try open_tail(io, dir, tail, options);
        errdefer opened.current.close(io);

        // Frames read back may never have reached the disk (a crash after the write, before the
        // sync): durable means a sync returned after the write (section 9), so make it true.
        if (tail.last_lsn > 0 and options.sync_policy != .none) try opened.current.sync(io);
        const frame_bytes = opened.offset - segment.segment_header_size;
        target.* = .{
            .dir = dir,
            .options = options,
            .buf = buf,
            .current = opened.current,
            .live_count = opened.live_count,
            .offset = opened.offset,
            .next_lsn = opened.current.first_lsn + frame_bytes,
            .last_lsn = tail.last_lsn,
            .durable_lsn = tail.last_lsn,
            .failed = false,
            .group = .{},
            .stats = .{},
        };
        target.check_invariants();
    }

    /// Closes the current segment (without a sync) and frees the buffer; `gpa` must be the
    /// allocator given to `init`. The writer is invalid afterwards.
    pub fn deinit(self: *Writer, io: Io, gpa: Allocator) void {
        assert(self.buf.len == frame.frame_bytes_max);
        assert(self.live_count >= 1);
        self.current.close(io);
        gpa.free(self.buf);
        self.* = undefined;
    }

    /// Index of the oldest live segment: the live ones are contiguous up to the current one.
    pub fn oldest_index(self: *const Writer) u32 {
        assert(self.live_count >= 1);
        // Contiguous: rotation adds `index + 1` and reclaim removes a prefix, never a middle one.
        assert(self.current.index >= self.live_count); // Indices start at 1.
        return self.current.index - (self.live_count - 1);
    }

    /// Records that the checkpoint deleted the `count` oldest live segments, so a later rotation
    /// may reuse their slots under `segments_max`. The current segment is never reclaimed:
    /// `count < live_count`, a caller contract (asserted).
    pub fn segments_reclaimed(self: *Writer, count: u32) void {
        assert(count >= 1);
        assert(count < self.live_count);
        self.live_count -= count;
        self.check_invariants();
    }

    /// Where the next frame goes; see `Position`.
    pub fn position(self: *const Writer) Position {
        assert(self.offset >= segment.segment_header_size);
        assert(self.next_lsn >= frame.lsn_first);
        return .{
            .segment_index = self.current.index,
            .offset = self.offset,
            .lsn = self.next_lsn,
        };
    }

    /// Writes one frame at the end of the log and returns its LSN. The frame is written, not
    /// durable: `sync` makes it so. `PayloadTooLarge` (over `payload_bytes_max`), `InvalidFrame`
    /// (a payload or type ADR-0003 section 6 forbids), `LsnExhausted` (the frame would end at
    /// `2^63`), `SegmentLimit` and `SegmentIndexExhausted` leave the writer unchanged. `Failed`
    /// means an earlier I/O error latched it. Any I/O error here latches it.
    pub fn append(
        self: *Writer,
        io: Io,
        frame_type: frame.Type,
        payload: []const u8,
    ) AppendError!Lsn {
        assert(self.buf.len == frame.frame_bytes_max);
        assert(self.next_lsn < frame.lsn_limit);
        if (self.failed) return error.Failed;
        if (payload.len > frame.payload_bytes_max) return error.PayloadTooLarge;
        const total = frame.frame_header_size + @as(u32, @intCast(payload.len));
        if (!frame.payload_valid(@intFromEnum(frame_type), self.next_lsn, payload)) {
            return error.InvalidFrame;
        }
        if (self.next_lsn + total >= frame.lsn_limit) return error.LsnExhausted;
        const full = self.offset + total > self.options.segment_bytes_max;
        if (full and self.offset > segment.segment_header_size) try self.rotate(io);

        const lsn = self.next_lsn;
        const used = frame.encode(self.buf, lsn, frame_type, payload);
        assert(used == total);
        self.failed = true; // Cleared below; a failed write may leave a partial frame behind.
        try self.current.append(io, self.buf[0..used], self.offset);
        self.failed = false;
        self.offset += used;
        self.next_lsn += used;
        self.last_lsn = lsn;
        return lsn;
    }

    /// Makes every appended frame durable per the `SyncPolicy` and moves `durable_lsn` to the
    /// last one, only after the file sync returned. A no-op when nothing is pending. A failure
    /// leaves `durable_lsn` as it was, latches the writer and is not retried (section 9).
    pub fn sync(self: *Writer, io: Io) SyncError!void {
        assert(self.durable_lsn <= self.last_lsn);
        assert(self.last_lsn < self.next_lsn);
        if (self.failed) return error.Failed;
        if (self.durable_lsn == self.last_lsn) return;
        self.failed = true;
        try self.current.sync(io);
        self.failed = false;
        self.group.batch_error = null;
        self.durable_lsn = self.last_lsn;
        self.stats.syncs += 1;
    }

    /// Returns when `durable_lsn >= upto` (group commit). The first committer whose LSN is not
    /// durable leads: it waits `group_commit_window` unless `group_commit_bytes_max` bytes are
    /// pending, syncs once and wakes the followers, who return when their LSN is durable. A
    /// failed leader sync returns its error to the leader and every follower waiting on it,
    /// latches the writer (later calls: `Failed`) and is not retried. `upto` must be an LSN
    /// returned by `append` (or 0), so a batch always ends at or past it. Commits may overlap
    /// each other; `append`, `sync` and `deinit` must not overlap a `commit`, the caller
    /// serializes them. No allocation, no `io.concurrent`.
    pub fn commit(self: *Writer, io: Io, upto: Lsn) CommitError!void {
        assert(upto <= self.last_lsn);
        assert(self.buf.len == frame.frame_bytes_max);
        const turn = try self.group.enter(io, &self.stats, upto, &self.durable_lsn, &self.failed);
        if (turn == .done) return;

        const pending = self.next_lsn - self.durable_lsn;
        const window = self.options.group_commit_window;
        if (pending < self.options.group_commit_bytes_max and window.nanoseconds > 0) {
            io.sleep(window, .awake) catch |err| {
                self.group.finish(io, &self.stats, &self.durable_lsn, &self.failed, .abandoned);
                return err;
            };
        }
        const target = self.last_lsn;
        assert(target >= upto);
        const outcome: group_commit.Outcome = if (self.current.sync(io)) |_|
            .{ .synced = target }
        else |err| switch (err) {
            // Canceled is not an I/O failure: nothing was learned about the disk, so the writer
            // stays usable and a waiting committer takes over as leader.
            error.Canceled => .abandoned,
            else => .{ .failed = err },
        };
        self.group.finish(io, &self.stats, &self.durable_lsn, &self.failed, outcome);
        switch (outcome) {
            .failed => |err| return err,
            .abandoned => return error.Canceled,
            .synced => {},
        }
        assert(self.durable_lsn >= upto);
    }

    /// Section 9 rotation: sync the full segment, create the next one, then hand the lock over.
    /// The limit errors come first, before any side effect.
    fn rotate(self: *Writer, io: Io) AppendError!void {
        assert(self.offset > segment.segment_header_size);
        assert(!self.failed);
        const seg_options = segment_options(self.options);
        const index = try segment.index_next(self.current.index, self.live_count, seg_options);
        self.failed = true; // Cleared on success; a half-made segment is recovery's to see.
        try self.current.sync(io);
        self.durable_lsn = self.last_lsn;
        const next = try create_segment(io, self.dir, index, self.next_lsn, self.options);
        const previous = self.current;
        self.current = next;
        self.offset = segment.segment_header_size;
        self.live_count += 1;
        self.failed = false;
        previous.close(io); // After the new segment is locked: no gap.
        assert(self.current.index == index);
    }

    /// Asserts internal consistency: counters, buffer and the LSN identity of section 5.
    pub fn check_invariants(self: *const Writer) void {
        assert(self.buf.len == frame.frame_bytes_max);
        assert(self.live_count >= 1);
        assert(self.live_count <= self.options.segments_max);
        assert(self.offset >= segment.segment_header_size);
        // No upper bound on `offset`: a log reopened with a smaller `segment_bytes_max` than its
        // newest segment is not an error, `append` rotates before the next frame.
        assert(self.offset <= segment.segment_bytes_limit);
        assert(self.next_lsn >= frame.lsn_first);
        assert(self.next_lsn < frame.lsn_limit);
        const frame_bytes = self.offset - segment.segment_header_size;
        assert(self.next_lsn == self.current.first_lsn + frame_bytes);
        assert(self.durable_lsn <= self.last_lsn);
        assert(self.last_lsn < self.next_lsn);
        if (self.last_lsn == 0) assert(self.durable_lsn == 0);
    }
};

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("writer_test.zig");
    _ = @import("writer_tail_test.zig");
    _ = @import("writer_fault_test.zig");
    _ = @import("writer_commit_test.zig");
    _ = @import("group_commit.zig");
}
