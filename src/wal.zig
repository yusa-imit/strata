//! strata.wal — Segmented write-ahead log: frames, group-commit writer, reader,
//! checkpoint, recovery.
//!
//! Landed: `wal/frame.zig` (ADR-0003 frame codec: 17-byte header, LSN-seeded CRC32C).
//!
//! Planned files (see docs/PRD.md):
//!   - `wal/segment.zig`
//!   - `wal/writer.zig`
//!   - `wal/reader.zig`
//!   - `wal/checkpoint.zig`
//!   - `wal/recovery.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

pub const frame = @import("wal/frame.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "wal: module compiles" {
    std.testing.refAllDecls(@This());
}
