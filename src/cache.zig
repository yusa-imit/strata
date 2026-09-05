//! strata.cache — Buffer pool (CLOCK), pin/unpin guards, dirty tracking, stats.
//!
//! Planned files (see docs/PRD.md):
//!   - `cache/buffer_pool.zig`
//!   - `cache/guard.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "cache: module compiles" {
    std.testing.refAllDecls(@This());
}
