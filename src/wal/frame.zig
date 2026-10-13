//! WAL frame codec (ADR-0003 WAL format v1, sections 3 to 7): the 17-byte frame header, the
//! position-seeded CRC32C, the frame types and the decode order a log reader relies on.
//!
//! Invariants: all integers are little-endian via `codec.fixed`; a frame is `len` (u32),
//! `crc` (u32), `lsn` (u64), `type` (u8), then `len` payload bytes, with no padding, and is at
//! most `frame_bytes_max` bytes; the checksum covers the whole frame with the stored `crc`
//! bytes read as zero and is seeded with the LSN the frame's position implies, so an intact
//! frame read at another position never verifies; the stored `lsn` is trusted only after the
//! checksum, and is compared with the expected one to make rejection certain, not merely
//! probable; encoding is canonical, so one logical frame has one byte image.
//! Allocation: none. Every function is pure over caller-owned slices, takes no `io`
//! (ADR-0001), and never mutates its input unless it is `encode`. A decoded `Frame.payload`
//! borrows from the image passed to `decode`.
//! Errors: bad bytes on disk are typed `DecodeError`s. `encode` takes values a writer controls,
//! so an out-of-range LSN, an oversize payload or a payload the frame type forbids is a caller
//! contract violation and is asserted. A well-checksummed frame with an unknown type or a
//! malformed payload is `Corrupted`, never `TornWrite`: it is not a crash artifact.

const std = @import("std");
const assert = std.debug.assert;
const codec = @import("../codec.zig");
const page_header = @import("../page/header.zig");

/// Log sequence number: the byte position of a frame in the frame stream. 0 means none.
pub const Lsn = u64;
pub const lsn_first: Lsn = 1;
/// Exclusive upper bound of every LSN (ADR-0003 section 5): 2^63.
pub const lsn_limit: Lsn = 1 << 63;
pub const frame_header_size: u32 = 17;
/// Largest legal frame, header included; a format constant, not an option.
pub const frame_bytes_max: u32 = 1 << 20;
pub const payload_bytes_max: u32 = frame_bytes_max - frame_header_size;

/// Frame type byte. 0 is never valid, 4..127 are reserved, 128..255 belong to consumers.
pub const Type = enum(u8) { record = 1, page_image = 2, checkpoint = 3, _ };

/// `payload` borrows from the decoded image; valid until the caller's buffer is reused.
pub const Frame = struct { lsn: Lsn, frame_type: Type, payload: []const u8 };

pub const DecodeError = error{ TornWrite, ChecksumMismatch, Corrupted };

const offset_len: u32 = 0;
const offset_crc: u32 = 4;
const offset_lsn: u32 = 8;
const offset_type: u32 = 16;
const page_id_size: u32 = 4;
const checkpoint_payload_size: u32 = 8;

comptime {
    assert(frame_header_size == offset_type + 1);
    assert(offset_crc == offset_len + 4);
    assert(offset_lsn == offset_crc + 4);
    assert(offset_type == offset_lsn + 8);
    assert(frame_bytes_max == payload_bytes_max + frame_header_size);
    assert(payload_bytes_max == 1048559);
    assert(lsn_limit == std.math.maxInt(i64) + 1);
    // A page image (id plus the largest page) must fit in one frame, many times over.
    assert(page_id_size + page_header.page_size_max <= payload_bytes_max);
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

/// True when `payload` is legal for `type_byte` in a frame at `lsn` (ADR-0003 section 6):
/// record and consumer types (128..255) take any payload; `page_image` is a page id then a
/// valid page size; `checkpoint` is a `redo_lsn` in `[1, lsn]`; 0 and 4..127 never.
fn payload_valid(type_byte: u8, lsn: Lsn, payload: []const u8) bool {
    assert(payload.len <= payload_bytes_max);
    assert(lsn < lsn_limit);
    const record: u8 = @intFromEnum(Type.record);
    const page_image: u8 = @intFromEnum(Type.page_image);
    const checkpoint: u8 = @intFromEnum(Type.checkpoint);
    return switch (type_byte) {
        0 => false,
        record => true,
        page_image => page_image_valid(payload),
        checkpoint => checkpoint_valid(lsn, payload),
        4...127 => false,
        128...255 => true,
    };
}

fn page_image_valid(payload: []const u8) bool {
    assert(payload.len <= payload_bytes_max);
    assert(page_header.page_size_max <= payload_bytes_max);
    if (payload.len < page_id_size) return false;
    const page_len: u32 = @intCast(payload.len - page_id_size);
    return page_header.page_size_valid(page_len);
}

fn checkpoint_valid(lsn: Lsn, payload: []const u8) bool {
    assert(payload.len <= payload_bytes_max);
    assert(lsn >= lsn_first);
    if (payload.len != checkpoint_payload_size) return false;
    const redo_lsn = get(u64, payload, 0);
    return redo_lsn >= lsn_first and redo_lsn <= lsn;
}

/// Seeded CRC32C of `frame_bytes` under `lsn_expected` (ADR-0003 section 4): the LSN as eight
/// little-endian bytes, then the frame with the stored crc field read as zero. Preconditions:
/// `frame_bytes` is exactly one frame (its `len` field matches the slice) and `lsn_expected`
/// is a legal LSN.
pub fn checksum(frame_bytes: []const u8, lsn_expected: Lsn) u32 {
    assert(frame_bytes.len >= frame_header_size);
    assert(frame_bytes.len <= frame_bytes_max);
    assert(frame_bytes.len == frame_header_size + get(u32, frame_bytes, offset_len));
    assert(lsn_expected >= lsn_first);
    assert(lsn_expected < lsn_limit);
    var seed: [8]u8 = undefined;
    put(u64, &seed, 0, lsn_expected);
    var hasher = codec.crc32c.Hasher.init();
    hasher.update(&seed);
    hasher.update(frame_bytes[offset_len..offset_crc]);
    hasher.update(&.{ 0, 0, 0, 0 }); // the crc field, as zero
    hasher.update(frame_bytes[offset_lsn..]); // lsn, type, payload
    return hasher.final();
}

/// Writes one frame at the start of `out` and returns the bytes used (`17 + payload.len`);
/// nothing past them is touched. Preconditions: `lsn` in `[lsn_first, lsn_limit)`; the payload
/// is legal for `frame_type` (section 6) and at most `payload_bytes_max`; `out` is large enough.
pub fn encode(out: []u8, lsn: Lsn, frame_type: Type, payload: []const u8) u32 {
    assert(payload.len <= payload_bytes_max);
    assert(lsn >= lsn_first);
    assert(lsn < lsn_limit);
    assert(payload_valid(@intFromEnum(frame_type), lsn, payload));
    const total: u32 = frame_header_size + @as(u32, @intCast(payload.len));
    assert(out.len >= total);
    put(u32, out, offset_len, @intCast(payload.len));
    put(u32, out, offset_crc, 0);
    put(u64, out, offset_lsn, lsn);
    out[offset_type] = @intFromEnum(frame_type);
    @memcpy(out[frame_header_size..][0..payload.len], payload);
    const sum = checksum(out[0..total], lsn);
    put(u32, out, offset_crc, sum);
    assert(get(u32, out, offset_crc) == sum);
    return total;
}

/// Steps 1 to 4 of ADR-0003 section 7: header present, `len` in range, whole frame present,
/// checksum matches. Returns the frame's total byte count. Precondition: `image.len` is at most
/// `frame_bytes_max` and `lsn_expected` is a legal LSN.
fn locate(image: []const u8, lsn_expected: Lsn) DecodeError!u32 {
    assert(image.len <= frame_bytes_max);
    assert(lsn_expected >= lsn_first);
    assert(lsn_expected < lsn_limit);
    if (image.len < frame_header_size) return error.TornWrite;
    const len = get(u32, image, offset_len);
    if (len > payload_bytes_max) return error.Corrupted; // Before any read sized by `len`.
    const total: u32 = frame_header_size + len;
    assert(total <= frame_bytes_max);
    if (image.len < total) return error.TornWrite;
    const stored = get(u32, image, offset_crc);
    if (stored != checksum(image[0..total], lsn_expected)) return error.ChecksumMismatch;
    return total;
}

/// Validates the frame at the start of `image` as the frame at `lsn_expected`, in ADR-0003
/// section 7 order: short header, over-long `len`, short frame (`TornWrite`/`Corrupted`),
/// checksum (`ChecksumMismatch`), stored LSN, then the type and payload rules (`Corrupted`).
/// Consumes exactly `17 + len` bytes; later bytes of `image` are ignored. Never mutates `image`.
/// Preconditions: `image.len <= frame_bytes_max`; `lsn_expected` in `[lsn_first, lsn_limit)`.
/// A segment header is disk data, so a reader range-checks its first LSN (typed `Corrupted`)
/// before deriving `lsn_expected` from it; this function asserts the range, it does not return.
pub fn decode(image: []const u8, lsn_expected: Lsn) DecodeError!Frame {
    assert(image.len <= frame_bytes_max);
    assert(lsn_expected >= lsn_first);
    const total = try locate(image, lsn_expected);
    assert(total >= frame_header_size);
    if (get(u64, image, offset_lsn) != lsn_expected) return error.Corrupted;
    const payload = image[frame_header_size..total];
    const type_byte = image[offset_type];
    if (!payload_valid(type_byte, lsn_expected, payload)) return error.Corrupted;
    return .{ .lsn = lsn_expected, .frame_type = @enumFromInt(type_byte), .payload = payload };
}

/// True iff steps 1 to 4 of `decode` pass: the bytes are exactly what some writer wrote at this
/// position. An intact frame that `decode` rejects is never a crash artifact (ADR-0003 section
/// 7). Same preconditions as `decode`.
pub fn intact(image: []const u8, lsn_expected: Lsn) bool {
    assert(image.len <= frame_bytes_max);
    assert(lsn_expected >= lsn_first);
    if (locate(image, lsn_expected)) |total| {
        assert(total <= image.len);
        return true;
    } else |err| switch (err) {
        error.TornWrite, error.ChecksumMismatch, error.Corrupted => return false,
    }
}

test {
    _ = @import("frame_test.zig"); // Contract tests live in their own file (800-line limit).
}
