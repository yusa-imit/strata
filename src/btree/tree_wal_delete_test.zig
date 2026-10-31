//! Tests for the logged delete (plan 005 item 9b-ii, ADR-0004 section 9): with a `wal.Writer`
//! attached each delete appends one `page_images` frame of the live pages it dirtied (an unlinked
//! page is not logged), an absent key logs nothing, a failed append latches the tree, and
//! `release_frees` obeys rule B: ids are freed only once the log that unlinked them is durable.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const sfx = @import("../wal/segment_fixtures.zig");
const fault_io = @import("../testing/fault_io.zig");
const overflow = @import("overflow.zig");
const tfx = @import("tree_fixtures.zig");
const tree_mod = @import("tree.zig");
const wal_test = @import("tree_wal_test.zig");

const Env = wal_test.Env;
const Rebuilt = wal_test.Rebuilt;
const Tree = tree_mod.Tree;
const BufferPool = @import("../cache/buffer_pool.zig").BufferPool;
const Id = header.Id;

const sizes = [_]u32{ 512, 4096 };

/// Deletes the keys `from ..< to` whose parity is `odd`, validating after each op.
fn delete_parity(t: *Tree, from: u32, to: u32, odd: bool) !void {
    assert(from <= to);
    assert(t.writer != null);
    var key_buf: [16]u8 = undefined;
    for (from..to) |n| {
        if ((n % 2 == 1) != odd) continue;
        const key = tfx.key_of(&key_buf, @intCast(n));
        try testing.expect(try t.delete(testing.io, key));
        try t.validate(testing.io, testing.allocator);
    }
}

fn delete_plain(t: *Tree, from: u32, to: u32) !void {
    assert(from <= to);
    assert(t.writer != null);
    var key_buf: [16]u8 = undefined;
    for (from..to) |n| {
        const key = tfx.key_of(&key_buf, @intCast(n));
        try testing.expect(try t.delete(testing.io, key));
    }
}

/// Keys at or past `keep_from` that are even stay; every other key below `limit` is gone.
fn expect_survivors(t: *Tree, keep_from: u32, limit: u32) !void {
    assert(keep_from <= limit);
    assert(t.page_size == t.pool.page_size);
    var key_buf: [16]u8 = undefined;
    var value_buf: [40]u8 = undefined;
    for (0..limit) |n| {
        const key = tfx.key_of(&key_buf, @intCast(n));
        const stays = n >= keep_from and n % 2 == 0;
        const want: ?[]const u8 = if (stays) wal_test.value_of(&value_buf, @intCast(n)) else null;
        try tfx.expect_get(t, key, want);
    }
}

fn page_lsn(t: *Tree, id: Id) !u64 {
    assert(id != .file_header);
    assert(t.pool.pinned_count() == 0);
    var guard = try t.pool.fetch(testing.io, id);
    defer guard.release();

    return header.peek(guard.bytes()).lsn;
}

/// An unlinked page must not stay dirty in the pool: the WAL gate lets a page with an old lsn
/// out before the delete's frame is durable.
fn expect_not_dirty(pool: *BufferPool, id: Id) !void {
    assert(id != .file_header);
    assert(pool.frames.len == pool.frames_max);
    const index = pool.table.get(@intFromEnum(id)) orelse return; // Not resident: fine.
    try testing.expect(!pool.frames[index].dirty);
}

test "logged deletes with merges, borrows and a root collapse replay into an equal tree" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        const count: u32 = 600;
        const keep_from = count - 8;
        try wal_test.insert_range(&env.tree, 0, count);
        try env.tree.validate(testing.io, testing.allocator);
        try delete_parity(&env.tree, 0, count, true); // Scattered: borrows and some merges.
        try delete_parity(&env.tree, 0, keep_from, false); // Then merges up to the root.
        try expect_survivors(&env.tree, keep_from, count);
        var root_guard = try env.pool.fetch(testing.io, env.tree.root);
        const root_type = header.peek(root_guard.bytes()).page_type;
        root_guard.release();
        try testing.expectEqual(header.Type.btree_leaf, root_type); // The root collapsed.
        const root = env.tree.root;
        env.crash();

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_survivors(&rebuilt.tree, keep_from, count);
        const applied = rebuilt.redo.stats.applied;
        try rebuilt.replay(&env); // Replay twice equals once.
        try testing.expectEqual(applied, rebuilt.redo.stats.applied);
        try rebuilt.tree.validate(testing.io, testing.allocator);
        try expect_survivors(&rebuilt.tree, keep_from, count);
    }
}

test "deleting an absent key appends no frame" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        try wal_test.insert_range(&env.tree, 0, 50);
        const lsn_before = env.writer.last_lsn;
        const position = env.writer.position();
        try testing.expect(!try env.tree.delete(testing.io, "k99999"));
        try testing.expect(!try env.tree.delete(testing.io, "a"));
        try testing.expectEqual(lsn_before, env.writer.last_lsn);
        try testing.expectEqual(position.offset, env.writer.position().offset);
        try testing.expect(!env.tree.failed);
        try testing.expect(!env.pool.track_on);
        try wal_test.expect_range(&env.tree, 0, 50, true);
        try env.tree.validate(testing.io, testing.allocator);
    }
}

test "cutting the frame of a merging delete leaves the tree before that delete" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        const count: u32 = 300;
        try wal_test.insert_range(&env.tree, 0, count);
        var n: u32 = 0;
        var before = env.writer.position();
        while (n < count) : (n += 1) { // Bounded: a leaf merges long before the last key.
            before = env.writer.position();
            const pending = env.tree.frees_len;
            try delete_plain(&env.tree, n, n + 1);
            if (env.tree.frees_len > pending) break;
        }
        try testing.expect(n < count);
        const root = env.tree.root;
        env.crash();

        const cut = try sfx.raw_open(env.tmp.dir, before.segment_index);
        try cut.setLength(testing.io, before.offset);
        cut.close(testing.io);

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try wal_test.expect_range(&rebuilt.tree, 0, n, false);
        try wal_test.expect_range(&rebuilt.tree, n, count, true);
    }
}

test "a failed append during delete latches the tree and drops the pool" {
    var env: Env = undefined;
    try env.start(512, .none);
    defer env.stop();

    try wal_test.insert_range(&env.tree, 0, 100);
    var faults: fault_io.FaultIo = undefined;
    fault_io.FaultIo.init(&faults, testing.io, .{
        .write = .canceled,
        .read = .none,
        .after_calls = 0,
    });
    const lsn_before = env.writer.last_lsn;
    try testing.expectError(error.Failed, env.tree.delete(faults.io(), "k00001"));
    try testing.expect(env.tree.failed);
    try testing.expectEqual(lsn_before, env.writer.last_lsn);
    try testing.expectEqual(@as(u32, 0), env.pool.dirty_count);
    try testing.expectError(error.Failed, env.tree.delete(testing.io, "k00002"));
    try testing.expectError(error.Failed, env.tree.insert(testing.io, "k2", "v2"));
    try testing.expectEqual(@as(u32, 0), try env.tree.release_frees(testing.io)); // Latched.
    env.pool.check_invariants();
}

test "the page a delete unlinks is not in its frame" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        const count: u32 = 300;
        try wal_test.insert_range(&env.tree, 0, count);
        var n: u32 = 0;
        var pending: u32 = 0;
        while (n < count) : (n += 1) { // Bounded: a leaf merges long before the last key.
            pending = env.tree.frees_len;
            try delete_plain(&env.tree, n, n + 1);
            if (env.tree.frees_len > pending) break;
        }
        try testing.expect(n < count);
        const last_lsn = env.writer.last_lsn;
        try testing.expectEqual(last_lsn, env.tree.frees_lsn);
        for (env.tree.frees_pending[pending..env.tree.frees_len]) |id| {
            try expect_not_dirty(&env.pool, id); // Else eviction could write it too early.
            if (env.pool.table.get(@intFromEnum(id)) == null) continue; // Dropped: fine.
            try testing.expect(try page_lsn(&env.tree, id) < last_lsn); // Never stamped.
        }
        try testing.expect(try page_lsn(&env.tree, env.tree.root) <= last_lsn);
        try env.tree.validate(testing.io, testing.allocator);
    }
}

test "release_frees waits for the log, frees, and a later insert reuses a page" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        const count: u32 = 600;
        try wal_test.insert_range(&env.tree, 0, count);
        try delete_plain(&env.tree, 0, count - 50);
        const pending = env.tree.frees_len;
        try testing.expect(pending > 0);
        try testing.expect(env.writer.durable_lsn < env.tree.frees_lsn);
        try testing.expectEqual(@as(u32, 0), try env.tree.release_frees(testing.io));
        try testing.expectEqual(pending, env.tree.frees_len); // Still pending, nothing freed.
        try testing.expect(env.pm.freelist_head == null);

        try env.writer.sync(testing.io);
        try testing.expectEqual(pending, try env.tree.release_frees(testing.io));
        try testing.expectEqual(@as(u32, 0), env.tree.frees_len);
        try testing.expect(env.pm.freelist_head != null);

        const pages = env.pm.page_count;
        try wal_test.insert_range(&env.tree, count, count + 100);
        try testing.expectEqual(pages, env.pm.page_count); // Freed ids were reused.
        try env.tree.validate(testing.io, testing.allocator);
        const root = env.tree.root;
        env.crash();

        var rebuilt: Rebuilt = undefined;
        try rebuilt.start(&env, size, root);
        defer rebuilt.stop();

        try rebuilt.tree.validate(testing.io, testing.allocator);
        try wal_test.expect_range(&rebuilt.tree, 0, count - 50, false);
        try wal_test.expect_range(&rebuilt.tree, count - 50, count + 100, true);
    }
}

test "overflow chains of an overwrite and a delete are freed only after durability" {
    for (sizes) |size| {
        var env: Env = undefined;
        try env.start(size, .none);
        defer env.stop();

        try wal_test.insert_range(&env.tree, 0, 5);
        const big1 = try testing.allocator.alloc(u8, size * 2 + 100);
        defer testing.allocator.free(big1);

        const big2 = try testing.allocator.alloc(u8, size * 3 + 50);
        defer testing.allocator.free(big2);

        for (big1, 0..) |*byte, index| byte.* = @truncate(index *% 7 +% 3);
        for (big2, 0..) |*byte, index| byte.* = @truncate(index *% 11 +% 5);
        const chain1 = overflow.chain_len(size, @intCast(big1.len));
        const chain2 = overflow.chain_len(size, @intCast(big2.len));
        try env.tree.insert(testing.io, "big", big1);
        try testing.expectEqual(@as(u32, 0), env.tree.frees_len);

        try env.tree.insert(testing.io, "big", big2); // The overwrite queues the old chain.
        try testing.expectEqual(chain1, env.tree.frees_len);
        try testing.expectEqual(env.writer.last_lsn, env.tree.frees_lsn);
        try testing.expectEqual(@as(u32, 0), try env.tree.release_frees(testing.io));
        try testing.expectEqual(chain1, env.tree.frees_len);
        try env.writer.sync(testing.io);
        try testing.expectEqual(chain1, try env.tree.release_frees(testing.io));
        try tfx.expect_get(&env.tree, "big", big2);

        try testing.expect(try env.tree.delete(testing.io, "big")); // The delete queues the chain.
        try testing.expectEqual(chain2, env.tree.frees_len);
        try testing.expectEqual(env.writer.last_lsn, env.tree.frees_lsn);
        try testing.expectEqual(@as(u32, 0), try env.tree.release_frees(testing.io));
        try env.writer.sync(testing.io);
        try testing.expectEqual(chain2, try env.tree.release_frees(testing.io));
        try tfx.expect_get(&env.tree, "big", null);
        try wal_test.expect_range(&env.tree, 0, 5, true);
        try env.tree.validate(testing.io, testing.allocator);
    }
}

test "a second delete moves frees_lsn and release_frees waits for the second sync" {
    var env: Env = undefined;
    try env.start(512, .none);
    defer env.stop();

    try wal_test.insert_range(&env.tree, 0, 300);
    try delete_plain(&env.tree, 0, 100);
    try env.writer.sync(testing.io);
    const first_lsn = env.tree.frees_lsn;
    try delete_plain(&env.tree, 100, 250); // Merges queue more ids behind a newer frame.
    try testing.expect(env.tree.frees_lsn > first_lsn);
    try testing.expect(env.writer.durable_lsn < env.tree.frees_lsn);
    const pending = env.tree.frees_len;
    try testing.expectEqual(@as(u32, 0), try env.tree.release_frees(testing.io));
    try testing.expectEqual(pending, env.tree.frees_len);
    try env.writer.sync(testing.io);
    try testing.expectEqual(pending, try env.tree.release_frees(testing.io));
}

test "FreesPendingLimit with a writer leaves the tree usable and logs nothing" {
    var env: Env = undefined;
    try env.start(512, .none);
    defer env.stop();

    try wal_test.insert_range(&env.tree, 0, 300);
    const big = try testing.allocator.alloc(u8, 512 * 3);
    defer testing.allocator.free(big);

    @memset(big, 0x77);
    try env.tree.insert(testing.io, "big", big);
    env.tree.frees_pending = env.frees[0..2]; // Too small for the chain of "big".
    const lsn_before = env.writer.last_lsn;
    const frees_lsn = env.tree.frees_lsn;
    try testing.expectError(error.FreesPendingLimit, env.tree.delete(testing.io, "big"));
    try testing.expect(!env.tree.failed);
    try testing.expect(!env.pool.track_on);
    try testing.expectEqual(lsn_before, env.writer.last_lsn);
    try testing.expectEqual(@as(u32, 0), env.tree.frees_len);
    try testing.expectEqual(frees_lsn, env.tree.frees_lsn);
    env.tree.frees_pending = env.frees[0..];
    try testing.expect(try env.tree.delete(testing.io, "big")); // The tree still works.
    try tfx.expect_get(&env.tree, "big", null);
}
