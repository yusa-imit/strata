//! strata.snapshot — Streaming snapshot writer/reader with versioned chunked format.
//!
//! Planned files (see docs/PRD.md):
//!   - `snapshot/writer.zig`
//!   - `snapshot/reader.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "snapshot: module compiles" {
    std.testing.refAllDecls(@This());
}
