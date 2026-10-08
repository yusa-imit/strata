//! Page header codec (ADR-0002 page format v1): the 24-byte header every page carries, the
//! page-0 file header, and the page-id-seeded CRC32C that covers a whole page.
//!
//! Invariants: all integers are little-endian via `codec.fixed`; a page is exactly `page_size`
//! bytes, a power of two in `[page_size_min, page_size_max]` (the slice length is the page size);
//! the checksum covers the whole page with bytes 8..12 read as zero and is seeded with the page
//! id, so an intact page read under another id never verifies; encoding is canonical (flags,
//! reserved bytes and the file header tail are zero), so one logical state has one byte image.
//! Allocation: none. Every function is pure over caller-owned slices, takes no `io` (ADR-0001),
//! and never mutates its input unless it is an `encode*` function.
//! Errors: bad bytes on disk are typed `DecodeError`s; a wrong slice length or an invalid value
//! passed to an `encode*` function is a caller contract violation and is asserted.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("../codec.zig");

pub const header_size: u32 = 24;
pub const file_header_size: u32 = 48;
pub const page_size_min: u32 = 512;
pub const page_size_max: u32 = 65536;
pub const format_version: u16 = 1;
pub const magic: [4]u8 = "STRA".*;

/// Page identifier. Id 0 is the file header page and doubles as the on-disk "none" link.
pub const Id = enum(u32) { file_header = 0, _ };

/// Page type byte. Values 128..255 belong to consumers and are accepted as-is.
pub const Type = enum(u8) { file_header = 1, free_trunk = 2, _ };

pub const Header = struct { page_type: Type, lsn: u64 };

pub const FileHeader = struct {
    page_size: u32,
    page_count: u32,
    freelist_head: ?Id,
    wal_lsn: u64,
};

pub const DecodeError = error{ Unwritten, Corrupted, ChecksumMismatch };

const offset_magic: u32 = 0;
const offset_type: u32 = 4;
const offset_flags: u32 = 5;
const offset_version: u32 = 6;
const offset_checksum: u32 = 8;
const offset_reserved: u32 = 12;
const offset_lsn: u32 = 16;
const offset_page_size: u32 = 24;
const offset_page_count: u32 = 28;
const offset_freelist_head: u32 = 32;
const offset_file_reserved: u32 = 36;
const offset_wal_lsn: u32 = 40;
const type_consumer_min: u8 = 128;

comptime {
    assert(header_size == offset_lsn + 8);
    assert(header_size % 8 == 0); // Payload `u64`s stay 8-aligned.
    assert(file_header_size == offset_wal_lsn + 8);
    assert(file_header_size % 8 == 0);
    assert(file_header_size <= page_size_min);
    assert(offset_checksum + 4 == offset_reserved);
    assert(std.math.isPowerOfTwo(page_size_min));
    assert(std.math.isPowerOfTwo(page_size_max));
}

/// True when `page_size` is a power of two in `[page_size_min, page_size_max]`.
pub fn page_size_valid(page_size: u32) bool {
    assert(page_size_min < page_size_max);
    assert(page_size_max <= std.math.maxInt(u32) / 2 + 1);
    if (@popCount(page_size) != 1) return false;
    return page_size >= page_size_min and page_size <= page_size_max;
}

fn page_len_valid(len: usize) bool {
    if (len > page_size_max) return false;
    return page_size_valid(@intCast(len));
}

fn get(comptime T: type, bytes: []const u8, offset: u32) T {
    assert(offset + codec.fixed.size_of(T) <= bytes.len);
    const value = codec.fixed.read(T, bytes[offset..]) catch |err| switch (err) {
        // The assertion above proves `bytes[offset..]` holds `size_of(T)` bytes.
        error.BufferTooSmall => unreachable,
    };
    assert(offset < bytes.len);
    return value;
}

fn put(comptime T: type, bytes: []u8, offset: u32, value: T) void {
    assert(offset + codec.fixed.size_of(T) <= bytes.len);
    codec.fixed.write(T, bytes[offset..], value) catch |err| switch (err) {
        // The assertion above proves `bytes[offset..]` holds `size_of(T)` bytes.
        error.BufferTooSmall => unreachable,
    };
    assert(offset < bytes.len);
}

fn magic_is_zero(page: []const u8) bool {
    assert(page.len >= header_size);
    return std.mem.allEqual(u8, page[offset_magic..][0..magic.len], 0);
}

/// True when the type byte is legal at `id` (ADR section 1): `file_header` only at id 0 and
/// nothing else there; `free_trunk` and consumer types (128..255) elsewhere.
fn type_valid(id: Id, type_byte: u8) bool {
    const file_header_byte: u8 = @intFromEnum(Type.file_header);
    const free_trunk_byte: u8 = @intFromEnum(Type.free_trunk);
    assert(file_header_byte != free_trunk_byte);
    if (id == .file_header) return type_byte == file_header_byte;
    return type_byte == free_trunk_byte or type_byte >= type_consumer_min;
}

/// Seeded CRC32C of `page` under `id` (ADR section 2); the stored checksum field is read as
/// zero. Precondition: `page.len` is a valid page size.
pub fn checksum(page: []const u8, id: Id) u32 {
    assert(page.len <= page_size_max);
    assert(page_len_valid(page.len));
    var id_bytes: [8]u8 = @splat(0);
    put(u64, &id_bytes, 0, @intFromEnum(id));
    assert(get(u32, &id_bytes, 0) == @intFromEnum(id));
    var hasher = codec.crc32c.Hasher.init();
    hasher.update(&id_bytes);
    hasher.update(page[0..offset_checksum]); // magic, page_type, flags, version
    hasher.update(&.{ 0, 0, 0, 0 }); // the checksum field, as zero
    hasher.update(page[offset_reserved..]); // reserved, lsn, payload
    return hasher.final();
}

/// Stamps magic, version, zero flags and reserved bytes, `header`, then the checksum over
/// `page`. Touches only the first 24 bytes. Preconditions: `page.len` is a valid page size and
/// `header.page_type` is legal at `id` (file_header only at id 0, never anything else there).
pub fn encode(page: []u8, id: Id, header: Header) void {
    assert(page.len <= page_size_max);
    assert(page_len_valid(page.len));
    assert(type_valid(id, @intFromEnum(header.page_type)));
    @memcpy(page[offset_magic..][0..magic.len], &magic);
    page[offset_type] = @intFromEnum(header.page_type);
    page[offset_flags] = 0;
    put(u16, page, offset_version, format_version);
    put(u32, page, offset_checksum, 0);
    put(u32, page, offset_reserved, 0);
    put(u64, page, offset_lsn, header.lsn);
    const sum = checksum(page, id);
    put(u32, page, offset_checksum, sum);
    assert(get(u32, page, offset_checksum) == sum);
}

/// Validates `page` as page `id` in ADR section 6 order: unwritten, magic, version, checksum,
/// then type, flags and reserved. Never mutates `page`. Precondition: `page.len` is a valid
/// page size.
pub fn decode(page: []const u8, id: Id) DecodeError!Header {
    assert(page.len <= page_size_max);
    assert(page_len_valid(page.len));
    if (magic_is_zero(page) and std.mem.allEqual(u8, page, 0)) return error.Unwritten;
    if (!std.mem.eql(u8, page[offset_magic..][0..magic.len], &magic)) return error.Corrupted;
    if (get(u16, page, offset_version) != format_version) return error.Corrupted;
    if (get(u32, page, offset_checksum) != checksum(page, id)) return error.ChecksumMismatch;
    const type_byte = page[offset_type];
    if (!type_valid(id, type_byte)) return error.Corrupted;
    if (page[offset_flags] != 0) return error.Corrupted;
    if (get(u32, page, offset_reserved) != 0) return error.Corrupted;
    return .{ .page_type = @enumFromInt(type_byte), .lsn = get(u64, page, offset_lsn) };
}

/// Writes a complete page-0 image: clears all of `page`, stores `file_header` in the payload,
/// then stamps the page header (type file_header, lsn 0) and checksum. Preconditions:
/// `page.len == file_header.page_size`, a valid size; `page_count >= 1`; a set `freelist_head`
/// is not id 0 and is below `page_count`.
pub fn encode_file_header(page: []u8, file_header: FileHeader) void {
    assert(page.len <= page_size_max);
    assert(page_len_valid(page.len));
    assert(file_header.page_size == page.len);
    assert(file_header.page_count >= 1);
    if (file_header.freelist_head) |head| {
        assert(head != .file_header);
        assert(@intFromEnum(head) < file_header.page_count);
    }
    @memset(page, 0);
    put(u32, page, offset_page_size, file_header.page_size);
    put(u32, page, offset_page_count, file_header.page_count);
    const head_raw: u32 = if (file_header.freelist_head) |head| @intFromEnum(head) else 0;
    put(u32, page, offset_freelist_head, head_raw);
    put(u64, page, offset_wal_lsn, file_header.wal_lsn);
    encode(page, .file_header, .{ .page_type = .file_header, .lsn = 0 });
    assert(get(u32, page, offset_file_reserved) == 0);
}

/// Fully validates `page` as page 0 (header decode, then payload rules of ADR section 5) and
/// returns the file header. Per-page cross-checks that need the file length belong to the
/// caller. Precondition: `page.len` is a valid page size.
pub fn decode_file_header(page: []const u8) DecodeError!FileHeader {
    assert(page.len <= page_size_max);
    assert(page_len_valid(page.len));
    const header = try decode(page, .file_header);
    assert(header.page_type == .file_header); // decode admits nothing else at id 0.
    if (get(u32, page, offset_page_size) != page.len) return error.Corrupted;
    const page_count = get(u32, page, offset_page_count);
    if (page_count < 1) return error.Corrupted;
    const head_raw = get(u32, page, offset_freelist_head);
    if (head_raw >= page_count and head_raw != 0) return error.Corrupted;
    if (get(u32, page, offset_file_reserved) != 0) return error.Corrupted;
    if (!std.mem.allEqual(u8, page[file_header_size..], 0)) return error.Corrupted;
    const head: ?Id = if (head_raw == 0) null else @enumFromInt(head_raw);
    return .{
        .page_size = get(u32, page, offset_page_size),
        .page_count = page_count,
        .freelist_head = head,
        .wal_lsn = get(u64, page, offset_wal_lsn),
    };
}

/// Reads the page size from the first `page_size_min` bytes of a file (open step 2). Checks
/// magic, version, page type and the size itself; the checksum cannot be verified yet because
/// the full page is not read. Precondition: `prefix.len == page_size_min`.
pub fn peek_page_size(prefix: []const u8) DecodeError!u32 {
    assert(prefix.len == page_size_min);
    assert(prefix.len >= file_header_size);
    if (magic_is_zero(prefix) and std.mem.allEqual(u8, prefix, 0)) return error.Unwritten;
    if (!std.mem.eql(u8, prefix[offset_magic..][0..magic.len], &magic)) return error.Corrupted;
    if (get(u16, prefix, offset_version) != format_version) return error.Corrupted;
    if (prefix[offset_type] != @intFromEnum(Type.file_header)) return error.Corrupted;
    const page_size = get(u32, prefix, offset_page_size);
    if (!page_size_valid(page_size)) return error.Corrupted;
    return page_size;
}

test {
    _ = @import("header_test.zig"); // Contract tests live in their own file (800-line limit).
}
