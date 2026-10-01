//! Seeded model-based tests for `file.zig`: the same op stream goes into a real file and into a
//! trivial in-memory reference, and every step compares length and full contents
//! (`check_invariants`). Reproduce a failure from `(model_seed, commit)`; nothing is random
//! beyond that seed. Test-only; I/O goes through `std.testing.io`, memory through
//! `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fixtures = @import("file_fixtures.zig");
const File = @import("file.zig").File;

const pattern = fixtures.pattern;
const create_rw = fixtures.create_rw;

const model_cap: usize = 4096;
const model_op_max: usize = 256;
const model_steps: u32 = 600;
const model_seed: u64 = 0x57A7_A002_0005;

/// Reference model: a byte array whose bytes beyond `len` are always zero.
const Model = struct {
    bytes: []u8,
    len: usize,

    fn init(gpa: std.mem.Allocator) !Model {
        comptime assert(model_cap >= model_op_max * 2); // Room for an op at the highest offset.
        const bytes = try gpa.alloc(u8, model_cap);
        @memset(bytes, 0);
        assert(bytes.len == model_cap);
        return .{ .bytes = bytes, .len = 0 };
    }

    fn deinit(model: *Model, gpa: std.mem.Allocator) void {
        assert(model.len <= model_cap);
        assert(model.bytes.len == model_cap);
        gpa.free(model.bytes);
        model.* = undefined;
    }

    fn write(model: *Model, data: []const u8, offset: usize) void {
        assert(offset + data.len <= model_cap);
        if (data.len == 0) return; // a zero-byte write never extends the file
        @memcpy(model.bytes[offset..][0..data.len], data);
        model.len = @max(model.len, offset + data.len);
        assert(model.len >= offset + data.len);
    }

    fn set_length(model: *Model, new_len: usize) void {
        assert(new_len <= model_cap);
        if (new_len < model.len) @memset(model.bytes[new_len..model.len], 0);
        model.len = new_len;
        assert(model.len == new_len);
    }

    /// Bytes `readAt` must return for `(offset, want)`: the count is clipped at EOF.
    fn read_count(model: Model, offset: usize, want: usize) usize {
        assert(model.len <= model_cap);
        if (offset >= model.len) return 0;
        const count = @min(want, model.len - offset);
        assert(count <= want);
        return count;
    }
};

/// Whole-file comparison against the model; run after every mutating step.
fn check_invariants(f: File, model: Model, scratch: []u8) !void {
    assert(model.len <= model_cap);
    assert(scratch.len >= model.len);
    assert(scratch.len >= 1); // The past-the-end probe below reads one byte into `scratch`.
    const io = testing.io;
    try testing.expectEqual(@as(u64, model.len), try f.length(io));
    try f.readAtAll(io, scratch[0..model.len], 0);
    try testing.expectEqualSlices(u8, model.bytes[0..model.len], scratch[0..model.len]);
    // One byte past the end must be unreadable: the file is not longer than the model.
    try testing.expectError(error.UnexpectedEof, f.readAtAll(io, scratch[0..1], model.len));
}

fn step_write(f: File, model: *Model, random: std.Random, step: u32) !void {
    assert(model.len <= model_cap);
    var data: [model_op_max]u8 = undefined;
    const data_len = random.uintAtMost(usize, model_op_max);
    pattern(data[0..data_len], step);
    const offset = random.uintAtMost(usize, model_cap - model_op_max);
    try f.writeAtAll(testing.io, data[0..data_len], offset);
    model.write(data[0..data_len], offset);
    assert(model.len <= model_cap);
}

fn step_read(f: File, model: Model, random: std.Random) !void {
    assert(model.len <= model_cap);
    var buf: [model_op_max]u8 = undefined;
    const want = random.uintAtMost(usize, model_op_max);
    const offset = random.uintAtMost(usize, model.len + 64);
    const expected_n = model.read_count(offset, want);
    const got = try f.readAt(testing.io, buf[0..want], offset);
    try testing.expectEqual(expected_n, got);
    const start = @min(offset, model.len); // `offset` may lie past the model; the slice is empty.
    const expected = model.bytes[start..][0..expected_n];
    try testing.expectEqualSlices(u8, expected, buf[0..got]);
    assert(got <= want);
}

test "file: seeded model — random writeAt/readAt/setLength match an in-memory reference" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;
    const f = try create_rw(tmp.dir, "model.bin");
    defer f.close(io);

    var model: Model = try .init(gpa);
    defer model.deinit(gpa);
    const scratch = try gpa.alloc(u8, model_cap);
    defer gpa.free(scratch);

    var prng: std.Random.DefaultPrng = .init(model_seed);
    const random = prng.random();
    var step: u32 = 0;
    while (step < model_steps) : (step += 1) {
        switch (random.uintLessThan(u8, 10)) {
            0...5 => try step_write(f, &model, random, step),
            6...8 => try step_read(f, model, random),
            9 => {
                const new_len = random.uintAtMost(usize, model_cap - model_op_max);
                try f.setLength(io, new_len);
                model.set_length(new_len);
            },
            else => unreachable, // `uintLessThan(u8, 10)` yields 0..9, all covered above.
        }
        try check_invariants(f, model, scratch);
    }
}

test "file: seeded model — close and reopen preserves the model's final image" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const gpa = testing.allocator;

    var model: Model = try .init(gpa);
    defer model.deinit(gpa);
    const scratch = try gpa.alloc(u8, model_cap);
    defer gpa.free(scratch);

    var prng: std.Random.DefaultPrng = .init(model_seed +% 1);
    const random = prng.random();
    for (0..4) |round| { // each round reopens the file, so state must survive close
        const f = try File.open(io, tmp.dir, "reopen.bin", .{ .create = true });
        defer f.close(io);
        try check_invariants(f, model, scratch);
        for (0..40) |i| try step_write(f, &model, random, @intCast(round * 100 + i));
        try check_invariants(f, model, scratch);
    }
    try testing.expect(model.len > 0);
}
