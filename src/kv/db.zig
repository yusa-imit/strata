//! strata.kv.Db: the embedded KV store over the B+Tree, the buffer pool, the page file and the
//! WAL (ADR-0005). `open` creates a database in an empty directory (page file `pages.db`, log
//! directory `wal`, root = page 1) or reopens an existing one, replaying the log past the last
//! checkpoint; `put`, `delete`, `get`, `checkpoint`, `flush` and `close` follow.
//!
//! Scope of this file today (plan 006 items "kv/db.zig" and "Recovery on open"): sections 1 to
//! 7 of the ADR. Not yet built: the commit frame, commit-bounded replay and `WriteBatch`
//! (section 8, later items): today one `put` or `delete` is one `page_images` frame, which is
//! atomic on its own, and `Writer.commit` of it is the durable point, so recovery applies every
//! intact frame.
//!
//! Durability: `put` and `delete` return after `Writer.commit` of their frame returned, then
//! raise the pool gate to `writer.durable_lsn` (never above a durable commit point). `close`
//! runs a checkpoint (all pages flushed and synced, `wal_lsn` = the last frame), so a clean
//! reopen replays nothing but the checkpoint frame. After a crash, `open` runs `redo_start`
//! from `wal_lsn`, one `Recovery.replay` into `PageRedo` (the page lsn makes redo idempotent),
//! a `PageManager.sync`, and only then builds the writer and the pool.
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

const Id = header.Id;
const map = errors.map;

/// Names of the layout (ADR-0005 section 1). Written only by this file.
const pages_name = "pages.db";
const wal_name = "wal";
/// The root is the first allocation of `create` on a fresh page file (section 2).
const root_id: Id = @enumFromInt(1);

pub const Engine = enum { btree };

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
    const ops_max: u32 = 2 * @as(u32, node.height_max(options.page_size)) + 1;
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
        if (self.writer.last_lsn == self.pm.wal_lsn) return; // Clean: nothing to checkpoint.
        _ = self.cp.run(io) catch |err| {
            self.latch();
            return map(err);
        };
        assert(self.pool.dirty_count == 0);
        assert(self.pm.wal_lsn == self.writer.last_lsn);
    }

    /// Makes the frame an op appended durable (if it appended one) and raises the gate to the
    /// writer's durable point. A failed commit latches the `Db`.
    fn commit(self: *State, io: Io, last_before: u64) Error!void {
        assert(!self.failed);
        assert(self.writer.last_lsn >= last_before);
        if (self.writer.last_lsn == last_before) return; // No frame: not a commit point.
        self.writer.commit(io, self.writer.last_lsn) catch |err| {
            self.latch();
            return map(err);
        };
        self.pool.set_durable_lsn(self.writer.durable_lsn);
        assert(self.writer.durable_lsn == self.writer.last_lsn);
    }

    /// The error of a failed tree op. The tree latches itself (and drops the pool) when it
    /// left unlogged pages behind; the `Db` follows.
    fn fail(self: *State, err: anyerror) Error {
        if (self.tree.failed) self.failed = true;
        assert(self.pool.pinned_count() == 0);
        return map(err);
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
        const last_before = state.writer.last_lsn;
        state.tree.insert(self.io, key, value) catch |err| return state.fail(err);
        try state.commit(self.io, last_before);
        assert(state.writer.last_lsn > last_before);
    }

    /// Removes `key`; true when it was present. Durable on return when it was.
    pub fn delete(self: *Db, key: []const u8) DeleteError!bool {
        const state = try self.usable();
        if (key.len > state.key_len_eff) return error.KeyTooLarge;
        assert(key.len <= state.key_len_eff);
        try state.begin_write(self.io);
        const last_before = state.writer.last_lsn;
        const found = state.tree.delete(self.io, key) catch |err| return state.fail(err);
        try state.commit(self.io, last_before);
        assert(found or state.writer.last_lsn == last_before); // Absent key: no frame.
        return found;
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

    var replayed: checkpoint.Lsn = 0; // A fresh log has no frame.
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
}

/// Steps 4 to 6 of section 4: derives the start from `wal_lsn`, replays every frame from it
/// into `PageRedo` (the torn tail is repaired by `Recovery`), then syncs the page file, because
/// redo does not. Returns the last frame's lsn, where the writer continues. The redo page
/// buffer is allocated here and freed before this returns. Idempotent: a crash anywhere in
/// here replays again to the same pages (redo is guarded by the page lsn).
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
    var target: redo.PageRedo = undefined;
    try redo.PageRedo.init(&target, gpa, &state.pm);
    defer target.deinit(gpa);

    const replay_options: recovery.ReplayOptions = .{
        .from_lsn = from,
        .segment_options = segment_options,
    };
    const result = recovery.Recovery.replay(
        io,
        gpa,
        state.wal_dir,
        target.apply_target(),
        replay_options,
    ) catch |err| return map(err);
    state.pm.sync(io) catch |err| return map(err);
    assert(result.last_lsn >= wal_lsn); // `redo_start` proved the log reaches its checkpoint.
    assert(result.last_lsn >= from);
    return result.last_lsn;
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
    state.pool.set_durable_lsn(state.writer.durable_lsn); // The gate: the last commit point.
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
}
