//! WAL recovery (ADR-0003 sections 8 and 10): reads the log from `from_lsn`, hands every intact
//! frame from there on to an `Apply` target in LSN order, and repairs the one damage a crash may
//! leave, a torn tail, by truncating it. Returns the LSN of the last intact frame (0 for a log
//! without frames), which is where a `Writer` continues.
//!
//! Start rule: `from_lsn == 0` replays from the first frame, which must be at `lsn_first` (a
//! log whose oldest segments were reclaimed needs a checkpoint LSN). Otherwise a frame must
//! start exactly at `from_lsn`: below the oldest frame, inside a frame or at or past the end of
//! the log it is `Corrupted`. The frames before `from_lsn` are read (their checksums are
//! checked) but not applied, so the cost of the seek is linear in the skipped bytes.
//!
//! Repair rule: only `TornWrite` from the reader is repaired, and only after `from_lsn` was
//! reached (a torn frame at the seek target is `Corrupted`: the checkpoint says it was whole):
//! a torn frame is cut off with `setLength(offset)` and a sync; a torn newest header (a partial
//! header) is deleted and the directory synced. An `Unwritten` newest segment is left alone: the
//! writer rewrites it. `ChecksumMismatch` and `Corrupted` are returned and nothing is changed,
//! so a bad frame followed by a valid one is never skipped. Repairs run after the whole log was
//! read, so an `Apply` error leaves the log untouched. A crash during a repair re-creates the
//! same torn state, so replaying twice applies the same frames and repairs once. Under
//! `SyncPolicy.none` no sync is issued, as in the writer.
//!
//! Single process: a repair checks that its segment still has the length the read saw (else
//! `Corrupted`), but recovery assumes it is the only process on the log; it runs before a
//! `Writer` opens it, and the segment lock is the backstop. Damage before `from_lsn` is found
//! too (those frames are read), so it blocks recovery. Not here: validating the checkpoint
//! frame at the page file's `wal_lsn` and deriving `redo_lsn` from it belong to the caller
//! (plan 004, item 10); `replay` takes the resulting `from_lsn`.
//!
//! Allocation: the reader's buffers, from `gpa`, freed before `replay` returns. No recursion;
//! the frame loop is bounded by `frames_max`. `io` is passed per call, and on to `Apply`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const file = @import("../file/file.zig");
const platform = @import("../file/platform.zig");
const frame = @import("frame.zig");
const reader = @import("reader.zig");
const segment = @import("segment.zig");

pub const Lsn = frame.Lsn;

/// What an `Apply` target may report; `replay` returns it unchanged and repairs nothing.
pub const ApplyError = error{ Failed, Corrupted };

/// The redo target: a type-erased pointer and one callback. `io` is passed to the callback so
/// that it need not keep one.
pub const Apply = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, io: Io, f: frame.Frame) ApplyError!void,
    };

    /// Calls the target. `f.payload` is valid only for the call.
    pub fn apply(self: Apply, io: Io, f: frame.Frame) ApplyError!void {
        assert(f.lsn >= frame.lsn_first);
        assert(f.payload.len <= frame.payload_bytes_max);
        try self.vtable.apply(self.ptr, io, f);
    }
};

pub const ReplayOptions = struct {
    /// First LSN to apply: 0 for the start of the log, else the LSN of an intact frame.
    from_lsn: Lsn,
    segment_options: segment.Options,
};

pub const Result = struct {
    /// LSN of the last intact frame of the log (not only of the applied ones), or 0.
    last_lsn: Lsn,
};

pub const ReplayError = ApplyError || reader.OpenError || reader.FormatError ||
    file.SetLengthError || file.SyncError || Io.Dir.DeleteFileError;

/// Frames are at least a header, so a segment holds at most this many.
const frames_per_segment_max: u64 =
    @divFloor(segment.segment_bytes_limit, frame.frame_header_size) + 1;

const Torn = struct { segment_index: u32, offset: u64, length: u64 };
/// How the scan ended: `torn` is the frame to cut, `header_index` the newest segment file whose
/// header the reader could not read (0 when there is none).
const Outcome = struct { last_lsn: Lsn, torn: ?Torn, header_index: u32 };

pub const Recovery = struct {
    /// Replays the log in `dir` (opened with iteration) into `target` and repairs a torn tail;
    /// see the file header. Errors: `Corrupted`, `ChecksumMismatch` (also for a bad start),
    /// `SegmentLimit`, `WouldBlock`, I/O errors, and whatever `target` returns.
    /// Precondition: `options.segment_options.segments_max >= 1`. A `from_lsn` that is no LSN is
    /// `Corrupted`.
    pub fn replay(
        io: Io,
        gpa: Allocator,
        dir: Io.Dir,
        target: Apply,
        options: ReplayOptions,
    ) ReplayError!Result {
        assert(options.segment_options.segments_max >= 1);
        if (options.from_lsn >= frame.lsn_limit) return error.Corrupted; // Not an LSN at all.
        const outcome = try scan(io, gpa, dir, target, options);
        if (outcome.torn) |torn| try cut_frame(io, dir, torn, options.segment_options);
        if (outcome.header_index != 0) {
            try discard_header(io, dir, outcome.header_index, options.segment_options);
        }
        if (outcome.torn != null) assert(outcome.header_index == 0); // Torn frame: newest is live.
        assert(outcome.last_lsn < frame.lsn_limit);
        return .{ .last_lsn = outcome.last_lsn };
    }
};

/// Reads the whole log, applying from `from_lsn`; changes nothing on disk.
fn scan(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    target: Apply,
    options: ReplayOptions,
) ReplayError!Outcome {
    assert(options.segment_options.segments_max >= 1);
    var rd: reader.Reader = undefined;
    try reader.Reader.open(&rd, io, gpa, dir, options.segment_options);
    defer rd.deinit(io, gpa);

    const from = if (options.from_lsn == 0) frame.lsn_first else options.from_lsn;
    if (options.from_lsn == 0 and rd.live_count > 0) {
        if (rd.entries[0].first_lsn != frame.lsn_first) return error.Corrupted;
    }
    var reached = options.from_lsn == 0;
    var last_lsn: Lsn = 0;
    const segments_max: u64 = options.segment_options.segments_max;
    const frames_max: u64 = segments_max * frames_per_segment_max;
    var frames_seen: u64 = 0;
    while (frames_seen < frames_max) : (frames_seen += 1) {
        const found = rd.next(io) catch |err| switch (err) {
            error.TornWrite => {
                if (!reached) return error.Corrupted; // Torn at or before the seek target.
                const at = rd.position();
                return .{
                    .last_lsn = last_lsn,
                    .torn = .{
                        .segment_index = at.segment_index,
                        .offset = at.offset,
                        .length = rd.length,
                    },
                    .header_index = 0,
                };
            },
            else => |other| return other, // Deliberate: every other error is the caller's.
        };
        const got = found orelse break;
        last_lsn = got.lsn;
        if (got.lsn < from) continue;
        if (!reached) {
            if (got.lsn != from) return error.Corrupted; // `from` is not a frame start.
            reached = true;
        }
        try target.apply(io, got);
    } else return error.Corrupted; // Unreachable for a sane log: the bound exceeds its frames.
    if (!reached) return error.Corrupted; // `from_lsn` at or past the end of the log.
    const header_index: u32 = if (rd.live_count < rd.file_count)
        rd.entries[rd.file_count - 1].index
    else
        0;
    return .{ .last_lsn = last_lsn, .torn = null, .header_index = header_index };
}

/// Cuts the torn frame at `torn` off its segment and syncs the file.
fn cut_frame(io: Io, dir: Io.Dir, torn: Torn, options: segment.Options) ReplayError!void {
    assert(torn.segment_index >= 1);
    assert(torn.offset >= segment.segment_header_size);
    const seg = segment.Segment.open(io, dir, torn.segment_index, options) catch |err|
        switch (err) {
            // Its header was whole a moment ago: a change since is damage.
            error.Unwritten, error.TornWrite => return error.Corrupted,
            else => |other| return other,
        };
    defer seg.close(io);

    const length = try seg.length(io);
    if (length != torn.length) return error.Corrupted; // The file changed since the read.
    if (length < torn.offset) return error.Corrupted;
    try seg.file.setLength(io, torn.offset);
    try seg.sync(io);
}

/// The newest segment `index` has no readable header: a partial header is deleted (and the
/// directory synced); an `Unwritten` one is left to the writer.
fn discard_header(io: Io, dir: Io.Dir, index: u32, options: segment.Options) ReplayError!void {
    assert(index >= 1);
    assert(options.segments_max >= 1);
    if (segment.Segment.open(io, dir, index, options)) |seg| {
        seg.close(io);
        return error.Corrupted; // It was unreadable a moment ago: it changed under us.
    } else |err| switch (err) {
        error.Unwritten => return,
        error.TornWrite => {},
        else => |other| return other, // Deliberate: I/O, lock and damage errors pass through.
    }
    var name: [segment.name_size]u8 = @splat(0);
    segment.format_name(index, &name);
    try dir.deleteFile(io, &name);
    if (options.sync_policy != .none) try platform.sync_dir(io, dir);
}

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("recovery_test.zig");
}
