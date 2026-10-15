//! Shared fixtures for the `writer.zig` contract tests (`writer_test.zig`,
//! `writer_tail_test.zig`, `writer_fault_test.zig`): option and open wrappers that check
//! `check_invariants` after every mutation, a reference model of ADR-0003 section 9 rotation
//! that shares no code with the writer, and read-back through the real `Reader`. Raw file
//! helpers come from `segment_fixtures.zig`, hand-built segments from `reader_fixtures.zig`.
//! Test-only; I/O goes through `std.testing.io` (or a `FaultIo` over it), memory through
//! `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const file_mod = @import("../file/file.zig");
const frame = @import("frame.zig");
const rfx = @import("reader_fixtures.zig");
const s = @import("segment.zig");
const sfx = @import("segment_fixtures.zig");
const writer_mod = @import("writer.zig");

pub const Writer = writer_mod.Writer;
pub const Lsn = frame.Lsn;
pub const header_size = s.segment_header_size;
pub const pa = rfx.pa;
pub const pb = rfx.pb;
pub const pc = rfx.pc;
pub const frame_size = rfx.frame_size;

pub fn options(
    segments_max: u32,
    segment_bytes_max: u64,
    policy: file_mod.SyncPolicy,
) writer_mod.Options {
    assert(segments_max >= 1);
    assert(segment_bytes_max > header_size);
    return .{
        .segments_max = segments_max,
        .sync_policy = policy,
        .segment_bytes_max = segment_bytes_max,
    };
}

/// Options with the `.none` policy: "durable" means handed to the OS.
pub fn opts(segments_max: u32, segment_bytes_max: u64) writer_mod.Options {
    assert(segments_max >= 1);
    assert(segment_bytes_max > header_size);
    return options(segments_max, segment_bytes_max, .none);
}

pub fn open_ok(w: *Writer, dir: Io.Dir, writer_options: writer_mod.Options) !void {
    assert(writer_options.segments_max >= 1);
    try Writer.init(w, testing.io, testing.allocator, dir, writer_options);
    w.check_invariants();
    assert(w.next_lsn >= frame.lsn_first);
}

pub fn expect_open_error(want: anyerror, dir: Io.Dir, writer_options: writer_mod.Options) !void {
    assert(want != error.OutOfMemory);
    assert(want != error.TestExpectedEqual);
    var w: Writer = undefined;
    const got = Writer.init(&w, testing.io, testing.allocator, dir, writer_options);
    try testing.expectError(want, got);
}

/// Appends a `record` through `testing.io`; the LSN is the writer's previous `next_lsn`.
pub fn append_ok(w: *Writer, payload: []const u8) !Lsn {
    assert(payload.len <= frame.payload_bytes_max);
    assert(w.buf.len == frame.frame_bytes_max);
    const before = w.next_lsn;
    const lsn = try w.append(testing.io, .record, payload);
    w.check_invariants();
    try testing.expectEqual(before, lsn);
    try testing.expectEqual(before + frame_size(payload.len), w.next_lsn);
    return lsn;
}

pub fn expect_position(w: *const Writer, index: u32, offset: u64, lsn: Lsn) !void {
    assert(index >= 1);
    assert(offset >= header_size);
    const got = w.position();
    try testing.expectEqual(index, got.segment_index);
    try testing.expectEqual(offset, got.offset);
    try testing.expectEqual(lsn, got.lsn);
    try testing.expectEqual(lsn, w.next_lsn);
}

/// Reads the whole log back through a `Reader`: the `records` in order at their `lsns`, then EOF.
pub fn expect_log(
    dir: Io.Dir,
    segments_max: u32,
    lsns: []const Lsn,
    records: []const []const u8,
) !void {
    assert(lsns.len == records.len);
    assert(segments_max >= 1);
    var rd: rfx.Reader = undefined;
    try rfx.open_ok(&rd, dir, segments_max);
    defer rd.deinit(testing.io, testing.allocator);

    for (lsns, records) |lsn, payload| try rfx.expect_record(&rd, lsn, payload);
    try rfx.expect_eof(&rd);
}

/// Pattern bytes for payloads: `payload_of(i, n)` is `n` bytes that depend on `i`.
const pool_size: u32 = 4096;
const pool: [pool_size]u8 = blk: {
    @setEvalBranchQuota(10 * pool_size);
    var bytes: [pool_size]u8 = undefined;
    for (&bytes, 0..) |*byte, i| byte.* = @truncate(i *% 31 +% 7);
    break :blk bytes;
};

pub fn payload_of(i: usize, len: usize) []const u8 {
    assert(len <= 1024);
    assert(i < 1 << 20);
    const start = (i * 13) % 512;
    return pool[start..][0..len];
}

/// Reference for ADR-0003 section 9 rotation: where the writer must put each frame.
pub const Model = struct {
    segment_bytes_max: u64,
    index: u32,
    offset: u64,
    next_lsn: Lsn,
    /// `first_lsns[i]` is the first LSN of segment `i + 1`.
    first_lsns: [64]Lsn,

    pub fn init(segment_bytes_max: u64) Model {
        assert(segment_bytes_max > header_size);
        assert(segment_bytes_max <= s.segment_bytes_limit);
        var model: Model = .{
            .segment_bytes_max = segment_bytes_max,
            .index = 1,
            .offset = header_size,
            .next_lsn = 1,
            .first_lsns = @splat(0),
        };
        model.first_lsns[0] = 1;
        assert(model.first_lsns[1] == 0);
        return model;
    }

    /// Places one frame with a `len` byte payload; returns its LSN.
    pub fn append(self: *Model, len: usize) Lsn {
        assert(self.index <= self.first_lsns.len);
        const total = frame_size(len);
        if (self.offset > header_size and self.offset + total > self.segment_bytes_max) {
            self.index += 1;
            self.offset = header_size;
            self.first_lsns[self.index - 1] = self.next_lsn;
        }
        const lsn = self.next_lsn;
        self.offset += total;
        self.next_lsn += total;
        assert(self.next_lsn - self.first_lsns[self.index - 1] == self.offset - header_size);
        return lsn;
    }
};

/// Every segment's header says the index and first LSN the model recorded.
pub fn expect_segments(dir: Io.Dir, model: *const Model) !void {
    assert(model.index >= 1);
    assert(model.first_lsns[0] == 1);
    for (1..model.index + 1) |index| {
        try sfx.expect_open_ok(dir, @intCast(index), model.first_lsns[index - 1]);
    }
    try sfx.expect_open_error(error.FileNotFound, dir, model.index + 1);
}
