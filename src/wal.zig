//! strata.wal — Segmented write-ahead log: frames, group-commit writer, reader,
//! checkpoint, recovery.
//!
//! Planned files (see docs/PRD.md):
//!   - `wal/frame.zig`
//!   - `wal/segment.zig`
//!   - `wal/writer.zig`
//!   - `wal/reader.zig`
//!   - `wal/checkpoint.zig`
//!   - `wal/recovery.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "wal: module compiles" {
    std.testing.refAllDecls(@This());
}
