//! strata.wal — Segmented write-ahead log: frames, group-commit writer, reader,
//! checkpoint, recovery.
//!
//! Landed: `wal/frame.zig` (ADR-0003 frame codec: 17-byte header, LSN-seeded CRC32C) and
//! `wal/segment.zig` (ADR-0003 segment files: names, 24-byte header, exclusive create/open,
//! positional append).
//!
//! Planned files (see docs/PRD.md):
//!   - `wal/writer.zig`
//!   - `wal/reader.zig`
//!   - `wal/checkpoint.zig`
//!   - `wal/recovery.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

pub const frame = @import("wal/frame.zig");
pub const segment = @import("wal/segment.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "wal: module compiles" {
    std.testing.refAllDecls(@This());
}
