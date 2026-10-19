//! Shared fixtures for the `checkpoint.zig` contract tests (`checkpoint_test.zig`,
//! `checkpoint_fault_test.zig`): an `Env` that owns a temporary directory holding a page file
//! (pages 1 to 3 written), a `BufferPool` over it, a WAL `Writer` and a `Checkpoint`; an
//! `edit` that logs a `page_image` frame and applies the same change to the pool (what a
//! B+Tree would do); a `Model` of the pages every committed edit must leave; and `recover`,
//! which reopens both files cold, derives the start with `redo_start`, replays with `PageRedo`
//! and checks the model. The log uses one frame per segment so reclaim is visible. Test-only;
//! I/O through `std.testing.io` unless a call is given another `Io`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const BufferPool = @import("../cache/buffer_pool.zig").BufferPool;
const file_mod = @import("../file/file.zig");
const fixtures = @import("../file/file_fixtures.zig");
const header = @import("../page/header.zig");
const pfx = @import("../page/manager_fixtures.zig");
const PageManager = @import("../page/manager.zig").PageManager;
const checkpoint = @import("checkpoint.zig");
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");
const redo = @import("redo.zig");
const rfx = @import("redo_fixtures.zig");
const segment = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");
const wfx = @import("writer_fixtures.zig");

pub const Lsn = frame.Lsn;
pub const sizes_all = pfx.sizes_all;
pub const page_file = "pages.db";
pub const pages_used: u32 = 3;
/// Header lsn of the pages written at `Env.init`: below every frame, so redo replaces them.
const initial_lsn: u64 = 0;

/// The page contents every committed edit must leave: seed and lsn per page id.
pub const Model = struct {
    seeds: [pages_used + 1]u32,
    lsns: [pages_used + 1]u64,

    pub fn init() Model {
        var model: Model = .{ .seeds = undefined, .lsns = undefined };
        assert(model.seeds.len == model.lsns.len);
        for (&model.seeds, 0..) |*seed, id| seed.* = initial_seed(@intCast(id));
        @memset(&model.lsns, initial_lsn);
        assert(model.seeds[1] == initial_seed(1));
        return model;
    }

    pub fn set(self: *Model, id: u32, seed: u32, lsn: Lsn) void {
        assert(self.lsns[id] < lsn);
        assert(self.seeds.len == self.lsns.len);
        assert(id >= 1 and id <= pages_used);
        assert(lsn >= frame.lsn_first);
        self.seeds[id] = seed;
        self.lsns[id] = lsn;
    }

    pub fn expect_pages(self: *const Model, pm: *PageManager) !void {
        assert(pm.page_count > pages_used);
        assert(self.seeds.len == pages_used + 1);
        for (1..pages_used + 1) |id| {
            try pfx.expect_pattern(pm, @intCast(id), self.seeds[id], self.lsns[id]);
        }
    }
};

fn initial_seed(id: u32) u32 {
    assert(id <= pages_used);
    assert(pages_used < 1000);
    return 1000 + id;
}

/// Segment options with the policy a test uses for the whole log.
pub fn seg_options(segments_max: u32, policy: file_mod.SyncPolicy) segment.Options {
    assert(segments_max >= 1);
    assert(segments_max < segment.segment_index_max);
    return .{ .segments_max = segments_max, .sync_policy = policy };
}

/// Initialised in place: `pool` and `cp` point at `pm` and `log`.
pub const Env = struct {
    tmp: testing.TmpDir,
    size: u32,
    segments_max: u32,
    pm: PageManager,
    pool: BufferPool,
    log: wfx.Writer,
    cp: checkpoint.Checkpoint,
    model: Model,
    /// The page file, pool and log are open; `close_handles` clears it.
    open: bool,

    /// `segment_frames` is how many full page-image frames a segment takes before it rotates.
    pub fn init(
        env: *Env,
        size: u32,
        segments_max: u32,
        segment_frames: u32,
        policy: file_mod.SyncPolicy,
    ) !void {
        assert(header.page_size_valid(size));
        assert(segment_frames >= 1);
        env.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer env.tmp.cleanup();

        env.open = false;
        env.size = size;
        env.segments_max = segments_max;
        env.model = Model.init();
        const page_options = pfx.opts_with(size, policy);
        try PageManager.create(&env.pm, testing.io, env.tmp.dir, page_file, page_options);
        errdefer env.pm.close(testing.io);

        try env.pm.ensure_page_count(testing.io, pages_used + 2);
        const buf = try testing.allocator.alloc(u8, size);
        defer testing.allocator.free(buf);

        for (1..pages_used + 1) |id| {
            const seed = initial_seed(@intCast(id));
            try pfx.write_pattern(&env.pm, @intCast(id), buf, seed, initial_lsn);
        }
        try env.pm.sync(testing.io);
        try BufferPool.init(&env.pool, testing.allocator, &env.pm, .{
            .frames_max = pages_used,
            .page_size = size,
        });
        errdefer env.pool.deinit(testing.allocator);

        const frame_bytes: u64 = frame.frame_header_size + 4 + size;
        const bytes_max = segment.segment_header_size + frame_bytes * segment_frames;
        const options = wfx.options(segments_max, bytes_max, policy);
        try wfx.open_ok(&env.log, env.tmp.dir, options);
        checkpoint.Checkpoint.init(&env.cp, &env.log, &env.pool, &env.pm);
        env.open = true;
    }

    /// Releases everything without flushing: also what a crash leaves (nothing is synced).
    pub fn deinit(env: *Env) void {
        assert(env.segments_max >= 1);
        assert(header.page_size_valid(env.size));
        if (env.open) env.close_handles();
        env.tmp.cleanup();
    }

    /// Drops the pool's dirty pages and closes the page file and the log, keeping the files.
    pub fn close_handles(env: *Env) void {
        assert(env.open);
        env.open = false;
        env.pool.discardAll();
        env.pool.deinit(testing.allocator);
        env.log.deinit(testing.io, testing.allocator);
        env.pm.close(testing.io);
        assert(env.size >= header.page_size_min);
    }

    /// Logs a `page_image` of page `id` built from `seed` and applies it to the pool, as a
    /// B+Tree would; the model learns it. Returns the frame's LSN.
    pub fn edit(env: *Env, id: u32, seed: u32) !Lsn {
        assert(id >= 1 and id <= pages_used);
        assert(env.open);
        return env.edit_io(testing.io, id, seed);
    }

    /// `edit` with the log and the pool going through `io` (a `FaultIo` in crash tests). When
    /// the pool step fails the frame is already in the log and the page is not edited.
    pub fn edit_io(env: *Env, io: Io, id: u32, seed: u32) !Lsn {
        assert(id >= 1 and id <= pages_used);
        const payload = try rfx.image_payload(env.size, id, seed, pfx.consumer_type, rfx.stale_lsn);
        defer testing.allocator.free(payload);

        assert(env.open);
        assert(payload.len == 4 + env.size);
        const lsn = try env.log.append(io, .page_image, payload);
        var guard = try env.pool.fetchForUpdate(io, pfx.id_of(id));
        defer guard.release();

        fixtures.pattern(guard.bytes_mut()[header.header_size..], seed);
        guard.set_lsn(lsn);
        env.model.set(id, seed, lsn);
        return lsn;
    }

    pub fn segment_exists(env: *const Env, index: u32) !bool {
        assert(index >= 1);
        assert(index < segment.segment_index_max);
        const handle = sfx.raw_open(env.tmp.dir, index) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |other| return other,
        };
        handle.close(testing.io);
        return true;
    }

    /// Exactly the segments `first ..= last` exist (and none just outside).
    pub fn expect_segments(env: *const Env, first: u32, last: u32) !void {
        assert(first >= 1 and first <= last);
        assert(last < env.segments_max + 8);
        for (1..last + 3) |index| {
            const want = index >= first and index <= last;
            try testing.expectEqual(want, try env.segment_exists(@intCast(index)));
        }
    }
};

pub const Recovered = struct { from_lsn: Lsn, wal_lsn: u64, applied: u64, last_lsn: Lsn };

/// Cold start: open the page file, `redo_start`, `Recovery.replay` through `PageRedo` (twice:
/// the second pass must apply nothing), then check the pages against `model`.
pub fn recover(dir: Io.Dir, size: u32, segments_max: u32, model: *const Model) !Recovered {
    assert(header.page_size_valid(size));
    assert(segments_max >= 1);
    var pm: PageManager = undefined;
    try PageManager.open(&pm, testing.io, dir, page_file, pfx.opts(size));
    defer pm.close(testing.io);

    const options = seg_options(segments_max, .none);
    const from = try checkpoint.redo_start(testing.io, testing.allocator, dir, pm.wal_lsn, options);
    var target: redo.PageRedo = undefined;
    try redo.PageRedo.init(&target, testing.allocator, &pm);
    defer target.deinit(testing.allocator);

    const replay_options: recovery.ReplayOptions = .{
        .from_lsn = from,
        .segment_options = options,
    };
    const gpa = testing.allocator;
    const apply = target.apply_target();
    const result = try recovery.Recovery.replay(testing.io, gpa, dir, apply, replay_options);
    const applied = target.stats.applied;
    const again = try recovery.Recovery.replay(testing.io, gpa, dir, apply, replay_options);
    try testing.expectEqual(result.last_lsn, again.last_lsn);
    try testing.expectEqual(applied, target.stats.applied); // Replaying twice = once.
    try model.expect_pages(&pm);
    return .{
        .from_lsn = from,
        .wal_lsn = pm.wal_lsn,
        .applied = applied,
        .last_lsn = result.last_lsn,
    };
}
