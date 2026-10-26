//! Root-to-leaf descent for the B+Tree (ADR-0004 sections 3, 5, 10): follows `child_index` through
//! internal nodes and returns the pinned leaf plus the path taken.
//!
//! Invariants: the walk takes at most `height_max(page_size)` steps; the root's level is free
//! (bounded by that step count) and every later node must have `level == parent level - 1`, so a
//! cycle, a leaf/internal mix-up or a too-deep tree is `error.Corrupted` and never an unbounded
//! loop. A child id of 0, the node's own id or at or past `page_count` is `Corrupted` too. Every
//! byte read is untrusted data (section 10); only caller contracts are asserted.
//! Allocation: none. Pins: one at a time while descending; the returned leaf guard is the only
//! pin that outlives the call. `io` is a parameter and is never stored (ADR-0001).

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const header = @import("../page/header.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const internal = @import("internal.zig");

const BufferPool = buffer_pool.BufferPool;
const PageGuard = buffer_pool.PageGuard;
const Id = header.Id;

pub const DescendError = buffer_pool.FetchError || node.ParseError;

/// The internal nodes visited, root first: `ids[i]` is the node and `slots[i]` the descent slot
/// taken in it (`count` means `right_child`). The leaf is not included; its id is `leaf`.
pub const Path = struct {
    ids: [node.height_limit]Id,
    slots: [node.height_limit]u16,
    /// Number of internal nodes on the path; the tree's height is `len + 1`.
    len: u8,
    leaf: Id,
};

/// Walks from `root` to the leaf that holds or would hold `key`, filling `path`. Returns the
/// leaf's pinned guard (writable when `for_update`; fetching alone dirties nothing). The caller
/// releases it. Preconditions: `key.len <= key_len_cap`, `root` is not the file header.
pub fn descend(
    pool: *BufferPool,
    io: Io,
    root: Id,
    key: []const u8,
    for_update: bool,
    path: *Path,
) DescendError!PageGuard {
    assert(key.len <= node.key_len_cap);
    assert(root != .file_header);
    path.len = 0;
    var id = root;
    var level_want: ?u8 = null;
    for (0..node.height_max(pool.page_size)) |_| {
        var pinned = if (for_update) try pool.fetchForUpdate(io, id) else try pool.fetch(io, id);
        const page = pinned.bytes();
        if (page[node.offset_type] == @intFromEnum(header.Type.btree_leaf)) {
            errdefer pinned.release();

            if (level_want) |want| {
                if (want != 0) return error.Corrupted;
            }
            const leaf = try node.parse_leaf(page);
            try leaf.check_link(id);
            path.leaf = id;
            return pinned;
        }
        defer pinned.release();

        const level = page[node.offset_level];
        if (level_want) |want| {
            if (level != want) return error.Corrupted;
        }
        const view = try internal.parse_internal(page, level);
        try view.check_link(id);
        const slot = try view.child_index(key);
        const child = try view.child_at(slot);
        if (child == id or @intFromEnum(child) >= pool.pages.page_count) return error.Corrupted;
        path.ids[path.len] = id;
        path.slots[path.len] = slot;
        path.len += 1;
        level_want = level - 1; // `parse_internal` accepted `level >= 1`.
        id = child;
    }
    return error.Corrupted; // Deeper than any valid tree of this page size.
}
