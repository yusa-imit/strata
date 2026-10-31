//! Tests for the logged insert (plan 005, ADR-0004 section 9): with a `wal.Writer` attached each
//! insert appends one `page_images` frame (an overflow chain first), replaying the log through
//! `PageRedo` into a fresh file rebuilds the tree, a cut last frame leaves the tree before the
//! op, replay twice equals once, and a failed append latches the tree and drops the pool.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const file_mod = @import("../file/file.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const recovery = @import("../wal/recovery.zig");
const redo = @import("../wal/redo.zig");
const wfx = @import("../wal/writer_fixtures.zig");
const sfx = @import("../wal/segment_fixtures.zig");
const fault_io = @import("../testing/fault_io.zig");
const node = @import("node.zig");
const overflow = @import("overflow.zig");
const tfx = @import("tree_fixtures.zig");
const tree_mod = @import("tree.zig");

const PageManager = manager.PageManager;
const BufferPool = buffer_pool.BufferPool;
const Tree = tree_mod.Tree;
const Id = header.Id;

const frames_max: u32 = 256;
const pages_max: u32 = 4096;
const segment_bytes_max: u64 = 1 << 24;

/// A logged tree in a temp dir: page file, pool, tree, writer. Initialised in place.
pub const Env = struct {
    tmp: testing.TmpDir,
    pm: PageManager,
    pool: BufferPool,
    tree: Tree,
    writer: wfx.Writer,
    frees: [512]Id,
    track: [64]u32,
    log_open: bool,

    pub fn start(self: *Env, size: u32, policy: file_mod.SyncPolicy) !void {
        assert(header.page_size_valid(size));
        self.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer self.tmp.cleanup();

        const options: manager.Options = .{
            .page_size = size,
            .page_count_max = pages_max,
            .sync_policy = policy,
        };
        try PageManager.create(&self.pm, testing.io, self.tmp.dir, "tree.db", options);
        errdefer self.pm.close(testing.io);

        const pool_options: buffer_pool.Options = .{ .frames_max = frames_max, .page_size = size };
        try BufferPool.init(&self.pool, testing.allocator, &self.pm, pool_options);
        errdefer self.pool.deinit(testing.allocator);

        const vb = &tfx.value_buf;
        try Tree.create(&self.tree, testing.io, &self.pool, &self.frees, vb);
        try wfx.open_ok(&self.writer, self.tmp.dir, wfx.opts(2, segment_bytes_max));
        self.tree.attach(&self.writer, &self.track);
        self.log_open = true;
        assert(self.tree.writer != null);
        assert(!self.tree.failed);
    }

    pub fn stop(self: *Env) void {
        assert(self.pool.pinned_count() == 0);
        assert(self.track.len == 64);
        if (self.log_open) self.writer.deinit(testing.io, testing.allocator);
        self.pool.discardAll();
        self.pool.deinit(testing.allocator);
        self.pm.close(testing.io);
        self.tmp.cleanup();
    }

    /// Closes the log (releases the segment lock) and drops the pool without flushing.
    pub fn crash(self: *Env) void {
        assert(self.pool.pinned_count() == 0);
        assert(self.log_open);
        self.pool.discardAll();
        self.writer.deinit(testing.io, testing.allocator);
        self.log_open = false;
        assert(!self.log_open);
        assert(self.pool.dirty_count == 0);
    }
};

/// A fresh file rebuilt from the log.
pub const Rebuilt = struct {
    pm: PageManager,
    pool: BufferPool,
    redo: redo.PageRedo,
    tree: Tree,
    frees: [8]Id,

    pub fn start(self: *Rebuilt, env: *Env, size: u32, root: Id) !void {
        assert(header.page_size_valid(size));
        assert(root != .file_header);
        assert(!env.log_open);
        const options: manager.Options = .{
            .page_size = size,
            .page_count_max = pages_max,
            .sync_policy = .none,
        };
        try PageManager.create(&self.pm, testing.io, env.tmp.dir, "replay.db", options);
        errdefer self.pm.close(testing.io);

        try redo.PageRedo.init(&self.redo, testing.allocator, &self.pm);
        errdefer self.redo.deinit(testing.allocator);

        const pool_options: buffer_pool.Options = .{ .frames_max = frames_max, .page_size = size };
        try BufferPool.init(&self.pool, testing.allocator, &self.pm, pool_options);
        errdefer self.pool.deinit(testing.allocator);

        try self.replay(env);
        try Tree.open(&self.tree, &self.pool, root, &self.frees, &tfx.value_buf);
    }

    pub fn replay(self: *Rebuilt, env: *Env) !void {
        assert(!env.log_open);
        assert(self.pm.page_count >= 1);
        const segment_options = wfx.opts(2, segment_bytes_max);
        const replay_options: recovery.ReplayOptions = .{
            .from_lsn = 0,
            .segment_options = .{
                .segments_max = segment_options.segments_max,
                .sync_policy = .none,
            },
        };
        const target = self.redo.apply_target();
        _ = try recovery.Recovery.replay(
            testing.io,
            testing.allocator,
            env.tmp.dir,
            target,
            replay_options,
        );
        assert(self.redo.stats.applied >= 1);
    }

    pub fn stop(self: *Rebuilt) void {
        assert(self.pool.pinned_count() == 0);
        assert(self.redo.buf.len == self.pm.page_size);
        self.pool.discardAll();
        self.pool.deinit(testing.allocator);
        self.redo.deinit(testing.allocator);
        self.pm.close(testing.io);
    }
};

pub fn value_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 40);
    @memset(buf[0..40], @as(u8, @truncate(n)) +% 1);
    std.mem.writeInt(u32, buf[0..4], n, .little);
    return buf[0..40];
}

pub fn expect_range(t: *Tree, from: u32, to: u32, present: bool) !void {
    assert(from <= to);
    var key_buf: [16]u8 = undefined;
    var value_buf: [40]u8 = undefined;
    for (from..to) |n| {
        const key = tfx.key_of(&key_buf, @intCast(n));
        const want: ?[]const u8 = if (present) value_of(&value_buf, @intCast(n)) else null;
        try tfx.expect_get(t, key, want);
    }
}

pub fn insert_range(t: *Tree, from: u32, to: u32) !void {
    assert(from <= to);
    var key_buf: [16]u8 = undefined;
    var value_buf: [40]u8 = undefined;
    for (from..to) |n| {
        const key = tfx.key_of(&key_buf, @intCast(n));
        try t.insert(testing.io, key, value_of(&value_buf, @intCast(n)));
    }
}

test "logged inserts with splits replay into an equal tree, twice equals once" {
    for ([_]u32{ 512, 1024, 4096 }) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        const count: u32 = 600;
        try insert_range(&env.tree, 0, count);
        try env.tree.validate(testing.io, testing.allocator);
        const root = env.tree.root;
        try testing.expect(env.pm.page_count > 8); // Several splits happened.
        env.crash();

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_range(&rebuilt.tree, 0, count, true);
        const applied = rebuilt.redo.stats.applied;
        try rebuilt.replay(&env); // Replay twice equals once: nothing new is written.
        try testing.expectEqual(applied, rebuilt.redo.stats.applied);
        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_range(&rebuilt.tree, 0, count, true);
    }
}

test "cutting the frame of the first split leaves the tree before the op" {
    for ([_]u32{ 512, 4096 }) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        var n: u32 = 0;
        var before = env.writer.position();
        while (n < 1000) : (n += 1) { // Bounded: a leaf splits long before 1000 keys.
            before = env.writer.position();
            const pages = env.pm.page_count;
            try insert_range(&env.tree, n, n + 1);
            if (env.pm.page_count != pages) break;
        }
        try testing.expect(n < 1000);
        const root = env.tree.root;
        env.crash();

        const cut = try sfx.raw_open(env.tmp.dir, before.segment_index);
        try cut.setLength(testing.io, before.offset);
        cut.close(testing.io);

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_range(&rebuilt.tree, 0, n, true);
        try expect_range(&rebuilt.tree, n, n + 1, false);
    }
}

test "an overflow value is logged first and replays" {
    for ([_]u32{ 512, 4096 }) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        try insert_range(&env.tree, 0, 20);
        const big = try testing.allocator.alloc(u8, size * 2 + 100); // About 3 chain pages.
        defer testing.allocator.free(big);

        for (big, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 3);
        const lsn_before = env.writer.last_lsn;
        try env.tree.insert(testing.io, "big-key", big);
        try testing.expect(env.writer.last_lsn > lsn_before);
        const root = env.tree.root;
        env.crash();

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_range(&rebuilt.tree, 0, 20, true);
        try tfx.expect_get(&rebuilt.tree, "big-key", big);
    }
}

test "a failed append latches the tree and drops the pool" {
    var env: Env = undefined;
    try env.start(512, .none);
    defer env.stop();

    var faults: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&faults, testing.io, .{
        .write = .canceled,
        .read = .none,
        .after_calls = 0,
    });
    const io = faults.io();
    try testing.expectError(error.Failed, env.tree.insert(io, "k1", "v1"));
    try testing.expect(env.tree.failed);
    try testing.expectEqual(@as(u32, 0), env.pool.dirty_count);
    try testing.expectError(error.Failed, env.tree.insert(testing.io, "k2", "v2"));
    env.pool.check_invariants();
}

test "ids popped from the freelist are synced before the frame is appended" {
    var env: Env = undefined;
    try env.start(512, .fsync);
    defer env.stop();

    const spare = try env.pm.allocate(testing.io);
    try env.pm.free(testing.io, spare); // The freelist now holds a page.
    try testing.expect(env.pm.freelist_head != null);

    var faults: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&faults, testing.io, .{
        .write = .none,
        .read = .none,
        .after_calls = 0,
        .sync_fail_after = 0,
    });
    const lsn_before = env.writer.last_lsn;
    try testing.expectError(error.Failed, env.tree.insert(faults.io(), "k1", "v1"));
    try testing.expect(faults.sync_calls >= 1); // The sync was tried ...
    try testing.expectEqual(lsn_before, env.writer.last_lsn); // ... and no frame went out.
}

test "a chain longer than the tracker is ValueTooLarge and leaves the tree usable" {
    var env: Env = undefined;
    try env.start(512, .none);
    defer env.stop();

    const ops_max: u32 = 2 * @as(u32, node.height_max(512)) + 1;
    env.tree.track = env.track[0..ops_max]; // A tracker just big enough for a tree path.
    const len: u32 = (ops_max + 1) * 512;
    try testing.expect(overflow.chain_len(512, len) > ops_max);
    try testing.expect(overflow.chain_len(512, len) <= env.frees.len);
    const big = try testing.allocator.alloc(u8, len);
    defer testing.allocator.free(big);

    @memset(big, 0x5a);
    const lsn_before = env.writer.last_lsn;
    try testing.expectError(error.ValueTooLarge, env.tree.insert(testing.io, "big", big));
    try testing.expect(!env.tree.failed); // Rejected up front: nothing was dirtied.
    try testing.expectEqual(lsn_before, env.writer.last_lsn);
    try env.tree.insert(testing.io, "k1", "v1");
    try tfx.expect_get(&env.tree, "k1", "v1");
    try tfx.expect_get(&env.tree, "big", null);
}

test "a failed chain append latches the tree and drops the pool" {
    var env: Env = undefined;
    try env.start(512, .fsync);
    defer env.stop();

    const spare = try env.pm.allocate(testing.io);
    try env.pm.free(testing.io, spare); // A popped id makes the chain log sync first.
    try testing.expect(env.pm.freelist_head != null);
    const big = try testing.allocator.alloc(u8, 512 * 3);
    defer testing.allocator.free(big);

    @memset(big, 0x33);
    var faults: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&faults, testing.io, .{
        .write = .none,
        .read = .none,
        .after_calls = 0,
        .sync_fail_after = 0,
    });
    const lsn_before = env.writer.last_lsn;
    try testing.expectError(error.Failed, env.tree.insert(faults.io(), "big", big));
    try testing.expect(env.tree.failed);
    try testing.expect(faults.sync_calls >= 1);
    try testing.expectEqual(lsn_before, env.writer.last_lsn); // No frame, not even the chain's.
    try testing.expectEqual(@as(u32, 0), env.pool.dirty_count);
    try testing.expectError(error.Failed, env.tree.insert(testing.io, "k2", "v2"));
    env.pool.check_invariants();
}
