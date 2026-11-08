//! `Recovery.truncate_after` (ADR-0005 section 4 step 5): cuts the log so that its last frame is
//! `last_lsn`, the last commit point. Frames after it belong to a group whose commit frame never
//! reached the log; they must go before a `Writer` appends past them, or the next commit frame
//! would adopt them.
//!
//! Rule: `last_lsn` names an intact frame of the log (else `Corrupted`, nothing changes), or is 0,
//! which keeps only the header of the oldest segment (and requires it to start at `lsn_first`).
//! The log is read first and closed, then changed in a crash-safe order: segments newer than the
//! one holding `last_lsn` are deleted newest first, each followed by a directory sync, and only
//! then is that segment cut with `setLength` and synced. Every crash point leaves a log that
//! this function cuts again to the same state, so running it twice, or after a crash midway,
//! gives one result. `SyncPolicy.none` issues no sync, as in the writer. An empty directory
//! with `last_lsn == 0` is a no-op.
//!
//! Single process, like `Recovery.replay`: it runs before a `Writer` opens the log.
//! Allocation: the reader's buffers from `gpa`, freed before any change. No recursion; both
//! loops are bounded (`frames_max`, `segments_max`).

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

pub const TruncateError = reader.OpenError || reader.FormatError || file.SetLengthError ||
    file.SyncError || Io.Dir.DeleteFileError || error{Corrupted};

/// Frames are at least a header, so a segment holds at most this many.
const frames_per_segment_max: u64 =
    @divFloor(segment.segment_bytes_limit, frame.frame_header_size) + 1;

/// Where the log must end: the segment holding the last frame, the byte offset after it, and the
/// indices of the segments to delete (`delete_count` of `deletes`, ascending).
const Plan = struct {
    segment_index: u32,
    end_offset: u64,
    delete_count: u32,
    deletes: []u32,
};

/// Cuts the log in `dir` (opened with iteration) so its last frame is `last_lsn`; see the file
/// header. Errors: `Corrupted` (no such frame), `ChecksumMismatch`, `SegmentLimit`,
/// `WouldBlock`, I/O errors. Precondition: `segment_options.segments_max >= 1`.
pub fn truncate_after(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    last_lsn: Lsn,
    segment_options: segment.Options,
) TruncateError!void {
    assert(segment_options.segments_max >= 1);
    if (last_lsn >= frame.lsn_limit) return error.Corrupted; // Not an LSN at all.
    const deletes = try gpa.alloc(u32, segment_options.segments_max);
    defer gpa.free(deletes);

    const plan = (try find_end(io, gpa, dir, last_lsn, segment_options, deletes)) orelse return;
    assert(plan.delete_count <= plan.deletes.len);
    assert(plan.deletes.len == segment_options.segments_max);
    var remaining: u32 = plan.delete_count;
    // The bound is the delete list's capacity (`delete_count <= deletes.len`, asserted above):
    // the loop runs exactly `delete_count` times, so no fallthrough branch exists.
    for (0..plan.delete_count) |_| { // Newest first: no hole at any crash point.
        remaining -= 1;
        var name: [segment.name_size]u8 = @splat(0);
        segment.format_name(plan.deletes[remaining], &name);
        try dir.deleteFile(io, &name);
        if (segment_options.sync_policy != .none) try platform.sync_dir(io, dir);
    }
    assert(remaining == 0);
    try cut_segment(io, dir, plan, segment_options);
}

/// Reads the log up to `last_lsn` and plans the cut; `null` for an empty log with `last_lsn` 0.
fn find_end(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    last_lsn: Lsn,
    segment_options: segment.Options,
    deletes: []u32,
) TruncateError!?Plan {
    assert(deletes.len == segment_options.segments_max);
    var rd: reader.Reader = undefined;
    try reader.Reader.open(&rd, io, gpa, dir, segment_options);
    defer rd.deinit(io, gpa);

    if (rd.live_count == 0 and last_lsn == 0) return null;
    if (rd.live_count == 0) return error.Corrupted;
    var index: u32 = rd.entries[0].index;
    var end_offset: u64 = segment.segment_header_size;
    if (last_lsn == 0) {
        if (rd.entries[0].first_lsn != frame.lsn_first) return error.Corrupted;
    } else {
        const at = try seek_end(io, &rd, last_lsn);
        index = at.segment_index;
        end_offset = at.offset;
    }
    var count: u32 = 0;
    for (rd.entries[0..rd.file_count]) |entry| {
        if (entry.index <= index) continue;
        deletes[count] = entry.index; // Sorted ascending by the reader.
        count += 1;
    }
    assert(count < rd.file_count);
    return .{
        .segment_index = index,
        .end_offset = end_offset,
        .delete_count = count,
        .deletes = deletes,
    };
}

/// Reads frames until the one at `last_lsn`; returns the position just after it.
fn seek_end(io: Io, rd: *reader.Reader, last_lsn: Lsn) TruncateError!reader.Position {
    assert(last_lsn >= frame.lsn_first);
    assert(rd.live_count >= 1);
    const frames_max: u64 = @as(u64, rd.entries.len) * frames_per_segment_max;
    for (0..frames_max) |_| {
        const got = rd.next(io) catch |err| switch (err) {
            error.TornWrite => return error.Corrupted, // The named frame lies past the tear.
            else => |other| return other,
        };
        const found = got orelse return error.Corrupted; // The log ends before `last_lsn`.
        if (found.lsn > last_lsn) return error.Corrupted; // `last_lsn` is not a frame start.
        if (found.lsn == last_lsn) return rd.position();
    }
    return error.Corrupted; // Unreachable for a sane log: the bound exceeds its frames.
}

/// Cuts the segment to `end_offset` and syncs it; a shorter file than that is damage.
fn cut_segment(io: Io, dir: Io.Dir, plan: Plan, options: segment.Options) TruncateError!void {
    assert(plan.segment_index >= 1);
    assert(plan.end_offset >= segment.segment_header_size);
    const seg = segment.Segment.open(io, dir, plan.segment_index, options) catch |err|
        switch (err) {
            // Its header was whole a moment ago: a change since is damage.
            error.Unwritten, error.TornWrite => return error.Corrupted,
            else => |other| return other,
        };
    defer seg.close(io);

    const length = try seg.length(io);
    if (length < plan.end_offset) return error.Corrupted;
    if (length == plan.end_offset) return;
    try seg.file.setLength(io, plan.end_offset);
    try seg.sync(io);
    assert(try seg.length(io) == plan.end_offset);
}

test {
    _ = @import("truncate_test.zig"); // Contract tests live in their own file.
}
