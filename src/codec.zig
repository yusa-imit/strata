//! strata.codec — varint (LEB128/zigzag), fixed-width LE, CRC32C (hw-accelerated), xxhash64.
//!
//! Planned files (see docs/PRD.md):
//!   - `codec/varint.zig`
//!   - `codec/fixed.zig`
//!   - `codec/crc32c.zig`
//!   - `codec/xxhash.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "codec: module compiles" {
    std.testing.refAllDecls(@This());
}
