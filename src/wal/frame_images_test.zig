//! Contract tests for the `page_images` frame (type 16, ADR-0004 section 9): the payload is
//! `count u32` (at least 1), `page_size u32` (a valid page size), then `count` entries of
//! `page_id u32` (at least 1, strictly ascending) and one page image that starts with `STRA`
//! and whose type byte is legal at that id. The payload length must be exactly
//! `8 + count * (4 + page_size)`. Anything else is `Corrupted` at read (`payload_valid` is
//! false), and `encode` refuses it. Offsets here are payload-relative (the ADR table counts the
//! 17-byte frame header). Frames that `encode` would refuse are forged field by field.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const f = @import("frame.zig");

const type_byte: u8 = @intFromEnum(f.Type.page_images);
const prefix_size: u32 = 8;
const entry_id_size: u32 = 4;
const lsn_test: f.Lsn = 100;

comptime {
    assert(type_byte == 16);
}

/// Builds a payload for `ids` at page size `size`, every page of type `page_type`. Owned.
fn build(size: u32, ids: []const u32, page_type: header.Type) ![]u8 {
    assert(header.page_size_valid(size));
    assert(ids.len >= 1);
    assert(ids.len <= f.images_count_max);
    const entry_size = entry_id_size + size;
    const payload = try testing.allocator.alloc(u8, prefix_size + ids.len * entry_size);
    errdefer testing.allocator.free(payload);

    @memset(payload, 0);
    std.mem.writeInt(u32, payload[0..4], @intCast(ids.len), .little);
    std.mem.writeInt(u32, payload[4..8], size, .little);
    for (ids, 0..) |id, index| {
        const base = prefix_size + index * entry_size;
        std.mem.writeInt(u32, payload[base..][0..4], id, .little);
        const page = payload[base + entry_id_size ..][0..size];
        header.encode(page, @enumFromInt(@max(id, 1)), .{ // Id 0 only forges the entry id.
            .page_type = page_type,
            .lsn = 1,
        });
    }
    return payload;
}

fn valid(payload: []const u8) bool {
    assert(payload.len <= f.payload_bytes_max);
    assert(lsn_test < f.lsn_limit);
    return f.payload_valid(type_byte, lsn_test, payload);
}

/// Offset of entry `index`'s id field in a payload at page size `size`.
fn entry_at(size: u32, index: u32) usize {
    assert(header.page_size_valid(size));
    return prefix_size + @as(usize, index) * (entry_id_size + size);
}

test "page_images: the type byte is 16 and the first entries have the ADR layout" {
    try testing.expectEqual(@as(u8, 16), @intFromEnum(f.Type.page_images));
    const payload = try build(512, &.{ 1, 3 }, .btree_leaf);
    defer testing.allocator.free(payload);

    const head = [_]u8{ 2, 0, 0, 0, 0x00, 0x02, 0, 0 }; // count 2, page_size 512
    try testing.expectEqualSlices(u8, &head, payload[0..8]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0, 0 }, payload[8..12]); // page id 1
    try testing.expectEqualSlices(u8, "STRA", payload[12..16]);
    try testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0 }, payload[524..528]); // page id 3
    try testing.expectEqual(@as(usize, 8 + 2 * (4 + 512)), payload.len);
    try testing.expect(valid(payload));
}

test "page_images: valid at all page sizes with one, two and three images" {
    const id_sets = [_][]const u32{ &.{1}, &.{ 2, 9 }, &.{ 1, 2, 4_000_000_000 } };
    for (fx.sizes_all) |size| for (id_sets) |ids| {
        const payload = try build(size, ids, fx.consumer_type);
        defer testing.allocator.free(payload);

        if (payload.len > f.payload_bytes_max) continue; // Too big for one frame: next test.
        try testing.expect(valid(payload));
    };
}

test "page_images: encode and decode round-trip and decode rejects forged payloads" {
    const payload = try build(1024, &.{ 5, 6 }, .btree_internal);
    defer testing.allocator.free(payload);

    var out: [f.frame_bytes_max]u8 = undefined;
    const used = f.encode(&out, 7, .page_images, payload);
    const got = try f.decode(out[0..used], 7);
    try testing.expectEqual(f.Type.page_images, got.frame_type);
    try testing.expectEqualSlices(u8, payload, got.payload);

    const bad = try testing.allocator.dupe(u8, payload);
    defer testing.allocator.free(bad);

    std.mem.writeInt(u32, bad[entry_at(1024, 1)..][0..4], 5, .little); // Repeated id.
    const forged = try forge(bad, 7);
    defer testing.allocator.free(forged);

    try testing.expectError(error.Corrupted, f.decode(forged, 7));
    try testing.expect(f.intact(forged, 7)); // Well checksummed: not a crash artifact.
}

/// A well-checksummed `page_images` frame at `lsn` around any payload. Owned.
fn forge(payload: []const u8, lsn: f.Lsn) ![]u8 {
    assert(payload.len <= f.payload_bytes_max);
    assert(lsn >= f.lsn_first);
    const total = f.frame_header_size + payload.len;
    const image = try testing.allocator.alloc(u8, total);
    errdefer testing.allocator.free(image);

    @memset(image, 0);
    std.mem.writeInt(u32, image[0..4], @intCast(payload.len), .little);
    std.mem.writeInt(u64, image[8..16], lsn, .little);
    image[16] = type_byte;
    @memcpy(image[f.frame_header_size..], payload);
    std.mem.writeInt(u32, image[4..8], f.checksum(image, lsn), .little);
    return image;
}

test "page_images: count 0 and a count that disagrees with the length are invalid" {
    for (fx.sizes_all) |size| {
        const payload = try build(size, &.{ 1, 2 }, fx.consumer_type);
        defer testing.allocator.free(payload);

        if (payload.len > f.payload_bytes_max) continue;
        const mutable = try testing.allocator.dupe(u8, payload);
        defer testing.allocator.free(mutable);

        std.mem.writeInt(u32, mutable[0..4], 0, .little);
        try testing.expect(!valid(mutable));
        try testing.expect(!valid(mutable[0..8])); // count 0 with no entries.
        std.mem.writeInt(u32, mutable[0..4], 1, .little); // Fewer than the bytes hold.
        try testing.expect(!valid(mutable));
        std.mem.writeInt(u32, mutable[0..4], 3, .little); // More than the bytes hold.
        try testing.expect(!valid(mutable));
        std.mem.writeInt(u32, mutable[0..4], std.math.maxInt(u32), .little); // No overflow.
        try testing.expect(!valid(mutable));
    }
}

test "page_images: a page_size that is invalid or differs from the entries is invalid" {
    const payload = try build(1024, &.{ 1, 2 }, fx.consumer_type);
    defer testing.allocator.free(payload);

    const sizes_bad = [_]u32{ 0, 1, 511, 1000, 1023, 2048, 512, 131072, std.math.maxInt(u32) };
    for (sizes_bad) |size_bad| {
        const mutable = try testing.allocator.dupe(u8, payload);
        defer testing.allocator.free(mutable);

        std.mem.writeInt(u32, mutable[4..8], size_bad, .little);
        try testing.expect(!valid(mutable));
    }
    try testing.expect(valid(payload));
}

test "page_images: page id 0, unsorted and repeated ids are invalid" {
    const cases = [_][]const u32{
        &.{0},
        &.{ 0, 1 },
        &.{ 1, 0 },
        &.{ 2, 1 },
        &.{ 1, 1 },
        &.{ 1, 3, 3 },
        &.{ 1, 5, 4 },
        &.{ 4_000_000_000, 1 },
    };
    for (cases) |ids| {
        const payload = try build(512, ids, fx.consumer_type);
        defer testing.allocator.free(payload);

        try testing.expect(!valid(payload));
    }
    const ascending = try build(512, &.{ 1, 2, 3, 4_294_967_295 }, fx.consumer_type);
    defer testing.allocator.free(ascending);

    try testing.expect(valid(ascending));
}

test "page_images: an image without STRA or with a type illegal at its id is invalid" {
    const payload = try build(512, &.{ 1, 2, 3 }, .btree_leaf);
    defer testing.allocator.free(payload);

    try testing.expect(valid(payload));
    for (0..3) |index| for (0..4) |byte| { // Any magic byte, in any entry.
        const mutable = try testing.allocator.dupe(u8, payload);
        defer testing.allocator.free(mutable);

        mutable[entry_at(512, @intCast(index)) + entry_id_size + byte] ^= 0x01;
        try testing.expect(!valid(mutable));
    };
    const type_offset: usize = 4; // The page type byte follows the magic in the page header.
    const illegal = [_]u8{ 0, 1, 3, 15, 19, 31, 64, 127 };
    for (illegal) |illegal_type| for (0..3) |index| {
        const mutable = try testing.allocator.dupe(u8, payload);
        defer testing.allocator.free(mutable);

        mutable[entry_at(512, @intCast(index)) + entry_id_size + type_offset] = illegal_type;
        try testing.expect(!valid(mutable));
    };
}

test "page_images: any truncation or extension is invalid" {
    const payload = try build(512, &.{ 1, 2 }, fx.consumer_type);
    defer testing.allocator.free(payload);

    for (0..payload.len) |cut| try testing.expect(!valid(payload[0..cut]));
    const longer = try testing.allocator.alloc(u8, payload.len + 1);
    defer testing.allocator.free(longer);

    @memcpy(longer[0..payload.len], payload);
    longer[payload.len] = 0;
    try testing.expect(!valid(longer));
    try testing.expect(valid(payload));
}

test "page_images: a frame can hold the largest legal batch and no more" {
    const size: u32 = 65536;
    const fit: u32 = @divFloor(f.payload_bytes_max - prefix_size, entry_id_size + size);
    try testing.expect(fit >= 15); // At 64 KiB pages: 2 * height + 1 images fit.
    var ids: [16]u32 = undefined;
    for (&ids, 0..) |*id, index| id.* = @intCast(index + 1);
    const full = try build(size, ids[0..fit], fx.consumer_type);
    defer testing.allocator.free(full);

    try testing.expect(valid(full));
    // One more entry would exceed the frame limit; `payload_valid` forbids oversize input, so
    // check the arithmetic the frame rule rests on.
    try testing.expect(prefix_size + (fit + 1) * (entry_id_size + size) > f.payload_bytes_max);
}
