//! strata.btree — Page-based B+Tree: slotted nodes, split/merge, overflow pages,
//! range cursors, WAL integration.
//!
//! Landed: `btree/node.zig` (ADR-0004 limits and leaf cell codec), `btree/internal.zig`
//! (internal cell codec), `btree/split.zig` (split point by bytes), `btree/descend.zig`
//! (bounded root-to-leaf walk), `btree/split_tree.zig` (splitting insert, root id fixed),
//! `btree/validate.zig` (whole-tree checks) and `btree/tree.zig` (`Tree`: create, get, insert
//! with splits, check_invariants, validate; unlogged), `btree/overflow.zig` (overflow chains:
//! write, walk and assemble, freed through `frees_pending`; large values up to 1 MiB in
//! `Tree.insert`, `delete`, `get`, the cursor and `validate`).
//!
//! `Tree.attach` logs each insert and delete as one `page_images` WAL frame (ADR-0004 rules A,
//! B and C); recovery replays it through `wal.PageRedo`. Bulk load is not implemented.
//!
//! Status: landed (format v1, ADR-0004).

const std = @import("std");

pub const node = @import("btree/node.zig");
pub const internal = @import("btree/internal.zig");
pub const split = @import("btree/split.zig");
pub const descend = @import("btree/descend.zig");
pub const split_tree = @import("btree/split_tree.zig");
pub const validate = @import("btree/validate.zig");
pub const overflow = @import("btree/overflow.zig");
pub const tree = @import("btree/tree.zig");
pub const Tree = tree.Tree;
pub const cursor = @import("btree/cursor.zig");
pub const Cursor = cursor.Cursor;

test "btree: module compiles" {
    std.testing.refAllDecls(@This());
}
