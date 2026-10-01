//! strata.codec — varint (LEB128/zigzag), fixed-width LE, CRC32C (hw-accelerated), xxhash64.
//!
//! Files (see docs/PRD.md):
//!   - `codec/varint.zig` (landed)
//!   - `codec/fixed.zig` (landed)
//!   - `codec/crc32c.zig` (landed)
//!   - `codec/xxhash.zig` (landed)
//!
//! Status: all four codecs landed (plan 002 items 2-4); `Error` keeps `NotImplemented` until
//! the milestone's docs item drops it.

const std = @import("std");

pub const crc32c = @import("codec/crc32c.zig");
pub const fixed = @import("codec/fixed.zig");
pub const varint = @import("codec/varint.zig");
pub const xxhash = @import("codec/xxhash.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "codec: module compiles" {
    std.testing.refAllDecls(@This());
}
