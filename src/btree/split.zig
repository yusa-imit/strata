//! B+Tree split point (ADR-0004 sections 8 and 13): chooses, by bytes, where a full node splits.
//!
//! The virtual sequence is the node's cells plus the incoming cell inserted at slot `at`; each
//! cell weighs its encoded size plus its 2 B slot. A leaf returns the index in that sequence of
//! the first cell of the right node. An internal node returns the index of the cell whose key
//! moves up: the left node gets the cells before it, the right node the cells after it, and the
//! child of the moved cell becomes `left.right_child`. The choice minimises |left - right| in
//! bytes (the lowest index wins a tie), both halves are non-empty and both fit under `usable`.
//! Invariants: because a cell and its slot are at most a quarter of `usable`, a valid split
//! always exists for a node that cannot take the incoming cell. Page bytes are untrusted data:
//! sizes come from the slot table and a bad one is `error.Corrupted`, never an assert; only the
//! caller contracts (page size, `at`, `incoming_bytes`) are asserted.
//! Allocation: none; every loop is bounded by `cell_count_max`.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("../page/header.zig");
const node = @import("node.zig");

const ParseError = node.ParseError;

/// Weight of virtual cell `v`: the incoming cell at `at`, else existing cell `v` or `v - 1`.
/// Slot offsets are untrusted bytes, so a cell that is empty or ends past the payload is data.
fn weight(page: []const u8, at: u32, incoming_bytes: u32, v: u32) ParseError!u32 {
    const page_size = node.page_size_of(page);
    assert(incoming_bytes >= 1);
    if (v == at) return incoming_bytes + node.slot_size;
    const index = if (v < at) v else v - 1;
    const payload_end = page_size - header.header_size;
    const slot_at = node.offset_slots + node.slot_size * index;
    assert(slot_at + node.slot_size <= page_size); // `index < count <= cell_count_max`.
    const start = node.get16(page, slot_at);
    const end = if (index == 0) payload_end else node.get16(page, slot_at - node.slot_size);
    if (start >= end or end > payload_end) return error.Corrupted;
    return end - start + node.slot_size;
}

/// Index of the split in the virtual cell sequence (see the file doc); leaf and internal nodes
/// are told apart by the type byte. Returns `error.Corrupted` when the page bytes cannot be
/// split: another type, a count above `cell_count_max` or too small (leaf < 1, internal < 2), a
/// cell that is empty or ends past the payload, or no point that leaves both halves under
/// `usable`. Caller contracts, asserted: a valid page size, `at <= count`, and `incoming_bytes`
/// (the encoded size of the cell to insert, without its slot) in `1 .. cell_bytes_max + slot`.
pub fn split_point(page: []const u8, incoming_bytes: u32, at: u16) ParseError!u16 {
    const page_size = node.page_size_of(page);
    const count: u32 = node.get16(page, node.offset_count);
    const type_byte = page[node.offset_type];
    const is_leaf = type_byte == @intFromEnum(header.Type.btree_leaf);
    if (!is_leaf and type_byte != @intFromEnum(header.Type.btree_internal)) return error.Corrupted;
    if (count > node.cell_count_max(page_size)) return error.Corrupted;
    assert(at <= count);
    const incoming_max = node.cell_bytes_max(page_size) + node.slot_size;
    assert(incoming_bytes >= 1 and incoming_bytes <= incoming_max);
    const total_cells = count + 1;
    const cells_min: u32 = if (is_leaf) 2 else 3;
    if (total_cells < cells_min) return error.Corrupted;
    var total: u32 = 0;
    for (0..node.cell_count_max(page_size) + 1) |v| {
        if (v >= total_cells) break;
        total += try weight(page, at, incoming_bytes, @intCast(v));
    }
    // Leaf: right node starts at `v`. Internal: cell `v` moves up, so it counts on neither side.
    const last: u32 = if (is_leaf) total_cells - 1 else total_cells - 2;
    var left: u32 = 0;
    var best: ?u16 = null;
    var best_diff: u32 = std.math.maxInt(u32);
    for (0..node.cell_count_max(page_size) + 1) |v| {
        if (v >= total_cells or v > last) break;
        const w = try weight(page, at, incoming_bytes, @intCast(v));
        const right = if (is_leaf) total - left else total - left - w;
        // Cells of a valid node are at most a quarter of `usable`, so the minimum is always
        // legal there; the clause rejects only corrupted (oversized) cells.
        const fits = left <= node.usable(page_size) and right <= node.usable(page_size);
        const diff = if (left > right) left - right else right - left;
        if (v >= 1 and fits and diff < best_diff) {
            best = @intCast(v);
            best_diff = diff;
        }
        left += w;
    }
    return best orelse error.Corrupted;
}

test {
    _ = @import("split_test.zig"); // Contract tests live in their own file (800-line limit).
}
