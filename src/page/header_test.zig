//! Contract tests for `header.zig` (ADR-0002 page format v1), kept in their own file so the
//! codec stays under the 800-line file limit (same split as `file/file_model_test.zig`).
//!
//! Every expected value is derived independently of the codec: `reference_checksum` rebuilds the
//! ADR section 2 byte string by hand, and the golden images are committed hex literals.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("../codec.zig");
const h = @import("header.zig");

const header_size = h.header_size;
const file_header_size = h.file_header_size;
const page_size_min = h.page_size_min;
const page_size_max = h.page_size_max;
const format_version = h.format_version;
const magic = h.magic;
const Id = h.Id;
const Type = h.Type;
const Header = h.Header;
const FileHeader = h.FileHeader;
const DecodeError = h.DecodeError;
const page_size_valid = h.page_size_valid;
const checksum = h.checksum;
const encode = h.encode;
const decode = h.decode;
const encode_file_header = h.encode_file_header;
const decode_file_header = h.decode_file_header;
const peek_page_size = h.peek_page_size;

const page_sizes = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };

/// Independent re-derivation of ADR-0002 section 2: a scratch copy with the checksum field zeroed
/// and the u64 little-endian zero-extended id prepended, hashed in one shot.
fn reference_checksum(gpa: std.mem.Allocator, page: []const u8, id: Id) !u32 {
    assert(page.len >= header_size);
    assert(page.len <= page_size_max);
    const scratch = try gpa.alloc(u8, 8 + page.len);
    defer gpa.free(scratch);
    std.mem.writeInt(u64, scratch[0..8], @intFromEnum(id), .little);
    @memcpy(scratch[8..], page);
    @memset(scratch[16..20], 0);
    return codec.crc32c.checksum(scratch);
}

/// Stores the reference checksum of `page` under `id` in bytes 8..12.
fn restamp(gpa: std.mem.Allocator, page: []u8, id: Id) !void {
    assert(page.len >= header_size);
    const sum = try reference_checksum(gpa, page, id);
    std.mem.writeInt(u32, page[8..12], sum, .little);
    assert(std.mem.readInt(u32, page[8..12], .little) == sum);
}

/// Overwrites `page[offset..]` with `bytes`, then restamps so only the targeted rule can fire.
fn patch_restamp(
    gpa: std.mem.Allocator,
    page: []u8,
    id: Id,
    offset: usize,
    bytes: []const u8,
) !void {
    assert(offset + bytes.len <= page.len);
    assert(bytes.len > 0);
    @memcpy(page[offset..][0..bytes.len], bytes);
    try restamp(gpa, page, id);
}

fn random_page(gpa: std.mem.Allocator, random: std.Random, size: u32) ![]u8 {
    assert(size >= page_size_min);
    assert(size <= page_size_max);
    const page = try gpa.alloc(u8, size);
    random.bytes(page);
    return page;
}

fn encode_any(page: []u8, id: Id, lsn: u64) void {
    assert(page.len <= page_size_max);
    const page_type: Type = if (id == .file_header) .file_header else .free_trunk;
    encode(page, id, .{ .page_type = page_type, .lsn = lsn });
    assert(page.len >= page_size_min);
}

/// Null on success; the error otherwise. `as_file_header` routes through `decode_file_header`.
fn decode_failure(page: []const u8, id: Id, as_file_header: bool) ?DecodeError {
    assert(page.len >= header_size);
    assert(!as_file_header or id == .file_header);
    if (as_file_header) {
        _ = decode_file_header(page) catch |err| return err;
    } else {
        _ = decode(page, id) catch |err| return err;
    }
    return null;
}

fn file_header_page(gpa: std.mem.Allocator, size: u32, file_header: FileHeader) ![]u8 {
    assert(size >= page_size_min);
    assert(file_header.page_size == size);
    const page = try gpa.alloc(u8, size);
    @memset(page, 0xAA); // Garbage first: encode_file_header must clear the whole page itself.
    encode_file_header(page, file_header);
    return page;
}

fn id_of(value: u32) Id {
    const id: Id = @enumFromInt(value);
    assert(@intFromEnum(id) == value);
    assert((id == .file_header) == (value == 0));
    return id;
}

/// Magic and version bytes are judged before the checksum; every other byte is checksum-covered.
fn flip_expected(byte_index: usize) DecodeError {
    assert(byte_index < page_size_max);
    const in_magic = byte_index < 4;
    const in_version = byte_index >= 6 and byte_index < 8;
    assert(!(in_magic and in_version));
    return if (in_magic or in_version) error.Corrupted else error.ChecksumMismatch;
}

fn expect_every_flip_rejected(page: []u8, id: Id, as_file_header: bool) !void {
    assert(page.len == page_size_min);
    assert(as_file_header == (id == .file_header));
    try std.testing.expectEqual(@as(?DecodeError, null), decode_failure(page, id, as_file_header));
    for (0..page.len) |byte_index| {
        const expected: ?DecodeError = flip_expected(byte_index);
        for (0..8) |bit_index| {
            const mask = @as(u8, 1) << @intCast(bit_index);
            page[byte_index] ^= mask;
            const actual = decode_failure(page, id, as_file_header);
            page[byte_index] ^= mask;
            try std.testing.expectEqual(expected, actual);
        }
    }
    try std.testing.expectEqual(@as(?DecodeError, null), decode_failure(page, id, as_file_header));
}

test "page header: encode then decode round-trips type and lsn at all 8 page sizes" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5724_0001);
    const random = prng.random();
    for (page_sizes) |size| {
        const page = try random_page(gpa, random, size);
        defer gpa.free(page);
        const payload = try gpa.dupe(u8, page[header_size..]);
        defer gpa.free(payload);
        const id = id_of(random.intRangeAtMost(u32, 1, std.math.maxInt(u32)));
        const expected: Header = .{ .page_type = .free_trunk, .lsn = random.int(u64) };
        encode(page, id, expected);
        const actual = try decode(page, id);
        try std.testing.expectEqual(expected.page_type, actual.page_type);
        try std.testing.expectEqual(expected.lsn, actual.lsn);
        try std.testing.expectEqualSlices(u8, payload, page[header_size..]);
    }
}

test "page header: round trip holds for boundary ids, lsn values, and consumer types" {
    const gpa = std.testing.allocator;
    var page: [512]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0x5724_0002);
    const ids = [_]u32{ 1, 2, 0x8000_0000, std.math.maxInt(u32) - 1, std.math.maxInt(u32) };
    const lsns = [_]u64{ 0, 1, 0x1_0000_0000, std.math.maxInt(u64) };
    const types = [_]u8{ 2, 128, 200, 255 };
    for (ids) |id_value| {
        for (lsns) |lsn| {
            for (types) |type_byte| {
                prng.random().bytes(&page);
                const expected: Header = .{ .page_type = @enumFromInt(type_byte), .lsn = lsn };
                encode(&page, id_of(id_value), expected);
                const actual = try decode(&page, id_of(id_value));
                try std.testing.expectEqual(expected.page_type, actual.page_type);
                try std.testing.expectEqual(lsn, actual.lsn);
                const sum = try reference_checksum(gpa, &page, id_of(id_value));
                try std.testing.expectEqual(sum, std.mem.readInt(u32, page[8..12], .little));
            }
        }
    }
    prng.random().bytes(&page);
    encode(&page, .file_header, .{ .page_type = .file_header, .lsn = 77 });
    const at_zero = try decode(&page, .file_header);
    try std.testing.expectEqual(Type.file_header, at_zero.page_type);
    try std.testing.expectEqual(@as(u64, 77), at_zero.lsn);
}

test "page header: golden 512 B image pins every header offset and the checksum rule" {
    const gpa = std.testing.allocator;
    const id = id_of(0x1234);
    const payload_head = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 0x01, 0x02, 0x03, 0x04 };
    var page: [512]u8 = @splat(0);
    @memcpy(page[24..32], &payload_head);
    page[511] = 0xA5;
    encode(&page, id, .{ .page_type = .free_trunk, .lsn = 0x1122334455667788 });

    // Committed image: magic, type, flags, version, checksum, reserved, lsn (all little-endian).
    const golden_header = [24]u8{
        0x53, 0x54, 0x52, 0x41, 0x02, 0x00, 0x01, 0x00,
        0x7A, 0x87, 0xD2, 0x76, 0x00, 0x00, 0x00, 0x00,
        0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11,
    };
    try std.testing.expectEqualSlices(u8, &golden_header, page[0..24]);
    try std.testing.expectEqualSlices(u8, "STRA", page[0..4]);
    try std.testing.expectEqual(@as(u8, 2), page[4]);
    try std.testing.expectEqual(@as(u8, 0), page[5]);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x00 }, page[6..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, page[12..16]);
    const lsn_bytes = [_]u8{ 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11 };
    try std.testing.expectEqualSlices(u8, &lsn_bytes, page[16..24]);

    const reference = try reference_checksum(gpa, &page, id);
    try std.testing.expectEqual(@as(u32, 0x76D2877A), reference);
    try std.testing.expectEqual(reference, std.mem.readInt(u32, page[8..12], .little));
    try std.testing.expectEqual(reference, checksum(&page, id));

    try std.testing.expectEqualSlices(u8, &payload_head, page[24..32]);
    try std.testing.expect(std.mem.allEqual(u8, page[32..511], 0));
    try std.testing.expectEqual(@as(u8, 0xA5), page[511]);
    const decoded = try decode(&page, id);
    try std.testing.expectEqual(Type.free_trunk, decoded.page_type);
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), decoded.lsn);
}

test "page header: checksum matches the independent derivation and ignores its own field" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5724_0003);
    const random = prng.random();
    for (page_sizes) |size| {
        const page = try random_page(gpa, random, size);
        defer gpa.free(page);
        const id = id_of(random.int(u32));
        const expected = try reference_checksum(gpa, page, id);
        try std.testing.expectEqual(expected, checksum(page, id));
        @memset(page[8..12], 0xFF); // The stored checksum field is read as zero.
        try std.testing.expectEqual(expected, checksum(page, id));
        page[size - 1] ^= 0x01; // But every other byte, including the last, is covered.
        try std.testing.expect(expected != checksum(page, id));
    }
}

test "page header: checksum differs for every single-bit change of the id" {
    var page: [512]u8 = @splat(0x5A);
    const base = id_of(0xA5A5_5A5A);
    const base_sum = checksum(&page, base);
    for (0..32) |bit_index| {
        const other = id_of(@intFromEnum(base) ^ (@as(u32, 1) << @intCast(bit_index)));
        try std.testing.expect(base_sum != checksum(&page, other));
    }
    try std.testing.expect(checksum(&page, .file_header) != checksum(&page, id_of(1)));
}

test "page header: every single-bit flip of a 512 B page is rejected with the region's error" {
    var prng = std.Random.DefaultPrng.init(0x5724_0004);
    var page: [512]u8 = undefined;
    prng.random().bytes(&page);
    encode(&page, id_of(9), .{ .page_type = .free_trunk, .lsn = prng.random().int(u64) });
    try expect_every_flip_rejected(&page, id_of(9), false);
}

test "page header: every single-bit flip of a 512 B file header page is rejected" {
    const gpa = std.testing.allocator;
    const page = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 40,
        .freelist_head = id_of(7),
        .wal_lsn = 0x0123_4567_89AB_CDEF,
    });
    defer gpa.free(page);
    try expect_every_flip_rejected(page, .file_header, true);
}

test "page header: a valid page decoded under any other id is a checksum mismatch" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5724_0005);
    const random = prng.random();
    const edges = [_]u32{ 0, 1, 2, 0x7FFF_FFFF, 0x8000_0000, std.math.maxInt(u32) };
    for ([_]u32{ 512, 4096 }) |size| {
        const page = try random_page(gpa, random, size);
        defer gpa.free(page);
        for (0..60) |round| {
            const a = if (round < edges.len) id_of(edges[round]) else id_of(random.int(u32));
            encode_any(page, a, random.int(u64));
            _ = try decode(page, a);
            for (0..16) |_| {
                const b = id_of(random.int(u32));
                if (a == b) continue;
                try std.testing.expectError(error.ChecksumMismatch, decode(page, b));
            }
            for (edges) |edge| {
                if (id_of(edge) == a) continue;
                try std.testing.expectError(error.ChecksumMismatch, decode(page, id_of(edge)));
            }
            for (0..32) |bit_index| {
                const b = id_of(@intFromEnum(a) ^ (@as(u32, 1) << @intCast(bit_index)));
                try std.testing.expectError(error.ChecksumMismatch, decode(page, b));
            }
        }
    }
}

test "page header: all-zero pages are unwritten at all 8 sizes and under any id" {
    const gpa = std.testing.allocator;
    for (page_sizes) |size| {
        const page = try gpa.alloc(u8, size);
        defer gpa.free(page);
        @memset(page, 0);
        try std.testing.expectError(error.Unwritten, decode(page, .file_header));
        try std.testing.expectError(error.Unwritten, decode(page, id_of(1)));
        try std.testing.expectError(error.Unwritten, decode(page, id_of(std.math.maxInt(u32))));
        try std.testing.expectError(error.Unwritten, decode_file_header(page));
    }
}

test "page header: zero magic with any non-zero byte after it is corrupted, never unwritten" {
    const gpa = std.testing.allocator;
    var page: [512]u8 = @splat(0);
    try std.testing.expectError(error.Unwritten, decode(&page, id_of(3))); // The boundary case.
    for (4..page.len) |offset| {
        @memset(&page, 0);
        page[offset] = 1;
        try std.testing.expectError(error.Corrupted, decode(&page, id_of(3)));
        try std.testing.expectError(error.Corrupted, decode(&page, .file_header));
    }
    for (page_sizes) |size| {
        const big = try gpa.alloc(u8, size);
        defer gpa.free(big);
        @memset(big, 0);
        big[size - 1] = 0x80;
        try std.testing.expectError(error.Corrupted, decode(big, id_of(3)));
    }
    @memset(&page, 0);
    @memcpy(page[0..3], "STR"); // A torn magic is not zero, and not valid.
    try std.testing.expectError(error.Corrupted, decode(&page, id_of(3)));
    @memcpy(page[0..4], "STRA"); // Valid magic over an all-zero rest: version 0.
    try std.testing.expectError(error.Corrupted, decode(&page, id_of(3)));
}

test "page header: torn page is a mismatch if sector 0 survives, corrupted if it is lost" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5724_0006);
    const page = try random_page(gpa, prng.random(), 4096);
    defer gpa.free(page);
    encode(page, id_of(21), .{ .page_type = .free_trunk, .lsn = 5 });
    _ = try decode(page, id_of(21));
    const torn = try gpa.dupe(u8, page);
    defer gpa.free(torn);
    @memset(torn[512..], 0); // New first sector, zero tail.
    try std.testing.expectError(error.ChecksumMismatch, decode(torn, id_of(21)));
    @memcpy(torn, page);
    @memset(torn[0..512], 0); // Lost first sector in front of live data.
    try std.testing.expectError(error.Corrupted, decode(torn, id_of(21)));
}

test "page header: a wrong version is corrupted even when the checksum is valid or stale" {
    const gpa = std.testing.allocator;
    var page: [512]u8 = @splat(0x11);
    encode(&page, id_of(5), .{ .page_type = .free_trunk, .lsn = 1 });
    const base = page;
    for ([_]u16{ 0, 2, 0x0100, 0xFFFF }) |version| {
        page = base;
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, version, .little);
        try patch_restamp(gpa, &page, id_of(5), 6, &bytes);
        try std.testing.expectError(error.Corrupted, decode(&page, id_of(5)));
        page = base;
        @memcpy(page[6..8], &bytes); // Stale checksum: version is judged before the checksum.
        try std.testing.expectError(error.Corrupted, decode(&page, id_of(5)));
    }
    page = base;
    const stored = std.mem.readInt(u16, page[6..8], .little);
    try std.testing.expectEqual(@as(u16, format_version), stored);
    _ = try decode(&page, id_of(5));
}

test "page header: every page_type byte is classified per ADR section 1 at id 5" {
    const gpa = std.testing.allocator;
    var base: [512]u8 = @splat(0x22);
    encode(&base, id_of(5), .{ .page_type = .free_trunk, .lsn = 9 });
    for (0..256) |type_value| {
        var page = base;
        page[4] = @intCast(type_value);
        try restamp(gpa, &page, id_of(5));
        const accepted = type_value == 2 or type_value >= 128;
        if (accepted) {
            const header = try decode(&page, id_of(5));
            const returned: u8 = @intFromEnum(header.page_type);
            try std.testing.expectEqual(@as(u8, @intCast(type_value)), returned);
            try std.testing.expectEqual(@as(u64, 9), header.lsn);
        } else {
            try std.testing.expectError(error.Corrupted, decode(&page, id_of(5)));
        }
    }
    var stale = base;
    stale[4] = 3; // Unchecked type byte with a stale checksum is a mismatch, not corrupted.
    try std.testing.expectError(error.ChecksumMismatch, decode(&stale, id_of(5)));
}

test "page header: only file_header is accepted at id 0, and id 0 accepts nothing else" {
    const gpa = std.testing.allocator;
    const base = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 3,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    defer gpa.free(base);
    for (0..256) |type_value| {
        const page = try gpa.dupe(u8, base);
        defer gpa.free(page);
        page[4] = @intCast(type_value);
        try restamp(gpa, page, .file_header);
        if (type_value == 1) {
            const header = try decode(page, .file_header);
            try std.testing.expectEqual(Type.file_header, header.page_type);
        } else {
            try std.testing.expectError(error.Corrupted, decode(page, .file_header));
            try std.testing.expectError(error.Corrupted, decode_file_header(page));
        }
    }
}

test "page header: non-zero flags or reserved bytes with a valid checksum are corrupted" {
    const gpa = std.testing.allocator;
    var base: [512]u8 = @splat(0x33);
    encode(&base, id_of(5), .{ .page_type = .free_trunk, .lsn = 4 });
    for ([_]u8{ 0x01, 0x80, 0xFF }) |flags| {
        var page = base;
        try patch_restamp(gpa, &page, id_of(5), 5, &.{flags});
        try std.testing.expectError(error.Corrupted, decode(&page, id_of(5)));
    }
    for (12..16) |offset| {
        var page = base;
        try patch_restamp(gpa, &page, id_of(5), offset, &.{0x01});
        try std.testing.expectError(error.Corrupted, decode(&page, id_of(5)));
    }
    var stale = base;
    stale[5] = 1; // Without a restamp the checksum is what notices.
    try std.testing.expectError(error.ChecksumMismatch, decode(&stale, id_of(5)));
    _ = try decode(&base, id_of(5));
}

test "page header: encode canonicalizes flags and reserved over a dirty header area" {
    var page: [512]u8 = @splat(0xFF);
    encode(&page, id_of(8), .{ .page_type = .free_trunk, .lsn = 0 });
    try std.testing.expectEqual(@as(u8, 0), page[5]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, page[12..16]);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, page[16..24]);
    _ = try decode(&page, id_of(8));
}

test "page header: encode touches only the 24 header bytes and is idempotent" {
    const gpa = std.testing.allocator;
    var prng = std.Random.DefaultPrng.init(0x5724_0007);
    var page: [512]u8 = undefined;
    prng.random().bytes(&page);
    const before = page;
    encode(&page, id_of(6), .{ .page_type = .free_trunk, .lsn = 0xAB });
    try std.testing.expectEqualSlices(u8, before[24..], page[24..]);
    const first = page;
    encode(&page, id_of(6), .{ .page_type = .free_trunk, .lsn = 0xAB });
    try std.testing.expectEqualSlices(u8, &first, &page);
    encode(&page, id_of(6), .{ .page_type = .free_trunk, .lsn = 0xAC });
    try std.testing.expectEqualSlices(u8, first[0..8], page[0..8]);
    try std.testing.expectEqualSlices(u8, first[12..16], page[12..16]);
    try std.testing.expectEqual(@as(u8, 0xAC), page[16]);
    try std.testing.expect(!std.mem.eql(u8, first[8..12], page[8..12]));
    const sum = try reference_checksum(gpa, &page, id_of(6));
    try std.testing.expectEqual(sum, std.mem.readInt(u32, page[8..12], .little));
}

test "page header: decode leaves the page bytes untouched on success and on failure" {
    var page: [512]u8 = @splat(0x44);
    encode(&page, id_of(2), .{ .page_type = .free_trunk, .lsn = 3 });
    const before = page;
    _ = try decode(&page, id_of(2));
    try std.testing.expectEqualSlices(u8, &before, &page);
    try std.testing.expectError(error.ChecksumMismatch, decode(&page, id_of(3)));
    try std.testing.expectEqualSlices(u8, &before, &page);
}

test "page header: page_size_valid accepts exactly the 8 powers of two from 512 to 65536" {
    for (page_sizes) |size| try std.testing.expect(page_size_valid(size));
    for (0..32) |shift| {
        const power = @as(u32, 1) << @intCast(shift);
        try std.testing.expectEqual(shift >= 9 and shift <= 16, page_size_valid(power));
        try std.testing.expect(!page_size_valid(power -% 1));
        try std.testing.expect(!page_size_valid(power +% 1));
    }
    const invalid = [_]u32{ 0, 1, 256, 511, 513, 3000, 65535, 65537, 131072, std.math.maxInt(u32) };
    for (invalid) |size| try std.testing.expect(!page_size_valid(size));
}

test "page header: file header round-trips at all 8 sizes with null and set freelist head" {
    const gpa = std.testing.allocator;
    for (page_sizes) |size| {
        const cases = [_]FileHeader{
            .{ .page_size = size, .page_count = 1, .freelist_head = null, .wal_lsn = 0 },
            .{ .page_size = size, .page_count = 2, .freelist_head = id_of(1), .wal_lsn = 1 },
            .{ .page_size = size, .page_count = 1000, .freelist_head = id_of(999), .wal_lsn = 7 },
            .{
                .page_size = size,
                .page_count = std.math.maxInt(u32),
                .freelist_head = id_of(std.math.maxInt(u32) - 1),
                .wal_lsn = std.math.maxInt(u64),
            },
        };
        for (cases) |expected| {
            const page = try file_header_page(gpa, size, expected);
            defer gpa.free(page);
            try std.testing.expectEqualDeep(expected, try decode_file_header(page));
            const header = try decode(page, .file_header);
            try std.testing.expectEqual(Type.file_header, header.page_type);
            try std.testing.expectEqual(@as(u64, 0), header.lsn);
            try std.testing.expect(std.mem.allEqual(u8, page[file_header_size..], 0));
        }
    }
}

test "page header: golden file header image pins every payload offset" {
    const gpa = std.testing.allocator;
    const page = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 0x0102,
        .freelist_head = id_of(0x0101),
        .wal_lsn = 0x0102030405060708,
    });
    defer gpa.free(page);
    const golden = [48]u8{
        0x53, 0x54, 0x52, 0x41, 0x01, 0x00, 0x01, 0x00, // magic, type, flags, version
        0x26, 0x36, 0xFB, 0x81, 0x00, 0x00, 0x00, 0x00, // checksum, reserved
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // lsn (page 0 stamps 0)
        0x00, 0x02, 0x00, 0x00, 0x02, 0x01, 0x00, 0x00, // page_size 512, page_count 0x0102
        0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, // freelist_head 0x0101, reserved
        0x08, 0x07, 0x06, 0x05, 0x04, 0x03, 0x02, 0x01, // wal_lsn
    };
    try std.testing.expectEqualSlices(u8, &golden, page[0..48]);
    try std.testing.expectEqual(@as(u32, 512), try codec.fixed.read(u32, page[24..]));
    try std.testing.expectEqual(@as(u32, 0x0102), try codec.fixed.read(u32, page[28..]));
    try std.testing.expectEqual(@as(u32, 0x0101), try codec.fixed.read(u32, page[32..]));
    try std.testing.expectEqual(@as(u32, 0), try codec.fixed.read(u32, page[36..]));
    const wal_lsn = try codec.fixed.read(u64, page[40..]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), wal_lsn);
    try std.testing.expect(std.mem.allEqual(u8, page[48..], 0));
    const reference = try reference_checksum(gpa, page, .file_header);
    try std.testing.expectEqual(@as(u32, 0x81FB3626), reference);
    try std.testing.expectEqual(@as(u32, 0x81FB3626), try codec.fixed.read(u32, page[8..]));
}

/// Patches `page` (a valid file header image) at `offset`, restamps, and expects `Corrupted`.
fn expect_patch_corrupted(
    gpa: std.mem.Allocator,
    base: []const u8,
    offset: usize,
    value: u32,
) !void {
    assert(base.len >= file_header_size);
    assert(offset + 4 <= base.len);
    const page = try gpa.dupe(u8, base);
    defer gpa.free(page);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try patch_restamp(gpa, page, .file_header, offset, &bytes);
    try std.testing.expectError(error.Corrupted, decode_file_header(page));
}

fn expect_patch_accepted(
    gpa: std.mem.Allocator,
    base: []const u8,
    offset: usize,
    value: u32,
) !FileHeader {
    assert(base.len >= file_header_size);
    assert(offset + 4 <= base.len);
    const page = try gpa.dupe(u8, base);
    defer gpa.free(page);
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try patch_restamp(gpa, page, .file_header, offset, &bytes);
    return decode_file_header(page);
}

test "page header: file header page_size invalid or unequal to the page length is corrupted" {
    const gpa = std.testing.allocator;
    const base = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 100,
        .freelist_head = id_of(50),
        .wal_lsn = 9,
    });
    defer gpa.free(base);
    _ = try expect_patch_accepted(gpa, base, 24, 512); // Restamping alone changes nothing.
    const invalid = [_]u32{ 0, 1, 256, 511, 513, 3000, 131072, 0x8000_0000, std.math.maxInt(u32) };
    for (invalid) |size| try expect_patch_corrupted(gpa, base, 24, size);
    // Valid power of two, but not the length of the page that carries it.
    for ([_]u32{ 1024, 4096, 65536 }) |size| try expect_patch_corrupted(gpa, base, 24, size);

    const big = try file_header_page(gpa, 4096, .{
        .page_size = 4096,
        .page_count = 100,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    defer gpa.free(big);
    try expect_patch_corrupted(gpa, big, 24, 512);
    try expect_patch_corrupted(gpa, big, 24, 8192);
    try expect_patch_corrupted(gpa, big, 24, 3000);
}

test "page header: file header page_count and freelist_head bounds are enforced exactly" {
    const gpa = std.testing.allocator;
    const base = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 100,
        .freelist_head = id_of(50),
        .wal_lsn = 9,
    });
    defer gpa.free(base);
    try expect_patch_corrupted(gpa, base, 28, 0); // page_count 0
    for ([_]u32{ 100, 101, 0x8000_0000, std.math.maxInt(u32) }) |head| {
        try expect_patch_corrupted(gpa, base, 32, head);
    }
    const edge = try expect_patch_accepted(gpa, base, 32, 99); // head == page_count - 1
    try std.testing.expectEqual(@as(?Id, id_of(99)), edge.freelist_head);
    const cleared = try expect_patch_accepted(gpa, base, 32, 0);
    try std.testing.expectEqual(@as(?Id, null), cleared.freelist_head);
    const shrunk = try expect_patch_accepted(gpa, base, 28, 51); // head 50 < 51
    try std.testing.expectEqual(@as(u32, 51), shrunk.page_count);
    try expect_patch_corrupted(gpa, base, 28, 50); // now head 50 == page_count
    try expect_patch_corrupted(gpa, base, 28, 1); // head 50 >= 1
}

test "page header: file header reserved word and non-zero tail are corrupted" {
    const gpa = std.testing.allocator;
    const base = try file_header_page(gpa, 1024, .{
        .page_size = 1024,
        .page_count = 10,
        .freelist_head = null,
        .wal_lsn = 1,
    });
    defer gpa.free(base);
    for ([_]u32{ 1, 0x100, 0x0001_0000, 0x8000_0000 }) |value| {
        try expect_patch_corrupted(gpa, base, 36, value);
    }
    for ([_]usize{ 48, 49, 100, 511, 512, 1020 }) |offset| {
        const page = try gpa.dupe(u8, base);
        defer gpa.free(page);
        try patch_restamp(gpa, page, .file_header, offset, &.{0x01});
        try std.testing.expectError(error.Corrupted, decode_file_header(page));
    }
    const wal = try gpa.dupe(u8, base);
    defer gpa.free(wal);
    const ones: [8]u8 = @splat(0xFF);
    try patch_restamp(gpa, wal, .file_header, 40, &ones);
    const accepted = try decode_file_header(wal); // wal_lsn is opaque: stored as given.
    try std.testing.expectEqual(@as(u64, std.math.maxInt(u64)), accepted.wal_lsn);
}

test "page header: decode_file_header reports unwritten, mismatch and corrupted correctly" {
    const gpa = std.testing.allocator;
    var page: [512]u8 = @splat(0);
    try std.testing.expectError(error.Unwritten, decode_file_header(&page));
    encode(&page, id_of(5), .{ .page_type = .free_trunk, .lsn = 0 });
    try std.testing.expectError(error.ChecksumMismatch, decode_file_header(&page)); // wrong id
    const fh = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 4,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    defer gpa.free(fh);
    fh[6] = 2; // version 2
    try std.testing.expectError(error.Corrupted, decode_file_header(fh));
    fh[6] = 1;
    fh[0] = 'X';
    try std.testing.expectError(error.Corrupted, decode_file_header(fh));
}

test "page header: peek_page_size returns the size from the first 512 bytes at all 8 sizes" {
    const gpa = std.testing.allocator;
    for (page_sizes) |size| {
        const page = try file_header_page(gpa, size, .{
            .page_size = size,
            .page_count = 3,
            .freelist_head = null,
            .wal_lsn = 0,
        });
        defer gpa.free(page);
        try std.testing.expectEqual(size, try peek_page_size(page[0..page_size_min]));
    }
}

test "page header: peek_page_size rejects what cannot be a strata file prefix" {
    const gpa = std.testing.allocator;
    const base = try file_header_page(gpa, 512, .{
        .page_size = 512,
        .page_count = 3,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    defer gpa.free(base);
    var prefix: [512]u8 = undefined;
    for ([_]u32{ 0, 1, 256, 511, 513, 3000, 131072, 0x8000_0000 }) |size| {
        @memcpy(&prefix, base);
        std.mem.writeInt(u32, prefix[24..28], size, .little);
        try std.testing.expectError(error.Corrupted, peek_page_size(&prefix));
    }
    for (0..4) |index| { // Any magic byte wrong.
        @memcpy(&prefix, base);
        prefix[index] ^= 0x20;
        try std.testing.expectError(error.Corrupted, peek_page_size(&prefix));
    }
    @memcpy(&prefix, base);
    prefix[6] = 2; // version 2
    try std.testing.expectError(error.Corrupted, peek_page_size(&prefix));
    for ([_]u8{ 0, 2, 3, 128, 255 }) |type_byte| { // Page 0 must be a file_header page.
        @memcpy(&prefix, base);
        prefix[4] = type_byte;
        try std.testing.expectError(error.Corrupted, peek_page_size(&prefix));
    }
    @memset(&prefix, 0);
    try std.testing.expectError(error.Unwritten, peek_page_size(&prefix));
    prefix[300] = 1; // Zero magic but live bytes: damage, not a fresh file.
    try std.testing.expectError(error.Corrupted, peek_page_size(&prefix));
}

test "page header: peek_page_size does not verify the checksum (the full page is not read yet)" {
    const gpa = std.testing.allocator;
    const page = try file_header_page(gpa, 4096, .{
        .page_size = 4096,
        .page_count = 3,
        .freelist_head = null,
        .wal_lsn = 0,
    });
    defer gpa.free(page);
    page[8] ^= 0xFF; // Damaged checksum: the open step 3 decode, not the peek, reports it.
    try std.testing.expectEqual(@as(u32, 4096), try peek_page_size(page[0..page_size_min]));
    try std.testing.expectError(error.ChecksumMismatch, decode_file_header(page));
}

fn fuzz_decode(_: void, smith: *std.testing.Smith) anyerror!void {
    const gpa = std.testing.allocator;
    var page: [512]u8 = undefined;
    smith.bytes(&page);
    assert(page.len == page_size_min);
    const id = id_of(if (smith.value(bool)) 0 else smith.value(u32));
    if (smith.value(bool)) { // Steer toward structurally valid pages so deep checks run.
        @memcpy(page[0..4], &magic);
        std.mem.writeInt(u16, page[6..8], format_version, .little);
        if (smith.value(bool)) page[5] = 0;
        if (smith.value(bool)) @memset(page[12..16], 0);
        if (smith.value(bool)) page[4] = if (id == .file_header) 1 else 2;
        try restamp(gpa, &page, id);
    }
    const all_zero = std.mem.allEqual(u8, &page, 0);
    if (decode(&page, id)) |header| {
        try std.testing.expect(!all_zero);
        var again = page; // Canonical encoding: a decodable image is its own re-encoding.
        encode(&again, id, header);
        try std.testing.expectEqualSlices(u8, &page, &again);
    } else |err| {
        try std.testing.expectEqual(all_zero, err == error.Unwritten);
    }
    if (decode_file_header(&page)) |file_header| {
        try std.testing.expectEqual(@as(u32, 512), file_header.page_size);
        try std.testing.expect(file_header.page_count >= 1);
        if (file_header.freelist_head) |head| {
            try std.testing.expect(head != .file_header);
            try std.testing.expect(@intFromEnum(head) < file_header.page_count);
        }
    } else |_| {}
    if (peek_page_size(page[0..page_size_min])) |size| {
        try std.testing.expect(page_size_valid(size));
    } else |_| {}
    assert(page.len == page_size_min);
}

test "page header: fuzz decode never panics and accepts only canonical images" {
    try std.testing.fuzz({}, fuzz_decode, .{});
}
