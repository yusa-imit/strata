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
//! (internal cell codec), `btree/split.zig` (split point by bytes), `btree/descend.zig`
//! (bounded root-to-leaf walk), `btree/split_tree.zig` (splitting insert, root id fixed),
//! `btree/validate.zig` (whole-tree checks) and `btree/tree.zig` (`Tree`: create, get, insert
//! with splits, check_invariants, validate; unlogged, no overflow values or delete yet).
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const node = @import("btree/node.zig");
pub const internal = @import("btree/internal.zig");
pub const split = @import("btree/split.zig");
pub const descend = @import("btree/descend.zig");
pub const split_tree = @import("btree/split_tree.zig");
pub const validate = @import("btree/validate.zig");
pub const tree = @import("btree/tree.zig");
pub const Tree = tree.Tree;
pub const cursor = @import("btree/cursor.zig");
pub const Cursor = cursor.Cursor;

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "btree: module compiles" {
    std.testing.refAllDecls(@This());
}
