//! strata benchmark harness. Run: `zig build bench -- [filter]` (the step builds ReleaseFast).
//!
//! Baseline: the codec layer — CRC32C (software, and hardware when the target CPU has the
//! instruction), xxhash64, and varint encode/decode — the CLOCK buffer pool (`pool.zig`) and the
//! B+Tree (`btree.zig`).
//! Each benchmark prints one line, `name  GB/s  ops/s  ns/op`, so results can be pasted into
//! docs/plans/000-inherited.md. An "op" is one kernel call: one buffer pass for the hashes, one
//! value for varint, one fetch + release of a 4 KiB page for the pool, one `get` or `insert`
//! for the tree.
//!
//! Sketch: the hashes stream a 1 MiB buffer (fits L2, so this measures the kernel, not DRAM)
//! 256 times; varint walks 64 Ki values 256 times. `pool_hit` re-fetches 256 resident pages;
//! `pool_miss_evict` walks 1024 pages through a 256-frame pool so each fetch reads the page
//! from a scratch file (in the OS page cache) and evicts a clean frame (see `pool.zig`).
//! `btree_get` looks up 1 Mi seeded-random keys of a 100k-key tree, `btree_insert_seq` builds
//! such a tree by ascending inserts and `btree_insert_logged` inserts 8192 keys with a WAL
//! attached; all three run in pools that hold the whole tree (see `btree.zig`). Wall
//! time per benchmark is about a second or less on a 2020s laptop. Inputs come from a seeded
//! PRNG, so a run is reproducible from the seed; only the clock is non-deterministic, and it
//! is read once around each kernel.
//! Allocation: the fixture is allocated once in `main` and freed there; kernels do not allocate.
//! The pool and tree benchmarks need files: `main` creates `strata-bench-<random>.db` and the
//! directory `strata-bench-<random>.db.tree` in the cwd and removes both on exit.

const std = @import("std");
const assert = std.debug.assert;
const strata = @import("strata");
const codec = strata.codec;
const pool_bench = @import("pool.zig");
const btree_bench = @import("btree.zig");

/// Everything a run needs, spelled out so no knob hides in a default (Tiger Style 1.15).
const Options = struct {
    seed: u64,
    /// Bytes hashed per pass; at least one so a pass can mutate its first byte.
    buffer_size: u32,
    /// Values encoded or decoded per pass.
    value_count: u32,
    /// Times each kernel repeats over its input.
    pass_count: u32,
    pool: pool_bench.Options,
    btree: btree_bench.Options,
};

const options_baseline: Options = .{
    .seed = 0x5742_A7A0_5EED,
    .buffer_size = 1 << 20,
    .value_count = 1 << 16,
    .pass_count = 256,
    .pool = .{
        .page_size = 4096,
        .frames_max = 256,
        .miss_page_count = 1024,
        .hit_pass_count = 262144,
        .miss_pass_count = 1024,
    },
    .btree = .{
        .page_size = 4096,
        .frames_max = 4096,
        .key_count = 100_000,
        .get_count = 1 << 20,
        .logged_key_count = 8192,
        .seed = 0x5742_A7A0_5EED,
    },
};

const RunError = codec.varint.EncodeError || codec.varint.DecodeError ||
    strata.cache.FetchError || btree_bench.RunError || error{
    /// The decoded stream did not end where the encoder said it did.
    StreamLengthMismatch,
};

/// What one kernel did; `sink` consumes the computed values so the optimizer cannot drop them
/// (for varint encode it is the byte count, the only value that kernel computes).
pub const Result = struct {
    operation_count: u64,
    byte_count: u64,
    sink: u64,
};

const Bench = struct {
    name: []const u8,
    run: *const fn (*Fixture) RunError!Result,
};

/// Seeded inputs shared by all kernels. Owns its three slices and the pool fixture (which owns
/// a scratch file); `fixture_deinit` frees them. Built in place: it must not move.
const Fixture = struct {
    pool: pool_bench.Fixture,
    btree: btree_bench.Fixture,
    pass_count: u32,
    bytes: []u8,
    values: []u64,
    /// Every value, varint-encoded back to back; `encoded_len` bytes are meaningful.
    encoded: []u8,
    encoded_len: u32,
    /// Encode target, as large as `encoded`.
    scratch: []u8,
};

const benches_always = [_]Bench{
    .{ .name = "crc32c_software", .run = Crc32cKernelType(.software).run },
    .{ .name = "xxhash64", .run = xxhash64_run },
    .{ .name = "varint_encode", .run = varint_encode_run },
    .{ .name = "varint_decode", .run = varint_decode_run },
    .{ .name = "pool_hit", .run = pool_hit_run },
    .{ .name = "pool_miss_evict", .run = pool_miss_evict_run },
    .{ .name = "btree_get", .run = btree_get_run },
    .{ .name = "btree_insert_seq", .run = btree_insert_seq_run },
    .{ .name = "btree_insert_logged", .run = btree_insert_logged_run },
};

const benches_hardware = [_]Bench{
    .{ .name = "crc32c_hardware", .run = Crc32cKernelType(.hardware).run },
};

const benches = if (codec.crc32c.hardware_available)
    benches_hardware ++ benches_always
else
    benches_always;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    const raw_args = try init.minimal.args.toSlice(init.arena.allocator());
    const filter: ?[]const u8 = if (raw_args.len > 1) raw_args[1] else null;

    var name_buffer: [pool_bench.name_len_max]u8 = undefined;
    const pool_name = try pool_file_name(io, &name_buffer);
    var fixture: Fixture = undefined;
    try fixture_init(&fixture, gpa, io, std.Io.Dir.cwd(), pool_name, options_baseline);
    defer fixture_deinit(&fixture, gpa);

    var buffer: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const out = &file_writer.interface;

    var ran_count: u32 = 0;
    for (benches) |bench| {
        if (!filter_matches(bench.name, filter)) continue;
        const start: std.Io.Clock.Timestamp = .now(io, .awake);
        const result = try bench.run(&fixture);
        const elapsed = start.untilNow(io);
        const elapsed_ns: u64 = @intCast(elapsed.raw.nanoseconds);
        std.mem.doNotOptimizeAway(result.sink);
        try report_write(out, bench.name, result, elapsed_ns);
        try out.flush();
        ran_count += 1;
    }
    if (!codec.crc32c.hardware_available and filter_matches("crc32c_hardware", filter)) {
        try out.print("{s:<20} skipped: target CPU has no CRC32C instruction\n", .{
            "crc32c_hardware",
        });
        ran_count += 1;
    }
    if (ran_count == 0) try out.print("no benchmark name contains the filter\n", .{});
    try out.flush();
}

fn filter_matches(name: []const u8, filter: ?[]const u8) bool {
    assert(name.len > 0);
    const text = filter orelse return true;
    const found = std.mem.find(u8, name, text) != null;
    if (text.len == 0) assert(found);
    return found;
}

/// Writes `name  G.mmm GB/s  ops/s  ns/op`. Integer math only; a zero elapsed time (clock
/// granularity) prints zero rates rather than dividing by zero. Precondition: the counts are
/// small enough that scaling them by 1e9 (operations) or 1000 (bytes) fits `u64`.
fn report_write(out: *std.Io.Writer, name: []const u8, result: Result, elapsed_ns: u64) !void {
    assert(name.len > 0);
    assert(result.operation_count > 0);
    assert(result.operation_count <= std.math.maxInt(u64) / std.time.ns_per_s);
    assert(result.byte_count <= std.math.maxInt(u64) / 1000);
    const operations_per_s: u64 = if (elapsed_ns == 0) 0 else @divFloor(
        result.operation_count * std.time.ns_per_s,
        elapsed_ns,
    );
    // Bytes per nanosecond is GB/s; scaling by 1000 keeps three decimals in integers.
    const mb_per_s: u64 = if (elapsed_ns == 0) 0 else @divFloor(
        result.byte_count * 1000,
        elapsed_ns,
    );
    const ns_per_operation = @divFloor(elapsed_ns, result.operation_count);
    try out.print("{s:<20} {d:>4}.{d:0>3} GB/s {d:>12} ops/s {d:>10} ns/op\n", .{
        name,
        @divFloor(mb_per_s, 1000),
        mb_per_s % 1000,
        operations_per_s,
        ns_per_operation,
    });
}

/// A random scratch file name, unique per run: `strata-bench-<16 hex digits>.db`.
fn pool_file_name(io: std.Io, buffer: []u8) ![]u8 {
    assert(buffer.len >= pool_bench.name_len_max);
    assert(pool_bench.name_len_max >= "strata-bench-".len + 16 + ".db".len);
    var random: [8]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.bufPrint(buffer, "strata-bench-{x:0>16}.db", .{
        std.mem.readInt(u64, &random, .little),
    });
    assert(name.len == "strata-bench-".len + 16 + ".db".len);
    return name;
}

fn fixture_init(
    fixture: *Fixture,
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    pool_sub_path: []const u8,
    options: Options,
) !void {
    assert(options.buffer_size >= 1);
    assert(options.value_count >= 4); // Room for the pinned boundary values.
    assert(options.value_count <= std.math.maxInt(u32) / codec.varint.encoded_size_max);
    assert(options.pass_count >= 1);

    const bytes = try gpa.alloc(u8, options.buffer_size);
    errdefer gpa.free(bytes);

    const values = try gpa.alloc(u64, options.value_count);
    errdefer gpa.free(values);

    const encoded = try gpa.alloc(u8, options.value_count * codec.varint.encoded_size_max);
    errdefer gpa.free(encoded);

    const scratch = try gpa.alloc(u8, encoded.len);
    errdefer gpa.free(scratch);

    var prng = std.Random.DefaultPrng.init(options.seed);
    const random = prng.random();
    random.bytes(bytes);
    @memset(encoded, 0);
    @memset(scratch, 0);
    // A random bit width per value gives sizes 1...9 about 11% each; a ten-byte encoding needs
    // the top bit set, so the boundary values are pinned in the last slots to guarantee 1, 2 and
    // 10 byte encodings are always present.
    for (values) |*value| {
        const width = random.intRangeAtMost(u32, 1, 64);
        value.* = random.int(u64) >> @intCast(64 - width);
    }
    const boundaries = [_]u64{ 0, 127, 128, std.math.maxInt(u64) };
    assert(values.len >= boundaries.len);
    @memcpy(values[values.len - boundaries.len ..], &boundaries);
    var encoded_len: u32 = 0;
    for (values) |value| encoded_len += try codec.varint.encode(encoded[encoded_len..], value);
    assert(encoded_len >= options.value_count);

    fixture.* = .{
        .pool = undefined, // Built in place below: the pools point at the manager inside it.
        .btree = undefined, // Likewise.
        .pass_count = options.pass_count,
        .bytes = bytes,
        .values = values,
        .encoded = encoded,
        .encoded_len = encoded_len,
        .scratch = scratch,
    };
    try pool_bench.fixture_init(&fixture.pool, gpa, io, dir, pool_sub_path, options.pool);
    errdefer pool_bench.fixture_deinit(&fixture.pool, gpa);

    // The B+Tree scratch directory sits next to the pool file: `<pool file name>.tree`.
    var tree_name_buffer: [btree_bench.name_len_max]u8 = undefined;
    const tree_name = try std.fmt.bufPrint(&tree_name_buffer, "{s}.tree", .{pool_sub_path});
    try btree_bench.fixture_init(&fixture.btree, gpa, io, dir, tree_name, options.btree);
}

fn fixture_deinit(fixture: *Fixture, gpa: std.mem.Allocator) void {
    assert(fixture.scratch.len == fixture.encoded.len);
    assert(fixture.encoded_len <= fixture.encoded.len);
    btree_bench.fixture_deinit(&fixture.btree, gpa);
    pool_bench.fixture_deinit(&fixture.pool, gpa);
    gpa.free(fixture.scratch);
    gpa.free(fixture.encoded);
    gpa.free(fixture.values);
    gpa.free(fixture.bytes);
    fixture.* = undefined;
}

/// CRC32C over the whole buffer, once per pass. The first byte changes every pass so the
/// optimizer cannot hoist the checksum out of the loop.
fn Crc32cKernelType(comptime path: codec.crc32c.Path) type {
    return struct {
        fn run(fixture: *Fixture) RunError!Result {
            assert(fixture.pass_count >= 1);
            assert(fixture.bytes.len >= 1);
            var sink: u64 = 0;
            for (0..fixture.pass_count) |pass| {
                fixture.bytes[0] = @truncate(pass);
                sink +%= codec.crc32c.checksum_path(path, fixture.bytes);
            }
            std.mem.doNotOptimizeAway(sink);
            return .{
                .operation_count = fixture.pass_count,
                .byte_count = @as(u64, fixture.pass_count) * fixture.bytes.len,
                .sink = sink,
            };
        }
    };
}

/// xxhash64 (seed 0) over the whole buffer, once per pass; same hoisting guard as CRC32C.
fn xxhash64_run(fixture: *Fixture) RunError!Result {
    assert(fixture.pass_count >= 1);
    assert(fixture.bytes.len >= 1);
    var sink: u64 = 0;
    for (0..fixture.pass_count) |pass| {
        fixture.bytes[0] = @truncate(pass);
        sink +%= codec.xxhash.hash(fixture.bytes, 0);
    }
    std.mem.doNotOptimizeAway(sink);
    return .{
        .operation_count = fixture.pass_count,
        .byte_count = @as(u64, fixture.pass_count) * fixture.bytes.len,
        .sink = sink,
    };
}

/// Encodes every value into `scratch`, once per pass. `values[0]` changes every pass so the
/// optimizer cannot hoist the encoding out of the loop; it is restored before returning, also on
/// error, so `values` always matches `encoded`.
fn varint_encode_run(fixture: *Fixture) RunError!Result {
    assert(fixture.pass_count >= 1);
    assert(fixture.values.len >= 1);
    const value_first = fixture.values[0];
    defer fixture.values[0] = value_first;

    var byte_count: u64 = 0;
    for (0..fixture.pass_count) |pass| {
        fixture.values[0] = @as(u64, pass) << 7;
        var offset: u32 = 0;
        for (fixture.values) |value| {
            offset += try codec.varint.encode(fixture.scratch[offset..], value);
        }
        byte_count += offset;
        std.mem.doNotOptimizeAway(fixture.scratch.ptr);
    }
    assert(byte_count >= @as(u64, fixture.pass_count) * fixture.values.len);
    return .{
        .operation_count = @as(u64, fixture.pass_count) * fixture.values.len,
        .byte_count = byte_count,
        .sink = byte_count,
    };
}

/// Decodes the encoded stream front to back, once per pass; the decoded values feed `sink`.
fn varint_decode_run(fixture: *Fixture) RunError!Result {
    assert(fixture.pass_count >= 1);
    assert(fixture.encoded_len <= fixture.encoded.len);
    var sink: u64 = 0;
    for (0..fixture.pass_count) |_| {
        var offset: u32 = 0;
        for (0..fixture.values.len) |_| {
            const decoded = try codec.varint.decode(fixture.encoded[offset..fixture.encoded_len]);
            sink +%= decoded.value;
            offset += decoded.size;
        }
        // A real check, not an assert: the baseline runs in ReleaseFast where asserts vanish.
        if (offset != fixture.encoded_len) return error.StreamLengthMismatch;
        std.mem.doNotOptimizeAway(fixture.encoded.ptr);
    }
    std.mem.doNotOptimizeAway(sink);
    return .{
        .operation_count = @as(u64, fixture.pass_count) * fixture.values.len,
        .byte_count = @as(u64, fixture.pass_count) * fixture.encoded_len,
        .sink = sink,
    };
}

/// One fetch + release per page of the resident working set; every fetch hits (`pool.zig`).
fn pool_hit_run(fixture: *Fixture) RunError!Result {
    assert(fixture.pass_count >= 1);
    assert(fixture.pool.options.hit_pass_count >= 1);
    return pool_bench.hit_run(&fixture.pool);
}

/// One fetch + release per page of a working set larger than the pool; every fetch misses and
/// evicts a clean frame (`pool.zig`).
fn pool_miss_evict_run(fixture: *Fixture) RunError!Result {
    assert(fixture.pass_count >= 1);
    assert(fixture.pool.options.miss_pass_count >= 1);
    return pool_bench.miss_run(&fixture.pool);
}

/// Point `get` of a seeded random order over a hot tree; every page access hits (`btree.zig`).
fn btree_get_run(fixture: *Fixture) RunError!Result {
    assert(fixture.btree.get_order.len >= 1);
    assert(fixture.btree.options.get_count >= 1);
    return btree_bench.get_run(&fixture.btree);
}

/// Ascending-key inserts into a fresh unlogged tree whose pool holds all of it (`btree.zig`).
fn btree_insert_seq_run(fixture: *Fixture) RunError!Result {
    assert(fixture.btree.name_len >= 1);
    assert(fixture.btree.options.key_count >= 1);
    return btree_bench.insert_seq_run(&fixture.btree);
}

/// The same inserts with a WAL attached: one `page_images` frame per insert (`btree.zig`).
fn btree_insert_logged_run(fixture: *Fixture) RunError!Result {
    assert(fixture.btree.name_len >= 1);
    assert(fixture.btree.options.logged_key_count >= 1);
    return btree_bench.insert_logged_run(&fixture.btree);
}

// -- tests ---------------------------------------------------------------------------------

test {
    _ = pool_bench; // The pool kernels' tests live in pool.zig; reference it so they run.
    _ = btree_bench; // Likewise for the B+Tree kernels.
}

const options_test: Options = .{
    .seed = 7,
    .buffer_size = 4099,
    .value_count = 257,
    .pass_count = 3,
    .pool = pool_bench.options_test,
    .btree = btree_bench.options_test,
};

fn test_fixture_init(
    fixture: *Fixture,
    tmp: *std.testing.TmpDir,
    pool_sub_path: []const u8,
    options: Options,
) !void {
    assert(pool_sub_path.len >= 1);
    assert(options.pass_count >= 1);
    const gpa = std.testing.allocator;
    try fixture_init(fixture, gpa, std.testing.io, tmp.dir, pool_sub_path, options);
}

fn test_leb128_len(value: u64) u64 {
    var rest = value >> 7;
    var length: u64 = 1;
    for (0..codec.varint.encoded_size_max) |_| {
        if (rest == 0) break;
        rest >>= 7;
        length += 1;
    }
    assert(length >= 1);
    assert(length <= codec.varint.encoded_size_max);
    return length;
}

test "fixture is reproducible from its seed and differs across seeds" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var first: Fixture = undefined;
    try test_fixture_init(&first, &tmp, "first.db", options_test);
    defer fixture_deinit(&first, gpa);

    var second: Fixture = undefined;
    try test_fixture_init(&second, &tmp, "second.db", options_test);
    defer fixture_deinit(&second, gpa);

    var other: Fixture = undefined;
    var options_other = options_test;
    options_other.seed = 8;
    try test_fixture_init(&other, &tmp, "other.db", options_other);
    defer fixture_deinit(&other, gpa);

    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expectEqualSlices(u64, first.values, second.values);
    try std.testing.expectEqual(first.encoded_len, second.encoded_len);
    try std.testing.expect(!std.mem.eql(u8, first.bytes, other.bytes));
    try std.testing.expect(!std.mem.eql(u64, first.values, other.values));
}

test "fixture encoded stream decodes back to the values at every size" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_init(&fixture, &tmp, "pool.db", options_test);
    defer fixture_deinit(&fixture, gpa);

    var offset: u32 = 0;
    var expected_len: u64 = 0;
    var size_seen = [_]bool{false} ** (codec.varint.encoded_size_max + 1);
    for (fixture.values) |value| {
        const decoded = try codec.varint.decode(fixture.encoded[offset..fixture.encoded_len]);
        try std.testing.expectEqual(value, decoded.value);
        size_seen[decoded.size] = true;
        offset += decoded.size;
        expected_len += test_leb128_len(value);
    }
    try std.testing.expectEqual(fixture.encoded_len, offset);
    try std.testing.expectEqual(expected_len, fixture.encoded_len);
    // The pinned boundary values (0, 127, 128, maxInt) guarantee the one, two and ten byte forms.
    try std.testing.expect(size_seen[1]);
    try std.testing.expect(size_seen[2]);
    try std.testing.expect(size_seen[codec.varint.encoded_size_max]);
    try std.testing.expectEqual(std.math.maxInt(u64), fixture.values[fixture.values.len - 1]);
}

test "hash kernels report the work and checksum what an independent hash computes" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_init(&fixture, &tmp, "pool.db", options_test);
    defer fixture_deinit(&fixture, gpa);

    var crc_expected: u64 = 0;
    var xxhash_expected: u64 = 0;
    for (0..fixture.pass_count) |pass| {
        fixture.bytes[0] = @truncate(pass);
        crc_expected +%= std.hash.crc.Crc32Iscsi.hash(fixture.bytes);
        xxhash_expected +%= std.hash.XxHash64.hash(0, fixture.bytes);
    }
    const crc = try Crc32cKernelType(.software).run(&fixture);
    const xxhash = try xxhash64_run(&fixture);

    try std.testing.expectEqual(crc_expected, crc.sink);
    try std.testing.expectEqual(xxhash_expected, xxhash.sink);
    try std.testing.expectEqual(@as(u64, options_test.pass_count), crc.operation_count);
    try std.testing.expectEqual(
        @as(u64, options_test.pass_count) * options_test.buffer_size,
        xxhash.byte_count,
    );
    if (codec.crc32c.hardware_available) {
        const hardware = try Crc32cKernelType(.hardware).run(&fixture);
        try std.testing.expectEqual(crc.sink, hardware.sink);
    }
}

test "varint kernels count the bytes and values they move" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_init(&fixture, &tmp, "pool.db", options_test);
    defer fixture_deinit(&fixture, gpa);

    const passes: u64 = options_test.pass_count;
    const operations: u64 = passes * options_test.value_count;
    var value_sum: u64 = 0;
    for (fixture.values) |value| value_sum +%= value;
    const decode = try varint_decode_run(&fixture);
    try std.testing.expectEqual(value_sum *% passes, decode.sink);
    try std.testing.expectEqual(operations, decode.operation_count);
    try std.testing.expectEqual(passes * fixture.encoded_len, decode.byte_count);

    var tail_len: u64 = 0;
    for (fixture.values[1..]) |value| tail_len += test_leb128_len(value);
    var head_len: u64 = 0;
    for (0..options_test.pass_count) |pass| head_len += test_leb128_len(@as(u64, pass) << 7);
    const value_first = fixture.values[0];
    const encode = try varint_encode_run(&fixture);
    try std.testing.expectEqual(passes * tail_len + head_len, encode.byte_count);
    try std.testing.expectEqual(operations, encode.operation_count);
    // The kernel restores `values[0]`, and the last pass's output is the canonical encoding of
    // every value after the first, which the fixture's own stream also holds.
    try std.testing.expectEqual(value_first, fixture.values[0]);
    const head_size = test_leb128_len(@as(u64, options_test.pass_count - 1) << 7);
    const first_size = test_leb128_len(value_first);
    try std.testing.expectEqualSlices(
        u8,
        fixture.encoded[first_size..fixture.encoded_len],
        fixture.scratch[head_size..][0 .. fixture.encoded_len - first_size],
    );
}

test "varint kernels return the typed error the codec found" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_init(&fixture, &tmp, "pool.db", options_test);
    defer fixture_deinit(&fixture, gpa);

    const scratch_full = fixture.scratch;
    fixture.scratch = scratch_full[0..5];
    try std.testing.expectError(error.BufferTooSmall, varint_encode_run(&fixture));
    fixture.scratch = scratch_full;

    fixture.encoded_len -= 1;
    try std.testing.expectError(error.Truncated, varint_decode_run(&fixture));
    fixture.encoded_len += 1;

    // One byte past the real stream: every value decodes, but the stream does not end on time.
    fixture.encoded_len += 1;
    try std.testing.expectError(error.StreamLengthMismatch, varint_decode_run(&fixture));
    fixture.encoded_len -= 1;

    // 0x80 0x00 spells zero in two bytes; the canonical form is one.
    fixture.encoded[0] = 0x80;
    fixture.encoded[1] = 0x00;
    try std.testing.expectError(error.Overlong, varint_decode_run(&fixture));
}

test "every registered benchmark runs on a small fixture and names are unique" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var fixture: Fixture = undefined;
    try test_fixture_init(&fixture, &tmp, "pool.db", options_test);
    defer fixture_deinit(&fixture, gpa);

    for (benches, 0..) |bench, index| {
        const result = try bench.run(&fixture);
        try std.testing.expect(result.operation_count > 0);
        try std.testing.expect(result.byte_count > 0);
        for (benches[index + 1 ..]) |later| {
            try std.testing.expect(!std.mem.eql(u8, bench.name, later.name));
        }
    }
    try std.testing.expect(benches.len >= benches_always.len);
}

test "fixture_init fails on an existing tree directory and removes the pool file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(std.testing.io, "pool.db.tree", .default_dir);
    var fixture: Fixture = undefined;
    try std.testing.expectError(
        error.PathAlreadyExists,
        test_fixture_init(&fixture, &tmp, "pool.db", options_test),
    );
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, "pool.db", .{}),
    );
    const present = try tmp.dir.statFile(std.testing.io, "pool.db.tree", .{});
    try std.testing.expect(present.kind == .directory);
}

test "pool file names are well formed, fit the fixture and differ between calls" {
    var first_buffer: [pool_bench.name_len_max]u8 = undefined;
    var second_buffer: [pool_bench.name_len_max]u8 = undefined;
    const first = try pool_file_name(std.testing.io, &first_buffer);
    const second = try pool_file_name(std.testing.io, &second_buffer);

    try std.testing.expect(std.mem.startsWith(u8, first, "strata-bench-"));
    try std.testing.expect(std.mem.endsWith(u8, first, ".db"));
    try std.testing.expect(first.len <= pool_bench.name_len_max);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "filter selects by substring and empty or absent filters select all" {
    try std.testing.expect(filter_matches("crc32c_software", null));
    try std.testing.expect(filter_matches("crc32c_software", ""));
    try std.testing.expect(filter_matches("crc32c_software", "crc"));
    try std.testing.expect(!filter_matches("crc32c_software", "varint"));
    try std.testing.expect(!filter_matches("xxhash64", "xxhash64_longer"));
}

test "report line prints GB/s, ops/s and ns/op from integer math" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    // 2 GB in 1 s: 2.000 GB/s; 1000 operations: 1000 ops/s, 1_000_000 ns/op.
    try report_write(&writer, "demo", .{
        .operation_count = 1000,
        .byte_count = 2_000_000_000,
        .sink = 0,
    }, 1_000_000_000);
    const line = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, line, "demo"));
    try std.testing.expect(std.mem.find(u8, line, "2.000 GB/s") != null);
    try std.testing.expect(std.mem.find(u8, line, "        1000 ops/s") != null);
    try std.testing.expect(std.mem.find(u8, line, "   1000000 ns/op\n") != null);
}

test "report line survives a zero elapsed time with zero rates" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const result: Result = .{ .operation_count = 5, .byte_count = 50, .sink = 0 };
    try report_write(&writer, "instant", result, 0);
    const line = writer.buffered();
    try std.testing.expect(std.mem.find(u8, line, "0.000 GB/s") != null);
    try std.testing.expect(std.mem.find(u8, line, "           0 ops/s") != null);
}
