//! Buffer pool benchmarks (plan 003 item 10): `pool_hit` and `pool_miss_evict`, both over a real
//! file through `PageManager` and a CLOCK `BufferPool`, with one fetch + release as the "op".
//!
//! Sketch: `fixture_init` creates a scratch file of `miss_page_count` pages, each filled with one
//! byte value, and builds two pools over it. The hit pool has `frames_max` frames and is warmed
//! with pages `1..=frames_max`, so the timed loop (those pages, `hit_pass_count` times) never
//! reads the file. The miss pool has the same size but is pre-filled with the last `frames_max`
//! pages; the timed loop walks all `miss_page_count` pages in order, `miss_pass_count` times.
//! The working set is larger than the pool, so CLOCK degenerates to FIFO and every fetch misses
//! and evicts a clean frame (no write-back, hence no dirty page ever exists). The miss path
//! therefore measures one `pread` of a page plus checksum verification, with the file in the OS
//! page cache. `byte_count` is `operation_count * page_size`.
//! Allocation: the fixture owns everything it needs and allocates it in `fixture_init`; the
//! kernels allocate nothing. `sink` sums the last byte of every page fetched, so the fetches
//! cannot be elided. The scratch file is removed by `fixture_deinit`.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const strata = @import("strata");
const Result = @import("main.zig").Result;

const BufferPool = strata.cache.BufferPool;
const FetchError = strata.cache.FetchError;
const header = strata.page.header;
const Id = strata.page.Id;
const PageManager = strata.page.manager.PageManager;

/// Longest scratch file name the fixture remembers for its cleanup.
pub const name_len_max: u32 = 64;

/// Page type byte of the benchmark pages: 128..255 belong to consumers (page `header`).
const page_type_bench: header.Type = @enumFromInt(130);

pub const Options = struct {
    /// A power of two in `[header.page_size_min, header.page_size_max]`.
    page_size: u32,
    /// Frames in each of the two pools; the hit working set is exactly this many pages.
    frames_max: u32,
    /// Pages in the miss working set; at least twice `frames_max` so a cyclic walk never hits.
    miss_page_count: u32,
    /// Walks over the hit working set.
    hit_pass_count: u32,
    /// Walks over the miss working set.
    miss_pass_count: u32,
};

/// Owns the scratch file, the manager and both pools. Built in place by `fixture_init` and must
/// not move afterwards: the pools point at `pages`. Caches `io` and `dir` for the kernels and
/// for removing the file (a long-lived owning struct, per the kingdom `io` convention).
pub const Fixture = struct {
    io: Io,
    dir: Io.Dir,
    name: [name_len_max]u8,
    name_len: u32,
    options: Options,
    pages: PageManager,
    hit_pool: BufferPool,
    miss_pool: BufferPool,
};

/// The byte every payload byte of page `raw` holds, a function of the page id alone.
pub fn payload_byte(raw: u32) u8 {
    assert(raw >= 1);
    assert(raw < std.math.maxInt(u32) / 37);
    return @truncate(raw * 37 + 1);
}

fn id_of(raw: u32) Id {
    assert(raw >= 1);
    assert(raw < std.math.maxInt(u32));
    return @enumFromInt(raw);
}

/// Creates `sub_path` in `dir`, fills it with `options.miss_page_count` pages, opens both pools
/// and warms them (see the file header). `sub_path` must not exist yet. On error nothing stays
/// allocated, open or on disk.
pub fn fixture_init(
    fixture: *Fixture,
    gpa: std.mem.Allocator,
    io: Io,
    dir: Io.Dir,
    sub_path: []const u8,
    options: Options,
) !void {
    assert(sub_path.len >= 1);
    assert(sub_path.len <= name_len_max);
    assert(header.page_size_valid(options.page_size));
    assert(options.frames_max >= 1);
    assert(options.miss_page_count >= 2 * options.frames_max);
    assert(options.hit_pass_count >= 1);
    assert(options.miss_pass_count >= 1);
    try PageManager.create(&fixture.pages, io, dir, sub_path, .{
        .page_size = options.page_size,
        .page_count_max = options.miss_page_count + 1,
        .sync_policy = .none,
    });
    errdefer file_delete(io, dir, sub_path);

    errdefer fixture.pages.close(io); // Runs first: the file is closed, then removed.

    try pages_fill(&fixture.pages, gpa, io, options);
    const pool_options: strata.cache.Options = .{
        .frames_max = options.frames_max,
        .page_size = options.page_size,
    };
    try BufferPool.init(&fixture.hit_pool, gpa, &fixture.pages, pool_options);
    errdefer fixture.hit_pool.deinit(gpa);

    try BufferPool.init(&fixture.miss_pool, gpa, &fixture.pages, pool_options);
    errdefer fixture.miss_pool.deinit(gpa);

    try pool_warm(&fixture.hit_pool, io, 1, options.frames_max);
    try pool_warm(
        &fixture.miss_pool,
        io,
        options.miss_page_count - options.frames_max + 1,
        options.frames_max,
    );
    fixture.io = io;
    fixture.dir = dir;
    fixture.options = options;
    fixture.name_len = @intCast(sub_path.len);
    @memcpy(fixture.name[0..sub_path.len], sub_path);
}

/// Frees the pools, closes the manager and removes the scratch file. Both pools must be
/// quiescent (no guard held), which every kernel guarantees on return.
pub fn fixture_deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
    assert(fixture.name_len >= 1);
    assert(fixture.pages.page_count == fixture.options.miss_page_count + 1);
    fixture.miss_pool.deinit(gpa);
    fixture.hit_pool.deinit(gpa);
    fixture.pages.close(fixture.io);
    file_delete(fixture.io, fixture.dir, fixture.name[0..fixture.name_len]);
    fixture.* = undefined;
}

/// Best effort: a file left behind is ignored by git (`*.db`) and harmless to the next run,
/// which picks a fresh name, so a failure is reported, not returned.
fn file_delete(io: Io, dir: Io.Dir, sub_path: []const u8) void {
    assert(sub_path.len >= 1);
    assert(sub_path.len <= name_len_max);
    dir.deleteFile(io, sub_path) catch |err| {
        std.log.err("bench: cannot remove {s}: {t}", .{ sub_path, err });
    };
}

/// Appends pages `1..=miss_page_count`, page `n` filled with `payload_byte(n)` and lsn `n`.
fn pages_fill(pm: *PageManager, gpa: std.mem.Allocator, io: Io, options: Options) !void {
    assert(pm.page_count == 1);
    assert(pm.page_size == options.page_size);
    const buf = try gpa.alloc(u8, options.page_size);
    defer gpa.free(buf);

    for (1..options.miss_page_count + 1) |index| {
        const raw: u32 = @intCast(index);
        const id = try pm.allocate(io);
        assert(id == id_of(raw));
        @memset(buf, payload_byte(raw));
        try pm.write(io, id, buf, .{ .page_type = page_type_bench, .lsn = raw });
    }
    assert(pm.page_count == options.miss_page_count + 1);
}

/// Fetches and releases pages `first..first + count`, so the pool holds them afterwards.
fn pool_warm(pool: *BufferPool, io: Io, first: u32, count: u32) FetchError!void {
    assert(first >= 1);
    assert(count >= 1);
    assert(count <= pool.frames_max);
    for (0..count) |offset| {
        var guard = try pool.fetch(io, id_of(first + @as(u32, @intCast(offset))));
        guard.release();
    }
    assert(pool.pinned_count() == 0);
}

/// `hit_pass_count` walks over the `frames_max` resident pages: every fetch is a hit.
pub fn hit_run(fixture: *Fixture) FetchError!Result {
    assert(fixture.options.hit_pass_count >= 1);
    assert(fixture.hit_pool.empty_count == 0);
    return cycle_run(
        &fixture.hit_pool,
        fixture.io,
        fixture.options.frames_max,
        fixture.options.hit_pass_count,
    );
}

/// `miss_pass_count` walks over `miss_page_count` pages through a pool of at most half that
/// many frames: every fetch misses and evicts a clean frame.
pub fn miss_run(fixture: *Fixture) FetchError!Result {
    assert(fixture.options.miss_pass_count >= 1);
    assert(fixture.miss_pool.empty_count == 0);
    return cycle_run(
        &fixture.miss_pool,
        fixture.io,
        fixture.options.miss_page_count,
        fixture.options.miss_pass_count,
    );
}

/// Fetches pages `1..=page_count` in order, `pass_count` times, releasing each at once.
fn cycle_run(pool: *BufferPool, io: Io, page_count: u32, pass_count: u32) FetchError!Result {
    assert(page_count >= 1);
    assert(pass_count >= 1);
    assert(page_count < pool.pages.page_count);
    assert(pool.pinned_count() == 0);
    var sink: u64 = 0;
    for (0..pass_count) |_| {
        for (1..@as(usize, page_count) + 1) |raw| {
            var guard = try pool.fetch(io, id_of(@intCast(raw)));
            sink +%= guard.bytes()[pool.page_size - 1];
            guard.release();
        }
    }
    std.mem.doNotOptimizeAway(sink);
    const operation_count = @as(u64, pass_count) * page_count;
    return .{
        .operation_count = operation_count,
        .byte_count = operation_count * pool.page_size,
        .sink = sink,
    };
}

// -- tests ---------------------------------------------------------------------------------

const testing = std.testing;

/// Tiny sizes for the harness's own tests; also used by `main.zig`'s fixture tests.
pub const options_test: Options = .{
    .page_size = 512,
    .frames_max = 4,
    .miss_page_count = 16,
    .hit_pass_count = 3,
    .miss_pass_count = 2,
};

fn test_fixture_open(fixture: *Fixture, tmp: *testing.TmpDir) !void {
    const gpa = testing.allocator;
    try fixture_init(fixture, gpa, testing.io, tmp.dir, "pool_bench.db", options_test);
}

test "pool_hit: every timed fetch hits after warm-up and the counts add up" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const before = fixture.hit_pool.stats();
    try testing.expectEqual(@as(u64, 0), before.hits);
    try testing.expectEqual(@as(u64, options_test.frames_max), before.misses);
    const operations: u64 = options_test.hit_pass_count * options_test.frames_max;
    const result = try hit_run(&fixture);
    const after = fixture.hit_pool.stats();

    try testing.expectEqual(operations, result.operation_count);
    try testing.expectEqual(operations * options_test.page_size, result.byte_count);
    try testing.expectEqual(before.hits + operations, after.hits);
    try testing.expectEqual(before.misses, after.misses);
    try testing.expectEqual(before.evictions, after.evictions);
    var byte_sum: u64 = 0;
    for (1..options_test.frames_max + 1) |raw| byte_sum += payload_byte(@intCast(raw));
    try testing.expectEqual(byte_sum * options_test.hit_pass_count, result.sink);
    try testing.expectEqual(@as(u32, 0), fixture.hit_pool.pinned_count());
}

test "pool_miss_evict: every timed fetch misses and evicts a clean frame, run after run" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const operations: u64 = options_test.miss_pass_count * options_test.miss_page_count;
    var byte_sum: u64 = 0;
    for (1..options_test.miss_page_count + 1) |raw| byte_sum += payload_byte(@intCast(raw));
    for (0..2) |_| {
        const before = fixture.miss_pool.stats();
        const result = try miss_run(&fixture);
        const after = fixture.miss_pool.stats();

        try testing.expectEqual(operations, result.operation_count);
        try testing.expectEqual(operations * options_test.page_size, result.byte_count);
        try testing.expectEqual(before.hits, after.hits);
        try testing.expectEqual(before.misses + operations, after.misses);
        try testing.expectEqual(before.evictions + operations, after.evictions);
        try testing.expectEqual(before.writebacks, after.writebacks);
        try testing.expectEqual(byte_sum * options_test.miss_pass_count, result.sink);
    }
    try testing.expectEqual(@as(u32, 0), fixture.miss_pool.pinned_count());
}

test "fixture pre-fills the miss pool so the first timed fetch already evicts" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    defer fixture_deinit(&fixture, testing.allocator);

    const stats = fixture.miss_pool.stats();
    try testing.expectEqual(@as(u64, options_test.frames_max), stats.misses);
    try testing.expectEqual(@as(u64, 0), stats.evictions);
    try testing.expectEqual(@as(u32, 0), fixture.miss_pool.empty_count);
    try testing.expectEqual(options_test.miss_page_count + 1, fixture.pages.page_count);
}

test "fixture_deinit removes its file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_open(&fixture, &tmp);
    const present = try tmp.dir.statFile(testing.io, "pool_bench.db", .{});
    try testing.expect(present.size > 0);
    fixture_deinit(&fixture, testing.allocator);

    try testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(testing.io, "pool_bench.db", .{}),
    );
}

test "fixture_init refuses an existing file and leaves it alone" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var first: Fixture = undefined;
    try test_fixture_open(&first, &tmp);
    defer fixture_deinit(&first, testing.allocator);

    var second: Fixture = undefined;
    try testing.expectError(error.WouldBlock, test_fixture_open(&second, &tmp));
    const present = try tmp.dir.statFile(testing.io, "pool_bench.db", .{});
    try testing.expectEqual(
        @as(u64, options_test.page_size) * (options_test.miss_page_count + 1),
        present.size,
    );
}
