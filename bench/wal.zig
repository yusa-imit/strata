//! WAL benchmarks (plan 006 item 11, PRD §5): `wal_append` and `wal_replay`, over real segment
//! files in a scratch directory. Each prints its figure next to its PRD floor.
//!
//! `wal_append`: 128 B `record` payloads (145 B frames) through `Writer.append` with sync policy
//! `.fdatasync`, `batch_count` appends per `Writer.commit` call. One caller thread, so the group
//! commit leader syncs once per batch: this is group commit as a single producer sees it (the
//! batch is what a window would gather). The op is one append; the sync cost is in the figure.
//! Floor: at least `append_ops_floor` ops/s.
//! `wal_replay`: a log of `log_bytes` of the same frames is written first with `.none` (setup,
//! untimed), then `Recovery.replay` reads it all into a counting `Apply` (timed). The op is one
//! replayed frame; the seconds are the figure. Floor: `log_bytes` = 1 GiB in under
//! `replay_floor_ms`. The size is a parameter: `zig build bench -- wal_replay <MiB>` picks a
//! smaller log, and the figure then only scales (it is not comparable to the floor).
//! Allocation: `Writer.init` and the reader allocate from `gpa`; the kernels' loops allocate
//! nothing. The counter's totals are checked with real branches, not asserts, since the bench
//! runs in ReleaseFast. `run_all` creates `strata-bench-wal-<random>` under its parent
//! directory and removes it on exit.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const strata = @import("strata");
const Result = @import("main.zig").Result;

const frame = strata.wal.frame;
const Writer = strata.wal.Writer;
const Apply = strata.wal.Apply;
const Recovery = strata.wal.Recovery;
const Lsn = frame.Lsn;

/// Bytes of every payload (PRD §5: 128 B appends).
pub const payload_len: u32 = 128;
/// Bytes of every frame on disk.
pub const frame_len: u32 = frame.frame_header_size + payload_len;
/// PRD §5 floor for appends under group commit with `.fdatasync`.
pub const append_ops_floor: u64 = 200_000;
/// PRD §5 floor for replaying a 1 GiB log, in milliseconds.
pub const replay_floor_ms: u64 = 5_000;
/// The size the floor is stated for.
pub const log_bytes_full: u64 = 1 << 30;

const dir_name_len_max: u32 = 64;

pub const Options = struct {
    /// Appends in the `wal_append` kernel.
    append_count: u32,
    /// Appends per `commit` call (the group).
    batch_count: u32,
    /// Bytes of log `wal_replay` reads; a multiple of nothing in particular, rounded down to
    /// whole frames.
    log_bytes: u64,
    /// `Writer.Options.segment_bytes_max` for both benchmarks.
    segment_bytes: u64,
};

/// One kernel's outcome with the time its timed section took.
pub const Timed = struct { result: Result, elapsed_ns: u64 };

pub const options_test: Options = .{
    .append_count = 100,
    .batch_count = 8,
    .log_bytes = 40 * frame_len,
    .segment_bytes = 16 * frame_len,
};

/// The counting redo target: frames, payload bytes, and a checksum of the payload heads.
const Counter = struct {
    frames: u64 = 0,
    bytes: u64 = 0,
    last_lsn: Lsn = 0,
    sink: u64 = 0,
    out_of_order: bool = false,

    const vtable: Apply.VTable = .{ .apply = apply_frame };

    fn apply_frame(ptr: *anyopaque, io: Io, f: frame.Frame) strata.wal.recovery.ApplyError!void {
        _ = io;
        assert(f.payload.len == payload_len);
        assert(f.lsn >= frame.lsn_first);
        const self: *Counter = @ptrCast(@alignCast(ptr));
        if (f.lsn <= self.last_lsn) self.out_of_order = true;
        self.frames += 1;
        self.bytes += f.payload.len;
        self.last_lsn = f.lsn;
        self.sink +%= f.payload[0];
    }

    fn target(self: *Counter) Apply {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

fn segments_for(bytes: u64, segment_bytes: u64) u32 {
    assert(segment_bytes >= frame_len);
    assert(bytes >= 1);
    const full = @divFloor(bytes + segment_bytes - 1, segment_bytes);
    return @intCast(full + 2); // The slack covers the header and the rotation rule.
}

fn writer_options(
    bytes: u64,
    segment_bytes: u64,
    policy: strata.file.file.SyncPolicy,
) strata.wal.writer.Options {
    assert(segment_bytes > strata.wal.segment.segment_header_size);
    assert(bytes >= frame_len);
    return .{
        .segments_max = segments_for(bytes, segment_bytes),
        .sync_policy = policy,
        .segment_bytes_max = segment_bytes,
    };
}

fn payload_fill(payload: *[payload_len]u8, index: u64) void {
    assert(payload.len == payload_len);
    assert(index < std.math.maxInt(u64));
    @memset(payload, @truncate(index));
    std.mem.writeInt(u64, payload[0..8], index, .little);
}

/// `append_count` appends, a `commit` after every `batch_count`-th and after the last, with
/// `.fdatasync`. Only the append loop is timed.
pub fn append_run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, options: Options) !Timed {
    assert(options.append_count >= 1);
    assert(options.batch_count >= 1);
    const bytes = @as(u64, options.append_count) * frame_len;
    var writer: Writer = undefined;
    const wopts = writer_options(bytes, options.segment_bytes, .fdatasync);
    try Writer.init(&writer, io, gpa, dir, wopts);
    defer writer.deinit(io, gpa);

    var payload: [payload_len]u8 = undefined;
    var last: Lsn = 0;
    const start: Io.Clock.Timestamp = .now(io, .awake);
    for (0..options.append_count) |index| {
        payload_fill(&payload, index);
        last = try writer.append(io, .record, &payload);
        if (@rem(index + 1, options.batch_count) == 0 or index + 1 == options.append_count) {
            try writer.commit(io, last);
        }
    }
    const elapsed_ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    if (writer.durable_lsn != last) return error.AppendsNotDurable;
    return .{
        .result = .{
            .operation_count = options.append_count,
            .byte_count = bytes,
            .sink = writer.stats.syncs,
        },
        .elapsed_ns = elapsed_ns,
    };
}

/// Setup, untimed: writes `frame_count` frames with `.none` and returns the frame count.
fn log_write(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, options: Options) !u64 {
    assert(options.log_bytes >= frame_len);
    assert(options.segment_bytes > strata.wal.segment.segment_header_size);
    const frame_count = @divFloor(options.log_bytes, frame_len);
    const wopts = writer_options(options.log_bytes, options.segment_bytes, .none);
    var writer: Writer = undefined;
    try Writer.init(&writer, io, gpa, dir, wopts);
    defer writer.deinit(io, gpa);

    var payload: [payload_len]u8 = undefined;
    for (0..frame_count) |index| {
        payload_fill(&payload, index);
        _ = try writer.append(io, .record, &payload);
    }
    assert(writer.next_lsn >= frame_count * frame_len);
    return frame_count;
}

/// Writes the log (untimed), then times `Recovery.replay` of all of it into a `Counter`.
pub fn replay_run(io: Io, gpa: std.mem.Allocator, dir: Io.Dir, options: Options) !Timed {
    assert(options.log_bytes >= frame_len);
    assert(options.segment_bytes > strata.wal.segment.segment_header_size);
    const frame_count = try log_write(io, gpa, dir, options);

    var counter: Counter = .{};
    const wopts = writer_options(options.log_bytes, options.segment_bytes, .none);
    const start: Io.Clock.Timestamp = .now(io, .awake);
    const replayed = try Recovery.replay(io, gpa, dir, counter.target(), .{
        .from_lsn = 0,
        .segment_options = .{
            .segments_max = wopts.segments_max,
            .sync_policy = .none,
        },
    });
    const elapsed_ns: u64 = @intCast(start.untilNow(io).raw.nanoseconds);
    if (counter.frames != frame_count or counter.out_of_order) return error.ReplayMismatch;
    if (replayed.last_lsn != counter.last_lsn) return error.ReplayMismatch;
    return .{
        .result = .{
            .operation_count = counter.frames,
            .byte_count = counter.bytes,
            .sink = counter.sink,
        },
        .elapsed_ns = elapsed_ns,
    };
}

/// Operations per second from integer math; zero elapsed time reads as zero.
pub fn ops_per_s(operation_count: u64, elapsed_ns: u64) u64 {
    assert(operation_count <= std.math.maxInt(u64) / std.time.ns_per_s);
    assert(operation_count > 0);
    if (elapsed_ns == 0) return 0;
    return @divFloor(operation_count * std.time.ns_per_s, elapsed_ns);
}

pub fn append_write(out: *Io.Writer, timed: Timed) !void {
    const rate = ops_per_s(timed.result.operation_count, timed.elapsed_ns);
    assert(timed.result.byte_count == timed.result.operation_count * frame_len);
    const verdict = if (rate >= append_ops_floor) "met" else "MISSED";
    try out.print("{s:<20} {d:>12} ops/s {d:>10} syncs  floor {d} ops/s: {s}\n", .{
        "wal_append",
        rate,
        timed.result.sink,
        append_ops_floor,
        verdict,
    });
}

pub fn replay_write(out: *Io.Writer, timed: Timed, log_bytes: u64) !void {
    const ms: u64 = @divFloor(timed.elapsed_ns, std.time.ns_per_ms);
    assert(timed.result.byte_count == timed.result.operation_count * payload_len);
    const comparable = log_bytes >= log_bytes_full;
    const verdict = if (!comparable) "n/a (log below 1 GiB)" else if (ms < replay_floor_ms)
        "met"
    else
        "MISSED";
    try out.print("{s:<20} {d:>8}.{d:0>3} s {d:>12} frames {d:>6} MiB  floor {d}.000 s: {s}\n", .{
        "wal_replay",
        @divFloor(ms, 1000),
        @rem(ms, 1000),
        timed.result.operation_count,
        @divFloor(log_bytes, 1 << 20),
        @divFloor(replay_floor_ms, 1000),
        verdict,
    });
}

/// Parses the optional replay size argument, in MiB; `null` is the full 1 GiB.
pub fn log_bytes_parse(arg: ?[]const u8) !u64 {
    const text = arg orelse return log_bytes_full;
    const mib = try std.fmt.parseInt(u32, text, 10);
    if (mib == 0) return error.InvalidLogSize;
    assert(mib >= 1);
    return @as(u64, mib) << 20;
}

/// Runs the benchmarks whose name contains `filter` (all when null), each in a fresh
/// subdirectory of a scratch directory created under `parent` and removed before returning.
/// Returns how many ran.
pub fn run_all(
    io: Io,
    gpa: std.mem.Allocator,
    parent: Io.Dir,
    filter: ?[]const u8,
    options: Options,
    out: *Io.Writer,
) !u32 {
    assert(options.log_bytes >= frame_len);
    assert(options.append_count >= 1);
    const names = [_][]const u8{ "wal_append", "wal_replay" };
    var random: [8]u8 = undefined;
    io.random(&random);
    var name_buffer: [dir_name_len_max]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buffer, "strata-bench-wal-{x:0>16}", .{
        std.mem.readInt(u64, &random, .little),
    });
    try parent.createDir(io, name, .default_dir);
    defer parent.deleteTree(io, name) catch |err| {
        std.log.err("bench: cannot remove {s}: {t}", .{ name, err });
    };

    const root = try parent.openDir(io, name, .{});
    defer root.close(io);

    var ran: u32 = 0;
    for (names) |bench_name| {
        const text = filter orelse "";
        if (std.mem.find(u8, bench_name, text) == null) continue;
        try root.createDir(io, bench_name, .default_dir);
        const dir = try root.openDir(io, bench_name, .{ .iterate = true });
        defer dir.close(io);

        if (std.mem.eql(u8, bench_name, "wal_append")) {
            try append_write(out, try append_run(io, gpa, dir, options));
        } else {
            try replay_write(out, try replay_run(io, gpa, dir, options), options.log_bytes);
        }
        try out.flush();
        ran += 1;
    }
    return ran;
}

// -- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "append_run: counts the appends, makes them durable and syncs once per batch" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const timed = try append_run(testing.io, testing.allocator, tmp.dir, options_test);
    try testing.expectEqual(@as(u64, options_test.append_count), timed.result.operation_count);
    const bytes: u64 = @as(u64, options_test.append_count) * frame_len;
    try testing.expectEqual(bytes, timed.result.byte_count);
    // 100 appends in batches of 8: 13 commits; rotation syncs add to the count, never remove.
    try testing.expect(timed.result.sink >= 13);
}

test "replay_run: replays exactly the frames the log holds across rotations" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const timed = try replay_run(testing.io, testing.allocator, tmp.dir, options_test);
    try testing.expectEqual(@as(u64, 40), timed.result.operation_count);
    try testing.expectEqual(@as(u64, 40) * payload_len, timed.result.byte_count);
    // The payload head byte is the low byte of the index (all below 256): 0 + 1 + ... + 39.
    try testing.expectEqual(@as(u64, 780), timed.result.sink);
}

test "run_all: filter selects, output names the floors and the scratch directory is gone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var buffer: [1024]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    const ran = try run_all(testing.io, testing.allocator, tmp.dir, null, options_test, &out);
    try testing.expectEqual(@as(u32, 2), ran);
    try testing.expect(std.mem.find(u8, out.buffered(), "wal_append") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "wal_replay") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "n/a") != null);

    var out_none = Io.Writer.fixed(&buffer);
    const gpa = testing.allocator;
    const none = try run_all(testing.io, gpa, tmp.dir, "btree", options_test, &out_none);
    try testing.expectEqual(@as(u32, 0), none);
    var walker = tmp.dir.iterate();
    try testing.expect((try walker.next(testing.io)) == null);
}

test "log size argument parses MiB and defaults to the full gigabyte" {
    try testing.expectEqual(log_bytes_full, try log_bytes_parse(null));
    try testing.expectEqual(@as(u64, 16) << 20, try log_bytes_parse("16"));
    try testing.expectError(error.InvalidLogSize, log_bytes_parse("0"));
    try testing.expectError(error.InvalidCharacter, log_bytes_parse("x"));
}

test "report lines state the verdict against the floor" {
    var buffer: [512]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    const fast: Timed = .{
        .result = .{ .operation_count = 1_000_000, .byte_count = 1_000_000 * frame_len, .sink = 3 },
        .elapsed_ns = std.time.ns_per_s,
    };
    try append_write(&out, fast);
    try testing.expect(std.mem.find(u8, out.buffered(), ": met") != null);
    try testing.expectEqual(@as(u64, 0), ops_per_s(5, 0));
    try testing.expectEqual(@as(u64, 5), ops_per_s(5, std.time.ns_per_s));

    var out_slow = Io.Writer.fixed(&buffer);
    const slow: Timed = .{
        .result = .{ .operation_count = 10, .byte_count = 10 * payload_len, .sink = 0 },
        .elapsed_ns = 6 * std.time.ns_per_s,
    };
    try replay_write(&out_slow, slow, log_bytes_full);
    try testing.expect(std.mem.find(u8, out_slow.buffered(), "MISSED") != null);
}
