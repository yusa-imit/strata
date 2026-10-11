//! Torn-page sweep over the real page codec at all eight page sizes (plan 003 item 9).
//!
//! The record matrix in `truncation_matrix_test.zig` proves the crash harness against a test-only
//! frame; this file feeds it the real thing. For every page size, 512 to 65536 bytes, a valid
//! `free_trunk` page and a valid file header page are written through a `CrashSink` and cut with
//! `.truncate` and `.torn` at every sampled point. The surviving image is padded with zeros to a
//! full page, which is what an unwritten tail looks like, and then:
//!   - `header.decode` / `header.decode_file_header` must accept it only when the padded image
//!     equals the original byte for byte, and otherwise fail with a typed error: `Unwritten` for
//!     an all-zero image, `ChecksumMismatch` or `Corrupted` for anything else;
//!   - `PageManager.read` over a file that ends inside the page is `TornWrite`, and over the same
//!     file zero-extended it must agree with the decoder;
//!   - `PageManager.open` over a torn page 0 is `Corrupted` or `ChecksumMismatch`, never open.
//! Silent acceptance of a damaged page is `error.AcceptedCorruptPage`. A decoder that skips the
//! checksum must make the sweep fail, so the sweep is shown able to fail.
//!
//! Cost bound: pages up to 4096 bytes are swept at every byte. Larger pages sweep every byte near
//! a 512-byte sector boundary (offset mod 512 in {0, 1, 511}), the first and last 64 bytes, and
//! one in `stride` bytes elsewhere. The file-backed sweeps skip the stride and use the dense rule
//! only up to 2048 bytes. Every sweep is bounded by `TruncationPoints` over `page_size + 1`.
//!
//! Allocation: each sweep allocates four page-sized buffers and frees them before returning.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const manager = @import("../page/manager.zig");
const crash = @import("crash.zig");

const CrashSink = crash.CrashSink;
const Cut = crash.Cut;
const TruncationPoints = crash.TruncationPoints;
const PageManager = manager.PageManager;
const Id = header.Id;

const Decode = fn (page: []const u8) header.DecodeError!void;

/// Id of the swept page; id 1 so a `PageManager` over a two-page file can read it.
const page_id: Id = @enumFromInt(1);
const page_count_file: u32 = 7;
const lsn_test: u64 = 0x0102_0304_0506_0708;
const stride: u64 = 127;
const edge_width: u64 = 64;
const dense_limit_bytes: u32 = 4096;
const sparse_limit_bytes: u32 = 2048;
const file_name = "matrix.db";

/// Which valid page image a sweep cuts.
const Kind = enum { trunk, file_header };

/// Outcome counts of one sweep; every cut lands in exactly one of the first five buckets.
const Tally = struct {
    unwritten: u32 = 0,
    checksum_mismatch: u32 = 0,
    corrupted: u32 = 0,
    accepted: u32 = 0,
    torn_write: u32 = 0,
    cuts: u32 = 0,
};

/// The valid page, sink storage, persisted image scratch and the zero-padded image.
const Buffers = struct {
    original: []u8,
    storage: []u8,
    scratch: []u8,
    padded: []u8,

    fn init(gpa: std.mem.Allocator, size: u32) !Buffers {
        assert(header.page_size_valid(size));
        const original = try gpa.alloc(u8, size);
        errdefer gpa.free(original);

        const storage = try gpa.alloc(u8, size);
        errdefer gpa.free(storage);

        const scratch = try gpa.alloc(u8, size);
        errdefer gpa.free(scratch);

        const padded = try gpa.alloc(u8, size);
        errdefer gpa.free(padded);

        assert(original.len == padded.len);
        return .{ .original = original, .storage = storage, .scratch = scratch, .padded = padded };
    }

    fn deinit(self: Buffers, gpa: std.mem.Allocator) void {
        assert(self.original.len == self.storage.len);
        assert(self.scratch.len == self.padded.len);
        gpa.free(self.original);
        gpa.free(self.storage);
        gpa.free(self.scratch);
        gpa.free(self.padded);
    }
};

/// Builds a valid page of `kind` into `page`: the trunk page has a non-zero payload to its last
/// byte, and the file header ends in a non-zero byte at offset 47, so no cut that loses a byte
/// of content can pad back to the original.
fn build_page(page: []u8, kind: Kind) void {
    assert(header.page_size_valid(@intCast(page.len)));
    switch (kind) {
        .trunk => {
            for (page[header.header_size..], 0..) |*byte, i| {
                const mixed: u32 = @as(u32, @truncate(i)) *% 131 +% 7;
                byte.* = @intCast(1 + mixed % 251);
            }
            header.encode(page, page_id, .{ .page_type = .free_trunk, .lsn = lsn_test });
        },
        .file_header => header.encode_file_header(page, .{
            .page_size = @intCast(page.len),
            .page_count = page_count_file,
            .freelist_head = @enumFromInt(5),
            .wal_lsn = lsn_test,
        }),
    }
    assert(page[page.len - 1] != 0 or kind == .file_header);
    assert(!std.mem.allEqual(u8, page, 0));
}

fn decode_trunk_page(page: []const u8) header.DecodeError!void {
    assert(header.page_size_valid(@intCast(page.len)));
    const decoded = try header.decode(page, page_id);
    assert(decoded.page_type == .free_trunk);
}

fn decode_file_page(page: []const u8) header.DecodeError!void {
    assert(header.page_size_valid(@intCast(page.len)));
    const file_header = try header.decode_file_header(page);
    assert(file_header.page_size == page.len);
}

/// Deliberately broken: trusts magic and version and never checks the checksum.
fn decode_unchecked(page: []const u8) header.DecodeError!void {
    assert(header.page_size_valid(@intCast(page.len)));
    assert(header.header_size == 24);
    if (std.mem.allEqual(u8, page, 0)) return error.Unwritten;
    if (!std.mem.eql(u8, page[0..header.magic.len], &header.magic)) return error.Corrupted;
    const version_offset = 6; // ADR-0002 page header: magic 0..4, type 4, flags 5, version 6..8.
    const version = std.mem.readInt(u16, page[version_offset..][0..2], .little);
    if (version != header.format_version) return error.Corrupted;
}

/// Deliberately broken: rejects every written page, including the intact one.
fn decode_always_corrupt(page: []const u8) header.DecodeError!void {
    assert(header.page_size_valid(@intCast(page.len)));
    assert(page.len >= header.page_size_min);
    if (std.mem.allEqual(u8, page, 0)) return error.Unwritten;
    return error.Corrupted;
}

/// True when the sweep visits `point`; `dense` selects the decode sweep, otherwise the cheaper
/// file-backed rule. Always true for the first and last `edge_width` bytes.
fn point_wanted(size: u32, point: u64, dense: bool) bool {
    assert(header.page_size_valid(size));
    assert(point <= size);
    const limit: u32 = if (dense) dense_limit_bytes else sparse_limit_bytes;
    if (size <= limit) return true;
    if (point < edge_width or point + edge_width >= size) return true;
    const in_sector = point % crash.sector_size;
    if (in_sector <= 1 or in_sector == crash.sector_size - 1) return true;
    return dense and point % stride == 0;
}

/// Replays the original page into a fresh sink under `cut` (second half first: the image must not
/// depend on write order), then zero-pads the survivor into `buffers.padded`. Returns the length
/// of the surviving image before padding.
fn persist(buffers: Buffers, cut: Cut, seed: u64) !u32 {
    const size = buffers.original.len;
    assert(buffers.storage.len == size);
    assert(buffers.padded.len == size);
    var sink: CrashSink = undefined;
    try sink.init(buffers.storage, cut, seed);
    const half = size / 2;
    const second = try sink.writeAt(buffers.original[half..], half);
    const first = try sink.writeAt(buffers.original[0..half], 0);
    try testing.expectEqual(size - half, second);
    try testing.expectEqual(half, first);
    sink.check_invariants();

    const image = try sink.persisted_into(buffers.scratch);
    assert(image.len <= size);
    @memcpy(buffers.padded[0..image.len], image);
    @memset(buffers.padded[image.len..], 0);
    return @intCast(image.len);
}

/// Classifies one decode outcome against the padded image: accepted only when it equals the
/// original, `Unwritten` only for an all-zero image, otherwise `ChecksumMismatch` or `Corrupted`.
fn judge(failure: ?anyerror, buffers: Buffers, tally: *Tally) !void {
    assert(buffers.padded.len == buffers.original.len);
    const identical = std.mem.eql(u8, buffers.padded, buffers.original);
    const zeroed = std.mem.allEqual(u8, buffers.padded, 0);
    assert(!(identical and zeroed)); // `build_page` never yields an all-zero page.
    tally.cuts += 1;
    const err = failure orelse {
        if (!identical) return error.AcceptedCorruptPage;
        tally.accepted += 1;
        return;
    };
    if (identical) return error.RejectedIntactPage;
    switch (err) {
        error.Unwritten => {
            if (!zeroed) return error.UnwrittenButNonzero;
            tally.unwritten += 1;
        },
        error.ChecksumMismatch => {
            if (zeroed) return error.ZeroImageNotUnwritten;
            tally.checksum_mismatch += 1;
        },
        error.Corrupted => {
            if (zeroed) return error.ZeroImageNotUnwritten;
            tally.corrupted += 1;
        },
        else => return error.UntypedFailure,
    }
}

fn check_decode_cut(
    comptime decode: Decode,
    buffers: Buffers,
    cut: Cut,
    seed: u64,
    tally: *Tally,
) !void {
    assert(buffers.original.len == buffers.padded.len);
    const image_len = try persist(buffers, cut, seed);
    assert(image_len <= buffers.original.len);
    const failure: ?anyerror = if (decode(buffers.padded)) |_| null else |err| err;
    try judge(failure, buffers, tally);
}

/// Sweeps the sampled truncation points of a valid `kind` page of `size` bytes with both cuts.
fn run_decode_sweep(
    comptime decode: Decode,
    kind: Kind,
    size: u32,
    seed: u64,
) !Tally {
    assert(header.page_size_valid(size));
    const buffers = try Buffers.init(testing.allocator, size);
    defer buffers.deinit(testing.allocator);

    build_page(buffers.original, kind);
    var tally: Tally = .{};
    var points = try TruncationPoints.init(size, size + 1);
    while (points.next()) |point| {
        if (!point_wanted(size, point, true)) continue;
        try check_decode_cut(decode, buffers, .{ .truncate = point }, seed, &tally);
        try check_decode_cut(decode, buffers, .{ .torn = point }, seed, &tally);
    }
    assert(tally.cuts > 0);
    return tally;
}

fn expect_sweep_shape(tally: Tally, kind: Kind) !void {
    try testing.expectEqual(tally.cuts, tally.unwritten + tally.checksum_mismatch +
        tally.corrupted + tally.accepted);
    // Only cuts at byte 0 are an all-zero image: a torn cut on a sector boundary has no garbage
    // range, so `.torn = 0` is the same empty image as `.truncate = 0`.
    try testing.expectEqual(@as(u32, 2), tally.unwritten);
    try testing.expect(tally.checksum_mismatch >= 1);
    try testing.expect(tally.corrupted >= 1);
    switch (kind) {
        // The payload is non-zero to the last byte: only the two full-page cuts are intact.
        .trunk => try testing.expectEqual(@as(u32, 2), tally.accepted),
        // Bytes past offset 48 are zero by construction, so cuts there pad back to the original.
        .file_header => try testing.expect(tally.accepted >= 2 and tally.accepted < tally.cuts),
    }
}

test "page matrix: free_trunk page is rejected at every sampled cut at all 8 sizes" {
    for (fx.sizes_all) |size| {
        const tally = try run_decode_sweep(decode_trunk_page, .trunk, size, 0x5eed_1000 + size);
        try expect_sweep_shape(tally, .trunk);
    }
}

test "page matrix: file header page is rejected at every sampled cut at all 8 sizes" {
    for (fx.sizes_all) |size| {
        const seed = 0x5eed_2000 + size;
        const tally = try run_decode_sweep(decode_file_page, .file_header, size, seed);
        try expect_sweep_shape(tally, .file_header);
    }
}

test "page matrix: other seeds change the garbage but never the verdict" {
    for ([_]u64{ 1, 2, 0xdead_beef, std.math.maxInt(u64) }) |seed| {
        const trunk = try run_decode_sweep(decode_trunk_page, .trunk, 1024, seed);
        try expect_sweep_shape(trunk, .trunk);
        const file_header = try run_decode_sweep(decode_file_page, .file_header, 1024, seed);
        try expect_sweep_shape(file_header, .file_header);
    }
}

test "page matrix: sampling covers sector boundaries, edges and the whole small pages" {
    for (fx.sizes_all) |size| {
        try testing.expect(point_wanted(size, 0, true));
        try testing.expect(point_wanted(size, size, true));
        try testing.expect(point_wanted(size, 512, true) or size == 512);
        try testing.expect(point_wanted(size, size - 1, false));
    }
    try testing.expect(point_wanted(4096, 1234, true)); // Dense up to 4096 bytes.
    try testing.expect(!point_wanted(8192, 1234, true)); // Mid-sector, off the stride.
    try testing.expect(point_wanted(8192, 1024 + 511, true));
    try testing.expect(point_wanted(65536, 32768 + 1, false));
    try testing.expect(!point_wanted(65536, 32768 + 2, false));
}

test "page matrix: a decoder that skips the checksum fails the sweep" {
    try testing.expectError(
        error.AcceptedCorruptPage,
        run_decode_sweep(decode_unchecked, .trunk, 512, 0x5eed_3001),
    );
    try testing.expectError(
        error.AcceptedCorruptPage,
        run_decode_sweep(decode_unchecked, .file_header, 4096, 0x5eed_3002),
    );
    // The real decoder passes the very same pages.
    const trunk = try run_decode_sweep(decode_trunk_page, .trunk, 512, 0x5eed_3001);
    try expect_sweep_shape(trunk, .trunk);
}

test "page matrix: a decoder that rejects the intact page fails the sweep" {
    try testing.expectError(
        error.RejectedIntactPage,
        run_decode_sweep(decode_always_corrupt, .trunk, 512, 0x5eed_3003),
    );
}

/// Checks `PageManager.read` of page 1 after `cut`: a file ending inside the page is `TornWrite`,
/// and the same file zero-extended to two pages must agree with the decoder's verdict.
fn check_read_cut(pm: *PageManager, buffers: Buffers, cut: Cut, seed: u64, tally: *Tally) !void {
    const io = testing.io;
    const size = pm.page_size;
    assert(buffers.original.len == size);
    assert(pm.page_count == 2);
    const image_len = try persist(buffers, cut, seed);
    try pm.file.setLength(io, size); // Drops page 1; page 0 stays intact.
    if (image_len > 0) try pm.file.writeAtAll(io, buffers.padded[0..image_len], size);
    try testing.expectEqual(@as(u64, size) + image_len, try pm.file.length(io));

    const read_buf = buffers.storage; // The sink is dead after `persist`.
    if (image_len < size) {
        try testing.expectError(error.TornWrite, pm.read(io, page_id, read_buf));
        tally.torn_write += 1;
        try pm.file.setLength(io, 2 * @as(u64, size));
    }
    const failure: ?anyerror = if (pm.read(io, page_id, read_buf)) |_| null else |err| err;
    try judge(failure, buffers, tally);
}

fn run_read_sweep(size: u32, seed: u64) !Tally {
    assert(header.page_size_valid(size));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try fx.craft(tmp.dir, file_name, fx.fh_of(size, 2), 2 * @as(u64, size));
    var pm: PageManager = undefined;
    try PageManager.open(&pm, testing.io, tmp.dir, file_name, fx.opts(size));
    defer pm.close(testing.io);

    const buffers = try Buffers.init(testing.allocator, size);
    defer buffers.deinit(testing.allocator);

    build_page(buffers.original, .trunk);
    var tally: Tally = .{};
    var points = try TruncationPoints.init(size, size + 1);
    while (points.next()) |point| {
        if (!point_wanted(size, point, false)) continue;
        try check_read_cut(&pm, buffers, .{ .truncate = point }, seed, &tally);
        try check_read_cut(&pm, buffers, .{ .torn = point }, seed, &tally);
    }
    assert(tally.cuts > 0);
    return tally;
}

test "page matrix: PageManager.read of a cut page is TornWrite or a typed decode error" {
    for (fx.sizes_all) |size| {
        const tally = try run_read_sweep(size, 0x5eed_4000 + size);
        try expect_sweep_shape(tally, .trunk);
        // Every cut that leaves a short file is torn; only the cuts at the full size are not.
        try testing.expect(tally.torn_write >= size / crash.sector_size);
        try testing.expect(tally.torn_write < tally.cuts);
    }
}

/// `PageManager.open` over page 0 after `cut`: a file too short for page 0 is `Corrupted`; the
/// zero-extended file opens only when the padded image is the original.
fn check_open_cut(dir: std.Io.Dir, buffers: Buffers, cut: Cut, seed: u64, tally: *Tally) !void {
    const io = testing.io;
    const size: u32 = @intCast(buffers.original.len);
    assert(header.page_size_valid(size));
    assert(tally.cuts < std.math.maxInt(u32));
    const image_len = try persist(buffers, cut, seed);
    const image = buffers.padded[0..image_len];
    if (image_len < size) {
        try fx.write_file(dir, file_name, image, image_len);
        try fx.expect_open_error(error.Corrupted, dir, file_name, size);
    }
    try fx.write_file(dir, file_name, image, page_count_file * @as(u64, size));
    const identical = std.mem.eql(u8, buffers.padded, buffers.original);
    tally.cuts += 1;
    var pm: PageManager = undefined;
    if (PageManager.open(&pm, io, dir, file_name, fx.opts(size))) {
        pm.close(io);
        if (!identical) return error.AcceptedCorruptPage;
        tally.accepted += 1;
    } else |err| {
        if (identical) return error.RejectedIntactPage;
        switch (err) {
            error.Corrupted => tally.corrupted += 1,
            error.ChecksumMismatch => tally.checksum_mismatch += 1,
            else => return error.UntypedFailure,
        }
    }
}

fn run_open_sweep(size: u32, seed: u64) !Tally {
    assert(header.page_size_valid(size));
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const buffers = try Buffers.init(testing.allocator, size);
    defer buffers.deinit(testing.allocator);

    build_page(buffers.original, .file_header);
    var tally: Tally = .{};
    var points = try TruncationPoints.init(size, size + 1);
    while (points.next()) |point| {
        if (!point_wanted(size, point, false)) continue;
        try check_open_cut(tmp.dir, buffers, .{ .truncate = point }, seed, &tally);
        try check_open_cut(tmp.dir, buffers, .{ .torn = point }, seed, &tally);
    }
    assert(tally.cuts > 0);
    return tally;
}

test "page matrix: PageManager.open of a cut page 0 is Corrupted or ChecksumMismatch" {
    for (fx.sizes_all) |size| {
        const tally = try run_open_sweep(size, 0x5eed_5000 + size);
        try testing.expectEqual(tally.cuts, tally.corrupted + tally.checksum_mismatch +
            tally.accepted);
        try testing.expect(tally.accepted >= 2 and tally.accepted < tally.cuts);
        try testing.expect(tally.corrupted >= 1);
        try testing.expect(tally.checksum_mismatch >= 1);
    }
}
