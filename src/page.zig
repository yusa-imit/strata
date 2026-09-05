//! strata.page — Page header/format, page manager, freelist, file header.
//!
//! Planned files (see docs/PRD.md):
//!   - `page/header.zig`
//!   - `page/manager.zig`
//!   - `page/freelist.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "page: module compiles" {
    std.testing.refAllDecls(@This());
}
