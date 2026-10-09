//! Seeded model test and fuzz target for `manager.zig` (plan 003 item 5): a fixed-seed op stream
//! of write and read against an in-memory reference array, compared after every step
//! (`check_invariants`), and a fuzz target that checks `open` against an oracle built from the
//! pure header codec alone.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("header.zig");
const fx = @import("manager_fixtures.zig");

const PageManager = @import("manager.zig").PageManager;
const opts = fx.opts;
const id_of = fx.id_of;
const write_file = fx.write_file;
const open_crafted = fx.open_crafted;
const page_count_max = fx.page_count_max;
const consumer_type = fx.consumer_type;

// ---------------------------------------------------------------------------------------------
// Seeded model test and fuzz target
// ---------------------------------------------------------------------------------------------

const model_seed: u64 = 0x57A7_A003_0005;
const model_steps: u32 = 200;
const model_pages: u32 = 16;
const model_size: u32 = 512;
const payload_len: usize = model_size - header.header_size;

/// Reference model: per page the payload, type and lsn last written, or "never written".
const Model = struct {
    payload: [model_pages][payload_len]u8,
    kind: [model_pages]header.Type,
    lsn: [model_pages]u64,
    written: [model_pages]bool,

    fn record(model: *Model, id: u32, buf: []const u8, kind: header.Type, lsn: u64) void {
        assert(id >= 1 and id < model_pages);
        assert(buf.len == model_size);
        @memcpy(&model.payload[id], buf[header.header_size..]);
        model.kind[id] = kind;
        model.lsn[id] = lsn;
        model.written[id] = true;
    }
};

/// Compares the whole file against the model: length, page 0, and every page raw on disk.
fn check_invariants(pm: *PageManager, model: *const Model, scratch: []u8) !void {
    assert(scratch.len == model_size);
    assert(!model.written[0]); // Page 0 is the manager's, never modelled.
    const io = testing.io;
    try testing.expectEqual(@as(u64, model_pages) * model_size, try pm.file.length(io));
    try pm.file.readAtAll(io, scratch, 0);
    const fh = try header.decode_file_header(scratch);
    try testing.expectEqual(model_pages, fh.page_count);
    for (1..model_pages) |index| {
        const id: u32 = @intCast(index);
        try pm.file.readAtAll(io, scratch, @as(u64, id) * model_size);
        if (!model.written[id]) {
            try testing.expect(std.mem.allEqual(u8, scratch, 0));
            continue;
        }
        const h = try header.decode(scratch, id_of(id));
        try testing.expectEqual(model.kind[id], h.page_type);
        try testing.expectEqual(model.lsn[id], h.lsn);
        try testing.expectEqualSlices(u8, &model.payload[id], scratch[header.header_size..]);
    }
}

fn model_step(pm: *PageManager, model: *Model, rng: std.Random, buf: []u8) !void {
    assert(buf.len == model_size);
    assert(model_pages <= page_count_max);
    const id = rng.intRangeAtMost(u32, 1, model_pages - 1);
    if (rng.boolean()) {
        rng.bytes(buf[header.header_size..]);
        const kind: header.Type = @enumFromInt(rng.intRangeAtMost(u8, 128, 255));
        const lsn = rng.int(u64);
        try pm.write(testing.io, id_of(id), buf, .{ .page_type = kind, .lsn = lsn });
        model.record(id, buf, kind, lsn);
        return;
    }
    @memset(buf, 0xEE);
    if (!model.written[id]) {
        try testing.expectError(error.Unwritten, pm.read(testing.io, id_of(id), buf));
        return;
    }
    const h = try pm.read(testing.io, id_of(id), buf);
    try testing.expectEqual(model.kind[id], h.page_type);
    try testing.expectEqual(model.lsn[id], h.lsn);
    try testing.expectEqualSlices(u8, &model.payload[id], buf[header.header_size..]);
}

test "manager: seeded write and read model matches a reference array after every step" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "model.db", model_size, model_pages);
    defer pm.close(testing.io);

    var model: Model = .{
        .payload = undefined,
        .kind = @splat(consumer_type),
        .lsn = @splat(0),
        .written = @splat(false),
    };
    var prng = std.Random.DefaultPrng.init(model_seed);
    var buf: [model_size]u8 = undefined;
    var scratch: [model_size]u8 = undefined;
    for (0..model_steps) |_| {
        try model_step(&pm, &model, prng.random(), &buf);
        try check_invariants(&pm, &model, &scratch);
    }
    var written: u32 = 0;
    for (model.written) |was| written += @intFromBool(was);
    try testing.expect(written >= 8); // The stream really exercised many pages.
}

/// Expected `open` outcome for a page-0 image kept in a file of `len` bytes, computed from the
/// pure codec only: null means success, otherwise the error `open` must return.
fn open_oracle(image: *const [512]u8, len: u64) ?anyerror {
    assert(image.len == header.page_size_min);
    assert(header.page_size_valid(512));
    if (len < image.len) return error.Corrupted;
    const size = header.peek_page_size(image) catch return error.Corrupted;
    if (size != image.len) return error.Corrupted;
    const fh = header.decode_file_header(image) catch |err| switch (err) {
        error.ChecksumMismatch => return error.ChecksumMismatch,
        error.Unwritten, error.Corrupted => return error.Corrupted,
    };
    if (len < @as(u64, fh.page_count) * image.len) return error.Corrupted;
    return null;
}

fn fuzz_open(_: void, smith: *std.testing.Smith) anyerror!void {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var image: [512]u8 = undefined;
    const count = smith.valueRangeAtMost(u32, 1, 8);
    assert(count >= 1);
    assert(count <= page_count_max);
    header.encode_file_header(&image, .{
        .page_size = 512,
        .page_count = count,
        .freelist_head = null,
        .wal_lsn = smith.value(u64),
    });
    const flips: usize = smith.valueRangeAtMost(u8, 0, 3);
    for (0..flips) |_| {
        image[smith.valueRangeAtMost(u32, 0, 511)] ^= smith.value(u8);
    }
    if (smith.value(bool)) { // Steer toward well-checksummed images so the deep checks run.
        header.encode(&image, .file_header, .{ .page_type = .file_header, .lsn = 0 });
    }
    const len = smith.valueRangeAtMost(u32, 0, 8 * 512);
    try write_file(tmp.dir, "fuzz.db", image[0..@min(len, 512)], len);

    var pm: PageManager = undefined;
    const opened = PageManager.open(&pm, testing.io, tmp.dir, "fuzz.db", opts(512));
    if (open_oracle(&image, len)) |expected| {
        try testing.expectError(expected, opened);
        return;
    }
    try opened;
    defer pm.close(testing.io);

    const fh = try header.decode_file_header(&image);
    try testing.expectEqual(fh.page_count, pm.page_count);
    try testing.expectEqual(fh.freelist_head, pm.freelist_head);
    try testing.expectEqual(fh.wal_lsn, pm.wal_lsn);
}

test "manager: fuzz open agrees with the pure codec oracle and never panics" {
    try std.testing.fuzz({}, fuzz_open, .{});
}
