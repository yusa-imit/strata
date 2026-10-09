//! Trunk-page freelist codec (ADR-0002 section 7): pure push and pop over the bytes of free-trunk
//! pages. The page manager does the I/O and owns `freelist_head`; this module decides which page
//! bytes change and what the new head is.
//!
//! Invariants: a trunk is a page of type `free_trunk` with `next_trunk` at 24, `count` at 28 and
//! `ids[]` from 32. `ids[0..count]` are non-zero, `ids[count..]` are zero, `count <= capacity`
//! and `next_trunk` never names the trunk itself. Push and pop touch only the head trunk, so
//! every operation reads and writes at most one existing page. Every mutation restamps the page
//! checksum through `header.encode`.
//! Allocation: none. Functions are pure over caller-owned slices and take no `io` (ADR-0001).
//! Errors: bad bytes on disk are typed `DecodeError`s (`Corrupted` for payload rules). A wrong
//! slice length, a zero or duplicate freed id, or a head that disagrees with its page is a
//! caller contract violation and is asserted. Range checks against `page_count` are the
//! manager's, which knows `page_count`.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("header.zig");

const Id = header.Id;
const DecodeError = header.DecodeError;

const offset_next: u32 = 24;
const offset_count: u32 = 28;
const offset_ids: u32 = 32;
const id_size: u32 = 4;

comptime {
    assert(offset_next == header.header_size);
    assert(offset_count == offset_next + id_size);
    assert(offset_ids == offset_count + id_size);
    assert(offset_ids <= header.page_size_min);
    assert(trunk_capacity(header.page_size_min) == 120); // ADR-0002 section 7.
    assert(trunk_capacity(header.page_size_max) == 16376);
}

/// Decoded fixed fields of a trunk page.
pub const Trunk = struct { next: ?Id, count: u32 };

/// Which page the caller must write after `free`.
pub const Written = enum { head_page, freed_page };

/// Result of `free`: `head` is the new `freelist_head`.
pub const Release = struct { head: Id, written: Written };

/// Result of `allocate`: `id` is `null` when the list is empty (the manager grows the file);
/// `head` is the new `freelist_head`; `head_dirty` says the head trunk bytes changed and must be
/// written (false when the trunk itself was handed out or the list was empty).
pub const Allocation = struct { id: ?Id, head: ?Id, head_dirty: bool };

/// Ids a trunk of `page_size` bytes holds. Precondition: `page_size` is a valid page size.
pub fn trunk_capacity(page_size: u32) u32 {
    assert(header.page_size_valid(page_size));
    assert(page_size > offset_ids);
    return @divExact(page_size - offset_ids, id_size);
}

fn get(page: []const u8, offset: u32) u32 {
    assert(offset + id_size <= page.len);
    return std.mem.readInt(u32, page[offset..][0..id_size], .little);
}

fn put(page: []u8, offset: u32, value: u32) void {
    assert(offset + id_size <= page.len);
    std.mem.writeInt(u32, page[offset..][0..id_size], value, .little);
    assert(get(page, offset) == value);
}

fn raw_of(id: ?Id) u32 {
    if (id) |present| assert(present != .file_header); // Page 0 is never a link target.
    return if (id) |present| @intFromEnum(present) else 0;
}

fn slot_offset(slot_index: u32) u32 {
    assert(slot_index <= header.page_size_max / id_size);
    assert(offset_ids + slot_index * id_size <= header.page_size_max);
    return offset_ids + slot_index * id_size;
}

fn capacity_of(page: []const u8) u32 {
    assert(page.len <= header.page_size_max);
    return trunk_capacity(@intCast(page.len));
}

/// Writes an empty trunk image: clears all of `page`, stores `next` (null = last trunk), count 0,
/// then stamps the header (type free_trunk) and checksum. Preconditions: `page.len` is a valid
/// page size; `id` is not page 0; `next` is not `id`.
pub fn format_trunk(page: []u8, id: Id, next: ?Id, lsn: u64) void {
    assert(id != .file_header);
    assert(raw_of(next) != @intFromEnum(id));
    @memset(page, 0);
    put(page, offset_next, raw_of(next));
    header.encode(page, id, .{ .page_type = .free_trunk, .lsn = lsn });
    assert(get(page, offset_count) == 0);
}

/// Fully validates `page` as trunk `id` and returns its fixed fields. Header failures pass
/// through; payload rule violations (wrong type, `count > capacity`, zero id in a live slot,
/// non-zero dead slot, self-linked `next_trunk`, trunk listed in its own slots) are `Corrupted`.
/// Duplicate ids across slots or trunks are not detectable here; the manager's bounded walk
/// owns that check (ADR-0002 Costs). Cost is O(page_size) per call, like the checksum.
/// Precondition: `page.len` is a valid page size.
pub fn decode_trunk(page: []const u8, id: Id) DecodeError!Trunk {
    assert(id != .file_header);
    const decoded = try header.decode(page, id);
    if (decoded.page_type != .free_trunk) return error.Corrupted;
    const next_raw = get(page, offset_next);
    if (next_raw == @intFromEnum(id)) return error.Corrupted;
    const count = get(page, offset_count);
    const capacity = capacity_of(page);
    if (count > capacity) return error.Corrupted;
    for (0..count) |slot_index| {
        const entry = get(page, slot_offset(@intCast(slot_index)));
        if (entry == 0) return error.Corrupted;
        if (entry == @intFromEnum(id)) return error.Corrupted; // A trunk cannot list itself.
    }
    if (!std.mem.allEqual(u8, page[slot_offset(count)..], 0)) return error.Corrupted;
    assert(count <= capacity);
    return .{ .next = if (next_raw == 0) null else @enumFromInt(next_raw), .count = count };
}

/// True when live slot `ids[0..count]` already names `freed`. Used only inside assertions.
fn contains(page: []const u8, count: u32, freed: Id) bool {
    assert(count <= capacity_of(page));
    for (0..count) |slot_index| {
        if (get(page, slot_offset(@intCast(slot_index))) == @intFromEnum(freed)) return true;
    }
    return false;
}

/// Frees page `freed`. With no head, or a full head trunk, `freed` becomes the new head trunk
/// (`freed_page` is formatted, `next_trunk` = old head) and the caller writes `freed_page`.
/// Otherwise `freed` is appended to the head trunk in `head_page`, which the caller writes;
/// `freed_page` is untouched. Never needs a page, so it cannot fail for lack of space.
/// Preconditions: `(head == null) == (head_page == null)`; `head_page` is the head trunk's
/// bytes; `freed` is not page 0, not the head and not already listed in the head trunk;
/// `freed_page` has the same length as the page size. Freeing a page that is already listed
/// in a non-head trunk is invisible here; the manager rejects it at its boundary.
/// Errors: the head trunk fails `decode_trunk`.
pub fn free(
    head: ?Id,
    head_page: ?[]u8,
    freed: Id,
    freed_page: []u8,
    lsn: u64,
) DecodeError!Release {
    assert(freed != .file_header);
    assert((head == null) == (head_page == null));
    if (head == null) {
        format_trunk(freed_page, freed, null, lsn);
        return .{ .head = freed, .written = .freed_page };
    }
    const head_id = head.?;
    const page = head_page.?;
    assert(head_id != freed);
    assert(freed_page.len == page.len);
    const trunk = try decode_trunk(page, head_id);
    assert(!contains(page, trunk.count, freed)); // A double free would hand the page out twice.
    if (trunk.count == capacity_of(page)) {
        format_trunk(freed_page, freed, head_id, lsn);
        return .{ .head = freed, .written = .freed_page };
    }
    put(page, slot_offset(trunk.count), @intFromEnum(freed));
    put(page, offset_count, trunk.count + 1);
    header.encode(page, head_id, .{ .page_type = .free_trunk, .lsn = lsn });
    return .{ .head = head_id, .written = .head_page };
}

/// Pops a page. Empty list: `id = null`. Head trunk with entries: returns the last id, zeroes its
/// slot and decrements `count` in `head_page` (LIFO: the most recently freed page is the most
/// likely to still be cached); the caller writes `head_page`. Head trunk with `count == 0`: the
/// trunk page itself is returned and the head moves to `next_trunk`; nothing is written.
/// Preconditions: `(head == null) == (head_page == null)`; `head_page` is the head trunk's bytes;
/// `head` came from the file header's `freelist_head` with 0 already mapped to null.
/// Errors: the head trunk fails `decode_trunk`.
pub fn allocate(head: ?Id, head_page: ?[]u8, lsn: u64) DecodeError!Allocation {
    assert((head == null) == (head_page == null));
    if (head == null) return .{ .id = null, .head = null, .head_dirty = false };
    const head_id = head.?;
    const page = head_page.?;
    const trunk = try decode_trunk(page, head_id);
    assert(trunk.count <= capacity_of(page));
    if (trunk.count == 0) return .{ .id = head_id, .head = trunk.next, .head_dirty = false };
    const last_slot = slot_offset(trunk.count - 1);
    const popped: Id = @enumFromInt(get(page, last_slot));
    assert(popped != .file_header);
    put(page, last_slot, 0);
    put(page, offset_count, trunk.count - 1);
    header.encode(page, head_id, .{ .page_type = .free_trunk, .lsn = lsn });
    return .{ .id = popped, .head = head_id, .head_dirty = true };
}

test {
    _ = @import("freelist_test.zig"); // Contract tests live in their own file (800-line limit).
}
