//! WAL segment files (ADR-0003 WAL format v1, sections 1, 2, 4, 8 and 9): the file name, the
//! 24-byte segment header with its index-seeded CRC32C, and one segment file opened for
//! exclusive use with positional append.
//!
//! Invariants: a segment is the file `wal-` + exactly 8 lowercase hex digits + `.log`, whose
//! digits are its `index`, a `u32` in `[1, segment_index_max]`; the header is `STWL`, a `u16`
//! version (1), a `u16` reserved (0), the `u32` index, a CRC32C and the `u64` `first_lsn` in
//! `[1, 2^63)`, all little-endian via `codec.fixed`, with no padding; the checksum covers the
//! header with its own field read as zero and is seeded with the index the file name claims, so
//! a segment renamed to another index fails with certainty (the seeds differ in at most 32
//! bits, which CRC32C always detects); a file longer than `segment_bytes_limit` is `Corrupted`;
//! a `Segment` value is immutable after `create`/`open` and its file is exclusively locked from
//! then until `close`. Frames are written by the caller at offsets `>= segment_header_size`.
//! Allocation: none. The codecs are pure over caller-owned slices; `Segment` methods use stack
//! scratch only (at most 64 KiB, for the all-zero scan of an unwritten file) and `io` is passed
//! per call (ADR-0001), so nothing stores an allocator or an `Io`.
//! Cost sketch: `create` is one exclusive create, one lock, one 24 byte write and one sync;
//! `open` is one open, one lock, one stat and one read of at most 24 bytes. Only a file whose
//! header region is all zero is read further, up to the whole file, in 64 KiB chunks.
//! Durability: `create` syncs the file but not its directory entry. ADR-0003 section 2 requires
//! the directory sync before the first frame is written; `File` has no directory handle sync
//! yet (ADR-0003 open question 4: a free function in `file/`, not a `File` method). The writer
//! (plan 004, item 5) owns that call, so a segment returned by `create` is not yet durable by
//! name and no frame may be appended to it before the writer has synced the directory.
//! Errors: bad bytes on disk are typed `HeaderError`s (section 8 order); the segment and index
//! limits are the typed `LimitError`s, not asserts, because they depend on directory contents;
//! a zero index, an out-of-range `first_lsn` or an incoherent `Options` passed in are caller
//! contract violations and are asserted.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const codec = @import("../codec.zig");
const file = @import("../file/file.zig");
const frame = @import("frame.zig");

/// Log sequence number (see `frame.Lsn`): the first frame's position in the frame stream.
pub const Lsn = frame.Lsn;
pub const segment_header_size: u32 = 24;
/// A segment file may not be longer than this (ADR-0003 section 9): 2^32 bytes.
pub const segment_bytes_limit: u64 = 1 << 32;
/// Index 0 is never valid, so the live range is `[1, segment_index_max]`.
pub const segment_index_max: u32 = std.math.maxInt(u32);
pub const format_version: u16 = 1;
pub const magic: [4]u8 = "STWL".*;
/// Byte length of every segment file name: `wal-` + 8 hex digits + `.log`.
pub const name_size: u32 = 16;

const name_prefix = "wal-";
const name_suffix = ".log";
const name_digit_count: u32 = 8;
const hex_digits = "0123456789abcdef";

const offset_magic: u32 = 0;
const offset_version: u32 = 4;
const offset_reserved: u32 = 6;
const offset_index: u32 = 8;
const offset_checksum: u32 = 12;
const offset_first_lsn: u32 = 16;

/// Chunk of the all-zero scan of an unwritten file; the scan is bounded by the file limit.
const scan_chunk_size: u32 = 65536;
const scan_chunk_count_max: u32 = @intCast(@divExact(segment_bytes_limit, scan_chunk_size));

comptime {
    assert(segment_header_size == offset_first_lsn + 8);
    assert(segment_header_size % 8 == 0); // `first_lsn` stays 8-aligned within the segment.
    assert(offset_version == offset_magic + magic.len);
    assert(offset_reserved == offset_version + 2);
    assert(offset_index == offset_reserved + 2);
    assert(offset_checksum == offset_index + 4);
    assert(offset_first_lsn == offset_checksum + 4);
    assert(name_size == name_prefix.len + name_digit_count + name_suffix.len);
    assert(name_digit_count * 4 == 32); // Every digit string is a `u32`: no overflow case.
    assert(segment_bytes_limit == 1 << 32);
    assert(@as(u64, scan_chunk_count_max) * scan_chunk_size == segment_bytes_limit);
}

pub const Options = struct {
    /// Most live segments a log may hold, at least 1 (ADR-0003 section 1).
    segments_max: u32,
    /// Carried by every segment `File`; one `durable_lsn` must mean one thing (section 9).
    sync_policy: file.SyncPolicy,
};

pub const Header = struct { index: u32, first_lsn: Lsn };

pub const HeaderError = error{ Unwritten, TornWrite, ChecksumMismatch, Corrupted };
pub const LimitError = error{ SegmentLimit, SegmentIndexExhausted };
pub const ReadExactError = Io.File.ReadPositionalError || error{TornWrite};
const ReadHeaderError = file.LengthError || ReadExactError || HeaderError;
pub const CreateError = file.OpenError || file.TryLockError || file.WriteError ||
    file.SyncError;
pub const OpenError = file.OpenError || file.TryLockError || ReadHeaderError;

/// Writes the file name of segment `index` into `out`. Precondition: `index >= 1`.
pub fn format_name(index: u32, out: *[name_size]u8) void {
    assert(index >= 1);
    assert(index <= segment_index_max);
    @memcpy(out[0..name_prefix.len], name_prefix);
    for (0..name_digit_count) |digit| {
        const shift: u5 = @intCast((name_digit_count - 1 - digit) * 4);
        const nibble: u8 = @intCast((index >> shift) & 0xf);
        out[name_prefix.len + digit] = hex_digits[nibble];
    }
    @memcpy(out[name_prefix.len + name_digit_count ..], name_suffix);
    assert(std.mem.startsWith(u8, out, name_prefix));
    assert(std.mem.endsWith(u8, out, name_suffix));
}

/// The index named by `file_name`, or null when it is not a segment name at all: it must be
/// exactly `wal-`, 8 lowercase hex digits, `.log` (uppercase, 7 or 9 digits and other suffixes
/// are ignored). A name that matches with index 0 is `Corrupted` (ADR-0003 section 1), so a
/// caller cannot forget the check. Precondition: `file_name` is non-empty.
pub fn parse_name(file_name: []const u8) error{Corrupted}!?u32 {
    assert(file_name.len > 0);
    assert(file_name.len < 4096); // Directory entries are short; a longer one is a caller bug.
    if (file_name.len != name_size) return null;
    if (!std.mem.startsWith(u8, file_name, name_prefix)) return null;
    if (!std.mem.endsWith(u8, file_name, name_suffix)) return null;
    var index: u32 = 0;
    for (file_name[name_prefix.len..][0..name_digit_count]) |char| {
        const digit: u32 = switch (char) {
            '0'...'9' => char - '0',
            'a'...'f' => char - 'a' + 10,
            else => return null,
        };
        index = (index << 4) | digit;
    }
    if (index == 0) return error.Corrupted;
    var canonical: [name_size]u8 = @splat(0);
    format_name(index, &canonical);
    assert(std.mem.eql(u8, &canonical, file_name));
    return index;
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

/// Seeded CRC32C of a header image (ADR-0003 section 4): the index as eight little-endian
/// bytes, then the header with the stored checksum field read as zero.
fn header_checksum(image: *const [segment_header_size]u8, index_seed: u32) u32 {
    assert(index_seed >= 1);
    assert(image.len == segment_header_size);
    var seed: [8]u8 = @splat(0);
    put(u64, &seed, 0, index_seed);
    var hasher = codec.crc32c.Hasher.init();
    hasher.update(&seed);
    hasher.update(image[0..offset_checksum]); // magic, version, reserved, index
    hasher.update(&.{ 0, 0, 0, 0 }); // the checksum field, as zero
    hasher.update(image[offset_first_lsn..]);
    return hasher.final();
}

/// Writes the canonical 24-byte header for `header` into `out`, checksum included.
/// Preconditions: `header.index >= 1`; `header.first_lsn` in `[frame.lsn_first, frame.lsn_limit)`.
pub fn encode_header(out: *[segment_header_size]u8, header: Header) void {
    assert(header.index >= 1);
    assert(header.first_lsn >= frame.lsn_first);
    assert(header.first_lsn < frame.lsn_limit);
    @memcpy(out[offset_magic..][0..magic.len], &magic);
    put(u16, out, offset_version, format_version);
    put(u16, out, offset_reserved, 0);
    put(u32, out, offset_index, header.index);
    put(u32, out, offset_checksum, 0);
    put(u64, out, offset_first_lsn, header.first_lsn);
    const sum = header_checksum(out, header.index);
    put(u32, out, offset_checksum, sum);
    assert(get(u32, out, offset_checksum) == sum);
}

/// Validates `bytes`, the first `min(file length, 24)` bytes of the file named for
/// `index_expected`, in ADR-0003 section 8 order: all zero (including empty) is `Unwritten`;
/// fewer than 24 bytes is `TornWrite`; bad magic or version is `Corrupted`; a bad checksum is
/// `ChecksumMismatch`; then a non-zero reserved field, a stored index other than
/// `index_expected` or a `first_lsn` outside `[1, 2^63)` is `Corrupted`. Never mutates `bytes`.
/// `Unwritten` speaks only for the bytes given: a caller that has a longer file must confirm
/// that the rest is zero too (`Segment.open` does). Preconditions: `bytes.len <= 24`;
/// `index_expected >= 1`.
pub fn decode_header(bytes: []const u8, index_expected: u32) HeaderError!Header {
    assert(bytes.len <= segment_header_size);
    assert(index_expected >= 1);
    if (std.mem.allEqual(u8, bytes, 0)) return error.Unwritten;
    if (bytes.len < segment_header_size) return error.TornWrite;
    const image: *const [segment_header_size]u8 = bytes[0..segment_header_size];
    if (!std.mem.eql(u8, image[offset_magic..][0..magic.len], &magic)) return error.Corrupted;
    if (get(u16, image, offset_version) != format_version) return error.Corrupted;
    const stored = get(u32, image, offset_checksum);
    if (stored != header_checksum(image, index_expected)) return error.ChecksumMismatch;
    if (get(u16, image, offset_reserved) != 0) return error.Corrupted;
    if (get(u32, image, offset_index) != index_expected) return error.Corrupted;
    const first_lsn = get(u64, image, offset_first_lsn);
    if (first_lsn < frame.lsn_first) return error.Corrupted;
    if (first_lsn >= frame.lsn_limit) return error.Corrupted;
    return .{ .index = index_expected, .first_lsn = first_lsn };
}

/// The index of the segment a writer creates after `index_newest` when `live_count` segments
/// exist (ADR-0003 section 9, rotation step 2). `SegmentIndexExhausted` when `index_newest` is
/// `segment_index_max`: permanent, no checkpoint helps, so it wins over `SegmentLimit`, which
/// is returned when one more segment would exceed `options.segments_max`.
/// Preconditions: `index_newest >= 1`; `live_count >= 1`; `options.segments_max >= 1`.
pub fn index_next(index_newest: u32, live_count: u32, options: Options) LimitError!u32 {
    assert(index_newest >= 1);
    assert(live_count >= 1);
    assert(options.segments_max >= 1);
    if (index_newest == segment_index_max) return error.SegmentIndexExhausted;
    if (live_count >= options.segments_max) return error.SegmentLimit;
    assert(index_newest < segment_index_max);
    return index_newest + 1;
}

/// `SegmentLimit` when a log found `live_count` segments, more than `options.segments_max`
/// (ADR-0003 section 1). A typed limit, not corruption. Precondition: `segments_max >= 1`.
pub fn live_count_check(live_count: u32, options: Options) error{SegmentLimit}!void {
    assert(options.segments_max >= 1);
    if (live_count > options.segments_max) return error.SegmentLimit;
    assert(live_count <= options.segments_max);
}

/// Reads `buf` exactly at `offset`; a file that ends first was cut under us: `TornWrite`.
fn read_exact(io: Io, handle: file.File, buf: []u8, offset: u64) ReadExactError!void {
    assert(offset <= segment_bytes_limit);
    assert(buf.len <= segment_bytes_limit);
    handle.readAtAll(io, buf, offset) catch |err| switch (err) {
        error.UnexpectedEof => return error.TornWrite,
        else => |other| return other,
    };
}

/// True when every byte of `[from, len)` is zero, read in chunks (ADR-0003 section 8, step 1:
/// "the whole file is zero"). Bounded by `scan_chunk_count_max` since `len` is at most
/// `segment_bytes_limit`.
pub fn zero_from(io: Io, handle: file.File, from: u64, len: u64) ReadExactError!bool {
    assert(from <= len);
    assert(len <= segment_bytes_limit);
    var chunk: [scan_chunk_size]u8 = @splat(0);
    var offset = from;
    for (0..scan_chunk_count_max) |_| {
        if (offset == len) break;
        const want: u32 = @intCast(@min(len - offset, scan_chunk_size));
        try read_exact(io, handle, chunk[0..want], offset);
        if (!std.mem.allEqual(u8, chunk[0..want], 0)) return false;
        offset += want;
    }
    assert(offset == len);
    return true;
}

/// Section 8 header decode of the open, locked `handle`: the length rule of section 9, the
/// first `min(length, 24)` bytes through `decode_header`, and for `Unwritten` the check that
/// the rest of the file is zero too (anything else there is `Corrupted`).
fn read_header(io: Io, handle: file.File, index: u32) ReadHeaderError!Header {
    assert(index >= 1);
    const len = try handle.length(io);
    if (len > segment_bytes_limit) return error.Corrupted;
    const prefix_len: u32 = @intCast(@min(len, segment_header_size));
    var prefix: [segment_header_size]u8 = @splat(0);
    try read_exact(io, handle, prefix[0..prefix_len], 0);
    return decode_header(prefix[0..prefix_len], index) catch |err| switch (err) {
        error.Unwritten => {
            if (!try zero_from(io, handle, prefix_len, len)) return error.Corrupted;
            return error.Unwritten;
        },
        error.TornWrite, error.ChecksumMismatch, error.Corrupted => return err,
    };
}

/// One segment file, locked exclusively from `create`/`open` until `close`. Copyable leaf: the
/// `File` handle is shared by copies, so close exactly one.
pub const Segment = struct {
    file: file.File,
    index: u32,
    first_lsn: Lsn,

    /// Creates segment `index` in ADR-0003 section 2 order: exclusive create (an existing file
    /// is `PathAlreadyExists` and untouched), lock, write the header, sync the file per
    /// `options.sync_policy`. The directory sync that must follow is the caller's (see the file
    /// header). On error nothing stays open or locked, but the file may remain, empty or torn;
    /// section 8 classifies it `Unwritten` or `TornWrite` and recovery owns it.
    /// Preconditions: `index >= 1`; `first_lsn` in `[frame.lsn_first, frame.lsn_limit)`;
    /// `options.segments_max >= 1`. A reader that locks the new empty file first makes the lock
    /// step fail `WouldBlock`; the empty file stays and recovery owns it.
    pub fn create(
        io: Io,
        dir: Io.Dir,
        index: u32,
        first_lsn: Lsn,
        options: Options,
    ) CreateError!Segment {
        assert(index >= 1);
        assert(first_lsn >= frame.lsn_first);
        assert(first_lsn < frame.lsn_limit);
        assert(options.segments_max >= 1);
        var name: [name_size]u8 = @splat(0);
        format_name(index, &name);
        const raw = try dir.createFile(io, &name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
        });
        const handle: file.File = .{
            .handle = raw,
            .sync_policy = options.sync_policy,
            .direct = false,
        };
        errdefer handle.close(io);

        try handle.tryLock(io, .exclusive);
        errdefer handle.unlock(io);

        var image: [segment_header_size]u8 = @splat(0);
        encode_header(&image, .{ .index = index, .first_lsn = first_lsn });
        try handle.writeAtAll(io, &image, 0);
        try handle.sync(io);
        return .{ .file = handle, .index = index, .first_lsn = first_lsn };
    }

    /// Opens segment `index` read-write, locks it exclusively (`WouldBlock` when another open
    /// holds it) and decodes its header per ADR-0003 section 8: `Unwritten` (zero length, or
    /// zero throughout), `TornWrite`, `Corrupted` (foreign file, bad field, non-zero bytes
    /// after a zero header, or longer than `segment_bytes_limit`), `ChecksumMismatch` (bit
    /// rot, or a file renamed to another index). On error nothing stays open or locked.
    /// Preconditions: `index >= 1`; `options.segments_max >= 1`.
    pub fn open(io: Io, dir: Io.Dir, index: u32, options: Options) OpenError!Segment {
        assert(index >= 1);
        assert(options.segments_max >= 1);
        var name: [name_size]u8 = @splat(0);
        format_name(index, &name);
        const handle = try file.File.open(io, dir, &name, .{
            .mode = .read_write,
            .create = false,
            .truncate = false,
            .direct = false,
            .lock = .none,
            .sync_policy = options.sync_policy,
        });
        errdefer handle.close(io);

        try handle.tryLock(io, .exclusive);
        errdefer handle.unlock(io);

        const header = try read_header(io, handle, index);
        assert(header.index == index);
        return .{ .file = handle, .index = header.index, .first_lsn = header.first_lsn };
    }

    /// Unlocks and closes the file; the value (and every copy) is invalid afterwards. Does not
    /// sync.
    pub fn close(self: *const Segment, io: Io) void {
        assert(self.index >= 1);
        assert(self.first_lsn >= frame.lsn_first);
        self.file.unlock(io);
        self.file.close(io);
    }

    /// Writes all of `bytes` at `offset` (positional; a gap past the end reads as zeros). Never
    /// syncs. Preconditions: `offset >= segment_header_size`, so the header is never touched;
    /// the write ends at or before `segment_bytes_limit`.
    pub fn append(
        self: *const Segment,
        io: Io,
        bytes: []const u8,
        offset: u64,
    ) file.WriteError!void {
        assert(offset >= segment_header_size);
        assert(offset <= segment_bytes_limit);
        assert(bytes.len <= segment_bytes_limit - offset);
        try self.file.writeAtAll(io, bytes, offset);
    }

    /// Current file length in bytes (header included).
    pub fn length(self: *const Segment, io: Io) file.LengthError!u64 {
        assert(self.index >= 1);
        assert(self.first_lsn < frame.lsn_limit);
        return self.file.length(io);
    }

    /// Makes every completed write durable per the file's `SyncPolicy` (a no-op for `.none`).
    /// A failed sync is never retried by the caller (ADR-0003 section 9).
    pub fn sync(self: *const Segment, io: Io) file.SyncError!void {
        assert(self.index >= 1);
        assert(self.first_lsn >= frame.lsn_first);
        try self.file.sync(io);
    }
};

test {
    // Contract tests live in their own files (800-line limit).
    _ = @import("segment_test.zig");
    _ = @import("segment_file_test.zig");
}
