//! strata.testing.crash — crash-injection sink and cut-point enumerator (plan 002).
//!
//! A `CrashSink` is a `writeAt` sink, not an `Io` or a `File`: it takes positional writes, keeps
//! one purely logical byte image in a caller-owned buffer, and `persisted_into` produces what
//! survives a crash described by a `Cut`. The cut is a byte position applied to the final
//! positional image, never to individual writes, so the outcome does not depend on how the
//! stream was chunked or in which order the chunks arrived. A `.torn` cut at byte N keeps
//! `[0, N)`, completes N's sector (512 bytes) with garbage and drops everything after it. The
//! garbage is a keyed pseudo-random mask, not old sector contents: a mix of `(seed, byte
//! position)` that is never zero, XORed into a copy of the logical bytes, so every torn byte
//! differs from the logical byte and the same seed and stream yield the same image.
//!
//! The plan's `forEachTruncation` is delivered as the `TruncationPoints` iterator: enumerate
//! `0..=len`, build one sink per point, replay, check recovery.
//!
//! Limits of the model: a truncation point is a floor, not a proof of power-loss safety. Real
//! devices may also reorder sectors, flush a sector only partially, or persist later bytes while
//! dropping earlier ones; none of that is reproduced here. A suite that passes at every cut
//! point has shown prefix-consistency, nothing more.
//!
//! Allocation: none, ever. Ownership: the caller owns the storage buffer (its length is the
//! stream capacity, at most `maxInt(u32)`), it must outlive the sink, and the sink must not move
//! after `init` because it is initialised in place. `init` zeroes the whole buffer; the buffer
//! always holds the logical stream, so `persisted_into` never mutates the sink.

const std = @import("std");
const assert = std.debug.assert;

/// Atomic unit of a torn write, in bytes.
pub const sector_size: u32 = 512;

/// Where the simulated crash lands in the logical write stream.
pub const Cut = union(enum) {
    /// Exactly the first N bytes persist; N is a byte offset.
    truncate: u64,
    /// Bytes `[0, N)` persist and the rest of N's sector is seeded garbage; N is a byte offset.
    torn: u64,
};

/// A positional write sink whose `persisted_into` image obeys a `Cut`.
pub const CrashSink = struct {
    storage: []u8,
    cut: Cut,
    seed: u64,
    /// Logical stream length: the highest end of any non-empty accepted write.
    len: u32,

    /// Zeroes `storage` and starts an empty stream. Returns `error.StorageTooLarge` when
    /// `storage.len > maxInt(u32)`, checked in every build mode.
    ///
    /// Precondition: `storage` is caller-owned and outlives the sink; the sink must not move
    /// after this call.
    pub fn init(
        target: *CrashSink,
        storage: []u8,
        cut: Cut,
        seed: u64,
    ) error{StorageTooLarge}!void {
        comptime assert(sector_size == 512);
        if (storage.len > std.math.maxInt(u32)) return error.StorageTooLarge;
        @memset(storage, 0);
        target.* = .{ .storage = storage, .cut = cut, .seed = seed, .len = 0 };
        assert(target.len == 0);
        assert(target.storage.len == storage.len);
    }

    /// Records `data` at `offset`; reports the full `data.len` accepted even when the cut will
    /// drop the bytes. An empty write never extends the stream.
    ///
    /// Returns `error.OutOfSpace`, leaving the sink untouched, when the write would end past
    /// `storage.len` or `offset > storage.len` (also for an empty write).
    ///
    /// Precondition: `init` succeeded. Not safe to call concurrently.
    pub fn writeAt(self: *CrashSink, data: []const u8, offset: u64) error{OutOfSpace}!usize {
        assert(self.len <= self.storage.len);
        assert(self.storage.len <= std.math.maxInt(u32));
        // Overflow-safe: compare against the remaining room, never add offset and length.
        if (offset > self.storage.len) return error.OutOfSpace;
        const start: usize = @intCast(offset);
        if (data.len > self.storage.len - start) return error.OutOfSpace;
        if (data.len == 0) return 0;

        @memcpy(self.storage[start..][0..data.len], data);
        const end: u32 = @intCast(start + data.len);
        self.len = @max(self.len, end);
        assert(self.len <= self.storage.len);
        assert(self.len >= end);
        return data.len;
    }

    /// Copies the post-crash file image into `out` and returns the filled prefix of `out`.
    /// Does not mutate the sink: repeated calls, and calls between writes, are always safe.
    ///
    /// Returns `error.OutOfSpace` when the image does not fit in `out`; `self.storage.len`
    /// bytes always suffice.
    pub fn persisted_into(self: *const CrashSink, out: []u8) error{OutOfSpace}![]const u8 {
        assert(self.len <= self.storage.len);
        assert(self.storage.len <= std.math.maxInt(u32));
        const image_len = image_len_of(self.cut, self.len);
        assert(image_len <= self.len);
        if (image_len > out.len) return error.OutOfSpace;

        const image = out[0..image_len];
        @memcpy(image, self.storage[0..image_len]);
        const range = torn_range(self.cut, self.len);
        assert(range.end <= image_len);
        garbage_xor(image[range.start..range.end], range.start, self.seed);
        return image;
    }

    /// Asserts internal consistency: length within capacity, zeroed tail, image within bounds.
    pub fn check_invariants(self: *const CrashSink) void {
        assert(self.storage.len <= std.math.maxInt(u32));
        assert(self.len <= self.storage.len);
        assert(std.mem.allEqual(u8, self.storage[self.len..], 0)); // Gaps and tail stay zero.
        assert(image_len_of(self.cut, self.len) <= self.len);
        const range = torn_range(self.cut, self.len);
        assert(range.start <= range.end);
        assert(range.end <= image_len_of(self.cut, self.len));
    }
};

/// Garbage region of a torn cut over a stream of `len` bytes, as `[start, end)`; empty for
/// truncate cuts and for torn cuts at or past the end of the stream or on a sector boundary.
const Range = struct { start: u32, end: u32 };

fn torn_range(cut: Cut, len: u32) Range {
    comptime assert(sector_size == 512);
    switch (cut) {
        .truncate => return .{ .start = 0, .end = 0 },
        .torn => |n| {
            if (n >= len) return .{ .start = len, .end = len };
            // n < len <= maxInt(u32), so aligning n up in u64 cannot overflow.
            const sector_end = std.mem.alignForward(u64, n, sector_size);
            const end: u32 = @intCast(@min(sector_end, len));
            const start: u32 = @intCast(n);
            assert(start <= end);
            assert(end <= len);
            return .{ .start = start, .end = end };
        },
    }
}

/// Length of the post-crash image of a stream of `len` bytes.
fn image_len_of(cut: Cut, len: u32) u32 {
    comptime assert(sector_size == 512);
    switch (cut) {
        .truncate => |n| return @intCast(@min(n, len)),
        .torn => |n| {
            const range = torn_range(cut, len);
            assert(range.end <= len);
            return if (n >= len) len else range.end;
        },
    }
}

/// XORs the keystream for byte positions `first_index ..` into `bytes`; applying it twice with
/// the same arguments restores the input.
fn garbage_xor(bytes: []u8, first_index: u32, seed: u64) void {
    assert(bytes.len <= sector_size);
    assert(@as(u64, first_index) + bytes.len <= std.math.maxInt(u32));
    for (bytes, 0..) |*byte, i| {
        byte.* ^= key_byte(seed, @as(u64, first_index) + i);
    }
}

/// A seeded counter-mode keystream byte (SplitMix64 finalizer) in `1..=255`; never zero, so
/// XOR always changes the byte.
fn key_byte(seed: u64, position: u64) u8 {
    assert(position <= std.math.maxInt(u32));
    var z: u64 = seed +% (position +% 1) *% 0x9E3779B97F4A7C15;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    z ^= z >> 31;
    const key: u8 = @intCast(1 + @mod(z, 255));
    assert(key != 0);
    return key;
}

/// Iterator over every truncation point `0..=len`.
pub const TruncationPoints = struct {
    len: u64,
    next_index: u64,

    /// Returns `error.TooManyCutPoints` when `len + 1 > count_max`, so a caller bounds the work
    /// of a sweep up front.
    pub fn init(len: u64, count_max: u32) error{TooManyCutPoints}!TruncationPoints {
        comptime assert(@sizeOf(TruncationPoints) == 16);
        // `len + 1 > count_max` rewritten so `len == maxInt(u64)` cannot overflow.
        if (len >= count_max) return error.TooManyCutPoints;
        const points: TruncationPoints = .{ .len = len, .next_index = 0 };
        assert(points.len < count_max);
        return points;
    }

    /// Yields `0, 1, ..., len` and then null forever.
    pub fn next(self: *TruncationPoints) ?u64 {
        assert(self.len < std.math.maxInt(u32));
        assert(self.next_index <= self.len + 1);
        if (self.next_index > self.len) return null;
        const point = self.next_index;
        self.next_index += 1;
        assert(point <= self.len);
        return point;
    }
};
