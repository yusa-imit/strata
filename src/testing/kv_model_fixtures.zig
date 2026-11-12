//! Fixtures for the seeded crash model test of `kv.Db` (`kv_model_test.zig`, plan 006 item 10): a
//! `Model` (one generation per key, the in-memory reference), a `Pending` (the effect of the op
//! in flight when the crash hit), and a `Run` that drives random put, delete, `WriteBatch`
//! commit, scan, checkpoint and close-and-reopen ops against a `Db` opened with `.fsync` over a
//! durable `FaultIo`, then crashes it (`FaultIo.crash` reverts every write not yet synced) and
//! reopens. After each crash the recovered contents (every key by `get`, and a full scan) must
//! equal the model as of the last op that returned, or that model plus the whole op that was in
//! flight: never part of a batch. Everything is reproducible from `(page size, seed)`. Test-only;
//! I/O through `std.testing.io`, memory through `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const batch_mod = @import("../kv/batch.zig");
const db_mod = @import("../kv/db.zig");
const fx = @import("../kv/db_fixtures.zig");
const durable_mod = @import("durable.zig");
const fault_io = @import("fault_io.zig");

const Db = fx.Db;
const WriteBatch = batch_mod.WriteBatch;

pub const sizes = fx.sizes;
/// Keys are `fx.key_of(n)` for `n < keys_max`.
pub const keys_max: u32 = 24;
/// Ops one `WriteBatch` may hold.
pub const batch_ops: u32 = 4;
/// Undo-log entries and pre-image pages a run may record between two syncs of the same file.
const undo_entries_max: u32 = 8192;
const undo_pages_max: u32 = 512;

/// The reference: the generation each key was last written with; 0 is absent.
pub const Model = struct {
    gens: [keys_max]u32,

    pub const empty: Model = .{ .gens = @splat(0) };

    pub fn count(self: *const Model) u32 {
        assert(self.gens.len == keys_max);
        var total: u32 = 0;
        for (self.gens) |gen| total += @intFromBool(gen != 0);
        assert(total <= keys_max);
        return total;
    }

    pub fn apply(self: *Model, pending: *const Pending) void {
        assert(pending.len <= batch_ops);
        for (0..pending.len) |i| {
            assert(pending.keys[i] < keys_max);
            self.gens[pending.keys[i]] = pending.gens[i];
        }
        assert(self.count() <= keys_max);
    }
};

/// The ops of the write in flight, in order; generation 0 is a delete.
pub const Pending = struct {
    len: u32,
    keys: [batch_ops]u32,
    gens: [batch_ops]u32,

    pub const none: Pending = .{ .len = 0, .keys = @splat(0), .gens = @splat(0) };

    pub fn add(self: *Pending, key: u32, gen: u32) void {
        assert(self.len < batch_ops);
        assert(key < keys_max);
        self.keys[self.len] = key;
        self.gens[self.len] = gen;
        self.len += 1;
    }
};

/// Counters that show a run was not vacuous.
pub const Stats = struct {
    rounds: u32 = 0,
    committed: u32 = 0,
    batches: u32 = 0,
    scans: u32 = 0,
    checkpoints: u32 = 0,
    reopens: u32 = 0,
    /// Rounds that ended in an injected fault (the rest crashed between two ops).
    faulted: u32 = 0,
    /// Faulted ops found fully applied after recovery, and fully absent.
    applied: u32 = 0,
    absent: u32 = 0,

    pub fn add(self: *Stats, other: Stats) void {
        assert(self.rounds <= 1 << 20);
        assert(other.rounds <= 1 << 20);
        inline for (std.meta.fields(Stats)) |field| {
            @field(self, field.name) += @field(other, field.name);
        }
    }
};

/// Options for the model run: `.fsync`, room for a batch, small log segments so the log rolls.
pub fn options_of(page_size: u32) fx.Options {
    assert(page_size >= 512);
    var result = fx.options(page_size, .fsync);
    result.batch_ops_max = batch_ops;
    result.batch_bytes_max = batch_ops * (result.key_len_max + result.value_len_max);
    result.wal_segment_bytes_max = @max(64 * 1024, 24 * @as(u64, page_size));
    result.pool_frames_max = db_mod.pool_frames_min(result) + 32;
    assert(result.sync_policy == .fsync);
    return result;
}

/// A `Db` that may be closed already (a reopen that failed leaves none).
const Session = struct { db: Db, open: bool };

/// Initialised in place: the fault wrapper points at the undo log.
pub const Run = struct {
    page_size: u32,
    options: fx.Options,
    rng: std.Random.DefaultPrng,
    tmp: testing.TmpDir,
    model: Model,
    pending: Pending,
    gen_next: u32,
    undo_entries: []durable_mod.Entry,
    undo_bytes: []u8,
    durable: durable_mod.Durable,
    fio: fault_io.FaultIo,
    value_buf: []u8,
    stats: Stats,

    pub fn init(run: *Run, page_size: u32, seed: u64) !void {
        assert(seed != 0);
        assert(page_size >= 512);
        const gpa = testing.allocator;
        run.page_size = page_size;
        run.options = options_of(page_size);
        run.rng = .init(seed *% 0x9E37_79B9_7F4A_7C15 +% page_size);
        run.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer run.tmp.cleanup();

        run.undo_entries = try gpa.alloc(durable_mod.Entry, undo_entries_max);
        errdefer gpa.free(run.undo_entries);

        run.undo_bytes = try gpa.alloc(u8, @as(usize, undo_pages_max) * page_size);
        errdefer gpa.free(run.undo_bytes);

        run.value_buf = try gpa.alloc(u8, run.options.value_len_max);
        run.model = .empty;
        run.pending = .none;
        run.gen_next = 1;
        run.stats = .{};
        run.arm_io(); // So `deinit` and the checks always see an initialised wrapper.
        assert(run.model.count() == 0);
    }

    pub fn deinit(run: *Run) void {
        assert(run.pending.len <= batch_ops);
        assert(run.value_buf.len == run.options.value_len_max);
        testing.allocator.free(run.value_buf);
        testing.allocator.free(run.undo_bytes);
        testing.allocator.free(run.undo_entries);
        run.tmp.cleanup();
    }

    /// A fresh undo log and a fault-free wrapper over `std.testing.io`: no files are open.
    fn arm_io(run: *Run) void {
        durable_mod.Durable.init(&run.durable, run.undo_entries, run.undo_bytes);
        const plan: fault_io.Plan = .{
            .write = .none,
            .read = .none,
            .after_calls = 0,
            .durable = &run.durable,
        };
        fault_io.FaultIo.init(&run.fio, testing.io, plan);
        run.fio.check_invariants();
        assert(run.durable.entries_used == 0);
    }

    /// Picks where the next crash comes from, relative to the calls so far: a canceled write
    /// from some call on, a failing sync from some call on, or none (a crash between two ops).
    fn arm_fault(run: *Run, ops_n: u32) void {
        assert(ops_n >= 1);
        assert(run.fio.plan.write == .none);
        const r = run.rng.random();
        switch (r.uintLessThan(u32, 4)) {
            0 => {},
            1, 2 => {
                run.fio.plan.write = .canceled;
                run.fio.plan.after_calls = run.fio.write_calls + r.uintLessThan(u32, ops_n * 6);
            },
            else => {
                run.fio.plan.sync_fail_after = run.fio.sync_calls + r.uintLessThan(u32, ops_n * 2);
            },
        }
        run.fio.check_invariants();
    }

    /// True once the wrapper has failed a write or a sync of the plan.
    fn faulted(run: *const Run) bool {
        assert(run.fio.plan.durable == &run.durable);
        assert(run.durable.entries.len == undo_entries_max);
        const plan = run.fio.plan;
        const write_hit = plan.write == .canceled and run.fio.write_calls > plan.after_calls;
        const sync_hit = if (plan.sync_fail_after) |after| run.fio.sync_calls > after else false;
        assert(plan.write == .canceled or !write_hit);
        return write_hit or sync_hit;
    }

    pub fn open_db(run: *Run, io: std.Io) !Db {
        assert(run.options.sync_policy == .fsync);
        assert(run.page_size == run.options.page_size);
        return Db.open(io, testing.allocator, run.tmp.dir, fx.sub_path, run.options);
    }

    /// One crash round: opens (recovers) on the durable wrapper, checks the recovered state,
    /// runs up to `ops_n` ops, then crashes: reverts the unsynced writes, blocks every further
    /// write and drops the `Db` through `close`, which can then change nothing on disk.
    pub fn round(run: *Run, ops_n: u32) !void {
        assert(ops_n >= 1);
        assert(run.pending.len <= batch_ops);
        run.arm_io();
        var s: Session = .{ .db = try run.open_db(run.fio.io()), .open = true };
        errdefer if (s.open) s.db.close();

        try run.verify(&s.db);
        run.arm_fault(ops_n);
        try run.drive(&s, ops_n);
        try run.crash(&s);
        run.stats.rounds += 1;
        assert(!s.open);
    }

    fn crash(run: *Run, s: *Session) !void {
        assert(s.open or run.pending.len == 0 or run.faulted());
        run.fio.check_invariants();
        run.durable.check_invariants();
        try testing.expect(!run.durable.overflowed); // The undo log is sized for a run.
        try testing.expect(!run.durable.closed_dirty);
        run.stats.faulted += @intFromBool(run.faulted());
        try run.fio.crash();
        run.fio.plan.write = .canceled; // Nothing the `Db` does from here reaches the files.
        run.fio.plan.after_calls = 0;
        run.fio.plan.sync_fail_after = 0;
        if (s.open) s.db.close();
        s.open = false;
        try testing.expectEqual(@as(u32, 0), run.durable.entries_used);
    }

    /// Runs ops until `ops_n` are done or one fails; a failure must be the injected fault.
    fn drive(run: *Run, s: *Session, ops_n: u32) !void {
        assert(s.open);
        assert(ops_n >= 1);
        assert(run.pending.len == 0);
        for (0..ops_n) |_| {
            run.step(s) catch |err| {
                if (!run.faulted()) return err; // A failure nothing injected: a real bug.
                return;
            };
            run.fio.check_invariants();
        }
        assert(run.pending.len == 0);
    }

    fn step(run: *Run, s: *Session) !void {
        assert(s.open);
        assert(run.pending.len == 0);
        const roll = run.rng.random().uintLessThan(u32, 100);
        if (roll < 40) return run.op_put(&s.db);
        if (roll < 60) return run.op_delete(&s.db);
        if (roll < 80) return run.op_batch(&s.db);
        if (roll < 88) return run.op_scan(&s.db);
        if (roll < 94) return run.op_checkpoint(&s.db);
        return run.op_reopen(s);
    }

    fn next_gen(run: *Run) u32 {
        assert(run.gen_next >= 1);
        run.gen_next += 1;
        assert(run.gen_next > 1);
        return run.gen_next - 1;
    }

    /// The write returned: the pending op is part of the model now.
    fn committed(run: *Run) void {
        assert(run.pending.len >= 1);
        run.model.apply(&run.pending);
        run.pending = .none;
        run.stats.committed += 1;
        assert(run.pending.len == 0);
        assert(run.model.count() <= keys_max);
    }

    fn op_put(run: *Run, db: *Db) !void {
        const n = run.rng.random().uintLessThan(u32, keys_max);
        const gen = run.next_gen();
        var key_buf: [8]u8 = undefined;
        run.pending.add(n, gen);
        const value = fx.value_of(run.value_buf, run.options.value_len_max, n, gen);
        try db.put(fx.key_of(&key_buf, n), value);
        run.committed();
    }

    fn op_delete(run: *Run, db: *Db) !void {
        const n = run.rng.random().uintLessThan(u32, keys_max);
        var key_buf: [8]u8 = undefined;
        run.pending.add(n, 0);
        const found = try db.delete(fx.key_of(&key_buf, n));
        assert(found == (run.model.gens[n] != 0)); // The model agrees on presence.
        run.committed();
    }

    fn op_batch(run: *Run, db: *Db) !void {
        const r = run.rng.random();
        var wb: WriteBatch = undefined;
        try WriteBatch.init(&wb, testing.allocator, db);
        defer wb.deinit(testing.allocator);

        const ops_n = r.intRangeAtMost(u32, 2, batch_ops);
        assert(ops_n <= batch_ops);
        var key_buf: [8]u8 = undefined;
        for (0..ops_n) |_| {
            const n = r.uintLessThan(u32, keys_max);
            const key = fx.key_of(&key_buf, n);
            if (r.uintLessThan(u32, 10) < 7) {
                const gen = run.next_gen();
                run.pending.add(n, gen);
                try wb.put(key, fx.value_of(run.value_buf, run.options.value_len_max, n, gen));
            } else {
                run.pending.add(n, 0);
                try wb.delete(key);
            }
        }
        try wb.commit();
        run.committed();
        run.stats.batches += 1;
    }

    fn op_checkpoint(run: *Run, db: *Db) !void {
        assert(run.pending.len == 0);
        assert(run.model.count() <= keys_max);
        try db.checkpoint();
        run.stats.checkpoints += 1;
        assert(run.pending.len == 0);
    }

    /// `Db.close` with the fault plan suspended: a close that fails halfway leaves page writes
    /// unsynced in a file it then closes, which the undo log cannot revert (`closed_dirty`). The
    /// plan resumes after, as many calls later as the close made.
    fn close_clean(run: *Run, db: *Db) void {
        const plan = run.fio.plan;
        const writes_before = run.fio.write_calls;
        const syncs_before = run.fio.sync_calls;
        run.fio.plan.write = .none;
        run.fio.plan.sync_fail_after = null;
        db.close();
        run.fio.plan = plan;
        run.fio.plan.after_calls +|= run.fio.write_calls - writes_before;
        if (plan.sync_fail_after) |after| {
            run.fio.plan.sync_fail_after = after +| (run.fio.sync_calls - syncs_before);
        }
        assert(run.fio.write_calls >= writes_before);
        assert(run.fio.sync_calls >= syncs_before);
    }

    /// A clean close (checkpoint) and open: no crash, so the model must hold exactly.
    fn op_reopen(run: *Run, s: *Session) !void {
        assert(s.open);
        assert(run.pending.len == 0);
        run.close_clean(&s.db);
        s.open = false;
        s.db = try run.open_db(run.fio.io());
        s.open = true;
        try run.verify(&s.db);
        run.stats.reopens += 1;
    }

    /// A scan of a random half-open range against the model.
    fn op_scan(run: *Run, db: *Db) !void {
        const r = run.rng.random();
        const from = r.uintLessThan(u32, keys_max);
        const to = r.intRangeAtMost(u32, from, keys_max); // `keys_max` is +infinity.
        var from_buf: [8]u8 = undefined;
        var to_buf: [8]u8 = undefined;
        const end: ?[]const u8 = if (to == keys_max) null else fx.key_of(&to_buf, to);
        var it = try db.scan(.{ .start = fx.key_of(&from_buf, from), .end = end });
        defer it.deinit();

        const ok = try run.scan_matches(&it, &run.model, from, to);
        try testing.expect(ok);
        run.stats.scans += 1;
    }

    /// The entries `it` yields are the keys of `model` in `[from, to)`, in order, with values.
    fn scan_matches(
        run: *Run,
        it: *db_mod.Iterator,
        model: *const Model,
        from: u32,
        to: u32,
    ) !bool {
        assert(from <= to);
        assert(to <= keys_max);
        var want_buf: [8]u8 = undefined;
        for (from..to) |n| {
            if (model.gens[n] == 0) continue;
            const entry = (try it.next()) orelse return false; // A key is missing.
            const want_key = fx.key_of(&want_buf, @intCast(n));
            if (!std.mem.eql(u8, entry.key, want_key)) return false;
            const want = fx.value_of(
                run.value_buf,
                run.options.value_len_max,
                @intCast(n),
                model.gens[n],
            );
            if (!std.mem.eql(u8, entry.value, want)) return false;
        }
        return (try it.next()) == null; // Nothing extra.
    }

    /// Every key by `get` and the whole key space by scan equal `model`.
    fn matches(run: *Run, db: *Db, model: *const Model) !bool {
        assert(run.value_buf.len >= run.options.value_len_max);
        var key_buf: [8]u8 = undefined;
        for (0..keys_max) |n| {
            const got = try db.get(fx.key_of(&key_buf, @intCast(n)));
            if (model.gens[n] == 0) {
                if (got != null) return false;
                continue;
            }
            const gen = model.gens[n];
            const want = fx.value_of(run.value_buf, run.options.value_len_max, @intCast(n), gen);
            if (got == null or !std.mem.eql(u8, got.?, want)) return false;
        }
        var it = try db.scan(.{ .start = "", .end = null });
        defer it.deinit();

        return run.scan_matches(&it, model, 0, keys_max);
    }

    /// The recovered `db` equals the model, or the model plus the whole pending op; the
    /// pending op is settled either way. `error.ModelMismatch` for anything else (a partial
    /// batch, a lost commit, an invented key).
    pub fn verify(run: *Run, db: *Db) !void {
        assert(run.pending.len <= batch_ops);
        assert(run.model.count() <= keys_max);
        if (try run.matches(db, &run.model)) {
            run.stats.absent += @intFromBool(run.pending.len > 0);
            run.pending = .none;
            return;
        }
        if (run.pending.len == 0) return error.ModelMismatch;
        var after = run.model;
        after.apply(&run.pending);
        if (!try run.matches(db, &after)) return error.ModelMismatch;
        run.model = after;
        run.pending = .none;
        run.stats.applied += 1;
    }

    /// The last check: opens on the plain `Io` after the final crash and compares.
    pub fn finish(run: *Run) !void {
        assert(run.durable.entries_used == 0);
        assert(run.pending.len <= batch_ops);
        assert(run.stats.rounds >= 1);
        var db = try run.open_db(testing.io);
        defer db.close();

        try run.verify(&db);
        assert(run.pending.len == 0);
    }
};
