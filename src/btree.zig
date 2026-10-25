//! strata.btree — Page-based B+Tree: slotted nodes, split/merge, overflow pages,
//! range cursors, bulk load.
//!
//! Planned files (see docs/PRD.md):
//!   - `btree/node.zig`
//!   - `btree/tree.zig`
//!   - `btree/cursor.zig`
//!   - `btree/overflow.zig`
//!
//! Landed: `btree/node.zig` (ADR-0004 limits and leaf cell codec), `btree/internal.zig`
//! (internal cell codec), `btree/split.zig` (split point by bytes) and `btree/tree.zig`
//! (`Tree`: create, get, insert into the root leaf; no split yet).
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const node = @import("btree/node.zig");
pub const internal = @import("btree/internal.zig");
pub const split = @import("btree/split.zig");
pub const tree = @import("btree/tree.zig");
pub const Tree = tree.Tree;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "btree: module compiles" {
    std.testing.refAllDecls(@This());
}
