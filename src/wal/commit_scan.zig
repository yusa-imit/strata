//! `CommitScan` (ADR-0005 section 8, "Validation"): an `Apply` target for pass 1 of `Db.open`'s
//! commit-bounded recovery. It finds the last commit point `K` (the LSN of the last `commit` or
//! `checkpoint` frame, or 0 for none) and checks that the log is made of whole groups.
//!
//! Rule: a commit point is a frame between groups. The next group starts at the frame after it,
//! so a `commit` frame's `first_lsn` must equal that start (the previous commit point's LSN plus
//! its frame size). The starting point is `from_lsn` (the checkpoint frame itself, whose frame
//! is the first one applied) or, when replay began at 0, `lsn_first`. A `commit` whose
//! `first_lsn` differs (a hole, a foreign or already closed group), a `commit` whose payload
//! breaks the frame rule, and a `checkpoint` that is not at a group boundary (a checkpoint runs
//! only between groups) are `Corrupted`: they are not crash artifacts. Every other frame after
//! `K` only counts in `frames_after`; if the log ends there, `truncate_after(K)` removes them.
//!
//! Allocation: none. Pure state over the frames it is handed; `io` is unused.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");

pub const Lsn = frame.Lsn;

pub const CommitScan = struct {
    /// LSN of the last `commit` or `checkpoint` frame seen, or 0.
    last_commit_lsn: Lsn,
    /// Where the next group must start: just past the last commit point.
    group_start: Lsn,
    /// `commit` frames accepted.
    commits: u64,
    /// Frames seen after the last commit point.
    frames_after: u64,

    const vtable: recovery.Apply.VTable = .{ .apply = apply_fn };

    /// `from_lsn` is the replay start given to `Recovery.replay`: 0, or an LSN that names a
    /// `checkpoint` frame (the first one applied).
    pub fn init(from_lsn: Lsn) CommitScan {
        assert(from_lsn < frame.lsn_limit);
        const group_start = if (from_lsn == 0) frame.lsn_first else from_lsn;
        assert(group_start >= frame.lsn_first);
        return .{
            .last_commit_lsn = 0,
            .group_start = group_start,
            .commits = 0,
            .frames_after = 0,
        };
    }

    /// The `Apply` target for `Recovery.replay`; valid while `self` stays at this address.
    pub fn target(self: *CommitScan) recovery.Apply {
        assert(self.group_start >= frame.lsn_first);
        assert(self.last_commit_lsn < self.group_start or self.last_commit_lsn == 0);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn apply_fn(ptr: *anyopaque, io: Io, f: frame.Frame) recovery.ApplyError!void {
        _ = io;
        const self: *CommitScan = @ptrCast(@alignCast(ptr));
        assert(f.lsn >= frame.lsn_first);
        assert(self.group_start >= frame.lsn_first);
        switch (f.frame_type) {
            .commit => try self.on_commit(f),
            .checkpoint => try self.on_checkpoint(f),
            .record, .page_image, .page_images, _ => self.frames_after += 1,
        }
    }

    fn on_commit(self: *CommitScan, f: frame.Frame) recovery.ApplyError!void {
        assert(f.frame_type == .commit);
        assert(self.group_start >= frame.lsn_first);
        if (!frame.payload_valid(@intFromEnum(f.frame_type), f.lsn, f.payload)) {
            return error.Corrupted;
        }
        if (frame.commit_first_lsn(f.payload) != self.group_start) return error.Corrupted;
        self.mark(f);
        self.commits += 1;
    }

    fn on_checkpoint(self: *CommitScan, f: frame.Frame) recovery.ApplyError!void {
        assert(f.frame_type == .checkpoint);
        assert(self.group_start >= frame.lsn_first);
        if (f.lsn != self.group_start) return error.Corrupted; // Inside an unfinished group.
        self.mark(f);
    }

    /// `f` is a commit point: the next group starts after it.
    fn mark(self: *CommitScan, f: frame.Frame) void {
        assert(f.lsn >= self.group_start);
        assert(f.frame_type == .commit or f.frame_type == .checkpoint);
        self.last_commit_lsn = f.lsn;
        self.group_start = f.lsn + frame.frame_header_size + @as(u32, @intCast(f.payload.len));
        self.frames_after = 0;
    }
};

test {
    _ = @import("commit_scan_test.zig"); // Contract tests live in their own file.
}
