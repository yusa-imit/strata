//! Group commit coordination for `Writer.commit` (ADR-0003 section 9, plan 004 item 6).
//!
//! Leader/follower, no background flusher: the first committer whose LSN is not durable becomes
//! the leader, waits for the batch to fill, syncs once and wakes everyone; the others are
//! followers and sleep on a condition until `durable_lsn` reaches their LSN or the leader's sync
//! failed. There is no `io.concurrent` and no `ConcurrencyUnavailable` path (ADR-0001): every
//! committer is a caller thread or task of its own.
//!
//! State (`Group`) is guarded by `mutex`. The writer's `durable_lsn` and `failed` are only
//! written while it is held, by the leader after its sync. The file sync itself runs outside the
//! mutex so followers can still enter and wait. Cancelation: a follower returns `Canceled` from
//! the wait without disturbing the batch; a leader canceled in its window hands leadership back
//! (`leader_active` cleared, followers woken, one of them leads) and syncs nothing. Cleanup after
//! the sync uses uncancelable locking: the batch must hear about the result.
//! Failure: a failed leader sync stores its error in `batch_error` and latches the writer;
//! followers that were waiting get that error, later committers get `error.Failed`.
//! Allocation: none; the struct is plain data built at `Writer.init`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const file = @import("../file/file.zig");
const frame = @import("frame.zig");

/// Counters, updated under the group mutex (or by the single caller of `Writer.sync`).
pub const Stats = struct {
    /// File syncs of the current segment issued by `commit` leaders and by `Writer.sync`.
    syncs: u64 = 0,
    /// `commit` calls that returned success.
    commits: u64 = 0,
};

pub const Error = error{Failed} || file.SyncError;

pub const Turn = enum { done, leader };

/// A waiter is woken once per finished leader pass; a pass either makes its LSN durable, fails
/// the writer or hands it leadership, so this many rounds is a bound that is never reached.
const rounds_max: u32 = 1 << 16;

pub const Group = struct {
    mutex: Io.Mutex = .init,
    cond: Io.Condition = .init,
    leader_active: bool = false,
    /// The error of the leader sync that latched the writer, for the followers of that batch.
    batch_error: ?file.SyncError = null,

    /// Decides what the caller does for `upto`: `done` (durable already, counted), `leader`
    /// (the caller must sync and then call `finish`), or an error: `Failed` when the writer is
    /// latched, the batch's own error for a follower whose leader failed, `Canceled`.
    pub fn enter(
        g: *Group,
        io: Io,
        stats: *Stats,
        upto: frame.Lsn,
        durable_lsn: *const frame.Lsn,
        failed: *const bool,
    ) Error!Turn {
        assert(upto < frame.lsn_limit);
        assert(rounds_max > 0);
        try g.mutex.lock(io);
        defer g.mutex.unlock(io);

        assert(!g.leader_active or g.batch_error == null);

        var waited = false;
        for (0..rounds_max) |_| {
            if (durable_lsn.* >= upto) {
                stats.commits += 1;
                return .done;
            }
            if (failed.*) {
                if (waited) return g.batch_error orelse error.Failed;
                return error.Failed;
            }
            if (!g.leader_active) {
                g.leader_active = true;
                return .leader;
            }
            waited = true;
            try g.cond.wait(io, &g.mutex);
        }
        // See `rounds_max`: a waiter is resolved long before the bound; if it is ever reached
        // the batch made no progress, which is a failure of this commit, not a hang.
        return error.Failed;
    }

    /// The leader's result: `target` is durable (`null`), or its sync failed with `err`, or it was
    /// canceled before syncing. Wakes every follower. Uncancelable by design.
    pub fn finish(
        g: *Group,
        io: Io,
        stats: *Stats,
        durable_lsn: *frame.Lsn,
        failed: *bool,
        outcome: Outcome,
    ) void {
        g.mutex.lockUncancelable(io);
        defer g.mutex.unlock(io);

        assert(g.leader_active);
        switch (outcome) {
            .synced => |target| {
                assert(target >= durable_lsn.*);
                stats.syncs += 1;
                stats.commits += 1;
                durable_lsn.* = target;
            },
            .failed => |err| {
                assert(!failed.*);
                stats.syncs += 1;
                g.batch_error = err;
                failed.* = true;
            },
            .abandoned => {},
        }
        g.leader_active = false;
        g.cond.broadcast(io);
    }
};

pub const Outcome = union(enum) {
    /// The sync returned: every frame up to this LSN is durable.
    synced: frame.Lsn,
    failed: file.SyncError,
    /// Canceled during the window: nothing synced, leadership returns to the waiters.
    abandoned,
};
