//! Seeded model tests for the B+Tree (plan 005 item 4E). A random op stream (get, insert of new
//! and existing keys with some overflow values, delete of present and absent keys, seek and
//! cursor steps) runs against a `Tree` and a sorted-array reference model in lockstep; every
//! result is compared, and the whole tree is compared with a forward and a backward scan.
//! Part one is unlogged (flush, cold re-read, `release_frees`, drain to an empty root leaf) at
//! three page sizes; part two attaches a WAL writer, cuts the run at a seeded point, replays the
//! log into a fresh file and requires the recovered tree to equal the model as of the last
//! returned op, replay twice equal to once, plus a variant that cuts the last op's frames.
//! Seeds are literals: a failure logs `(seed, size, op)` and reproduces from them.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const sfx = @import("../wal/segment_fixtures.zig");
const tfx = @import("../btree/tree_fixtures.zig");
const tree_mod = @import("../btree/tree.zig");
const wal_test = @import("../btree/tree_wal_test.zig");
const mfx = @import("btree_model_fixtures.zig");

const Env = wal_test.Env;
const Rebuilt = wal_test.Rebuilt;
const Tree = tree_mod.Tree;
const Driver = mfx.Driver;
const Model = mfx.Model;

const frames: u32 = 64;
const pages_max: u32 = 2048;
const release_every: u32 = 37;
const scan_every: u32 = 50;
const validate_every: u32 = 100;
const seeds_unlogged = [_]u64{ 0x5eed_0001, 0x5eed_0002, 0x5eed_0003 };
const seeds_logged = [_]u64{ 0x1091_c001, 0x1091_c002 };

/// Drops every pending free id (`release_frees` after the writer's sync, if logged).
fn release(t: *Tree) !void {
    assert(t.pool.pinned_count() == 0);
    assert(t.frees_len <= t.frees_pending.len);
    if (t.writer) |writer| try writer.sync(testing.io);
    _ = try t.release_frees(testing.io);
    if (t.writer != null) assert(t.frees_len == 0);
    assert(t.pool.pinned_count() == 0);
}

/// Deletes every key the model holds, then checks the tree is one empty root leaf.
fn drain(d: *Driver, t: *Tree) !void {
    assert(d.model.len <= mfx.key_space);
    assert(t.pool.pinned_count() == 0);
    var key_buf: [16]u8 = undefined;
    for (0..mfx.key_space) |_| {
        if (d.model.len == 0) break;
        const key = d.model.items[d.model.len / 2].key;
        try testing.expect(d.model.remove(key));
        try testing.expect(try t.delete(testing.io, tfx.key_of(&key_buf, key)));
        if (d.model.len % 16 == 0) try t.check_invariants(testing.io);
    }
    try testing.expectEqual(@as(u32, 0), d.model.len);
    try release(t);
    var guard = try t.pool.fetch(testing.io, t.root);
    const root_type = header.peek(guard.bytes()).page_type;
    guard.release();
    try testing.expectEqual(header.Type.btree_leaf, root_type);
    try d.expect_equal(t, testing.io);
}

fn run_unlogged(size: u32, ops_max: u32, seed: u64) !void {
    assert(header.page_size_valid(size));
    assert(ops_max >= 300);
    var fx: tfx.Fixture = undefined;
    try fx.start(testing.allocator, size, frames, pages_max);
    defer fx.stop(testing.allocator);

    var d: Driver = undefined;
    try d.init(testing.allocator, size, seed, .full);
    defer d.deinit(testing.allocator);

    errdefer std.log.err("btree model: seed={d} size={d} op={d}", .{ seed, size, d.ops_done });
    const t = &fx.tree;
    for (0..ops_max) |op| {
        try d.step(t, testing.io);
        const done: u32 = @intCast(op + 1);
        if (done % scan_every == 0) try d.scan_full(t, testing.io);
        if (done % validate_every == 0) try t.validate(testing.io, testing.allocator);
        if (done % release_every == 0) try release(t);
        if (done == @divFloor(ops_max, 3) or done == 2 * @divFloor(ops_max, 3)) {
            try fx.pool.flushAll(testing.io); // Pinned frames are clean after this; edit on.
        }
        if (done == @divFloor(ops_max, 2)) try fx.cold(); // Next reads come from the file.
    }
    try testing.expect(d.large_puts > 0);
    try testing.expect(d.model.len > 0);
    try d.expect_equal(t, testing.io);
    try fx.cold();
    try d.expect_equal(t, testing.io);
    try drain(&d, t);
}

test "model: sorted array keeps order, overwrites and removes" {
    var model: Model = undefined;
    model.init();
    model.put(.{ .key = 9, .len = 3, .salt = 1 });
    model.put(.{ .key = 2, .len = 4, .salt = 1 });
    model.put(.{ .key = 5, .len = 5, .salt = 1 });
    model.put(.{ .key = 5, .len = 6, .salt = 2 }); // Overwrite.
    try model.expect_sorted();
    try testing.expectEqual(@as(u32, 3), model.len);
    try testing.expectEqual(@as(u32, 6), model.find(5).?.len);
    try testing.expectEqual(@as(u32, 1), model.lower_bound(3));
    try testing.expectEqual(@as(u32, 3), model.lower_bound(10));
    try testing.expect(model.remove(2));
    try testing.expect(!model.remove(2));
    try testing.expectEqual(@as(u32, 0), model.lower_bound(0));
    try testing.expect(model.find(2) == null);
}

test "model: unlogged seeded run at 512 B pages" {
    for (seeds_unlogged) |seed| try run_unlogged(512, 2000, seed);
}

test "model: unlogged seeded run at 4 KiB pages" {
    for (seeds_unlogged) |seed| try run_unlogged(4096, 1500, seed);
}

test "model: unlogged seeded run at 64 KiB pages" {
    for (seeds_unlogged) |seed| try run_unlogged(65536, 600, seed);
}

/// Logged run: `ops` write ops under a writer, then a crash (pool dropped, no flush). With
/// `torn` the last op's frames are cut off and the model is the one before that op.
fn run_logged(size: u32, seed: u64, ops: u32, torn: bool) !void {
    assert(header.page_size_valid(size));
    assert(ops >= 100);
    var env: Env = undefined;
    try env.start(size, .none);
    defer env.stop();

    var d: Driver = undefined;
    try d.init(testing.allocator, size, seed, .writes);
    defer d.deinit(testing.allocator);

    errdefer std.log.err("btree model: seed={d} size={d} op={d}", .{ seed, size, d.ops_done });
    var before: Model = undefined;
    var before_root = env.tree.root;
    var before_pos = env.writer.position();
    for (0..ops) |op| {
        before = d.model;
        before_root = env.tree.root;
        before_pos = env.writer.position();
        try d.step(&env.tree, testing.io);
        const done: u32 = @intCast(op + 1);
        if (done % release_every == 0) try release(&env.tree);
        if (done % validate_every == 0) try env.tree.validate(testing.io, testing.allocator);
    }
    try testing.expect(d.large_puts > 0);
    var root = env.tree.root;
    try d.expect_equal(&env.tree, testing.io);
    env.crash();
    if (torn) {
        const cut = try sfx.raw_open(env.tmp.dir, before_pos.segment_index);
        try cut.setLength(testing.io, before_pos.offset);
        cut.close(testing.io);
        d.model = before;
        root = before_root;
    }
    try expect_recovered(&env, &d, size, root);
}

fn expect_recovered(env: *Env, d: *Driver, size: u32, root: header.Id) !void {
    assert(!env.log_open);
    assert(root != .file_header);
    var rebuilt: Rebuilt = undefined;
    try rebuilt.start(env, size, root);
    defer rebuilt.stop();

    try d.expect_equal(&rebuilt.tree, testing.io);
    const applied = rebuilt.redo.stats.applied;
    try rebuilt.replay(env); // Replay twice equals once: nothing new is written.
    try testing.expectEqual(applied, rebuilt.redo.stats.applied);
    try d.expect_equal(&rebuilt.tree, testing.io);
}

test "model: logged run, crash at a seeded cut, replay equals the model" {
    for ([_]u32{ 512, 4096 }) |size| {
        for (seeds_logged) |seed| {
            var cut = std.Random.DefaultPrng.init(seed ^ size);
            const ops = cut.random().intRangeAtMost(u32, 300, 700);
            try run_logged(size, seed, ops, false);
        }
    }
}

test "model: logged run, cut last op's frames, replay equals the model before it" {
    for ([_]u32{ 512, 4096 }) |size| {
        for (seeds_logged) |seed| {
            var cut = std.Random.DefaultPrng.init(seed ^ size);
            const ops = cut.random().intRangeAtMost(u32, 300, 700);
            try run_logged(size, seed, ops, true);
        }
    }
}
