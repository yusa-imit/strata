//! strata.codec — varint (LEB128/zigzag), fixed-width LE, CRC32C (hw-accelerated), xxhash64.
//!
//! Files (see docs/PRD.md):
//!   - `codec/varint.zig` (landed)
//!   - `codec/fixed.zig` (landed)
//!   - `codec/crc32c.zig` (planned)
//!   - `codec/xxhash.zig` (planned)
//!
//! Status: `fixed` and `varint` landed (plan 002 item 2); `crc32c` and `xxhash` are still to
//! come, so `Error` keeps `NotImplemented` until they land.

const std = @import("std");

pub const crc32c = @import("codec/crc32c.zig");
pub const fixed = @import("codec/fixed.zig");
pub const varint = @import("codec/varint.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "codec: module compiles" {
    std.testing.refAllDecls(@This());
}
