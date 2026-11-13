//! Seeded crash model test for `kv.Db` (plan 006 item 10): at three page sizes and three fixed
//! seeds each, random put, delete, `WriteBatch` commit, scan, checkpoint and close-and-reopen
//! ops run over a durable `FaultIo` under `.fsync`, with a canceled write, a failing sync or a
//! plain stop ending each round in a crash that reverts every unsynced write. Four crash and
//! recovery rounds per run, ops continuing after each recovery. After every recovery the
//! contents equal the model of the ops that returned, or that plus the one op in flight, whole.
//! The harness is checked against a deliberately wrong model, so a vacuous check cannot pass.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fx = @import("kv_model_fixtures.zig");
const kv_fx = @import("../kv/db_fixtures.zig");

const Run = fx.Run;
const seeds = [_]u64{ 0x5eed_0001, 0x5eed_0002, 0x5eed_0003 };
const rounds: u32 = 4;

/// Every seed at one page size; returns the summed counters.
fn run_size(page_size: u32, ops_n: u32) !fx.Stats {
    assert(page_size >= 512);
    assert(ops_n >= 1);
    var total: fx.Stats = .{};
    for (seeds) |seed| {
        var run: Run = undefined;
        try Run.init(&run, page_size, seed);
        defer run.deinit();

        for (0..rounds) |_| try run.round(ops_n);
        try run.finish();
        try testing.expect(run.stats.rounds == rounds);
        total.add(run.stats);
    }
    return total;
}

/// The runs did real work: ops committed, scans, checkpoints and reopens ran, an op in flight was
/// found absent after recovery, and at least one crash came from an injected fault and one from a
/// stop between ops. `applied` (an op in flight found whole on disk) is not asserted: no random
/// seed reaches it, the synthetic test below covers that path.
fn expect_not_vacuous(total: fx.Stats) !void {
    assert(total.applied + total.absent <= total.rounds + total.reopens);
    assert(total.faulted <= total.rounds);
    try testing.expect(total.committed >= 10);
    try testing.expect(total.scans >= 1);
    try testing.expect(total.reopens >= 1);
    try testing.expect(total.checkpoints >= 1);
    try testing.expect(total.absent >= 1);
    try testing.expect(total.faulted >= 1);
    try testing.expect(total.faulted < total.rounds);
    try testing.expectEqual(@as(u32, rounds * seeds.len), total.rounds);
}

test "kv model: seeded crash rounds recover the model at 512 B" {
    const total = try run_size(512, 150);
    try expect_not_vacuous(total);
    try testing.expect(total.batches >= 1);
}

test "kv model: seeded crash rounds recover the model at 4 KiB" {
    const total = try run_size(4096, 100);
    try expect_not_vacuous(total);
    try testing.expect(total.batches >= 1);
}

test "kv model: seeded crash rounds recover the model at 64 KiB" {
    const total = try run_size(65536, 30);
    try expect_not_vacuous(total);
}

test "kv model: a model that disagrees with the disk is reported" {
    var run: Run = undefined;
    try Run.init(&run, 512, seeds[0]);
    defer run.deinit();

    try run.round(24);
    try run.finish(); // Settles the op in flight, if any.
    const saved = run.model.gens[0];
    run.model.gens[0] = saved + 1000; // A generation nobody wrote (or a key nobody put).
    try testing.expectError(error.ModelMismatch, run.finish());
    run.model.gens[0] = saved;
    try run.finish(); // Restored: the disk matches again.
}

/// Writes `gen` of key `n` straight to `db`, as an op that got through before the crash would.
fn put_gen(run: *Run, db: *kv_fx.Db, n: u32, gen: u32) !void {
    assert(n < fx.keys_max);
    assert(gen >= 1);
    var key_buf: [8]u8 = undefined;
    const value = kv_fx.value_of(run.value_buf, run.options.value_len_max, n, gen);
    try db.put(kv_fx.key_of(&key_buf, n), value);
}

test "kv model: an op in flight is adopted whole when on disk, a part of it is a mismatch" {
    var run: Run = undefined;
    try Run.init(&run, 512, seeds[1]);
    defer run.deinit();

    try run.round(24);
    try run.finish(); // Settled: the disk is the model.
    assert(run.pending.len == 0);
    assert(run.stats.rounds == 1);
    var db = try run.open_db(testing.io);
    defer db.close();

    try put_gen(&run, &db, 0, 5000);
    try put_gen(&run, &db, 1, 5001);
    run.pending.add(0, 5000);
    run.pending.add(1, 5001);
    const applied_before = run.stats.applied;
    try run.verify(&db); // Both puts are on disk: the whole op, adopted.
    try testing.expectEqual(applied_before + 1, run.stats.applied);
    try testing.expectEqual(@as(u32, 5001), run.model.gens[1]);

    try put_gen(&run, &db, 0, 6000); // Only the first of two puts reached the disk.
    run.pending.add(0, 6000);
    run.pending.add(1, 6001);
    try testing.expectError(error.ModelMismatch, run.verify(&db));
    try testing.expectEqual(@as(u32, 5000), run.model.gens[0]); // The model did not move.
}
