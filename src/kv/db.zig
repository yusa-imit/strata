//! strata.kv.Db: the embedded KV store over the B+Tree, the buffer pool, the page file and the
//! WAL (ADR-0005). `open` creates a database in an empty directory (page file `pages.db`, log
//! directory `wal`, root = page 1) or reopens an existing one, replaying the log past the last
//! checkpoint; `put`, `delete`, `get`, `checkpoint`, `flush` and `close` follow.
//!
//! Scope of this file today (plan 006 items "kv/db.zig", "Recovery on open", "Commit frame and
//! commit-bounded recovery" and the group half of "WriteBatch"): sections 1 to 8 of the ADR. One
//! `put` or `delete`, or one `commit_ops` call (the apply side of `WriteBatch`, `batch.zig`), is
//! a group: its `page_images` frame(s), then one `commit` frame; a group that logged nothing (an
//! absent-key `delete`, an empty batch) logs no `commit` frame and is not a commit point.
//!
//! Durability: `put` and `delete` return after `Writer.commit` of their `commit` frame returned,
//! then raise the pool gate to it (the last commit point, never `writer.durable_lsn`). `close`
//! runs a checkpoint (all pages flushed and synced, `wal_lsn` = the last frame), so a clean
//! reopen replays nothing but the checkpoint frame. After a crash, `open` runs `redo_start`
//! from `wal_lsn`, a first `Recovery.replay` into `CommitScan` (the last commit point `K`, a
//! torn tail repaired), `Recovery.truncate_after(K)`, a second replay into `PageRedo` (the page
//! lsn makes redo idempotent), a `PageManager.sync`, and only then builds the writer and the
//! pool. No frame past `K` is ever applied, and the log ends at `K` before the writer appends.
//! Latch: a failed commit, checkpoint or tree op that left unlogged pages drops the pool and
//! every later call is `Failed`; reopen recovers by replay.
//! Allocation: `open` allocates the `State`, the pool, the writer buffer, `frees`, `track` and
//! `value_buf`, which stay until `close`, and nothing else after it returns. During `open`,
//! `probe_log`, `redo_start` and `Recovery.replay` each open a log `Reader` that allocates via
//! `gpa` and frees it before returning, and the redo page buffer is freed likewise. `gpa` is
//! stored to free the long-lived buffers in `close`. Only this file caches an `Io` (`Db.io`,
//! set once, asserted equal to `State.io` by every method).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("../btree/node.zig");
const internal = @import("../btree/internal.zig");
const overflow = @import("../btree/overflow.zig");
const tree_mod = @import("../btree/tree.zig");
const file = @import("../file/file.zig");
const platform = @import("../file/platform.zig");
const checkpoint = @import("../wal/checkpoint.zig");
const commit_scan = @import("../wal/commit_scan.zig");
const frame = @import("../wal/frame.zig");
const reader = @import("../wal/reader.zig");
const recovery = @import("../wal/recovery.zig");
const redo = @import("../wal/redo.zig");
const segment = @import("../wal/segment.zig");
const writer_mod = @import("../wal/writer.zig");
const errors = @import("errors.zig");

pub const Error = errors.Error;
pub const OpenError = errors.OpenError;
pub const GetError = errors.GetError;
pub const PutError = errors.PutError;
pub const DeleteError = errors.DeleteError;
pub const FlushError = errors.FlushError;
pub const CheckpointError = errors.CheckpointError;
pub const BatchError = errors.BatchError;
pub const CommitError = errors.CommitError;

const Id = header.Id;
const map = errors.map;

/// Names of the layout (ADR-0005 section 1). Written only by this file.
const pages_name = "pages.db";
const wal_name = "wal";
/// The root is the first allocation of `create` on a fresh page file (section 2).
const root_id: Id = @enumFromInt(1);

pub const Engine = enum { btree };

/// One recorded write of a batch; `value` is ignored by `.delete`. Borrowed, never copied here.
pub const BatchOp = struct {
    kind: enum { put, delete },
    key: []const u8,
    value: []const u8,
};

/// Every field is spelled at the call site (ADR-0005 section 5): there are no defaults.
pub const Options = struct {
    engine: Engine,
    /// Page file and log share it.
    sync_policy: file.SyncPolicy,
    /// A power of two, 512 to 65536.
    page_size: u32,
    /// `PageManager` growth limit, at least 2 (page 0 and the root).
    page_count_max: u32,
    /// At least `pool_frames_min(options)`, asserted.
    pool_frames_max: u32,
    /// Clamped to `node.key_len_max(page_size)`; see `Db.key_len_max`.
    key_len_max: u32,
    /// At most `node.value_len_max`; sizes `value_buf`.
    value_len_max: u32,
    /// At least 1; sizes the pool floor and `frees` (a put or delete is a batch of 1).
    batch_ops_max: u32,
    /// At least `key_len_max + value_len_max`.
    batch_bytes_max: u32,
    /// At least 2: one segment of headroom for the checkpoint (section 7).
    wal_segments_max: u32,
    wal_segment_bytes_max: u64,
};

/// Frames the pool needs so that one group, an op's pins and the tracker never exhaust it
/// (ADR-0005 section 8). Pure over `options`; `open` asserts `pool_frames_max` against it.
pub fn pool_frames_min(options: Options) u32 {
    assert(header.page_size_valid(options.page_size));
    assert(options.batch_ops_max >= 1);
    const height: u64 = node.height_max(options.page_size);
    const cap: u64 = node.overflow_capacity(options.page_size);
    const ops: u64 = options.batch_ops_max;
    const chain_bytes: u64 = @divTrunc(options.batch_bytes_max + cap - 1, cap);
    const group: u64 = ops * (2 * height + 1) + chain_bytes + ops;
    const track: u64 = track_len(options);
    const floor = @max(group + 2 * height + 2, track + 2 * height + 2);
    assert(floor >= 2 * height + 2);
    return @intCast(floor);
}

/// `max(2 * height_max + 1, chain(value_len_max))` (section 5).
fn track_len(options: Options) u32 {
    assert(options.value_len_max <= node.value_len_max);
    assert(header.page_size_valid(options.page_size));
    const ops_max: u32 = node.op_pages_max(options.page_size);
    return @max(ops_max, overflow.chain_len(options.page_size, options.value_len_max));
}

/// `batch_ops_max * (height_max + chain) + chain` (section 5).
fn frees_len(options: Options) u32 {
    assert(options.batch_ops_max >= 1);
    assert(options.value_len_max <= node.value_len_max);
    const chain = overflow.chain_len(options.page_size, options.value_len_max);
    const height: u32 = node.height_max(options.page_size);
    return options.batch_ops_max * (height + chain) + chain;
}

fn options_check(options: Options) void {
    assert(header.page_size_valid(options.page_size));
    assert(options.page_count_max >= 2);
    assert(options.key_len_max >= 1);
    assert(options.value_len_max >= 1 and options.value_len_max <= node.value_len_max);
    assert(options.batch_ops_max >= 1);
    assert(options.batch_bytes_max >= options.key_len_max + options.value_len_max);
    assert(options.wal_segments_max >= 2);
    assert(options.pool_frames_max >= pool_frames_min(options));
}

/// Everything that borrows another part by pointer lives here, allocated once, never moved.
const State = struct {
    io: Io,
    options: Options,
    key_len_eff: u32,
    sub: Io.Dir,
    wal_dir: Io.Dir,
    pm: manager.PageManager,
    pool: buffer_pool.BufferPool,
    writer: writer_mod.Writer,
    tree: tree_mod.Tree,
    cp: checkpoint.Checkpoint,
    frees: []Id,
    track: []u32,
    value_buf: []u8,
    /// The last commit point: a `commit` or `checkpoint` frame, or 0. The pool gate (section 7).
    commit_lsn: frame.Lsn,
    failed: bool,

    fn manager_options(self: *const State) manager.Options {
        assert(header.page_size_valid(self.options.page_size));
        assert(self.options.page_count_max >= 2);
        return .{
            .page_size = self.options.page_size,
            .page_count_max = self.options.page_count_max,
            .sync_policy = self.options.sync_policy,
        };
    }

    fn writer_options(self: *const State) writer_mod.Options {
        assert(self.options.wal_segments_max >= 2);
        assert(self.options.wal_segment_bytes_max > segment.segment_header_size);
        return .{
            .segments_max = self.options.wal_segments_max,
            .sync_policy = self.options.sync_policy,
            .segment_bytes_max = self.options.wal_segment_bytes_max,
            .group_commit_window = .zero, // One caller per `Db`: nobody joins a window.
        };
    }

    fn segment_options(self: *const State) segment.Options {
        assert(self.options.wal_segments_max >= 2);
        assert(self.options.engine == .btree);
        return .{
            .segments_max = self.options.wal_segments_max,
            .sync_policy = self.options.sync_policy,
        };
    }

    /// Start of every write: frees queued ids (rule B) and keeps one segment of log headroom
    /// (section 7). Its errors are returned before the op touches anything.
    fn begin_write(self: *State, io: Io) Error!void {
        try self.release(io);
        if (self.writer.live_count + 1 >= self.options.wal_segments_max) {
            try self.run_checkpoint(io);
        }
        assert(self.writer.live_count < self.options.wal_segments_max);
        assert(!self.failed);
    }

    fn release(self: *State, io: Io) Error!void {
        assert(!self.failed);
        _ = self.tree.release_frees(io) catch |err| return map(err);
        // Every op commits before it returns, so queued ids are always past their frame.
        assert(self.tree.frees_lsn <= self.writer.durable_lsn);
    }

    /// A sharp checkpoint (flush, sync, `wal_lsn`, reclaim). Any failure latches the `Db`.
    fn run_checkpoint(self: *State, io: Io) Error!void {
        assert(!self.failed);
        assert(self.pool.pinned_count() == 0);
        assert(self.writer.last_lsn == self.commit_lsn); // Between groups: no open one.
        if (self.writer.last_lsn == self.pm.wal_lsn) return; // Clean: nothing to checkpoint.
        _ = self.cp.run(io) catch |err| {
            self.latch();
            return map(err);
        };
        assert(self.pool.dirty_count == 0);
        assert(self.pm.wal_lsn == self.writer.last_lsn);
        self.commit_lsn = self.writer.last_lsn; // A checkpoint frame is a commit point.
    }

    /// Closes the group an op ran: when it appended any frame, appends one `commit` frame whose
    /// `first_lsn` is the writer's `next_lsn` at group start (`first_lsn`), makes it durable and
    /// raises the gate to it (sections 7 and 8). A group with no frame is not a commit point.
    /// A failed append or commit latches the `Db`: the group's pages are dropped.
    fn commit(self: *State, io: Io, first_lsn: frame.Lsn) Error!void {
        assert(!self.failed);
        assert(self.writer.next_lsn >= first_lsn);
        if (self.writer.next_lsn == first_lsn) return; // No frame: not a commit point.
        const payload = frame.commit_payload(first_lsn);
        const lsn = self.writer.append(io, .commit, &payload) catch |err| {
            self.latch();
            return map(err);
        };
        self.writer.commit(io, lsn) catch |err| {
            self.latch();
            return map(err);
        };
        assert(self.writer.durable_lsn == lsn);
        assert(lsn > first_lsn);
        self.commit_lsn = lsn;
        self.pool.set_durable_lsn(lsn); // The gate: the last commit point, never a bare frame.
    }

    /// The error of a failed tree op. The tree latches itself (and drops the pool) when it
    /// left unlogged pages behind; the `Db` follows.
    fn fail(self: *State, err: anyerror) Error {
        if (self.tree.failed) self.failed = true;
        assert(self.pool.pinned_count() == 0);
        return map(err);
    }

    /// `fail` for an op inside a group that started at `first_lsn`: when an earlier op already
    /// logged a frame, the group is open and cannot be left behind (the next commit frame would
    /// not follow the last commit point), so the `Db` latches.
    fn fail_group(self: *State, err: anyerror, first_lsn: frame.Lsn) Error {
        assert(self.writer.next_lsn >= first_lsn);
        assert(!self.failed or self.tree.failed);
        if (self.writer.next_lsn != first_lsn) self.latch();
        return self.fail(err);
    }

    /// Drops every unlogged change; every later call is `Failed` until reopen.
    fn latch(self: *State) void {
        self.failed = true;
        self.pool.discardAll();
        assert(self.pool.dirty_count == 0);
    }

    /// Syncs directory names after a create, unless the policy is `.none` (ADR-0003 section 9).
    fn sync_names(self: *const State, dir: Io.Dir) Error!void {
        assert(dir.handle >= 0);
        if (self.options.sync_policy == .none) return;
        platform.sync_dir(self.io, dir) catch |err| return map(err);
    }
};

pub const Db = struct {
    io: Io,
    gpa: Allocator,
    state: *State,

    /// Creates the database in an empty (or absent) `sub_path` of `dir`, or reopens an existing
    /// one: after a crash it replays every intact log frame past the last checkpoint and repairs
    /// a torn log tail, so every `put` and `delete` that returned is visible. A non-empty
    /// directory without `pages.db`, a half-created database, a missing or empty `wal` (whatever
    /// `wal_lsn` is; the page file stays unchanged), a root page that is no tree node and a
    /// log that does not match the page file are `Corrupted`; a held database is `WouldBlock`.
    /// On error nothing stays open, locked or allocated (a half-created directory stays on
    /// disk: delete it). Cost: a few reads of the log from the checkpoint, so `checkpoint`
    /// bounds the open time.
    pub fn open(
        io: Io,
        gpa: Allocator,
        dir: Io.Dir,
        sub_path: []const u8,
        options: Options,
    ) OpenError!Db {
        options_check(options);
        assert(sub_path.len >= 1);
        const state = try gpa.create(State);
        errdefer gpa.destroy(state);

        state.io = io;
        state.options = options;
        state.key_len_eff = @min(options.key_len_max, node.key_len_max(options.page_size));
        state.failed = false;
        state.commit_lsn = 0;
        const fresh = try open_sub(state, dir, sub_path);
        errdefer state.sub.close(io);

        try open_files(state, gpa, fresh);
        errdefer close_files(state, gpa);

        try open_runtime(state, gpa, fresh);
        assert(state.tree.root == root_id);
        return .{ .io = io, .gpa = gpa, .state = state };
    }

    /// Checkpoints (unless the database is already clean or latched) and releases everything.
    /// A failed checkpoint is not reported: the log keeps every committed change, and the next
    /// `open` replays it. Pending page ids are freed first (best effort; an id that stays
    /// pending leaks, which ADR-0002 section 7 calls safe).
    pub fn close(self: *Db) void {
        const state = self.live();
        const io = self.io;
        if (!state.failed) {
            // Best effort, like the checkpoint: an id that stays pending leaks, which is safe.
            if (state.tree.release_frees(io)) |_| {} else |_| {}
        }
        if (!state.failed and state.writer.last_lsn != state.pm.wal_lsn) {
            if (state.cp.run(io)) |_| {} else |_| {} // See the doc: the log still holds it all.
        }
        state.pool.discardAll(); // Empty after a checkpoint; a failed one leaves gated pages.
        state.pool.deinit(self.gpa);
        state.writer.deinit(io, self.gpa);
        state.pm.close(io);
        state.wal_dir.close(io);
        state.sub.close(io);
        self.gpa.free(state.frees);
        self.gpa.free(state.track);
        self.gpa.free(state.value_buf);
        self.gpa.destroy(state);
        self.* = undefined;
    }

    /// Page ids unlinked by deletes that wait for `release_frees` (a diagnostic): they are
    /// freed at the start of the next write or `flush`, and by `close`.
    pub fn pending_frees(self: *const Db) u32 {
        const state = self.live();
        assert(state.tree.frees_len <= state.frees.len);
        return state.tree.frees_len;
    }

    /// The effective key limit: `min(options.key_len_max, node.key_len_max(page_size))`.
    pub fn key_len_max(self: *const Db) u32 {
        const state = self.state;
        assert(state.key_len_eff >= 1);
        assert(state.key_len_eff <= node.key_len_max(state.options.page_size));
        return state.key_len_eff;
    }

    /// The value under `key`, or null. Borrowed from a pool frame or the value buffer: valid
    /// until the next call on this `Db`; copy it to keep it.
    pub fn get(self: *Db, key: []const u8) GetError!?[]const u8 {
        const state = try self.usable();
        if (key.len > state.key_len_eff) return error.KeyTooLarge;
        assert(key.len <= state.key_len_eff);
        const found = state.tree.get(self.io, key) catch |err| return state.fail(err);
        assert(state.pool.pinned_count() == 0);
        assert(!state.failed);
        return found;
    }

    /// Stores `value` under `key`; returns after the log frame is durable per `SyncPolicy`.
    /// `KeyTooLarge` and `ValueTooLarge` are returned before any page changes.
    pub fn put(self: *Db, key: []const u8, value: []const u8) PutError!void {
        const state = try self.usable();
        if (key.len > state.key_len_eff) return error.KeyTooLarge;
        if (value.len > state.options.value_len_max) return error.ValueTooLarge;
        assert(value.len <= state.value_buf.len);
        try state.begin_write(self.io);
        const first_lsn = state.writer.next_lsn;
        state.tree.insert(self.io, key, value) catch |err| return state.fail(err);
        try state.commit(self.io, first_lsn);
        assert(state.commit_lsn > first_lsn);
    }

    /// Removes `key`; true when it was present. Durable on return when it was.
    pub fn delete(self: *Db, key: []const u8) DeleteError!bool {
        const state = try self.usable();
        if (key.len > state.key_len_eff) return error.KeyTooLarge;
        assert(key.len <= state.key_len_eff);
        try state.begin_write(self.io);
        const first_lsn = state.writer.next_lsn;
        const found = state.tree.delete(self.io, key) catch |err| return state.fail(err);
        try state.commit(self.io, first_lsn);
        assert(found or state.writer.next_lsn == first_lsn); // Absent key: no frame.
        return found;
    }

    /// Applies `ops` in order as ONE group, then one `commit` frame (ADR-0005 section 8): after
    /// a crash none of them or all of them are visible; the last write to a key wins. Every
    /// limit is checked for all ops before the first applies (`KeyTooLarge`, `ValueTooLarge`,
    /// `BatchTooLarge`, nothing changed). An empty `ops` does nothing; so does a group that
    /// logged no frame (deletes of absent keys), which is not a commit point. A failure after
    /// the first frame was logged latches the `Db`: the open group cannot be rolled back, and
    /// reopen recovers to the last commit point. `WriteBatch.commit` is the usual caller; the
    /// slices are only read.
    pub fn commit_ops(self: *Db, ops: []const BatchOp) CommitError!void {
        const state = try self.usable();
        try batch_check(state.options, state.key_len_eff, ops);
        if (ops.len == 0) return;
        try state.begin_write(self.io);
        const first_lsn = state.writer.next_lsn;
        const commit_before = state.commit_lsn;
        for (ops) |op| {
            switch (op.kind) {
                .put => state.tree.insert(self.io, op.key, op.value) catch |err| {
                    return state.fail_group(err, first_lsn);
                },
                .delete => _ = state.tree.delete(self.io, op.key) catch |err| {
                    return state.fail_group(err, first_lsn);
                },
            }
        }
        try state.commit(self.io, first_lsn);
        const logged = state.writer.next_lsn > first_lsn;
        assert(logged == (state.commit_lsn > commit_before)); // Only a logged group is a commit.
        assert(!state.failed);
    }

    /// Frees queued page ids and checkpoints; see `checkpoint`.
    pub fn flush(self: *Db) FlushError!void {
        try self.checkpoint();
        assert(self.state.pool.dirty_count == 0);
        assert(self.state.pm.wal_lsn == self.state.writer.last_lsn);
    }

    /// Frees queued page ids, then runs a sharp checkpoint (flush, sync, `wal_lsn`, reclaim;
    /// ADR-0005 section 7): every change is in the page file, `wal_lsn` names the checkpoint
    /// frame, and the segments wholly below it are deleted. A clean `Db` (nothing logged since
    /// the last checkpoint) does nothing. Precondition: no write is in flight (one caller per
    /// `Db`, so always true between calls). This is what bounds the log: it holds at most
    /// `wal_segments_max - 1` segments before a write, because every write checkpoints first
    /// when it would not (`begin_write`); call it to shrink the log or the recovery time. A
    /// failure latches the `Db` (`Failed` afterwards): the log still holds every committed
    /// change, and `open` replays it. Errors are returned as `Error`.
    pub fn checkpoint(self: *Db) CheckpointError!void {
        const state = try self.usable();
        try state.release(self.io);
        try state.run_checkpoint(self.io);
        assert(state.pool.dirty_count == 0);
        assert(state.pm.wal_lsn == state.writer.last_lsn);
    }

    fn live(self: *const Db) *State {
        assert(self.state.io.userdata == self.io.userdata); // `io` is set once (ADR-0001).
        assert(self.state.io.vtable == self.io.vtable);
        return self.state;
    }

    fn usable(self: *const Db) error{Failed}!*State {
        const state = self.live();
        if (state.failed) return error.Failed;
        assert(state.tree.root == root_id);
        return state;
    }
};

/// The limits of a batch (ADR-0005 section 8): op count, per-op key and value, and the sum of
/// key and value bytes. Pure; returns before anything is touched.
fn batch_check(options: Options, key_len_eff: u32, ops: []const BatchOp) BatchError!void {
    assert(options.batch_ops_max >= 1);
    assert(key_len_eff >= 1);
    if (ops.len > options.batch_ops_max) return error.BatchTooLarge;
    var bytes: u64 = 0;
    for (ops) |op| { // Bound: `ops.len <= batch_ops_max`.
        if (op.key.len > key_len_eff) return error.KeyTooLarge;
        if (op.value.len > options.value_len_max) return error.ValueTooLarge;
        bytes += op.key.len + op.value.len;
    }
    if (bytes > options.batch_bytes_max) return error.BatchTooLarge;
}

/// Makes `sub_path` if it is absent and opens it with iteration. True when the database must
/// be created (the directory was absent or has no entry at all, a bound of one read).
fn open_sub(state: *State, dir: Io.Dir, sub_path: []const u8) Error!bool {
    const io = state.io;
    assert(sub_path.len >= 1);
    dir.createDir(io, sub_path, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |other| return map(other),
    };
    state.sub = dir.openDir(io, sub_path, .{ .iterate = true }) catch |err| return map(err);
    errdefer state.sub.close(io);

    assert(state.sub.handle >= 0);

    var entries = state.sub.iterate();
    const first = entries.next(io) catch |err| return map(err);
    const empty = first == null;
    if (empty) try state.sync_names(dir); // C1: the name of `sub_path` is durable.
    return empty;
}

/// C2 to C4 (create) or steps 1 to 7 of section 4 (open): page file, log directory, replay and
/// writer. On error everything opened here is closed again.
fn open_files(state: *State, gpa: Allocator, fresh: bool) Error!void {
    const io = state.io;
    const pm_options = state.manager_options();
    if (fresh) {
        manager.PageManager.create(&state.pm, io, state.sub, pages_name, pm_options) catch |err| {
            return map(err);
        };
    } else {
        manager.PageManager.open(&state.pm, io, state.sub, pages_name, pm_options) catch |err| {
            return map_missing(err);
        };
    }
    errdefer state.pm.close(io);

    if (!fresh and state.pm.page_count < 2) return error.Corrupted; // No root: half-created.
    if (fresh) {
        state.sub.createDir(io, wal_name, .default_dir) catch |err| return map(err);
        try state.sync_names(state.sub); // C3: `pages.db` and `wal` are durable names.
    }
    state.wal_dir = state.sub.openDir(io, wal_name, .{ .iterate = true }) catch |err| {
        return map_missing(err);
    };
    errdefer state.wal_dir.close(io);

    var replayed: checkpoint.Lsn = 0; // A fresh log has no frame; else K, the last commit.
    if (!fresh) {
        try probe_log(state, gpa);
        replayed = try replay_log(state, gpa);
    }
    const writer_options = state.writer_options();
    writer_mod.Writer.init(&state.writer, io, gpa, state.wal_dir, writer_options) catch |err| {
        return map_init(err);
    };
    if (state.writer.last_lsn != replayed) {
        state.writer.deinit(io, gpa); // The log changed under our lock: do not trust it.
        return error.Corrupted;
    }
    assert(!fresh or state.writer.last_lsn == 0);
    state.commit_lsn = replayed;
}

/// Steps 4 to 6 of section 4: derives the start from `wal_lsn`, finds the last commit point `K`
/// with a first pass into `CommitScan` (which also repairs a torn tail), cuts the log after
/// `K`, replays the frames `<= K` into `PageRedo`, then syncs the page file, because redo does
/// not. Returns `K`, where the writer continues. The redo page buffer is allocated here and
/// freed before this returns. Idempotent: a crash anywhere in here runs again to the same pages
/// (redo is guarded by the page lsn, the cut re-creates the same state).
fn replay_log(state: *State, gpa: Allocator) Error!checkpoint.Lsn {
    const io = state.io;
    const segment_options = state.segment_options();
    const wal_lsn = state.pm.wal_lsn;
    const from = checkpoint.redo_start(
        io,
        gpa,
        state.wal_dir,
        wal_lsn,
        segment_options,
    ) catch |err| return map(err);
    assert(from <= wal_lsn);
    const replay_options: recovery.ReplayOptions = .{
        .from_lsn = from,
        .segment_options = segment_options,
    };
    var scan = commit_scan.CommitScan.init(from);
    const first = recovery.Recovery.replay(
        io,
        gpa,
        state.wal_dir,
        scan.target(),
        replay_options,
    ) catch |err| return map(err);
    const commit_last = scan.last_commit_lsn;
    assert(commit_last <= first.last_lsn);
    if (commit_last < first.last_lsn) { // Frames of an unfinished group follow `K`.
        recovery.Recovery.truncate_after(
            io,
            gpa,
            state.wal_dir,
            commit_last,
            segment_options,
        ) catch |err| return map(err);
    }
    var target: redo.PageRedo = undefined;
    try redo.PageRedo.init(&target, gpa, &state.pm);
    defer target.deinit(gpa);

    const second = recovery.Recovery.replay(
        io,
        gpa,
        state.wal_dir,
        target.apply_target(),
        replay_options,
    ) catch |err| return map(err);
    state.pm.sync(io) catch |err| return map(err);
    // The log ends at `K` now, so no frame past it reached `PageRedo`.
    assert(second.last_lsn == commit_last);
    assert(commit_last >= wal_lsn); // `redo_start` proved the log reaches its checkpoint.
    return commit_last;
}

/// A missing file or directory where the layout needs one is a damaged database.
fn map_missing(err: anyerror) Error {
    assert(@errorName(err).len >= 1);
    assert(@intFromError(err) != 0);
    return switch (err) {
        error.FileNotFound, error.NotDir => error.Corrupted,
        else => map(err),
    };
}

/// `RecoveryRequired` from `Writer.init` is a torn tail after `replay_log` repaired it: another
/// process touched the log under our lock, which is `Corrupted`.
fn map_init(err: anyerror) Error {
    assert(@errorName(err).len >= 1);
    assert(@intFromError(err) != 0);
    return switch (err) {
        error.RecoveryRequired => error.Corrupted,
        else => map(err),
    };
}

/// A reopened database must have at least one live segment: `Writer.init` would otherwise
/// create segment 1 and silently reset it (ADR-0003 open question 3).
fn probe_log(state: *State, gpa: Allocator) Error!void {
    const io = state.io;
    var probe: reader.Reader = undefined;
    reader.Reader.open(&probe, io, gpa, state.wal_dir, state.segment_options()) catch |err| {
        return map(err);
    };
    defer probe.deinit(io, gpa);

    if (probe.live_count < 1) return error.Corrupted;
    assert(probe.file_count >= 1);
}

fn close_files(state: *State, gpa: Allocator) void {
    assert(state.wal_dir.handle >= 0);
    assert(state.writer.live_count >= 1);
    state.writer.deinit(state.io, gpa);
    state.pm.close(state.io);
    state.wal_dir.close(state.io);
}

/// Allocates the buffers, builds the pool and tree, attaches the log and raises the gate (C5,
/// C6 and section 4 step 8). On error everything allocated here is freed.
fn open_runtime(state: *State, gpa: Allocator, fresh: bool) Error!void {
    assert(state.writer.live_count >= 1);
    const options = state.options;
    state.frees = try gpa.alloc(Id, frees_len(options));
    errdefer gpa.free(state.frees);

    state.track = try gpa.alloc(u32, track_len(options));
    errdefer gpa.free(state.track);

    state.value_buf = try gpa.alloc(u8, options.value_len_max);
    errdefer gpa.free(state.value_buf);

    const pool_options: buffer_pool.Options = .{
        .frames_max = options.pool_frames_max,
        .page_size = options.page_size,
    };
    try buffer_pool.BufferPool.init(&state.pool, gpa, &state.pm, pool_options);
    errdefer state.pool.deinit(gpa);

    errdefer state.pool.discardAll();
    if (fresh) {
        try create_root(state);
    } else {
        try check_root(state);
        const tree = &state.tree;
        tree_mod.Tree.open(tree, &state.pool, root_id, state.frees, state.value_buf) catch |err| {
            return map(err);
        };
    }
    state.tree.attach(&state.writer, state.track);
    state.pool.set_durable_lsn(state.commit_lsn); // The gate: the last commit point (K).
    checkpoint.Checkpoint.init(&state.cp, &state.writer, &state.pool, &state.pm);
    assert(state.pool.gate_on);
    assert(state.pool.pinned_count() == 0);
}

/// C5: page 1 = an empty leaf, flushed and synced. The completion marker of a create.
fn create_root(state: *State) Error!void {
    const io = state.io;
    assert(state.pm.page_count == 1);
    assert(state.pm.freelist_head == null);
    tree_mod.Tree.create(&state.tree, io, &state.pool, state.frees, state.value_buf) catch |err| {
        return map(err);
    };
    assert(state.tree.root == root_id);
    state.pool.flushAll(io) catch |err| return map(err);
    state.pm.sync(io) catch |err| return map(err);
    assert(state.pm.page_count == 2);
    assert(state.pool.dirty_count == 0);
}

/// Section 2: page 1 must be a leaf or an internal node that parses at its own level.
fn check_root(state: *State) Error!void {
    const io = state.io;
    assert(state.pm.page_count >= 2);
    var guard = state.pool.fetch(io, root_id) catch |err| return map(err);
    defer guard.release();

    const page = guard.bytes();
    assert(page.len == state.options.page_size);
    switch (header.peek(page).page_type) {
        .btree_leaf => _ = node.parse_leaf(page) catch return error.Corrupted,
        .btree_internal => {
            const level = page[node.offset_level];
            _ = internal.parse_internal(page, level) catch return error.Corrupted;
        },
        else => return error.Corrupted,
    }
}

test {
    _ = @import("db_test.zig"); // Contract tests live in their own files (800-line limit).
    _ = @import("db_recover_test.zig");
    _ = @import("db_commit_test.zig");
    _ = @import("batch.zig");
    _ = @import("batch_test.zig");
}
