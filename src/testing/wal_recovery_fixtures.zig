//! Fixtures for the seeded crash-recovery property test (`wal_recovery_test.zig`, plan 004
//! item 11): a `Run` that drives a random op stream (records, commits, syncs, page edits, pool
//! flushes, checkpoints) through the real `Writer`, `BufferPool`, `PageManager` and `Checkpoint`
//! of `wal/checkpoint_fixtures.zig` over a `FaultIo` that cancels every write from a random call
//! on; a `Ref` that is the trivial in-memory reference model (every frame appended, in order);
//! `cut_tail`, which applies a `CrashSink` truncate or torn cut to the unsynced tail of the
//! newest segment; and `recover_check`, which recovers cold with `redo_start`, `Recovery.replay`
//! and `PageRedo` (twice) and compares the frames and the pages with the reference. Everything
//! is reproducible from `(page size, seed)`. Test-only; I/O through `std.testing.io`, memory
//! through `std.testing.allocator`, no allocation that outlives a call.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const cfx = @import("../wal/checkpoint_fixtures.zig");
const checkpoint = @import("../wal/checkpoint.zig");
const frame = @import("../wal/frame.zig");
const pfx = @import("../page/manager_fixtures.zig");
const PageManager = @import("../page/manager.zig").PageManager;
const recovery = @import("../wal/recovery.zig");
const redo = @import("../wal/redo.zig");
const rfx = @import("../wal/redo_fixtures.zig");
const segment = @import("../wal/segment.zig");
const sfx = @import("../wal/segment_fixtures.zig");
const crash = @import("crash.zig");
const fault_io = @import("fault_io.zig");
const FaultIo = fault_io.FaultIo;

pub const Lsn = frame.Lsn;
pub const sizes: [3]u32 = .{ 512, 4096, 65536 };

const segments_max: u32 = 12;
const segment_frames: u32 = 3;
const recs_max: u32 = 256;
const record_bytes_max: u32 = 48;
/// Writes that pass before the cancel starts: about the number a full op stream makes.
const crash_after_max: u32 = 300;
const sync_fail_after_max: u32 = 60;

/// One frame appended to the log: what a reference model of the log knows about it.
pub const Rec = struct {
    lsn: Lsn,
    frame_type: frame.Type,
    /// The page a `page_image` rewrote, else 0.
    page_id: u32,
    seed: u32,
    len: u32,
    hash: u64,

    fn of_payload(lsn: Lsn, frame_type: frame.Type, payload: []const u8) Rec {
        assert(lsn >= frame.lsn_first);
        assert(payload.len <= frame.payload_bytes_max);
        const hash = std.hash.Wyhash.hash(0, payload);
        const len: u32 = @intCast(payload.len);
        return .{
            .lsn = lsn,
            .frame_type = frame_type,
            .page_id = 0,
            .seed = 0,
            .len = len,
            .hash = hash,
        };
    }

    pub fn expect_same(got: Rec, want: Rec) !void {
        assert(got.lsn >= frame.lsn_first);
        assert(want.lsn >= frame.lsn_first);
        try testing.expectEqual(want.lsn, got.lsn);
        try testing.expectEqual(want.frame_type, got.frame_type);
        try testing.expectEqual(want.len, got.len);
        try testing.expectEqual(want.hash, got.hash);
    }
};

/// The reference model: every frame the harness saw the log accept, in LSN order.
pub const Ref = struct {
    recs: [recs_max]Rec,
    count: u32,

    pub fn init() Ref {
        comptime assert(recs_max >= 100);
        return .{ .recs = undefined, .count = 0 };
    }

    pub fn items(self: *const Ref) []const Rec {
        assert(self.count <= recs_max);
        assert(self.count == 0 or self.recs[0].lsn >= frame.lsn_first);
        return self.recs[0..self.count];
    }

    fn push(self: *Ref, rec: Rec) void {
        assert(self.count < recs_max);
        assert(self.count == 0 or self.recs[self.count - 1].lsn < rec.lsn);
        self.recs[self.count] = rec;
        self.count += 1;
    }

    fn add_record(self: *Ref, lsn: Lsn, payload: []const u8) void {
        assert(payload.len >= 1);
        assert(lsn >= frame.lsn_first);
        self.push(Rec.of_payload(lsn, .record, payload));
    }

    fn add_checkpoint(self: *Ref, lsn: Lsn) void {
        assert(lsn >= frame.lsn_first);
        assert(self.count < recs_max);
        var payload: [8]u8 = undefined;
        std.mem.writeInt(u64, &payload, lsn, .little);
        self.push(Rec.of_payload(lsn, .checkpoint, &payload));
    }

    fn add_edit(self: *Ref, size: u32, lsn: Lsn, id: u32, seed: u32) !void {
        assert(id >= 1 and id <= cfx.pages_used);
        assert(self.count < recs_max);
        const payload = try rfx.image_payload(size, id, seed, pfx.consumer_type, rfx.stale_lsn);
        defer testing.allocator.free(payload);

        var rec = Rec.of_payload(lsn, .page_image, payload);
        rec.page_id = id;
        rec.seed = seed;
        self.push(rec);
    }

    /// The frames at or after `from_lsn`.
    pub fn from_lsn(self: *const Ref, from: Lsn) []const Rec {
        assert(self.count <= recs_max);
        const all = self.items();
        for (all, 0..) |rec, i| {
            if (rec.lsn >= from) return all[i..];
        }
        assert(all.len == 0 or all[all.len - 1].lsn < from);
        return all[all.len..];
    }

    /// End of the frame at `lsn` (the next frame's LSN, else `next_lsn`); `lsn == 0` is the
    /// start of the log.
    pub fn end_of(self: *const Ref, lsn: Lsn, next_lsn: Lsn) Lsn {
        assert(self.count <= recs_max);
        assert(lsn < next_lsn);
        const all = self.items();
        if (lsn == 0) return if (all.len > 0) all[0].lsn else next_lsn;
        for (all, 0..) |rec, i| {
            if (rec.lsn != lsn) continue;
            return if (i + 1 < all.len) all[i + 1].lsn else next_lsn;
        }
        unreachable; // Every LSN the writer calls durable is a frame the harness recorded.
    }

    /// The pages every frame up to `upto` leaves, on top of the initial pages.
    pub fn model_at(self: *const Ref, upto: Lsn) cfx.Model {
        assert(self.count <= recs_max);
        var model = cfx.Model.init();
        for (self.items()) |rec| {
            if (rec.lsn > upto) break;
            if (rec.page_id != 0) model.set(rec.page_id, rec.seed, rec.lsn);
        }
        assert(model.seeds.len == cfx.pages_used + 1);
        return model;
    }
};

/// An `Apply` target that records every frame it forwards to `inner`.
const Tee = struct {
    inner: recovery.Apply,
    seen: [recs_max]Rec,
    count: u32,

    const vtable: recovery.Apply.VTable = .{ .apply = apply_fn };

    fn target(self: *Tee) recovery.Apply {
        assert(self.count <= recs_max);
        assert(self.inner.ptr != @as(*anyopaque, self));
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn apply_fn(ptr: *anyopaque, io: Io, f: frame.Frame) recovery.ApplyError!void {
        const self: *Tee = @ptrCast(@alignCast(ptr));
        assert(self.count <= recs_max);
        assert(f.lsn >= frame.lsn_first);
        if (self.count == recs_max) return error.Failed;
        try self.inner.apply(io, f);
        self.seen[self.count] = Rec.of_payload(f.lsn, f.frame_type, f.payload);
        self.count += 1;
    }

    fn items(self: *const Tee) []const Rec {
        assert(self.count <= recs_max);
        assert(self.count == 0 or self.seen[0].lsn >= frame.lsn_first);
        return self.seen[0..self.count];
    }
};

const Verdict = enum { crash, skip, fatal };

/// What an op's error means to the run: the injected faults are the crash, a full log is
/// relieved by a checkpoint, anything else is a real failure of the code under test.
fn classify(err: anyerror) Verdict {
    assert(err != error.OutOfMemory);
    return switch (err) {
        error.Canceled, error.InputOutput, error.Failed => .crash,
        error.SegmentLimit => .skip,
        else => .fatal,
    };
}

/// Counters that show a run was not vacuous.
pub const Stats = struct {
    ops: u32 = 0,
    crashed: bool = false,
    checkpoints: u32 = 0,
    reclaimed: u32 = 0,
    cut_bytes: u64 = 0,
    replayed: u32 = 0,
    from_lsn: Lsn = 0,
};

/// Initialised in place: the fault wrapper and the checkpoint env point into it.
pub const Run = struct {
    env: cfx.Env,
    fio: FaultIo,
    rng: std.Random.DefaultPrng,
    ref: Ref,
    /// Highest LSN a commit, sync or checkpoint returned for before the crash.
    acked_lsn: Lsn,
    /// The log's `durable_lsn` at the crash.
    durable_lsn: Lsn,
    finished: bool,
    stats: Stats,

    pub fn init(run: *Run, size: u32, seed: u64) !void {
        assert(seed != 0);
        try cfx.Env.init(&run.env, size, segments_max, segment_frames, .none);
        errdefer run.env.deinit();

        run.rng = .init(seed *% 0x9E37_79B9_7F4A_7C15 +% size);
        const r = run.rng.random();
        const sync_fail: ?u32 = if (r.uintLessThan(u32, 4) == 0)
            r.uintLessThan(u32, sync_fail_after_max)
        else
            null;
        const plan: fault_io.Plan = .{
            .write = .canceled,
            .read = .none,
            .after_calls = r.uintLessThan(u32, crash_after_max),
            .sync_fail_after = sync_fail,
        };
        FaultIo.init(&run.fio, testing.io, plan);
        run.ref = Ref.init();
        run.acked_lsn = 0;
        run.durable_lsn = 0;
        run.finished = false;
        run.stats = .{};
        run.env.pool.set_durable_lsn(run.env.log.durable_lsn); // Gate on from the first edit.
        run.fio.check_invariants();
        assert(run.ref.count == 0);
        assert(!run.finished);
    }

    pub fn deinit(run: *Run) void {
        assert(run.stats.ops <= 1000);
        assert(run.ref.count <= recs_max);
        run.env.deinit();
    }

    /// Runs up to `ops_max` random ops, stopping at the first injected fault (the crash).
    pub fn drive(run: *Run, ops_max: u32) !void {
        assert(ops_max >= 1);
        assert(ops_max + 8 < recs_max);
        for (0..ops_max) |_| {
            if (run.finished) break;
            run.stats.ops += 1;
            run.step() catch |err| switch (classify(err)) {
                .crash => run.finished = true,
                .skip => run.relieve(),
                .fatal => return err,
            };
            if (run.finished) break;
            run.env.pool.set_durable_lsn(run.env.log.durable_lsn);
            run.env.log.check_invariants();
            run.env.pool.check_invariants();
        }
        run.stats.crashed = run.fio.plan.after_calls < run.fio.write_calls;
        assert(run.stats.ops <= ops_max);
        assert(run.ref.count <= recs_max);
    }

    fn step(run: *Run) !void {
        assert(!run.finished);
        assert(run.ref.count + 8 < recs_max);
        const io = run.fio.io();
        const roll = run.rng.random().uintLessThan(u32, 100);
        if (roll < 15) return run.op_record(io);
        if (roll < 27) return run.op_commit(io);
        if (roll < 65) return run.op_edit(io);
        if (roll < 80) return run.env.pool.flushAll(io);
        if (roll < 86) return run.op_sync(io);
        return run.op_checkpoint(io);
    }

    /// The log is full: a checkpoint is the only way to make room; if that fails too, the
    /// stream ends (a full log, not a crash).
    fn relieve(run: *Run) void {
        assert(!run.finished);
        assert(run.ref.count + 8 < recs_max);
        run.op_checkpoint(run.fio.io()) catch {
            run.finished = true;
        };
        assert(run.ref.count < recs_max);
        assert(run.env.log.live_count <= segments_max);
    }

    fn op_record(run: *Run, io: Io) !void {
        var payload: [record_bytes_max]u8 = undefined;
        const r = run.rng.random();
        const len = r.intRangeAtMost(u32, 1, record_bytes_max);
        r.bytes(&payload);
        assert(len >= 1 and len <= record_bytes_max);
        const lsn = try run.env.log.append(io, .record, payload[0..len]);
        assert(lsn < run.env.log.next_lsn);
        run.ref.add_record(lsn, payload[0..len]);
    }

    fn op_commit(run: *Run, io: Io) !void {
        const upto = run.env.log.last_lsn;
        assert(upto >= run.env.log.durable_lsn);
        try run.env.log.commit(io, upto);
        run.acked_lsn = @max(run.acked_lsn, upto);
        assert(run.env.log.durable_lsn >= run.acked_lsn);
    }

    fn op_sync(run: *Run, io: Io) !void {
        const upto = run.env.log.last_lsn;
        assert(upto >= run.env.log.durable_lsn);
        try run.env.log.sync(io);
        run.acked_lsn = @max(run.acked_lsn, upto);
        assert(run.env.log.durable_lsn >= run.acked_lsn);
    }

    fn op_edit(run: *Run, io: Io) !void {
        const r = run.rng.random();
        const id = r.intRangeAtMost(u32, 1, cfx.pages_used);
        const seed = r.int(u32);
        const before = run.env.log.next_lsn;
        const result = run.env.edit_io(io, id, seed);
        // A frame is in the log even when the pool step failed after the append.
        if (run.env.log.next_lsn > before) try run.ref.add_edit(run.env.size, before, id, seed);
        _ = try result;
        assert(run.env.log.last_lsn == before);
        assert(run.ref.items()[run.ref.count - 1].page_id == id);
    }

    fn op_checkpoint(run: *Run, io: Io) !void {
        const before = run.env.log.next_lsn;
        const result = run.env.cp.run(io);
        if (run.env.log.next_lsn > before) run.ref.add_checkpoint(before);
        // Step 1 returned: the checkpoint frame is committed, so durable.
        if (run.env.cp.stage != .idle) run.acked_lsn = @max(run.acked_lsn, run.env.cp.redo_lsn);
        const done = try result;
        assert(run.env.cp.stage == .reclaimed);
        assert(done.redo_lsn == before);
        run.stats.checkpoints += 1;
        run.stats.reclaimed += done.segments_reclaimed;
        run.env.cp.check_invariants();
    }

    /// The crash: drops the pool and the handles, cuts the unsynced tail of the newest segment,
    /// recovers cold and compares with the reference model.
    pub fn crash_and_recover(run: *Run) !void {
        const log = &run.env.log;
        log.check_invariants();
        run.durable_lsn = log.durable_lsn;
        try testing.expect(run.acked_lsn <= run.durable_lsn);
        const durable_end = run.ref.end_of(run.durable_lsn, log.next_lsn);
        assert(durable_end >= log.current.first_lsn);
        const durable_offset = segment.segment_header_size + (durable_end - log.current.first_lsn);
        const index = log.current.index;
        run.env.close_handles();
        const dir = run.env.tmp.dir;
        run.stats.cut_bytes = try cut_tail(dir, index, durable_offset, run.rng.random());
        try run.recover_check();
        assert(run.stats.replayed <= run.ref.count);
        assert(run.stats.from_lsn <= run.durable_lsn);
    }

    fn recover_check(run: *Run) !void {
        const size = run.env.size;
        const dir = run.env.tmp.dir;
        assert(!run.env.open);
        assert(run.durable_lsn >= run.acked_lsn);
        var pm: PageManager = undefined;
        try PageManager.open(&pm, testing.io, dir, cfx.page_file, pfx.opts(size));
        defer pm.close(testing.io);

        const options = cfx.seg_options(segments_max, .none);
        const gpa = testing.allocator;
        const from = try checkpoint.redo_start(testing.io, gpa, dir, pm.wal_lsn, options);
        var page_redo: redo.PageRedo = undefined;
        try redo.PageRedo.init(&page_redo, gpa, &pm);
        defer page_redo.deinit(gpa);

        var tee: Tee = .{ .inner = page_redo.apply_target(), .seen = undefined, .count = 0 };
        const replay_options: recovery.ReplayOptions = .{
            .from_lsn = from,
            .segment_options = options,
        };
        const first = try replay_tee(dir, &tee, replay_options);
        const applied = page_redo.stats.applied;
        try run.check_frames(from, tee.items(), first.last_lsn);
        try run.ref.model_at(first.last_lsn).expect_pages(&pm);
        run.stats.replayed = tee.count;
        run.stats.from_lsn = from;

        // Idempotence: the same frames again, nothing applied, the same pages.
        const count_first = tee.count;
        tee.count = 0;
        const again = try replay_tee(dir, &tee, replay_options);
        try testing.expectEqual(first.last_lsn, again.last_lsn);
        try testing.expectEqual(count_first, tee.count);
        try testing.expectEqual(applied, page_redo.stats.applied);
        try run.ref.model_at(again.last_lsn).expect_pages(&pm);
    }

    /// Properties 1 and 2: every durable frame at or after `from` is replayed, in order, and
    /// the replayed frames are exactly a prefix of what the model appended.
    fn check_frames(run: *const Run, from: Lsn, seen: []const Rec, last_lsn: Lsn) !void {
        const want = run.ref.from_lsn(from);
        try testing.expect(seen.len <= want.len); // Nothing invented past the model's log.
        for (seen, want[0..seen.len]) |got, expected| try got.expect_same(expected);
        var required: usize = 0;
        for (want) |rec| {
            if (rec.lsn <= run.durable_lsn) required += 1;
        }
        try testing.expect(seen.len >= required); // Nothing durable lost.
        if (from != 0) {
            try testing.expect(seen.len >= 1);
            try testing.expectEqual(from, seen[0].lsn);
            try testing.expectEqual(frame.Type.checkpoint, seen[0].frame_type);
        }
        if (seen.len > 0) try testing.expectEqual(seen[seen.len - 1].lsn, last_lsn);
        assert(required <= want.len);
        assert(from <= run.durable_lsn);
    }
};

/// Applies a seeded truncate or torn cut at a random byte in `[durable_offset, length]` to the
/// segment file `index`, through a `CrashSink`; returns how many bytes it dropped or damaged.
pub fn cut_tail(dir: Io.Dir, index: u32, durable_offset: u64, r: std.Random) !u64 {
    assert(index >= 1);
    assert(durable_offset >= segment.segment_header_size);
    const f = try sfx.raw_open(dir, index);
    defer f.close(testing.io);

    const length: u32 = @intCast(try f.length(testing.io));
    try testing.expect(durable_offset <= length);
    // Half the cuts land exactly at the durable end: all the unsynced frames are lost.
    const at = if (r.boolean()) durable_offset else r.intRangeAtMost(u64, durable_offset, length);
    const cut: crash.Cut = if (r.boolean()) .{ .truncate = at } else .{ .torn = at };
    const bytes = try testing.allocator.alloc(u8, 3 * @as(usize, length));
    defer testing.allocator.free(bytes);

    const image = bytes[0..length];
    const storage = bytes[length..][0..length];
    const out = bytes[2 * @as(usize, length) ..][0..length];
    try f.readAtAll(testing.io, image, 0);
    var sink: crash.CrashSink = undefined;
    assert(storage.len == length and out.len == length);
    assert(image.len == length);
    try sink.init(storage, cut, r.int(u64));
    _ = try sink.writeAt(image, 0);
    sink.check_invariants();
    const kept = try sink.persisted_into(out);
    try testing.expect(kept.len >= durable_offset);
    try f.setLength(testing.io, kept.len);
    try f.writeAtAll(testing.io, kept, 0);
    return length - at;
}

fn replay_tee(
    dir: Io.Dir,
    tee: *Tee,
    options: recovery.ReplayOptions,
) recovery.ReplayError!recovery.Result {
    assert(tee.count == 0 or tee.seen[0].lsn >= frame.lsn_first);
    assert(options.segment_options.segments_max == segments_max);
    return recovery.Recovery.replay(testing.io, testing.allocator, dir, tee.target(), options);
}
