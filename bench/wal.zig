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
//! `replay_floor_ms`. The size is a parameter: `zig build bench -- wal <MiB>` picks a smaller
//! log, and the figure then only scales (it is not comparable to the floor). The argument is
//! parsed and validated (1 ... `mib_max`) before any bench runs, and `run_all` checks the free
//! space of the scratch filesystem (`InsufficientSpace`) before it creates a single file. The
//! replayed payload-head sum is compared with the sum computed from what was appended
//! (`ReplayMismatch`).
//! macOS: `.fdatasync` there is `Io.File.sync` (fsync), not `F_FULLFSYNC`; the append line says
//! so. The figure is then not a drive-cache-flushed one.
//! Allocation: `Writer.init` and the reader allocate from `gpa`; the kernels' loops allocate
//! nothing. The counter's totals are checked with real branches, not asserts, since the bench
//! runs in ReleaseFast. `run_all` creates `strata-bench-wal-<random>` under its parent
//! directory and removes it on exit.

const std = @import("std");
const builtin = @import("builtin");
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

/// Largest replay log the argument may ask for, in MiB (16 GiB).
pub const mib_max: u32 = 16 * 1024;

const dir_name_len_max: u32 = 64;
const is_darwin = builtin.os.tag.isDarwin();

/// What `log_bytes_parse` rejects.
pub const ParseError = error{
    /// Not a decimal number, zero, or too large for `u32`.
    InvalidLogSize,
    /// More than `mib_max` MiB.
    LogTooLarge,
};

/// What the verification and space checks return.
pub const CheckError = error{ AppendsNotDurable, ReplayMismatch, InsufficientSpace };

/// The benchmarks this file runs; `@tagName` is the name the filter matches.
const Name = enum { wal_append, wal_replay };

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
    /// Free bytes of the scratch filesystem; null asks the OS (`free_bytes`). Tests set it.
    free_bytes: ?u64,
};

/// One kernel's outcome with the time its timed section took; `sync_count` is the syncs the
/// writer issued (zero for replay).
pub const Timed = struct { result: Result, elapsed_ns: u64, sync_count: u64 };

pub const options_test: Options = .{
    .append_count = 100,
    .batch_count = 8,
    .log_bytes = 40 * frame_len,
    .segment_bytes = 16 * frame_len,
    .free_bytes = null,
};

/// The counting redo target: frames, payload bytes, and the sum of the payload head bytes.
const Counter = struct {
    frames: u64 = 0,
    bytes: u64 = 0,
    last_lsn: Lsn = 0,
    head_sum: u64 = 0,
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
        self.head_sum += f.payload[0];
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
    try append_verify(writer.durable_lsn, last);
    return .{
        .result = .{
            .operation_count = options.append_count,
            .byte_count = bytes,
            .sink = writer.stats.syncs,
        },
        .elapsed_ns = elapsed_ns,
        .sync_count = writer.stats.syncs,
    };
}

/// Every append must be durable once the last commit returned.
fn append_verify(durable_lsn: Lsn, last_lsn: Lsn) CheckError!void {
    assert(last_lsn >= frame.lsn_first);
    assert(durable_lsn <= last_lsn);
    if (durable_lsn != last_lsn) return error.AppendsNotDurable;
}

/// Sum of the payload head byte (the low byte of the index) over indexes `0 ..< frame_count`:
/// 255 * 256 / 2 per full cycle of 256 plus the triangle of the partial cycle.
fn head_sum_expected(frame_count: u64) u64 {
    assert(frame_count >= 1);
    assert(frame_count <= std.math.maxInt(u64) / 256);
    const cycle_count = @divFloor(frame_count, 256);
    const rest = @rem(frame_count, 256);
    const partial = if (rest == 0) 0 else @divExact(rest * (rest - 1), 2);
    return cycle_count * 32_640 + partial;
}

/// The replay must have applied exactly the frames appended, in order, with the payloads
/// appended, and `Recovery.replay` must agree with the target on the last LSN.
fn replay_verify(
    counter: *const Counter,
    frame_count: u64,
    replayed_last_lsn: Lsn,
) CheckError!void {
    assert(frame_count >= 1);
    assert(frame_count <= std.math.maxInt(u64) / 256);
    if (counter.frames != frame_count or counter.out_of_order) return error.ReplayMismatch;
    if (counter.bytes != frame_count * payload_len) return error.ReplayMismatch;
    if (counter.head_sum != head_sum_expected(frame_count)) return error.ReplayMismatch;
    if (replayed_last_lsn != counter.last_lsn) return error.ReplayMismatch;
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
    try replay_verify(&counter, frame_count, replayed.last_lsn);
    return .{
        .result = .{
            .operation_count = counter.frames,
            .byte_count = counter.bytes,
            .sink = counter.head_sum,
        },
        .elapsed_ns = elapsed_ns,
        .sync_count = 0,
    };
}

/// Operations per second from integer math; zero elapsed time reads as zero.
pub fn ops_per_s(operation_count: u64, elapsed_ns: u64) u64 {
    assert(operation_count <= std.math.maxInt(u64) / std.time.ns_per_s);
    assert(operation_count > 0);
    if (elapsed_ns == 0) return 0;
    return @divFloor(operation_count * std.time.ns_per_s, elapsed_ns);
}

/// One result line: rate, syncs, the batch and sync policy it was measured under, the floor.
/// On macOS a second line says `.fdatasync` is not `F_FULLFSYNC` there.
pub fn append_write(out: *Io.Writer, timed: Timed, options: Options) !void {
    const rate = ops_per_s(timed.result.operation_count, timed.elapsed_ns);
    assert(timed.result.byte_count == timed.result.operation_count * frame_len);
    assert(options.batch_count >= 1);
    const verdict = if (rate >= append_ops_floor) "met" else "MISSED";
    try out.print("{s:<20} {d:>12} ops/s {d:>10} syncs  batch {d} {t}  floor {d} ops/s: {s}\n", .{
        "wal_append",
        rate,
        timed.sync_count,
        options.batch_count,
        strata.file.file.SyncPolicy.fdatasync,
        append_ops_floor,
        verdict,
    });
    if (is_darwin) try out.print("{s:<20} {s}\n", .{ "", darwin_note });
}

/// Printed under the append line on macOS.
pub const darwin_note = "note: macOS fdatasync is fsync, not F_FULLFSYNC (drive cache not flushed)";

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

/// Parses the optional replay size argument, in MiB; `null` is the full 1 GiB. Rejects zero,
/// non-numbers and anything above `mib_max`.
pub fn log_bytes_parse(arg: ?[]const u8) ParseError!u64 {
    const text = arg orelse return log_bytes_full;
    const mib = std.fmt.parseInt(u32, text, 10) catch |err| switch (err) {
        error.InvalidCharacter, error.Overflow => return error.InvalidLogSize,
    };
    if (mib == 0) return error.InvalidLogSize;
    if (mib > mib_max) return error.LogTooLarge;
    assert(mib >= 1);
    assert(mib <= mib_max);
    return @as(u64, mib) << 20;
}

/// The usage text for a rejected size argument.
pub fn usage_write(out: *Io.Writer, err: ParseError) !void {
    assert(mib_max >= 1);
    try out.print("error: {t}: the WAL size is a whole number of MiB, 1 ... {d}\n", .{
        err,
        mib_max,
    });
    try out.print("usage: zig build bench -- [filter] [wal_mib]   (default {d} MiB)\n", .{
        @shrExact(log_bytes_full, 20),
    });
}

/// Free bytes available to this process on the filesystem holding `parent`; null where this
/// target has no probe or the probe failed (the space check is then skipped). `parent` may be
/// the cwd pseudo-handle, so the probe opens its own descriptor for ".".
pub fn free_bytes(io: Io, parent: Io.Dir) ?u64 {
    const dir = parent.openDir(io, ".", .{}) catch return null;
    defer dir.close(io);

    assert(dir.handle >= 0);
    if (comptime is_darwin) {
        var info: DarwinStatfs = undefined;
        if (fstatfs(dir.handle, &info) != 0) return null;
        return info.bavail * info.bsize;
    } else if (comptime builtin.os.tag == .linux and (builtin.cpu.arch == .x86_64 or
        builtin.cpu.arch == .aarch64))
    {
        var info: LinuxStatfs = undefined;
        const fd: usize = @intCast(dir.handle);
        const rc = std.os.linux.syscall2(.fstatfs, fd, @intFromPtr(&info));
        if (std.os.linux.errno(rc) != .SUCCESS) return null;
        return info.bavail * @as(u64, @intCast(info.bsize));
    } else {
        return null;
    }
}

/// `struct statfs` from darwin `<sys/mount.h>`; only the leading fields are read.
const DarwinStatfs = extern struct {
    bsize: u32,
    iosize: i32,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    rest: [2136]u8,
};

/// `struct statfs` of 64-bit linux; only the leading fields are read.
const LinuxStatfs = extern struct {
    type: i64,
    bsize: i64,
    blocks: u64,
    bfree: u64,
    bavail: u64,
    rest: [80]u8,
};

comptime {
    assert(@sizeOf(DarwinStatfs) == 2168);
    assert(@offsetOf(DarwinStatfs, "bavail") == 24);
    assert(@sizeOf(LinuxStatfs) == 120);
}

extern "c" fn fstatfs(fd: c_int, buf: *DarwinStatfs) c_int;

/// Bytes the whole run may leave on disk at once: both logs plus rotation slack.
pub fn space_need(options: Options) u64 {
    assert(options.segment_bytes >= frame_len);
    assert(options.log_bytes <= @as(u64, mib_max) << 20);
    const append_bytes = @as(u64, options.append_count) * frame_len;
    return append_bytes + options.log_bytes + 2 * options.segment_bytes;
}

/// `free` is null when unknown (no check). Fails with `InsufficientSpace` below `need`.
pub fn space_check(free: ?u64, need: u64) CheckError!void {
    assert(need > 0);
    assert(need < std.math.maxInt(u64) / 2);
    const have = free orelse return;
    if (have < need) return error.InsufficientSpace;
}

/// Runs the benchmarks whose name contains `filter` (all when null), each in a fresh
/// subdirectory of a scratch directory created under `parent` and removed before returning,
/// also when a benchmark fails. The free space of `parent` is checked before anything is
/// created. Returns how many ran.
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
    try space_check(options.free_bytes orelse free_bytes(io, parent), space_need(options));
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
    for (std.enums.values(Name)) |bench_name| {
        const text = filter orelse "";
        if (std.mem.find(u8, @tagName(bench_name), text) == null) continue;
        try root.createDir(io, @tagName(bench_name), .default_dir);
        const dir = try root.openDir(io, @tagName(bench_name), .{ .iterate = true });
        defer dir.close(io);

        switch (bench_name) {
            .wal_append => try append_write(out, try append_run(io, gpa, dir, options), options),
            .wal_replay => {
                const timed = try replay_run(io, gpa, dir, options);
                try replay_write(out, timed, options.log_bytes);
            },
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
    try testing.expect(timed.sync_count >= 13);
    try testing.expectEqual(timed.sync_count, timed.result.sink);
}

test "replay_run: replays exactly the frames the log holds across rotations" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const timed = try replay_run(testing.io, testing.allocator, tmp.dir, options_test);
    try testing.expectEqual(@as(u64, 40), timed.result.operation_count);
    try testing.expectEqual(@as(u64, 40) * payload_len, timed.result.byte_count);
    // The payload head byte is the low byte of the index (all below 256): 0 + 1 + ... + 39.
    try testing.expectEqual(@as(u64, 780), timed.result.sink);
    try testing.expectEqual(head_sum_expected(40), timed.result.sink);
    try testing.expectEqual(@as(u64, 0), timed.sync_count);
}

test "run_all: filter selects, output names the floors and the scratch directory is gone" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    var buffer: [2048]u8 = undefined;
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

test "log size argument parses MiB, defaults to the gigabyte and rejects bad input" {
    try testing.expectEqual(log_bytes_full, try log_bytes_parse(null));
    try testing.expectEqual(@as(u64, 16) << 20, try log_bytes_parse("16"));
    try testing.expectEqual(@as(u64, mib_max) << 20, try log_bytes_parse("16384"));
    try testing.expectError(error.InvalidLogSize, log_bytes_parse("0"));
    try testing.expectError(error.InvalidLogSize, log_bytes_parse("x"));
    try testing.expectError(error.InvalidLogSize, log_bytes_parse("-3"));
    try testing.expectError(error.InvalidLogSize, log_bytes_parse("99999999999999"));
    try testing.expectError(error.LogTooLarge, log_bytes_parse("16385"));

    var buffer: [256]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try usage_write(&out, error.LogTooLarge);
    try testing.expect(std.mem.find(u8, out.buffered(), "LogTooLarge") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "usage:") != null);
}

test "report lines state the verdict, batch and sync policy against the floor" {
    var buffer: [512]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    const fast: Timed = .{
        .result = .{ .operation_count = 1_000_000, .byte_count = 1_000_000 * frame_len, .sink = 3 },
        .elapsed_ns = std.time.ns_per_s,
        .sync_count = 3,
    };
    try append_write(&out, fast, options_test);
    try testing.expect(std.mem.find(u8, out.buffered(), ": met") != null);
    try testing.expect(std.mem.find(u8, out.buffered(), "batch 8 fdatasync") != null);
    const note_found = std.mem.find(u8, out.buffered(), darwin_note) != null;
    try testing.expectEqual(is_darwin, note_found);
    try testing.expectEqual(@as(u64, 0), ops_per_s(5, 0));
    try testing.expectEqual(@as(u64, 5), ops_per_s(5, std.time.ns_per_s));

    var out_slow = Io.Writer.fixed(&buffer);
    const slow: Timed = .{
        .result = .{ .operation_count = 10, .byte_count = 10 * payload_len, .sink = 0 },
        .elapsed_ns = 6 * std.time.ns_per_s,
        .sync_count = 0,
    };
    try replay_write(&out_slow, slow, log_bytes_full);
    try testing.expect(std.mem.find(u8, out_slow.buffered(), "MISSED") != null);
}

test "append_verify returns AppendsNotDurable when the last append is not durable" {
    try append_verify(40, 40);
    try testing.expectError(error.AppendsNotDurable, append_verify(39, 40));
    try testing.expectError(error.AppendsNotDurable, append_verify(0, 40));
}

test "head_sum_expected matches a loop across cycle boundaries" {
    for ([_]u64{ 1, 2, 255, 256, 257, 511, 512, 1000 }) |frame_count| {
        var sum: u64 = 0;
        for (0..frame_count) |index| sum += @as(u8, @truncate(index));
        try testing.expectEqual(sum, head_sum_expected(frame_count));
    }
}

test "replay_verify returns ReplayMismatch for each way the replay can differ" {
    const frame_count: u64 = 40;
    const good: Counter = .{
        .frames = frame_count,
        .bytes = frame_count * payload_len,
        .last_lsn = 777,
        .head_sum = 780,
        .out_of_order = false,
    };
    try replay_verify(&good, frame_count, 777);

    var bad = good;
    bad.frames -= 1;
    try testing.expectError(error.ReplayMismatch, replay_verify(&bad, frame_count, 777));
    bad = good;
    bad.out_of_order = true;
    try testing.expectError(error.ReplayMismatch, replay_verify(&bad, frame_count, 777));
    bad = good;
    bad.bytes += 1;
    try testing.expectError(error.ReplayMismatch, replay_verify(&bad, frame_count, 777));
    bad = good;
    bad.head_sum += 1; // The payload sum alone differs.
    try testing.expectError(error.ReplayMismatch, replay_verify(&bad, frame_count, 777));
    try testing.expectError(error.ReplayMismatch, replay_verify(&good, frame_count, 778));
}

test "space_check fails with InsufficientSpace and run_all creates nothing then" {
    try space_check(null, 100);
    try space_check(100, 100);
    try testing.expectError(error.InsufficientSpace, space_check(99, 100));
    try testing.expect(space_need(options_test) > options_test.log_bytes);

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    if (free_bytes(testing.io, tmp.dir)) |free| try testing.expect(free > 0);
    var options = options_test;
    options.free_bytes = space_need(options_test) - 1;
    var buffer: [1024]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.InsufficientSpace,
        run_all(testing.io, testing.allocator, tmp.dir, null, options, &out),
    );
    var walker = tmp.dir.iterate();
    try testing.expect((try walker.next(testing.io)) == null);
    try testing.expectEqual(@as(usize, 0), out.buffered().len);
}

test "run_all removes the scratch directory when a benchmark fails" {
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A four byte sink makes the first result line fail after the kernel ran in the directory.
    var buffer: [4]u8 = undefined;
    var out = Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.WriteFailed,
        run_all(testing.io, testing.allocator, tmp.dir, null, options_test, &out),
    );
    var walker = tmp.dir.iterate();
    try testing.expect((try walker.next(testing.io)) == null);
}
