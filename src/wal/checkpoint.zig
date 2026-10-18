//! WAL checkpoint and segment reclaim (ADR-0003 section 10): makes every change logged so far
//! durable in the page file, records where recovery may start, and deletes the log segments
//! that start can no longer need. Also derives that start (`redo_start`) from the page file's
//! `wal_lsn`.
//!
//! Sharp checkpoint, `Checkpoint.run`, five steps with a sync between every pair that must not
//! be reordered by the OS (writes persist in order only across a sync):
//!   1. append a `checkpoint` frame at LSN `C` with `redo_lsn = C` and `Writer.commit` it;
//!   2. raise the pool's WAL bound to `C` (nothing logged is gated) and `flushAll`;
//!   3. `PageManager.sync`: every page written in step 2 is durable;
//!   4. `PageManager.set_wal_lsn(C)`: page 0 now names the checkpoint frame;
//!   5. `PageManager.sync`: the new `wal_lsn` is durable.
//! A crash or error anywhere recovers from the old or the new `wal_lsn`: before step 5 returns
//! the file header holds either, both name an intact `checkpoint` frame (or 0), and every page
//! the new start relies on was synced in step 3. Honest limit: step 4 rewrites page 0 in one
//! write, which is not atomic above 512 B (ADR-0002 section 6: only a sector write is). The old
//! and the new image differ only in `wal_lsn` (byte 40) and the checksum, both inside the first
//! 512 B, and are zero after byte 48, so if the device writes that first sector atomically a
//! torn write leaves exactly the old or the new page 0 at every page size. Without that
//! guarantee a torn page 0 is `ChecksumMismatch` on `PageManager.open`, a typed error and not a
//! silent wrong start, but the page file is then unopenable (ADR-0003 open question 6).
//! `Checkpoint.stage` is the last step that completed, for diagnostics and tests. Reclaim
//! follows (`reclaim`): segment `k` is deleted iff it is not the newest and
//! `(k+1).first_lsn <= C`, ascending, then one directory sync (skipped under
//! `SyncPolicy.none`). The active segment is never deleted. `Writer.live_count`
//! is lowered through `Writer.segments_reclaimed` after each delete, so a failure part-way keeps
//! it true; a failed reclaim leaves a complete checkpoint, and `reclaim` may be called again.
//! `reclaim` deletes only below `reclaim_lsn`, the checkpoint whose step 5 returned; after a
//! `run` that failed earlier it is `NotCheckpointed` (or the previous completed checkpoint), so
//! it can never delete what the durable `wal_lsn` still needs.
//!
//! Caller contract (asserted or typed): every frame appended before `run` has been applied to
//! the pool (or the page file) and no dirty page has an lsn above the log (`PagesAheadOfLog`,
//! checked before the checkpoint frame is appended), nothing edits pages during `run`, one
//! `Checkpoint` per log and page file, and no other handle holds an old segment (a held lock
//! is `WouldBlock`). A page file whose `wal_lsn` is at or past the log's next LSN belongs to
//! another log: `Corrupted` before any side effect. `run` must leave room: if the current
//! segment is full and the log holds `segments_max` segments, appending `C` is `SegmentLimit`
//! and only a checkpoint could have prevented it, so checkpoint before the limit.
//!
//! Recovery start, `redo_start`: `wal_lsn == 0` means "from the start of the log" and returns 0
//! (what `Recovery.replay` takes for that; it also accepts an empty log then). Otherwise the
//! frame that starts exactly at `wal_lsn` must be an intact `checkpoint` frame, else `Corrupted`
//! (a log that ends first, a frame boundary elsewhere, another frame type, a reclaimed start,
//! and so a page file paired with a foreign WAL, all land here); its `redo_lsn` is returned.
//! This is the caller's step before `Recovery.replay`, not part of it. Cost: one sequential
//! pass over the log up to `wal_lsn` (every frame's checksum is checked), like the replay seek.
//!
//! Allocation: `Checkpoint` allocates nothing and stores no allocator; `redo_start` has the
//! reader's `open` allocations, freed before it returns. The three collaborators are borrowed,
//! must outlive the `Checkpoint` and stay unmoved. `io` is per call (ADR-0001). Loops are bound
//! by `Writer.live_count` and, in `redo_start`, by the frames a log of `segments_max` can hold.
//! Single caller: not thread-safe, and it must not overlap `Writer.commit` of another thread.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const buffer_pool = @import("../cache/buffer_pool.zig");
const file = @import("../file/file.zig");
const platform = @import("../file/platform.zig");
const manager = @import("../page/manager.zig");
const frame = @import("frame.zig");
const reader = @import("reader.zig");
const segment = @import("segment.zig");
const writer = @import("writer.zig");

pub const Lsn = frame.Lsn;

const BufferPool = buffer_pool.BufferPool;
const PageManager = manager.PageManager;
const Writer = writer.Writer;

/// The last step of `run` that completed (`idle` before the first), in order.
pub const Stage = enum(u8) {
    idle,
    logged,
    flushed,
    pages_synced,
    header_set,
    header_synced,
    reclaimed,
};

/// `NotCheckpointed`: no checkpoint of this value has completed its fifth step, so no segment
/// may be deleted yet (the durable `wal_lsn` may still name an older start).
pub const ReclaimError = segment.OpenError || Io.Dir.DeleteFileError || file.SyncError ||
    error{NotCheckpointed};
/// `Corrupted`: the page file's `wal_lsn` is not below the log's next LSN. `PagesAheadOfLog`:
/// a dirty page has an lsn above the log's last frame; checked before anything is appended, and
/// again after `flushAll` (a dirty page left is one the gate held back).
pub const RunError = writer.AppendError || writer.CommitError || buffer_pool.FlushError ||
    manager.SyncError || manager.WriteError || ReclaimError ||
    error{ Corrupted, PagesAheadOfLog };
pub const StartError = reader.OpenError || reader.FormatError;

pub const Result = struct {
    /// LSN of the checkpoint frame, which is also where recovery starts replaying.
    redo_lsn: Lsn,
    /// Segments deleted by this call.
    segments_reclaimed: u32,
};

/// Frames are at least a header, so a log of `segments_max` full segments holds at most this
/// many: the bound of the seek in `redo_start`.
const frames_per_segment_max: u64 =
    @divFloor(segment.segment_bytes_limit, frame.frame_header_size) + 1;
const payload_size: u32 = 8;

pub const Checkpoint = struct {
    log: *Writer,
    pool: *BufferPool,
    pages: *PageManager,
    stage: Stage,
    /// LSN of the last checkpoint frame this value committed, or 0. Diagnostic: it may name a
    /// frame whose `wal_lsn` never became durable.
    redo_lsn: Lsn,
    /// `redo_lsn` of the last checkpoint whose step 5 returned, or 0: the only LSN `reclaim`
    /// may delete below. Set once the new `wal_lsn` is durable, never earlier.
    reclaim_lsn: Lsn,
    /// A segment was deleted and the directory not yet synced.
    dir_dirty: bool,

    /// Binds the three collaborators; no I/O, nothing allocated. The pool must be over `pages`.
    pub fn init(target: *Checkpoint, log: *Writer, pool: *BufferPool, pages: *PageManager) void {
        assert(pool.pages == pages);
        assert(log.live_count >= 1);
        target.* = .{
            .log = log,
            .pool = pool,
            .pages = pages,
            .stage = .idle,
            .redo_lsn = 0,
            .reclaim_lsn = 0,
            .dir_dirty = false,
        };
        target.check_invariants();
    }

    /// Runs the five steps, then `reclaim`; see the file header. Errors come from the step that
    /// failed (`stage` says which one completed last); the writer is latched by a failed step 1
    /// as usual, and a failure in steps 2 to 5 leaves a committed checkpoint frame that no
    /// `wal_lsn` names yet, which is harmless.
    pub fn run(self: *Checkpoint, io: Io) RunError!Result {
        self.check_invariants();
        self.stage = .idle;
        const lsn_c = self.log.next_lsn;
        if (self.pages.wal_lsn >= lsn_c) return error.Corrupted; // Foreign log: no side effect.
        if (self.pool.dirty_lsn_max() > self.log.last_lsn) return error.PagesAheadOfLog;

        var payload: [payload_size]u8 = undefined;
        std.mem.writeInt(u64, &payload, lsn_c, .little);
        const appended = try self.log.append(io, .checkpoint, &payload);
        assert(appended == lsn_c);
        try self.log.commit(io, lsn_c);
        assert(self.log.durable_lsn >= lsn_c);
        self.redo_lsn = lsn_c;
        self.stage = .logged;

        self.pool.set_durable_lsn(lsn_c);
        try self.pool.flushAll(io);
        if (self.pool.dirty_count != 0) return error.PagesAheadOfLog;
        self.stage = .flushed;

        try self.pages.sync(io);
        self.stage = .pages_synced;
        try self.pages.set_wal_lsn(io, lsn_c);
        self.stage = .header_set;
        try self.pages.sync(io);
        self.stage = .header_synced;
        self.reclaim_lsn = lsn_c; // Durable now: only from here may segments below it go.

        const reclaimed = try self.reclaim(io);
        assert(self.stage == .reclaimed);
        return .{ .redo_lsn = lsn_c, .segments_reclaimed = reclaimed };
    }

    /// Deletes the segments wholly below the last *completed* checkpoint (`reclaim_lsn`), oldest
    /// first, never the newest, and syncs the directory once. Returns how many were deleted.
    /// `NotCheckpointed` (nothing deleted) when no checkpoint of this value has finished its
    /// fifth step: a `run` that failed earlier leaves the durable `wal_lsn` at an older start,
    /// which still needs those segments. May be called again after an error (it continues where
    /// it stopped, and syncs a directory left unsynced).
    pub fn reclaim(self: *Checkpoint, io: Io) ReclaimError!u32 {
        self.check_invariants();
        if (self.reclaim_lsn == 0) return error.NotCheckpointed;
        assert(self.reclaim_lsn <= self.redo_lsn);
        const log = self.log;
        var deleted: u32 = 0;
        for (0..log.live_count) |_| { // Each pass deletes one of at most `live_count - 1`.
            if (log.live_count == 1) break; // Only the active segment is left.
            const index = log.oldest_index();
            if (try self.first_lsn_of(io, index + 1) > self.reclaim_lsn) break;
            try delete_segment(io, log.dir, index);
            log.segments_reclaimed(1);
            self.dir_dirty = true;
            deleted += 1;
        }
        if (self.dir_dirty and log.options.sync_policy != .none) {
            try platform.sync_dir(io, log.dir);
        }
        self.dir_dirty = false;
        self.stage = .reclaimed;
        assert(log.live_count >= 1);
        return deleted;
    }

    /// The first LSN of live segment `index`: from the writer for the current one (which it
    /// holds locked), from its header otherwise.
    fn first_lsn_of(self: *Checkpoint, io: Io, index: u32) ReclaimError!Lsn {
        assert(index >= 1);
        assert(index <= self.log.current.index);
        if (index == self.log.current.index) return self.log.current.first_lsn;
        const seg_options: segment.Options = .{
            .segments_max = self.log.options.segments_max,
            .sync_policy = self.log.options.sync_policy,
        };
        const seg = try segment.Segment.open(io, self.log.dir, index, seg_options);
        defer seg.close(io);

        assert(seg.index == index);
        return seg.first_lsn;
    }

    /// Asserts internal consistency: the stage, the checkpoint LSN and the writer agree.
    pub fn check_invariants(self: *const Checkpoint) void {
        assert(self.pool.pages == self.pages);
        assert(self.log.live_count >= 1);
        assert(self.redo_lsn <= self.log.last_lsn);
        assert(self.reclaim_lsn <= self.redo_lsn);
        if (self.stage != .idle) assert(self.redo_lsn >= frame.lsn_first);
        if (self.dir_dirty) assert(self.reclaim_lsn != 0);
    }
};

fn delete_segment(io: Io, dir: Io.Dir, index: u32) Io.Dir.DeleteFileError!void {
    assert(index >= 1);
    assert(index < segment.segment_index_max);
    var name: [segment.name_size]u8 = @splat(0);
    segment.format_name(index, &name);
    try dir.deleteFile(io, &name);
}

/// Where `Recovery.replay` should start, from the page file's `wal_lsn`; see the file header.
/// `dir` is opened with iteration; `options` are the log's segment options. Returns 0 for
/// `wal_lsn == 0`, else the `redo_lsn` of the checkpoint frame at `wal_lsn`. Errors: `Corrupted`
/// as above, plus the reader's (`ChecksumMismatch`, `SegmentLimit`, `WouldBlock`, I/O).
/// Changes nothing on disk. Precondition: `options.segments_max >= 1`.
pub fn redo_start(
    io: Io,
    gpa: Allocator,
    dir: Io.Dir,
    wal_lsn: Lsn,
    options: segment.Options,
) StartError!Lsn {
    assert(options.segments_max >= 1);
    if (wal_lsn == 0) return 0;
    if (wal_lsn >= frame.lsn_limit) return error.Corrupted; // Not an LSN at all.
    var rd: reader.Reader = undefined;
    try reader.Reader.open(&rd, io, gpa, dir, options);
    defer rd.deinit(io, gpa);

    // Frames before `wal_lsn` are read in order; the loop ends at the frame with `lsn >=
    // wal_lsn`, or when the log ends first (`null`), so it needs one pass per frame at most.
    const frames_max = @as(u64, options.segments_max) * frames_per_segment_max;
    for (0..frames_max) |_| {
        const found = rd.next(io) catch |err| switch (err) {
            error.TornWrite => return error.Corrupted, // The log ends inside the way there.
            error.ChecksumMismatch, error.Corrupted => |damage| return damage,
            // Deliberate: the I/O and lock errors (open, tryLock, length, read) are the
            // caller's; the set is large and owned by `file`, so it is not listed here.
            else => |other| return other,
        };
        const got = found orelse return error.Corrupted; // The log ends before `wal_lsn`.
        if (got.lsn < wal_lsn) continue;
        if (got.lsn != wal_lsn) return error.Corrupted; // Inside a frame, or reclaimed.
        if (got.frame_type != .checkpoint) return error.Corrupted;
        assert(got.payload.len == payload_size); // `frame.decode` checked the payload.
        const redo_lsn = std.mem.readInt(u64, got.payload[0..payload_size], .little);
        assert(redo_lsn >= frame.lsn_first);
        assert(redo_lsn <= got.lsn);
        return redo_lsn;
    } else return error.Corrupted; // Unreachable for a sane log: the bound exceeds its frames.
}

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("checkpoint_test.zig");
    _ = @import("checkpoint_fault_test.zig");
}
