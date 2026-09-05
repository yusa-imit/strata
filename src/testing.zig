//! strata.testing — Crash-injection harness (torn writes, truncation at arbitrary offsets), differential model.
//!
//! Planned files (see docs/PRD.md):
//!   - `testing/crash.zig`
//!   - `testing/model.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "testing: module compiles" {
    std.testing.refAllDecls(@This());
}
