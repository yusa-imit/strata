//! Shared fixtures for the `recovery.zig` contract tests (`recovery_test.zig`): a model `Apply`
//! target that records (and can fail on) the frames it gets, replay wrappers over
//! `std.testing.io`, and a check that a `Writer` opens the repaired log and appends. Raw file
//! helpers come from `segment_fixtures.zig`, hand-built segments from `reader_fixtures.zig`.
//! Test-only; memory through `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");
const rfx = @import("reader_fixtures.zig");
const sfx = @import("segment_fixtures.zig");
const wfx = @import("writer_fixtures.zig");

pub const Lsn = frame.Lsn;
pub const pa = rfx.pa;
pub const pb = rfx.pb;
pub const pc = rfx.pc;
pub const header_size = rfx.header_size;

/// LSNs and end offsets of the three-frame log `pa, pb, pc` in segment 1 (first LSN 1).
pub const lsn1: Lsn = 1;
pub const lsn2: Lsn = lsn1 + 22;
pub const lsn3: Lsn = lsn2 + 24;
pub const lsn_end: Lsn = lsn3 + 24;
pub const f1_end: u32 = header_size + 22;
pub const f2_end: u32 = f1_end + 24;
pub const f3_end: u32 = f2_end + 24;

const records_max: u32 = 16;

/// Records every applied frame; fails with `fail_with` when asked to apply frame number
/// `fail_at` (counted from 0), without recording it.
pub const Model = struct {
    count: u32 = 0,
    lsns: [records_max]Lsn = @splat(0),
    lens: [records_max]u8 = @splat(0),
    bytes: [records_max][16]u8 = @splat(@splat(0)),
    fail_at: u32 = std.math.maxInt(u32),
    fail_with: recovery.ApplyError = error.Failed,

    const vtable: recovery.Apply.VTable = .{ .apply = apply_fn };

    pub fn target(self: *Model) recovery.Apply {
        assert(self.count <= records_max);
        assert(self.fail_at >= 0);
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn apply_fn(ptr: *anyopaque, io: Io, f: frame.Frame) recovery.ApplyError!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        assert(self.count <= records_max);
        assert(f.payload.len <= 16);
        _ = io;
        if (self.count == self.fail_at) return self.fail_with;
        self.lsns[self.count] = f.lsn;
        self.lens[self.count] = @intCast(f.payload.len);
        @memcpy(self.bytes[self.count][0..f.payload.len], f.payload);
        self.count += 1;
    }

    pub fn expect_records(
        self: *const Model,
        lsns: []const Lsn,
        payloads: []const []const u8,
    ) !void {
        assert(self.count <= records_max);
        assert(lsns.len == payloads.len);
        try testing.expectEqual(@as(u32, @intCast(lsns.len)), self.count);
        for (lsns, payloads, 0..) |lsn, payload, i| {
            try testing.expectEqual(lsn, self.lsns[i]);
            try testing.expectEqualSlices(u8, payload, self.bytes[i][0..self.lens[i]]);
        }
    }

    pub fn expect_equal(self: *const Model, other: *const Model) !void {
        assert(self.count <= records_max);
        assert(other.count <= records_max);
        try testing.expectEqual(self.count, other.count);
        try testing.expectEqualSlices(Lsn, self.lsns[0..self.count], other.lsns[0..other.count]);
        try testing.expectEqualSlices(u8, self.lens[0..self.count], other.lens[0..other.count]);
    }
};

pub fn options(from_lsn: Lsn, segments_max: u32) recovery.ReplayOptions {
    assert(lsn1 == 1);
    assert(segments_max >= 1);
    assert(from_lsn < frame.lsn_limit);
    return .{ .from_lsn = from_lsn, .segment = rfx.opts(segments_max) };
}

pub fn replay(
    dir: Io.Dir,
    model: *Model,
    from_lsn: Lsn,
    segments_max: u32,
) recovery.ReplayError!recovery.Result {
    assert(segments_max >= 1);
    assert(model.count <= records_max);
    const opts = options(from_lsn, segments_max);
    return recovery.Recovery.replay(testing.io, testing.allocator, dir, model.target(), opts);
}

pub fn replay_ok(dir: Io.Dir, model: *Model, from_lsn: Lsn) !Lsn {
    assert(from_lsn < frame.lsn_limit);
    assert(model.count == 0);
    const result = try replay(dir, model, from_lsn, 4);
    assert(result.last_lsn < frame.lsn_limit);
    return result.last_lsn;
}

pub fn expect_replay_error(want: anyerror, dir: Io.Dir, from_lsn: Lsn, segments_max: u32) !void {
    assert(from_lsn < frame.lsn_limit);
    assert(want != error.OutOfMemory);
    var model: Model = .{};
    try testing.expectError(want, replay(dir, &model, from_lsn, segments_max));
}

/// Segment 1 with `pa, pb, pc`, then its length set to `len` (a cut or a zero extension).
pub fn put_three(dir: Io.Dir, len: u64) !void {
    assert(len <= f3_end + (1 << 20));
    assert(len >= header_size);
    var image: [256]u8 = undefined;
    const n = rfx.build(&image, 1, 1, &.{ pa, pb, pc });
    assert(n == f3_end);
    try sfx.put_file(dir, 1, image[0..@min(len, n)], len);
}

/// Segment `index` has exactly `want` bytes; the handle is closed again.
pub fn expect_len(dir: Io.Dir, index: u32, want: u64) !void {
    assert(index >= 1);
    assert(want < frame.lsn_limit);
    const f = try sfx.raw_open(dir, index);
    defer f.close(testing.io);

    try sfx.expect_length(f, want);
}

/// A `Writer` opens the log, appends one frame at `next_lsn` and closes.
pub fn expect_writer_continues(dir: Io.Dir, next_lsn: Lsn) !void {
    assert(next_lsn < frame.lsn_limit);
    assert(next_lsn >= frame.lsn_first);
    var w: wfx.Writer = undefined;
    try wfx.open_ok(&w, dir, wfx.opts(4, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    try testing.expectEqual(next_lsn, w.next_lsn);
    try testing.expectEqual(next_lsn, try wfx.append_ok(&w, pa));
}
