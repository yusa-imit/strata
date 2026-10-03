//! Tests for `crash.zig` (plan 002, "testing/crash.zig"), written before the implementation.
//! Expected values are literals, hand-applied cuts, or the written data itself, never output
//! of `CrashSink`. Garbage bytes are only constrained by properties (determinism, difference
//! from the logical bytes, seed sensitivity), because the PRNG stream is an implementation
//! detail. Everything allocating goes through `std.testing.allocator`; no I/O happens here.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const crash = @import("crash.zig");

const CrashSink = crash.CrashSink;
const Cut = crash.Cut;
const TruncationPoints = crash.TruncationPoints;
const sector_size = crash.sector_size;

const capacity: usize = 8192;

/// Length of the post-crash image of a sink with at most `capacity` bytes of storage.
fn persisted_len(sink: *const CrashSink) !usize {
    assert(sink.storage.len <= capacity);
    assert(sink.len <= sink.storage.len);
    var scratch: [capacity]u8 = undefined;
    return (try sink.persisted_into(&scratch)).len;
}

/// Position-dependent, never-zero bytes, so data is distinguishable from gaps and dirty storage.
fn fill(buf: []u8, tag: u32) void {
    assert(buf.len <= std.math.maxInt(u32));
    for (buf, 0..) |*byte, i| {
        const mixed: u32 = @as(u32, @truncate(i)) *% 131 +% tag;
        byte.* = @intCast(1 + mixed % 251);
    }
    assert(buf.len == 0 or buf[0] != 0);
}

/// A sink over dirty (0xFF) heap storage; `init` must zero it. Must not move after `init`.
const Fixture = struct {
    storage: []u8,
    sink: CrashSink,
    scratch: [capacity]u8,

    /// The post-crash image, copied into the fixture's scratch buffer.
    fn image(fx: *Fixture) ![]const u8 {
        assert(fx.storage.len == capacity);
        assert(fx.sink.len <= capacity);
        return fx.sink.persisted_into(&fx.scratch);
    }

    fn init(fx: *Fixture, gpa: std.mem.Allocator, cut: Cut, seed: u64) !void {
        fx.storage = try gpa.alloc(u8, capacity);
        @memset(fx.storage, 0xFF);
        try fx.sink.init(fx.storage, cut, seed);
        assert(fx.storage.len == capacity);
        assert(fx.sink.storage.len == capacity);
    }

    fn deinit(fx: *Fixture, gpa: std.mem.Allocator) void {
        assert(fx.storage.len == capacity);
        assert(fx.sink.storage.len == capacity);
        gpa.free(fx.storage);
        fx.* = undefined;
    }

    /// One `writeAt` that must be accepted in full, followed by the invariant check.
    fn put(fx: *Fixture, data: []const u8, offset: u64) !void {
        assert(offset <= capacity);
        assert(data.len <= capacity);
        const accepted = try fx.sink.writeAt(data, offset);
        try testing.expectEqual(data.len, accepted);
        fx.sink.check_invariants();
    }
};

/// Post-crash image of a stream that is `data` written once at offset 0. Caller frees.
fn single_write_image(gpa: std.mem.Allocator, cut: Cut, seed: u64, data: []const u8) ![]u8 {
    assert(data.len <= capacity);
    assert(data.len > 0);
    var fx: Fixture = undefined;
    try fx.init(gpa, cut, seed);
    defer fx.deinit(gpa);

    try fx.put(data, 0);
    return gpa.dupe(u8, try fx.image());
}

/// Checks a torn image for cut `n`: length, intact prefix, and a garbage region that differs
/// from the logical bytes (only asserted when the region is long enough to rule out chance).
fn expect_torn_image(gpa: std.mem.Allocator, data: []const u8, n: u64, want_len: usize) !void {
    assert(want_len <= data.len);
    assert(data.len <= capacity);
    const img = try single_write_image(gpa, .{ .torn = n }, 0x5EED, data);
    defer gpa.free(img);

    try testing.expectEqual(want_len, img.len);
    const prefix: usize = @intCast(@min(n, want_len));
    try testing.expectEqualSlices(u8, data[0..prefix], img[0..prefix]);
    if (want_len - prefix >= 16) {
        try testing.expect(!std.mem.eql(u8, data[prefix..want_len], img[prefix..want_len]));
    }
}

test "crash: sector_size is the 512-byte contract" {
    try testing.expectEqual(@as(u32, 512), sector_size);
}

test "crash: init zeroes dirty storage and nothing persists before the first write" {
    var storage: [1024]u8 = @splat(0xFF);
    var sink: CrashSink = undefined;
    try sink.init(&storage, .{ .truncate = 100 }, 1);

    try testing.expect(std.mem.allEqual(u8, &storage, 0));
    try testing.expectEqual(@as(usize, 0), try persisted_len(&sink));
    sink.check_invariants();
}

test "crash: truncate persists exactly the first N bytes across boundary cuts" {
    const gpa = testing.allocator;
    var data: [1300]u8 = undefined;
    fill(&data, 3);

    const cuts = [_]u64{ 0, 1, 511, 512, 513, 1299, 1300, 1301, 5000 };
    const want = [_]usize{ 0, 1, 511, 512, 513, 1299, 1300, 1300, 1300 }; // len+1 clips
    for (cuts, want) |n, want_len| {
        const img = try single_write_image(gpa, .{ .truncate = n }, 7, &data);
        defer gpa.free(img);
        try testing.expectEqual(want_len, img.len);
        try testing.expectEqualSlices(u8, data[0..want_len], img);
    }
}

test "crash: truncate ignores the seed" {
    const gpa = testing.allocator;
    var data: [900]u8 = undefined;
    fill(&data, 9);

    const a = try single_write_image(gpa, .{ .truncate = 700 }, 1, &data);
    defer gpa.free(a);
    const b = try single_write_image(gpa, .{ .truncate = 700 }, 0xDEAD_BEEF, &data);
    defer gpa.free(b);
    try testing.expectEqualSlices(u8, data[0..700], a);
    try testing.expectEqualSlices(u8, a, b);
}

test "crash: writeAt reports the full length even when the cut drops the bytes" {
    const gpa = testing.allocator;
    var data: [100]u8 = undefined;
    fill(&data, 5);

    const cuts = [_]Cut{
        .{ .truncate = 0 },
        .{ .truncate = 5 },
        .{ .torn = 3 },
        .{ .torn = 1024 },
    };
    const want = [_]usize{ 0, 5, 100, 100 }; // torn 3 completes its sector, clipped to 100
    for (cuts, want) |cut, want_len| {
        var fx: Fixture = undefined;
        try fx.init(gpa, cut, 2);
        defer fx.deinit(gpa);

        try testing.expectEqual(@as(usize, 100), try fx.sink.writeAt(&data, 0));
        fx.sink.check_invariants();
        try testing.expectEqual(want_len, try persisted_len(&fx.sink));
    }
}

test "crash: torn on a sector boundary is identical to truncate" {
    const gpa = testing.allocator;
    var data: [2000]u8 = undefined;
    fill(&data, 11);

    const boundaries = [_]u64{ 0, 512, 1024, 1536 };
    for (boundaries) |n| {
        const torn = try single_write_image(gpa, .{ .torn = n }, 42, &data);
        defer gpa.free(torn);
        const cut = try single_write_image(gpa, .{ .truncate = n }, 42, &data);
        defer gpa.free(cut);

        try testing.expectEqual(@as(usize, @intCast(n)), torn.len);
        try testing.expectEqualSlices(u8, data[0..@intCast(n)], torn);
        try testing.expectEqualSlices(u8, cut, torn);
    }
}

test "crash: torn inside a sector keeps the prefix, completes the sector, drops the rest" {
    const gpa = testing.allocator;
    var data: [2000]u8 = undefined;
    fill(&data, 13);

    const Case = struct { n: u64, len: usize };
    const cases = [_]Case{
        .{ .n = 1, .len = 512 },
        .{ .n = 255, .len = 512 },
        .{ .n = 511, .len = 512 },
        .{ .n = 513, .len = 1024 },
        .{ .n = 1023, .len = 1024 },
        .{ .n = 1025, .len = 1536 },
        .{ .n = 1537, .len = 2000 }, // sector end 2048 is clipped to the stream length
    };
    for (cases) |c| try expect_torn_image(gpa, &data, c.n, c.len);
}

test "crash: torn clips the completed sector at the logical stream length" {
    const gpa = testing.allocator;
    var data: [700]u8 = undefined;
    fill(&data, 17);

    const Case = struct { n: u64, len: usize };
    const cases = [_]Case{
        .{ .n = 513, .len = 700 },
        .{ .n = 600, .len = 700 },
        .{ .n = 699, .len = 700 },
        .{ .n = 700, .len = 700 }, // cut at the exact end: no garbage region remains
        .{ .n = 701, .len = 700 },
        .{ .n = 5000, .len = 700 },
        .{ .n = 512, .len = 512 }, // a sector boundary inside the stream is a clean cut
    };
    for (cases) |c| try expect_torn_image(gpa, &data, c.n, c.len);
}

test "crash: cut offsets near u64 max clip to the stream without overflow" {
    const gpa = testing.allocator;
    var data: [1300]u8 = undefined;
    fill(&data, 19);

    const u64_max = std.math.maxInt(u64);
    const huge = [_]u64{ u64_max, u64_max - 1, u64_max - 511 }; // last one is sector-aligned
    for (huge) |n| {
        const cut = try single_write_image(gpa, .{ .truncate = n }, 1, &data);
        defer gpa.free(cut);
        try testing.expectEqualSlices(u8, &data, cut);
        try expect_torn_image(gpa, &data, n, data.len);
    }
}

test "crash: torn garbage is a seeded mask, neither zero nor the logical bytes" {
    const gpa = testing.allocator;
    var data: [2000]u8 = undefined;
    fill(&data, 23);

    for (1..9) |seed| {
        const img = try single_write_image(gpa, .{ .torn = 1 }, seed, &data);
        defer gpa.free(img);
        try testing.expectEqual(@as(usize, 512), img.len);
        try testing.expectEqual(data[0], img[0]);
        try testing.expect(!std.mem.eql(u8, data[1..512], img[1..512]));
        try testing.expect(!std.mem.allEqual(u8, img[1..512], 0));
    }
}

test "crash: torn is deterministic per seed and only the garbage region depends on it" {
    const gpa = testing.allocator;
    var data: [2000]u8 = undefined;
    fill(&data, 29);

    const first = try single_write_image(gpa, .{ .torn = 100 }, 11, &data);
    defer gpa.free(first);
    const again = try single_write_image(gpa, .{ .torn = 100 }, 11, &data);
    defer gpa.free(again);
    const other = try single_write_image(gpa, .{ .torn = 100 }, 12, &data);
    defer gpa.free(other);

    try testing.expectEqual(@as(usize, 512), first.len);
    try testing.expectEqualSlices(u8, first, again);
    try testing.expectEqual(first.len, other.len);
    try testing.expectEqualSlices(u8, data[0..100], first[0..100]);
    try testing.expectEqualSlices(u8, data[0..100], other[0..100]);
    try testing.expect(!std.mem.eql(u8, first[100..], other[100..]));
}

test "crash: a one-byte garbage region still varies with the seed" {
    const gpa = testing.allocator;
    var data: [2000]u8 = undefined;
    fill(&data, 31);

    var seen: [256]bool = @splat(false);
    for (0..64) |seed| {
        const img = try single_write_image(gpa, .{ .torn = 511 }, seed, &data);
        defer gpa.free(img);
        try testing.expectEqual(@as(usize, 512), img.len);
        try testing.expectEqualSlices(u8, data[0..511], img[0..511]);
        seen[img[511]] = true;
    }
    var distinct: usize = 0;
    for (seen) |hit| distinct += @intFromBool(hit);
    try testing.expect(distinct >= 2);
}

test "crash: adjacent writes compose into one logical stream" {
    const gpa = testing.allocator;
    var data: [300]u8 = undefined;
    fill(&data, 37);
    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .truncate = 5000 }, 1);
    defer fx.deinit(gpa);

    try fx.put(data[0..100], 0);
    try fx.put(data[100..300], 100);
    try testing.expectEqualSlices(u8, &data, try fx.image());
}

test "crash: out-of-order writes cut by position, with the gap reading as zeros" {
    const gpa = testing.allocator;
    var a: [100]u8 = undefined;
    var b: [100]u8 = undefined;
    fill(&a, 41);
    fill(&b, 43);

    const cuts = [_]u64{ 150, 300, 301 };
    const want = [_]usize{ 150, 300, 300 };
    for (cuts, want) |n, want_len| {
        var fx: Fixture = undefined;
        try fx.init(gpa, .{ .truncate = n }, 1);
        defer fx.deinit(gpa);
        try fx.put(&b, 200); // the later bytes arrive first
        try fx.put(&a, 0);

        var expected: [300]u8 = @splat(0);
        @memcpy(expected[0..100], &a);
        @memcpy(expected[200..300], &b);
        try testing.expectEqual(want_len, try persisted_len(&fx.sink));
        try testing.expectEqualSlices(u8, expected[0..want_len], try fx.image());
    }
}

test "crash: overlapping writes let the later write win and length is the highest end" {
    const gpa = testing.allocator;
    var a: [100]u8 = undefined;
    var b: [100]u8 = undefined;
    fill(&a, 47);
    fill(&b, 53);
    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .truncate = 190 }, 1);
    defer fx.deinit(gpa);

    try fx.put(&a, 0);
    try fx.put(&b, 50); // 200 bytes arrived but the stream spans [0, 150)

    var expected: [150]u8 = undefined;
    @memcpy(expected[0..50], a[0..50]);
    @memcpy(expected[50..150], &b);
    try testing.expectEqual(@as(usize, 150), try persisted_len(&fx.sink));
    try testing.expectEqualSlices(u8, &expected, try fx.image());
}

test "crash: an empty write never extends the stream" {
    const gpa = testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .truncate = 5000 }, 1);
    defer fx.deinit(gpa);

    try fx.put("", 100);
    try testing.expectEqual(@as(usize, 0), try persisted_len(&fx.sink));
    try fx.put("0123456789", 0);
    try fx.put("", 100);
    try testing.expectEqualSlices(u8, "0123456789", try fx.image());
}

test "crash: torn image does not depend on how the stream was chunked" {
    const gpa = testing.allocator;
    var data: [1500]u8 = undefined;
    fill(&data, 59);

    const whole = try single_write_image(gpa, .{ .torn = 700 }, 5, &data);
    defer gpa.free(whole);

    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .torn = 700 }, 5);
    defer fx.deinit(gpa);
    try fx.put(data[1000..1500], 1000);
    try fx.put(data[0..700], 0);
    try fx.put(data[600..1000], 600);
    try testing.expectEqual(@as(usize, 1024), try persisted_len(&fx.sink));
    try testing.expectEqualSlices(u8, whole, try fx.image());
}

test "crash: OutOfSpace boundary — end == storage.len is accepted, one more is not" {
    var storage: [1024]u8 = undefined;
    var sink: CrashSink = undefined;
    const data: [25]u8 = @splat(0xAB);

    try sink.init(&storage, .{ .truncate = 4096 }, 1);
    try testing.expectEqual(@as(usize, 24), try sink.writeAt(data[0..24], 1000));
    try testing.expectEqual(@as(usize, 1024), try persisted_len(&sink));
    sink.check_invariants();

    try sink.init(&storage, .{ .truncate = 4096 }, 1);
    try testing.expectError(error.OutOfSpace, sink.writeAt(&data, 1000));
    try testing.expectError(error.OutOfSpace, sink.writeAt(data[0..1], 1024));
    try testing.expectError(error.OutOfSpace, sink.writeAt(data[0..1], std.math.maxInt(u64)));
    try testing.expectError(error.OutOfSpace, sink.writeAt(data[0..2], 1023));
    try testing.expectEqual(@as(usize, 1), try sink.writeAt(data[0..1], 1023));
    try testing.expectEqual(@as(usize, 0), try sink.writeAt("", 1024));
    try testing.expectEqual(@as(usize, 1024), try persisted_len(&sink));
    sink.check_invariants();
}

test "crash: a rejected write leaves the image and storage untouched" {
    var storage: [1024]u8 = undefined;
    var sink: CrashSink = undefined;
    try sink.init(&storage, .{ .truncate = 4096 }, 1);
    const data: [25]u8 = @splat(0xCD);

    try testing.expectEqual(@as(usize, 10), try sink.writeAt(data[0..10], 0));
    try testing.expectError(error.OutOfSpace, sink.writeAt(&data, 1000));
    sink.check_invariants();
    try testing.expectEqual(@as(usize, 10), try persisted_len(&sink));
    try testing.expect(std.mem.allEqual(u8, storage[10..], 0)); // no partial copy of the bad write
}

test "crash: zero-capacity storage rejects every non-empty write" {
    var empty: [0]u8 = undefined;
    var sink: CrashSink = undefined;
    try sink.init(&empty, .{ .torn = 7 }, 1);

    try testing.expectError(error.OutOfSpace, sink.writeAt("x", 0));
    try testing.expectEqual(@as(usize, 0), try sink.writeAt("", 0));
    try testing.expectEqual(@as(usize, 0), try persisted_len(&sink));
    sink.check_invariants();
}

fn expect_points(len: u64, count_max: u32) !void {
    assert(len < 1 << 20);
    assert(count_max > len);
    var points = try TruncationPoints.init(len, count_max);
    const visits_max: usize = @intCast(len + 1);
    for (0..visits_max) |expected| {
        const point = points.next() orelse return error.TestUnexpectedResult;
        try testing.expectEqual(@as(u64, expected), point);
    }
    for (0..3) |_| try testing.expectEqual(@as(?u64, null), points.next()); // exhausted for good
}

test "crash: TruncationPoints visits exactly 0..=len, len + 1 points, then null" {
    const lens = [_]u64{ 0, 1, 2, 511, 512, 513, 4096 };
    for (lens) |len| try expect_points(len, 4097);
}

test "crash: TruncationPoints count_max boundary — len + 1 == count_max is ok, +1 is not" {
    try expect_points(10, 11);
    try testing.expectError(error.TooManyCutPoints, TruncationPoints.init(10, 10));
    try testing.expectError(error.TooManyCutPoints, TruncationPoints.init(10, 9));
    try expect_points(0, 1);
    try testing.expectError(error.TooManyCutPoints, TruncationPoints.init(0, 0));
    try testing.expectError(error.TooManyCutPoints, TruncationPoints.init(1, 1));
}

test "crash: TruncationPoints count_max boundary holds at the u32 limit without overflow" {
    const count_max: u32 = std.math.maxInt(u32);
    var edge = try TruncationPoints.init(count_max - 1, count_max); // len + 1 == count_max
    try testing.expectEqual(@as(?u64, 0), edge.next());
    try testing.expectEqual(@as(?u64, 1), edge.next());
    const over = TruncationPoints.init(count_max, count_max); // len + 1 == count_max + 1
    try testing.expectError(error.TooManyCutPoints, over);
    const huge = TruncationPoints.init(std.math.maxInt(u64), count_max);
    try testing.expectError(error.TooManyCutPoints, huge);
}

test "crash: every enumerated truncation point yields the matching stream prefix" {
    const gpa = testing.allocator;
    var data: [600]u8 = undefined;
    fill(&data, 61);

    var points = try TruncationPoints.init(data.len, data.len + 1);
    var visited: usize = 0;
    for (0..data.len + 1) |_| {
        const n = points.next() orelse break;
        const img = try single_write_image(gpa, .{ .truncate = n }, 3, &data);
        defer gpa.free(img);
        try testing.expectEqualSlices(u8, data[0..@intCast(n)], img);
        visited += 1;
    }
    try testing.expectEqual(data.len + 1, visited);
    try testing.expectEqual(@as(?u64, null), points.next());
}

// ---------------------------------------------------------------------------------------------
// Model-based seeded test: random write streams into two identically-seeded sinks (one is a
// determinism twin) and a trivial reference, with the cut applied by hand after every step.
// Reproduce a failure from `(model_seed, seed index, commit)`.
// ---------------------------------------------------------------------------------------------

const model_seed: u64 = 0x57A7_A002_0007;
const model_seed_count: u64 = 48;
const model_steps: u32 = 40;
const model_cap: usize = 4096;
const model_write_max: usize = 400;

/// Reference: the logical stream as a zero-initialised byte array plus its highest end.
const Model = struct {
    bytes: []u8,
    len: usize,

    fn write(model: *Model, data: []const u8, offset: usize) void {
        assert(offset + data.len <= model_cap);
        assert(model.bytes.len == model_cap);
        if (data.len == 0) return; // a zero-byte write never extends the stream
        @memcpy(model.bytes[offset..][0..data.len], data);
        model.len = @max(model.len, offset + data.len);
    }
};

/// Hand-applied cut: bytes of the logical stream that persist unchanged.
fn model_prefix_len(cut: Cut, stream_len: usize) usize {
    assert(stream_len <= model_cap);
    const n: u64 = switch (cut) {
        .truncate => |n| n,
        .torn => |n| n,
    };
    assert(n < std.math.maxInt(u32));
    return @intCast(@min(n, stream_len));
}

/// Hand-applied cut: length of the whole post-crash image (a torn cut completes its sector).
fn model_image_len(cut: Cut, stream_len: usize) usize {
    assert(stream_len <= model_cap);
    const n: u64 = switch (cut) {
        .truncate => |n| n,
        .torn => |n| std.mem.alignForward(u64, n, sector_size),
    };
    assert(n < std.math.maxInt(u32));
    return @intCast(@min(n, stream_len));
}

fn model_check(sink: *const CrashSink, twin: *const CrashSink, model: Model, cut: Cut) !void {
    assert(model.len <= model_cap);
    assert(model.bytes.len == model_cap);
    var got_buf: [model_cap]u8 = undefined;
    var twin_buf: [model_cap]u8 = undefined;
    const got = try sink.persisted_into(&got_buf);
    const image_len = model_image_len(cut, model.len);
    const prefix_len = model_prefix_len(cut, model.len);
    try testing.expectEqual(image_len, got.len);
    try testing.expectEqualSlices(u8, model.bytes[0..prefix_len], got[0..prefix_len]);
    if (image_len - prefix_len >= 16) {
        const stale = got[prefix_len..image_len];
        try testing.expect(!std.mem.eql(u8, model.bytes[prefix_len..image_len], stale));
    }
    const twin_image = try twin.persisted_into(&twin_buf);
    try testing.expectEqualSlices(u8, got, twin_image); // same seed, same stream: same bytes
    sink.check_invariants();
    twin.check_invariants();
}

fn model_run(gpa: std.mem.Allocator, seed_index: u64) !void {
    assert(seed_index < model_seed_count);
    assert(model_cap >= model_write_max * 2);
    var prng = std.Random.DefaultPrng.init(model_seed ^ seed_index);
    const rng = prng.random();
    const cut_n = rng.uintLessThan(u64, model_cap / 2 + sector_size);
    const cut: Cut = if (rng.boolean()) .{ .truncate = cut_n } else .{ .torn = cut_n };
    const sink_seed = rng.int(u64);

    const store_a = try gpa.alloc(u8, model_cap);
    defer gpa.free(store_a);

    const store_b = try gpa.alloc(u8, model_cap);
    defer gpa.free(store_b);

    const ref = try gpa.alloc(u8, model_cap);
    defer gpa.free(ref);

    @memset(store_a, 0xFF);
    @memset(store_b, 0xFF);
    @memset(ref, 0);
    var sink: CrashSink = undefined;
    try sink.init(store_a, cut, sink_seed);
    var twin: CrashSink = undefined;
    try twin.init(store_b, cut, sink_seed);
    var model: Model = .{ .bytes = ref, .len = 0 };
    try model_check(&sink, &twin, model, cut);

    for (0..model_steps) |_| try model_step(&sink, &twin, &model, cut, rng);
}

fn model_step(
    sink: *CrashSink,
    twin: *CrashSink,
    model: *Model,
    cut: Cut,
    rng: std.Random,
) !void {
    assert(model.len <= model_cap);
    assert(model.bytes.len == model_cap);
    var data: [model_write_max]u8 = undefined;
    const offset = rng.uintLessThan(usize, model_cap + 64);
    const len = rng.uintLessThan(usize, model_write_max);
    rng.bytes(data[0..len]);

    if (offset + len <= model_cap) {
        try testing.expectEqual(len, try sink.writeAt(data[0..len], offset));
        try testing.expectEqual(len, try twin.writeAt(data[0..len], offset));
        model.write(data[0..len], offset);
    } else {
        try testing.expectError(error.OutOfSpace, sink.writeAt(data[0..len], offset));
        try testing.expectError(error.OutOfSpace, twin.writeAt(data[0..len], offset));
    }
    try model_check(sink, twin, model.*, cut);
}

test "crash: model-based seeded write streams match a hand-applied cut after every step" {
    const gpa = testing.allocator;
    for (0..model_seed_count) |seed_index| try model_run(gpa, seed_index);
}

test "crash: a never-queried sink and a queried sink give the same final image" {
    const gpa = testing.allocator;
    var data: [1500]u8 = undefined;
    fill(&data, 67);
    var quiet: Fixture = undefined;
    try quiet.init(gpa, .{ .torn = 700 }, 5);
    defer quiet.deinit(gpa);

    var queried: Fixture = undefined;
    try queried.init(gpa, .{ .torn = 700 }, 5);
    defer queried.deinit(gpa);

    const starts = [_]usize{ 1000, 0, 600 };
    const ends = [_]usize{ 1500, 700, 1000 };
    for (starts, ends) |start, end| {
        try quiet.put(data[start..end], start);
        try queried.put(data[start..end], start);
        _ = try queried.image(); // Querying must not disturb later writes.
        _ = try queried.image();
    }
    try testing.expectEqual(@as(usize, 1024), (try quiet.image()).len);
    try testing.expectEqualSlices(u8, try quiet.image(), try queried.image());
}

test "crash: torn at 100 then an overlapping later write over [100, 512) is re-masked" {
    const gpa = testing.allocator;
    var first: [2000]u8 = undefined;
    var second: [300]u8 = undefined;
    fill(&first, 71);
    fill(&second, 73);
    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .torn = 100 }, 3);
    defer fx.deinit(gpa);

    try fx.put(&first, 0);
    const before = try gpa.dupe(u8, try fx.image());
    defer gpa.free(before);

    try fx.put(&second, 100); // Rewrites logical bytes [100, 400).
    var logical: [2000]u8 = first;
    @memcpy(logical[100..400], &second);
    const after = try fx.image();

    try testing.expectEqual(@as(usize, 512), before.len);
    try testing.expectEqual(@as(usize, 512), after.len);
    try testing.expectEqualSlices(u8, logical[0..100], after[0..100]);
    for (100..512) |i| {
        try testing.expect(before[i] != first[i]);
        try testing.expect(after[i] != logical[i]);
    }

    var fresh: Fixture = undefined;
    try fresh.init(gpa, .{ .torn = 100 }, 3);
    defer fresh.deinit(gpa);

    try fresh.put(&logical, 0);
    try testing.expectEqualSlices(u8, try fresh.image(), after);
}

test "crash: two consecutive persisted_into calls are identical and leave storage logical" {
    const gpa = testing.allocator;
    var data: [900]u8 = undefined;
    fill(&data, 79);
    var fx: Fixture = undefined;
    try fx.init(gpa, .{ .torn = 300 }, 8);
    defer fx.deinit(gpa);

    try fx.put(&data, 0);
    const first = try gpa.dupe(u8, try fx.image());
    defer gpa.free(first);

    try testing.expectEqualSlices(u8, first, try fx.image());
    try testing.expectEqualSlices(u8, &data, fx.storage[0..data.len]);
    fx.sink.check_invariants();
}

test "crash: persisted_into reports OutOfSpace when the output is too small" {
    var storage: [1024]u8 = undefined;
    var sink: CrashSink = undefined;
    try sink.init(&storage, .{ .truncate = 4096 }, 1);
    _ = try sink.writeAt("0123456789", 0);

    var small: [9]u8 = undefined;
    try testing.expectError(error.OutOfSpace, sink.persisted_into(&small));
    var exact: [10]u8 = undefined;
    try testing.expectEqualSlices(u8, "0123456789", try sink.persisted_into(&exact));
}

test "crash: an empty write past storage.len is OutOfSpace, at storage.len it is accepted" {
    var storage: [64]u8 = undefined;
    var sink: CrashSink = undefined;
    try sink.init(&storage, .{ .truncate = 4096 }, 1);

    try testing.expectError(error.OutOfSpace, sink.writeAt("", 65));
    try testing.expectError(error.OutOfSpace, sink.writeAt("", std.math.maxInt(u64)));
    try testing.expectEqual(@as(usize, 0), try sink.writeAt("", 64));
    try testing.expectEqual(@as(usize, 0), try persisted_len(&sink));
    sink.check_invariants();
}

test "crash: init rejects storage larger than u32 with StorageTooLarge" {
    if (@sizeOf(usize) < 8) return error.SkipZigTest;
    var backing: [16]u8 = undefined;
    const too_big_len: usize = @as(usize, std.math.maxInt(u32)) + 1;
    const fake = @as([*]u8, &backing)[0..too_big_len]; // Never touched: init fails first.
    var sink: CrashSink = undefined;
    try testing.expectError(error.StorageTooLarge, sink.init(fake, .{ .truncate = 1 }, 1));
}
