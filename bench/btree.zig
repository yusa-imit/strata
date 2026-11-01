//! B+Tree benchmarks (plan 005 item 11): `btree_get`, `btree_insert_seq` and
//! `btree_insert_logged`, over real page files through `PageManager` and a CLOCK `BufferPool`
//! large enough to hold a whole tree, so every page access is a pool hit. One tree call (`get`
//! or `insert`) is the "op"; `byte_count` is `operation_count * (key_len + value_len)`.
//!
//! Sketch: keys are the index as a big-endian `u64` (so numeric order is byte order), values are
//! 16 bytes derived from the index. `fixture_init` creates a scratch directory holding three
//! page files and one WAL, and builds the get tree there: `key_count` ascending inserts, after
//! which every page of it sits in the pool. `btree_get` then looks up `get_count` keys in a
//! seeded pseudo-random order, never touching the file. `btree_insert_seq` creates an empty tree
//! in the second pool inside the timed kernel and inserts `key_count` ascending keys.
//! `btree_insert_logged` does the same for `logged_key_count` keys in the third pool after
//! `Tree.attach`, so each insert also appends one `page_images` frame (a full page image) to the
//! WAL (sync policy `.none`: the figure is the append path, not the disk). It is recorded, not
//! gated. Each pool has `frames_max` frames and its file room for twice that, so a tree that
//! outgrows the pool is evicting, not stopped by a full file; every build checks the sizing
//! invariant with a real branch (`TreeOutgrewPool`: no eviction, at most `frames_max` pages),
//! because the bench runs in ReleaseFast where asserts vanish.
//! Allocation: the fixture allocates everything in `fixture_init` (pools, WAL buffers, the get
//! order, the value buffer); the kernels allocate nothing. `sink` sums the first eight value
//! bytes of every key read (get) or is the page count the tree grew to (inserts), so the work
//! cannot be elided. The insert kernels each run once per fixture (they build their tree).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const strata = @import("strata");
const Result = @import("main.zig").Result;

const BufferPool = strata.cache.BufferPool;
const header = strata.page.header;
const Id = header.Id;
const PageManager = strata.page.manager.PageManager;
const Tree = strata.btree.Tree;
const Writer = strata.wal.Writer;

/// Longest scratch directory name the fixture remembers for its cleanup.
pub const name_len_max: u32 = 64;

/// Bytes of every key: the index, big-endian.
pub const key_len: u32 = 8;
/// Bytes of every value: the index, then its complement, both little-endian.
pub const value_len: u32 = 16;

/// Everything a kernel can return: the tree's own errors, tree creation, and the checks the
/// get kernel makes with real branches (the bench runs in ReleaseFast, where asserts vanish).
pub const RunError = strata.btree.tree.InsertError || strata.btree.tree.CreateError || error{
    /// A key the fixture inserted was not found.
    KeyMissing,
    /// A value had a length other than `value_len`.
    ValueSizeMismatch,
    /// A tree evicted a page or holds more pages than its pool has frames: the figure would
    /// include file reads, not just pool hits.
    TreeOutgrewPool,
    /// An insert kernel ran a second time on one fixture (it builds its own tree).
    AlreadyRun,
};

/// Length of the value storage handed to every tree: far above the inline limit, never used.
const value_buf_len: u32 = 4096;
/// Entries of the pool's op tracker the logged tree uses (`Tree.attach` needs `>= 2 * height + 1`).
const track_len: u32 = 64;
/// Slots of the pending-free list; the benchmarks never delete, so it stays empty.
const frees_len: u32 = 16;
/// The WAL: `segments_max` segments of `segment_bytes_max` bytes bound the logged insert count.
const wal_segments_max: u32 = 8;
const wal_segment_bytes_max: u64 = 1 << 24;

pub const Options = struct {
    /// A power of two in `[header.page_size_min, header.page_size_max]`.
    page_size: u32,
    /// Frames of each of the three pools; also bounds the pages of each tree.
    frames_max: u32,
    /// Keys in the get tree and in the sequential insert; the tree must fit `frames_max`.
    key_count: u32,
    /// Lookups the get kernel performs, in seeded pseudo-random order over `key_count` keys.
    get_count: u32,
    /// Keys of the logged insert; each appends a page image, so `logged_key_count * page_size`
    /// (twice, for splits) must fit the WAL.
    logged_key_count: u32,
    seed: u64,
};

/// One page file, its pool and the tree over them. Built in place: the pool points at `pages`
/// and the tree at the pool, so it must not move. `tree` is set by the kernel that owns the env
/// (the get env's tree is built by `fixture_init`).
const Env = struct {
    pages: PageManager,
    pool: BufferPool,
    tree: Tree,
    frees: [frees_len]Id,
};

/// Owns the scratch directory, three envs, the WAL and the buffers. Built in place by
/// `fixture_init`; must not move. Caches `io` and the parent `parent` for the kernels and the
/// cleanup (a long-lived owning struct, per the kingdom `io` convention).
pub const Fixture = struct {
    io: Io,
    parent: Io.Dir,
    dir: Io.Dir,
    name: [name_len_max]u8,
    name_len: u32,
    options: Options,
    get: Env,
    seq: Env,
    logged: Env,
    writer: Writer,
    track: [track_len]u32,
    value_buf: []u8,
    /// Key indexes the get kernel looks up, in order; `options.get_count` of them.
    get_order: []u32,
    seq_used: bool,
    logged_used: bool,
};

pub fn key_encode(key: *[key_len]u8, index: u32) void {
    assert(index < std.math.maxInt(u32));
    std.mem.writeInt(u64, key, index, .big);
    assert(std.mem.readInt(u64, key, .big) == index);
}

pub fn value_encode(value: *[value_len]u8, index: u32) void {
    assert(index < std.math.maxInt(u32));
    std.mem.writeInt(u64, value[0..8], index, .little);
    std.mem.writeInt(u64, value[8..16], ~@as(u64, index), .little);
    assert(std.mem.readInt(u64, value[0..8], .little) == index);
}

/// Creates directory `sub_path` in `parent` with the three page files and the WAL in it, and
/// builds the get tree. `sub_path` must not exist yet. On error nothing stays allocated, open or
/// on disk.
pub fn fixture_init(
    fixture: *Fixture,
    gpa: std.mem.Allocator,
    io: Io,
    parent: Io.Dir,
    sub_path: []const u8,
    options: Options,
) !void {
    assert(sub_path.len >= 1);
    assert(sub_path.len <= name_len_max);
    assert(header.page_size_valid(options.page_size));
    assert(options.frames_max >= track_len + 32); // Room for `Tree.attach`'s pin bound.
    assert(options.key_count >= 1);
    assert(options.get_count >= 1);
    assert(options.logged_key_count >= 1);
    assert(options.logged_key_count <= options.key_count);
    const log_bytes = @as(u64, options.logged_key_count) * options.page_size * 2;
    assert(log_bytes <= wal_segments_max * wal_segment_bytes_max);

    try parent.createDir(io, sub_path, .default_dir);
    errdefer dir_delete(io, parent, sub_path);

    const dir = try parent.openDir(io, sub_path, .{ .iterate = true });
    errdefer dir.close(io);

    const value_buf = try gpa.alloc(u8, value_buf_len);
    errdefer gpa.free(value_buf);

    const get_order = try gpa.alloc(u32, options.get_count);
    errdefer gpa.free(get_order);

    get_order_fill(get_order, options);
    fixture.* = .{
        .io = io,
        .parent = parent,
        .dir = dir,
        .name = undefined,
        .name_len = @intCast(sub_path.len),
        .options = options,
        .get = undefined,
        .seq = undefined,
        .logged = undefined,
        .writer = undefined,
        .track = undefined,
        .value_buf = value_buf,
        .get_order = get_order,
        .seq_used = false,
        .logged_used = false,
    };
    @memcpy(fixture.name[0..sub_path.len], sub_path);
    try trees_open(fixture, gpa);
}

/// Opens the three envs and the WAL, and fills the get tree. On error everything is closed.
fn trees_open(fixture: *Fixture, gpa: std.mem.Allocator) !void {
    const io = fixture.io;
    const options = fixture.options;
    assert(fixture.name_len >= 1);
    assert(fixture.value_buf.len == value_buf_len);
    try env_init(&fixture.get, gpa, io, fixture.dir, "get.db", options);
    errdefer env_deinit(&fixture.get, gpa, io);

    const get_tree = &fixture.get.tree;
    try Tree.create(get_tree, io, &fixture.get.pool, &fixture.get.frees, fixture.value_buf);
    var key: [key_len]u8 = undefined;
    var value: [value_len]u8 = undefined;
    for (0..options.key_count) |index| {
        key_encode(&key, @intCast(index));
        value_encode(&value, @intCast(index));
        try get_tree.insert(io, &key, &value);
    }
    try pool_check(&fixture.get.pool);
    try env_init(&fixture.seq, gpa, io, fixture.dir, "seq.db", options);
    errdefer env_deinit(&fixture.seq, gpa, io);

    try env_init(&fixture.logged, gpa, io, fixture.dir, "log.db", options);
    errdefer env_deinit(&fixture.logged, gpa, io);

    try Writer.init(&fixture.writer, io, gpa, fixture.dir, .{
        .segments_max = wal_segments_max,
        .sync_policy = .none,
        .segment_bytes_max = wal_segment_bytes_max,
    });
    assert(fixture.get.pool.pinned_count() == 0);
    assert(fixture.get.pool.stats().evictions == 0);
}

/// The sizing invariant of the file header: the tree evicted nothing and its pages (not counting
/// the file header page) fit the frames, so every access of a kernel is a pool hit.
fn pool_check(pool: *BufferPool) error{TreeOutgrewPool}!void {
    assert(pool.pages.page_count >= 2);
    assert(pool.pinned_count() == 0);
    if (pool.stats().evictions != 0) return error.TreeOutgrewPool;
    if (pool.pages.page_count > pool.frames_max + 1) return error.TreeOutgrewPool;
}

/// Seeded lookup order: `get_order.len` indexes in `[0, key_count)`.
fn get_order_fill(get_order: []u32, options: Options) void {
    assert(get_order.len == options.get_count);
    assert(options.key_count >= 1);
    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    for (get_order) |*index| index.* = random.uintLessThan(u32, options.key_count);
}

fn env_init(
    env: *Env,
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Options,
) !void {
    assert(sub_path.len >= 1);
    assert(options.frames_max >= 1);
    try PageManager.create(&env.pages, io, dir, sub_path, .{
        .page_size = options.page_size,
        // Room for a tree twice the pool, so overflow shows up as evictions (`pool_check`).
        .page_count_max = 2 * options.frames_max + 2,
        .sync_policy = .none,
    });
    errdefer env.pages.close(io);

    try BufferPool.init(&env.pool, gpa, &env.pages, .{
        .frames_max = options.frames_max,
        .page_size = options.page_size,
    });
    env.tree = undefined;
}

/// Drops the pool without writing back (the file is about to be removed) and closes the file.
fn env_deinit(env: *Env, gpa: std.mem.Allocator, io: Io) void {
    assert(env.pool.pinned_count() == 0);
    assert(env.pool.pages == &env.pages);
    env.pool.discardAll();
    env.pool.deinit(gpa);
    env.pages.close(io);
}

/// Frees the pools and the WAL, closes the files and removes the scratch directory. Every
/// pool must be quiescent (no guard held), which every kernel guarantees on return.
pub fn fixture_deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
    assert(fixture.name_len >= 1);
    assert(fixture.get_order.len == fixture.options.get_count);
    fixture.writer.deinit(fixture.io, gpa);
    env_deinit(&fixture.logged, gpa, fixture.io);
    env_deinit(&fixture.seq, gpa, fixture.io);
    env_deinit(&fixture.get, gpa, fixture.io);
    gpa.free(fixture.get_order);
    gpa.free(fixture.value_buf);
    fixture.dir.close(fixture.io);
    dir_delete(fixture.io, fixture.parent, fixture.name[0..fixture.name_len]);
    fixture.* = undefined;
}

/// Best effort: a directory left behind is harmless to the next run, which picks a fresh name,
/// so a failure is reported, not returned.
fn dir_delete(io: Io, parent: Io.Dir, sub_path: []const u8) void {
    assert(sub_path.len >= 1);
    assert(sub_path.len <= name_len_max);
    parent.deleteTree(io, sub_path) catch |err| {
        std.log.err("bench: cannot remove {s}: {t}", .{ sub_path, err });
    };
}

/// `get_count` lookups on the hot get tree, each a pool hit down the tree.
pub fn get_run(fixture: *Fixture) RunError!Result {
    assert(fixture.get_order.len == fixture.options.get_count);
    assert(fixture.get.pool.pinned_count() == 0);
    const tree = &fixture.get.tree;
    var key: [key_len]u8 = undefined;
    var sink: u64 = 0;
    for (fixture.get_order) |index| {
        key_encode(&key, index);
        const found = try tree.get(fixture.io, &key);
        const value = found orelse return error.KeyMissing;
        if (value.len != value_len) return error.ValueSizeMismatch;
        sink +%= std.mem.readInt(u64, value[0..8], .little);
    }
    std.mem.doNotOptimizeAway(sink);
    const operation_count: u64 = fixture.get_order.len;
    return .{
        .operation_count = operation_count,
        .byte_count = operation_count * (key_len + value_len),
        .sink = sink,
    };
}

/// Creates an empty tree and inserts `key_count` ascending keys, unlogged. Runs once.
pub fn insert_seq_run(fixture: *Fixture) RunError!Result {
    assert(fixture.seq.pool.pinned_count() == 0);
    assert(fixture.options.key_count >= 1);
    if (fixture.seq_used) return error.AlreadyRun;
    fixture.seq_used = true;
    const env = &fixture.seq;
    try Tree.create(&env.tree, fixture.io, &env.pool, &env.frees, fixture.value_buf);
    return insert_run(&env.tree, fixture.io, fixture.options.key_count);
}

/// The same inserts through `Tree.attach`: each one appends a `page_images` frame. Runs once.
pub fn insert_logged_run(fixture: *Fixture) RunError!Result {
    assert(fixture.logged.pool.pinned_count() == 0);
    assert(fixture.options.logged_key_count >= 1);
    if (fixture.logged_used) return error.AlreadyRun;
    fixture.logged_used = true;
    const env = &fixture.logged;
    try Tree.create(&env.tree, fixture.io, &env.pool, &env.frees, fixture.value_buf);
    env.tree.attach(&fixture.writer, &fixture.track);
    return insert_run(&env.tree, fixture.io, fixture.options.logged_key_count);
}

/// Inserts keys `0..key_count` in order. The sink is the page count the tree reached.
fn insert_run(tree: *Tree, io: Io, key_count: u32) RunError!Result {
    assert(key_count >= 1);
    assert(tree.pool.pinned_count() == 0);
    var key: [key_len]u8 = undefined;
    var value: [value_len]u8 = undefined;
    for (0..key_count) |index| {
        key_encode(&key, @intCast(index));
        value_encode(&value, @intCast(index));
        try tree.insert(io, &key, &value);
    }
    try pool_check(tree.pool);
    const page_count: u64 = tree.pool.pages.page_count;
    std.mem.doNotOptimizeAway(page_count);
    return .{
        .operation_count = key_count,
        .byte_count = @as(u64, key_count) * (key_len + value_len),
        .sink = page_count,
    };
}

// -- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// Tiny sizes for the harness's own tests; also used by `main.zig`'s fixture tests.
pub const options_test: Options = .{
    .page_size = 512,
    .frames_max = 256,
    .key_count = 1000,
    .get_count = 3000,
    .logged_key_count = 400,
    .seed = 7,
};

fn test_fixture_open(fixture: *Fixture, tmp: *testing.TmpDir) !void {
    assert(options_test.logged_key_count <= options_test.key_count);
    assert(options_test.get_count >= 1);
    try fixture_init(fixture, testing.allocator, testing.io, tmp.dir, "tree_bench", options_test);
}

/// Every key `0..count` reads back with its value, an absent key is null, and the tree validates.
fn test_tree_expect(tree: *Tree, count: u32) !void {
    assert(count >= 1);
    assert(tree.pool.pinned_count() == 0);
    var key: [key_len]u8 = undefined;
    var value: [value_len]u8 = undefined;
    for (0..count) |index| {
        key_encode(&key, @intCast(index));
        value_encode(&value, @intCast(index));
        const found = try tree.get(testing.io, &key);
        try testing.expect(found != null);
        try testing.expectEqualSlices(u8, &value, found.?);
    }
    key_encode(&key, count);
    try testing.expectEqual(@as(?[]const u8, null), try tree.get(testing.io, &key));
    try tree.validate(testing.io, testing.allocator);
    try testing.expectEqual(@as(u32, 0), tree.pool.pinned_count());
}

test "btree_get: every lookup hits and the sink is the sum of the looked-up indexes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const before = fixture.get.pool.stats();
    const result = try get_run(&fixture);
    const after = fixture.get.pool.stats();

    const operations: u64 = options_test.get_count;
    var index_sum: u64 = 0;
    for (fixture.get_order) |index| index_sum += index;
    try testing.expectEqual(operations, result.operation_count);
    try testing.expectEqual(operations * (key_len + value_len), result.byte_count);
    try testing.expectEqual(index_sum, result.sink);
    try testing.expect(after.hits >= before.hits + operations);
    try testing.expectEqual(before.misses, after.misses);
    try testing.expectEqual(@as(u64, 0), after.evictions);
    try testing.expectEqual(@as(u32, 0), fixture.get.pool.pinned_count());
}

test "fixture builds a valid get tree and a reproducible seeded lookup order" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first: Fixture = undefined;
    try test_fixture_open(&first, &tmp);
    defer fixture_deinit(&first, testing.allocator);

    var second: Fixture = undefined;
    var options_other = options_test;
    options_other.seed = 8;
    try fixture_init(
        &second,
        testing.allocator,
        testing.io,
        tmp.dir,
        "other_bench",
        options_other,
    );
    defer fixture_deinit(&second, testing.allocator);

    try test_tree_expect(&first.get.tree, options_test.key_count);
    try testing.expect(first.get.pages.page_count > 3); // More than a root: the tree has height.
    try testing.expect(first.get_order.len == options_test.get_count);
    for (first.get_order) |index| try testing.expect(index < options_test.key_count);
    try testing.expect(!std.mem.eql(u32, first.get_order, second.get_order));
}

test "btree_insert_seq: builds a valid tree in a pool that evicts nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const result = try insert_seq_run(&fixture);

    const operations: u64 = options_test.key_count;
    try testing.expectEqual(operations, result.operation_count);
    try testing.expectEqual(operations * (key_len + value_len), result.byte_count);
    try testing.expectEqual(@as(u64, fixture.seq.pages.page_count), result.sink);
    try testing.expect(result.sink > 3);
    try testing.expectEqual(@as(u64, 0), fixture.seq.pool.stats().evictions);
    try testing.expectEqual(@as(u64, 0), fixture.seq.pool.stats().writebacks);
    try testing.expect(fixture.seq.tree.writer == null);
    try test_tree_expect(&fixture.seq.tree, options_test.key_count);
}

test "btree_insert_logged: builds a valid tree and appends a page image per insert" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const lsn_before = fixture.writer.next_lsn;
    const result = try insert_logged_run(&fixture);

    const operations: u64 = options_test.logged_key_count;
    try testing.expectEqual(operations, result.operation_count);
    try testing.expectEqual(operations * (key_len + value_len), result.byte_count);
    try testing.expectEqual(@as(u64, fixture.logged.pages.page_count), result.sink);
    try testing.expect(fixture.logged.tree.writer != null);
    try testing.expect(!fixture.logged.tree.failed);
    try testing.expectEqual(@as(u64, 0), fixture.logged.pool.stats().evictions);
    // One frame per insert, each carrying at least the leaf's whole page.
    const log_bytes = fixture.writer.next_lsn - lsn_before;
    try testing.expect(log_bytes >= operations * options_test.page_size);
    try test_tree_expect(&fixture.logged.tree, options_test.logged_key_count);
}

test "both insert kernels run on one fixture and mark themselves used" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    _ = try insert_seq_run(&fixture);
    _ = try insert_logged_run(&fixture);
    try testing.expect(fixture.seq_used);
    try testing.expect(fixture.logged_used);
    try testing.expectError(error.AlreadyRun, insert_seq_run(&fixture));
    try testing.expectError(error.AlreadyRun, insert_logged_run(&fixture));
}

test "get_run reports a missing key as KeyMissing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    fixture.get_order[0] = options_test.key_count; // One past the last inserted key.
    try testing.expectError(error.KeyMissing, get_run(&fixture));
    try testing.expectEqual(@as(u32, 0), fixture.get.pool.pinned_count());
}

test "get_run reports a value of the wrong length as ValueSizeMismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    var key: [key_len]u8 = undefined;
    key_encode(&key, fixture.get_order[0]);
    const short = [_]u8{ 1, 2, 3 };
    try fixture.get.tree.insert(testing.io, &key, &short);
    try testing.expectError(error.ValueSizeMismatch, get_run(&fixture));
    try testing.expectEqual(@as(u32, 0), fixture.get.pool.pinned_count());
}

test "get_order_fill: the same seed and options give the same order" {
    const gpa = testing.allocator;
    const first = try gpa.alloc(u32, options_test.get_count);
    defer gpa.free(first);

    const second = try gpa.alloc(u32, options_test.get_count);
    defer gpa.free(second);

    get_order_fill(first, options_test);
    get_order_fill(second, options_test);
    try testing.expectEqualSlices(u32, first, second);
    for (first) |index| try testing.expect(index < options_test.key_count);
}

test "a tree that outgrows its pool is TreeOutgrewPool, at init and in the insert kernel" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var tiny = options_test;
    tiny.frames_max = track_len + 32; // The smallest legal pool: the 1000-key tree needs more.
    var fixture: Fixture = undefined;
    try testing.expectError(
        error.TreeOutgrewPool,
        fixture_init(&fixture, testing.allocator, testing.io, tmp.dir, "tiny", tiny),
    );
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(testing.io, "tiny", .{}));

    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    fixture.options.key_count = 2500; // Built into a pool of 256 frames, which it outgrows.
    try testing.expectError(error.TreeOutgrewPool, insert_seq_run(&fixture));
}

test "fixture_init frees and removes everything when any allocation fails" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fail_index_max: usize = 64;
    var fail_index: usize = 0;
    while (fail_index < fail_index_max) : (fail_index += 1) {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const gpa = failing.allocator();
        var fixture: Fixture = undefined;
        if (fixture_init(&fixture, gpa, testing.io, tmp.dir, "tree_bench", options_test)) |_| {
            fixture_deinit(&fixture, gpa);
            break; // Past the last allocation: the sweep covered every failure point.
        } else |err| switch (err) {
            error.OutOfMemory => {},
            else => return err,
        }
        try testing.expectError(
            error.FileNotFound,
            tmp.dir.openDir(testing.io, "tree_bench", .{}),
        );
    } else return error.TestUnexpectedResult; // The sweep bound is too small.
    try testing.expect(fail_index >= 3); // At least value_buf, order and a pool were allocated.
}

test "fixture_deinit removes its directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    var present = try tmp.dir.openDir(testing.io, "tree_bench", .{});
    present.close(testing.io);
    fixture_deinit(&fixture, testing.allocator);

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.openDir(testing.io, "tree_bench", .{}),
    );
}

test "fixture_init refuses an existing directory and leaves it alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first: Fixture = undefined;
    try test_fixture_open(&first, &tmp);
    defer fixture_deinit(&first, testing.allocator);

    var second: Fixture = undefined;
    try testing.expectError(error.PathAlreadyExists, test_fixture_open(&second, &tmp));
    const present = try tmp.dir.statFile(testing.io, "tree_bench/get.db", .{});
    try testing.expect(present.size > 0);
}
