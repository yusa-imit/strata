//! Seeded crash-recovery property test of the WAL stack (plan 004 item 11, PRD section 6
//! phase 3E). For each fixed seed and each of three page sizes, a random op stream (appends,
//! commits, syncs, page edits through the pool's WAL-before-data gate, pool flushes,
//! checkpoints with segment reclaim) runs against the real `Writer`, `BufferPool`,
//! `PageManager` and `Checkpoint` over a `FaultIo` that cancels every write from a random call
//! on. The crash then cuts the unsynced tail of the newest segment (truncate or torn, through
//! `CrashSink`), and recovery (`redo_start`, `Recovery.replay`, `PageRedo`) is compared with a
//! trivial in-memory model of every appended frame:
//!   1. every LSN a commit, sync or checkpoint returned for is replayed, in order;
//!   2. nothing is invented: the replayed frames are a prefix of the appended ones (unsynced
//!      but intact frames may survive, and are exactly the model's);
//!   3. every page equals the model at the last recovered LSN, so a page written back ahead of
//!      its log (gate off) or skipped by redo is caught;
//!   4. a second replay yields the same frames, applies nothing and leaves the same pages.
//! A failure reproduces from the printed page size and seed alone. The fixed seeds are a
//! floor, not a proof; the totals test guards against a vacuous sweep.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fx = @import("wal_recovery_fixtures.zig");

const seeds = [_]u64{ 1, 2, 3, 5, 8, 13, 21, 34, 55, 89, 144, 233 };
const ops_max: u32 = 80;

const Totals = struct {
    runs: u32 = 0,
    crashes: u32 = 0,
    checkpoints: u32 = 0,
    reclaimed: u32 = 0,
    cut_bytes: u64 = 0,
    replayed: u32 = 0,
    from_nonzero: u32 = 0,

    fn add(self: *Totals, stats: fx.Stats) void {
        assert(self.runs < 1 << 20);
        assert(stats.ops <= ops_max + 8);
        self.runs += 1;
        if (stats.crashed) self.crashes += 1;
        self.checkpoints += stats.checkpoints;
        self.reclaimed += stats.reclaimed;
        self.cut_bytes += stats.cut_bytes;
        self.replayed += stats.replayed;
        if (stats.from_lsn != 0) self.from_nonzero += 1;
    }
};

fn run_one(size: u32, seed: u64) !fx.Stats {
    assert(seed != 0);
    assert(size >= 512);
    var run: fx.Run = undefined;
    try fx.Run.init(&run, size, seed);
    defer run.deinit();

    run.drive(ops_max) catch |err| {
        std.log.err("wal recovery property: drive failed, size={d} seed={d}", .{ size, seed });
        return err;
    };
    run.crash_and_recover() catch |err| {
        std.log.err("wal recovery property: failed, size={d} seed={d}", .{ size, seed });
        return err;
    };
    return run.stats;
}

fn sweep(size: u32) !Totals {
    assert(seeds.len >= 8);
    assert(size >= 512);
    var totals: Totals = .{};
    for (seeds) |seed| totals.add(try run_one(size, seed));
    try testing.expectEqual(@as(u32, seeds.len), totals.runs);
    return totals;
}

/// The sweep exercised what the properties are about, so a green run is not a vacuous one.
fn expect_not_vacuous(totals: Totals) !void {
    assert(totals.runs == seeds.len);
    assert(totals.crashes <= totals.runs);
    try testing.expect(totals.crashes > 0); // Some runs end at an injected fault.
    try testing.expect(totals.crashes < totals.runs); // And some at the end of the stream.
    try testing.expect(totals.cut_bytes > 0); // Some cuts drop or tear unsynced bytes.
    try testing.expect(totals.checkpoints > 0);
    try testing.expect(totals.reclaimed > 0); // Reclaim ran.
    try testing.expect(totals.from_nonzero > 0); // Recovery started from a checkpoint.
    try testing.expect(totals.replayed > 0);
}

test "wal recovery property: 512 B pages, every seed" {
    try expect_not_vacuous(try sweep(fx.sizes[0]));
}

test "wal recovery property: 4 KiB pages, every seed" {
    try expect_not_vacuous(try sweep(fx.sizes[1]));
}

test "wal recovery property: 64 KiB pages, every seed" {
    try expect_not_vacuous(try sweep(fx.sizes[2]));
}

test "wal recovery property: a run is reproducible from its seed" {
    const a = try run_one(fx.sizes[0], seeds[3]);
    const b = try run_one(fx.sizes[0], seeds[3]);
    try testing.expectEqual(a, b);
    try testing.expect(a.ops >= 1);
}
