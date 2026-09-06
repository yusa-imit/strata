//! strata.btree — Page-based B+Tree: slotted nodes, split/merge, overflow pages,
//! range cursors, bulk load.
//!
//! Planned files (see docs/PRD.md):
//!   - `btree/node.zig`
//!   - `btree/tree.zig`
//!   - `btree/cursor.zig`
//!   - `btree/overflow.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "btree: module compiles" {
    std.testing.refAllDecls(@This());
}
