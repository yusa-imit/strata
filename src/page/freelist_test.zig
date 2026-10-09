//! Contract tests for `freelist.zig` (ADR-0002 section 7, trunk-page freelist).
//!
//! Expected values are independent of the codec: capacities are literals, raw trunk bytes are read
//! with `std.mem.readInt`, and the model test compares the on-"disk" list against a boolean
//! membership array that never looks at trunk bytes.

const std = @import("std");
const assert = std.debug.assert;
const h = @import("header.zig");
const fl = @import("freelist.zig");

const Id = h.Id;
const DecodeError = h.DecodeError;
const page_sizes = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };
const capacities = [_]u32{ 120, 248, 504, 1016, 2040, 4088, 8184, 16376 };
const lsn_test: u64 = 77;

fn id_of(raw: u32) Id {
    assert(raw > 0);
    assert(raw < 1 << 20);
    return @enumFromInt(raw);
}

fn raw32(page: []const u8, offset: usize) u32 {
    assert(page.len >= 512);
    assert(offset + 4 <= page.len);
    return std.mem.readInt(u32, page[offset..][0..4], .little);
}

/// Rewrites bytes inside a trunk, then restamps the header checksum so only one rule can fire.
fn patch(page: []u8, id: Id, offset: usize, value: u32) void {
    assert(offset >= 24 and offset < page.len);
    assert(offset % 4 == 0);
    std.mem.writeInt(u32, page[offset..][0..4], value, .little);
    h.encode(page, id, .{ .page_type = .free_trunk, .lsn = lsn_test });
}

fn new_trunk(gpa: std.mem.Allocator, page_size: u32, id: Id, next: ?Id) ![]u8 {
    assert(h.page_size_valid(page_size));
    assert(id != .file_header);
    const page = try gpa.alloc(u8, page_size);
    @memset(page, 0xAA); // format_trunk must overwrite stale bytes.
    fl.format_trunk(page, id, next, lsn_test);
    return page;
}

test "trunk_capacity matches (page_size - 32) / 4 at all 8 sizes" {
    for (page_sizes, capacities) |page_size, capacity| {
        try std.testing.expectEqual(capacity, fl.trunk_capacity(page_size));
        try std.testing.expectEqual((page_size - 32) / 4, capacity);
    }
}

test "format_trunk golden layout at 512 bytes" {
    const gpa = std.testing.allocator;
    const page = try new_trunk(gpa, 512, id_of(5), id_of(9));
    defer gpa.free(page);

    try std.testing.expectEqual(@as(u32, 9), raw32(page, 24));
    try std.testing.expectEqual(@as(u32, 0), raw32(page, 28));
    try std.testing.expect(std.mem.allEqual(u8, page[32..], 0));
    const header = try h.decode(page, id_of(5));
    try std.testing.expectEqual(h.Type.free_trunk, header.page_type);
    try std.testing.expectEqual(lsn_test, header.lsn);
    const trunk = try fl.decode_trunk(page, id_of(5));
    try std.testing.expectEqual(@as(?Id, id_of(9)), trunk.next);
    try std.testing.expectEqual(@as(u32, 0), trunk.count);
}

test "pop on an empty list returns null and keeps the head empty" {
    const allocation = try fl.allocate(null, null, lsn_test);
    try std.testing.expectEqual(@as(?Id, null), allocation.id);
    try std.testing.expectEqual(@as(?Id, null), allocation.head);
    try std.testing.expect(!allocation.head_dirty);
}

test "first free becomes the trunk, later frees fill it, pops are LIFO" {
    const gpa = std.testing.allocator;
    const first = try gpa.alloc(u8, 512);
    defer gpa.free(first);
    const spare = try gpa.alloc(u8, 512);
    defer gpa.free(spare);
    const release = try fl.free(null, null, id_of(3), first, lsn_test);
    try std.testing.expectEqual(id_of(3), release.head);
    try std.testing.expectEqual(fl.Written.freed_page, release.written);
    try std.testing.expectEqual(@as(?Id, null), (try fl.decode_trunk(first, id_of(3))).next);

    @memset(spare, 0x5C);
    const second = try fl.free(id_of(3), first, id_of(4), spare, lsn_test + 1);
    try std.testing.expect(std.mem.allEqual(u8, spare, 0x5C)); // appends never touch `freed`.
    try std.testing.expectEqual(lsn_test + 1, (try h.decode(first, id_of(3))).lsn);
    try std.testing.expectEqual(id_of(3), second.head);
    try std.testing.expectEqual(fl.Written.head_page, second.written);
    try std.testing.expectEqual(@as(u32, 1), raw32(first, 28));
    try std.testing.expectEqual(@as(u32, 4), raw32(first, 32));
    _ = try fl.free(id_of(3), first, id_of(8), spare, lsn_test);

    const popped = try fl.allocate(id_of(3), first, lsn_test + 2);
    try std.testing.expectEqual(lsn_test + 2, (try h.decode(first, id_of(3))).lsn);
    try std.testing.expectEqual(@as(?Id, id_of(8)), popped.id);
    try std.testing.expect(popped.head_dirty);
    try std.testing.expectEqual(@as(u32, 0), raw32(first, 36)); // slot 1 zeroed again.
    const popped2 = try fl.allocate(id_of(3), first, lsn_test);
    try std.testing.expectEqual(@as(?Id, id_of(4)), popped2.id);
    const before = try gpa.dupe(u8, first);
    defer gpa.free(before);
    const trunk_itself = try fl.allocate(id_of(3), first, lsn_test + 3);
    try std.testing.expectEqualSlices(u8, before, first); // handing out the trunk writes nothing.
    try std.testing.expectEqual(@as(?Id, id_of(3)), trunk_itself.id);
    try std.testing.expectEqual(@as(?Id, null), trunk_itself.head);
    try std.testing.expect(!trunk_itself.head_dirty);
}

test "full head spills to a new trunk and drains back through next_trunk" {
    const gpa = std.testing.allocator;
    const capacity = fl.trunk_capacity(512);
    const pages = try gpa.alloc([512]u8, capacity + 3);
    defer gpa.free(pages);

    var head: ?Id = null;
    var id_raw: u32 = 1;
    for (0..capacity + 1) |_| { // trunk id 1, then `capacity` entries fill it.
        const id = id_of(id_raw);
        const head_page: ?[]u8 = if (head) |head_id| &pages[@intFromEnum(head_id)] else null;
        const release = try fl.free(head, head_page, id, &pages[id_raw], lsn_test);
        head = release.head;
        id_raw += 1;
    }
    try std.testing.expectEqual(id_of(1), head.?);
    try std.testing.expectEqual(capacity, (try fl.decode_trunk(&pages[1], id_of(1))).count);

    const spill = try fl.free(head, &pages[1], id_of(id_raw), &pages[id_raw], lsn_test);
    try std.testing.expectEqual(fl.Written.freed_page, spill.written);
    try std.testing.expectEqual(id_of(id_raw), spill.head);
    const new_trunk_info = try fl.decode_trunk(&pages[id_raw], id_of(id_raw));
    try std.testing.expectEqual(@as(?Id, id_of(1)), new_trunk_info.next);
    try std.testing.expectEqual(@as(u32, 0), new_trunk_info.count);

    const drained_new = try fl.allocate(spill.head, &pages[id_raw], lsn_test);
    try std.testing.expectEqual(@as(?Id, id_of(id_raw)), drained_new.id);
    try std.testing.expectEqual(@as(?Id, id_of(1)), drained_new.head);
    try std.testing.expect(!drained_new.head_dirty);
    const back = try fl.allocate(drained_new.head, &pages[1], lsn_test);
    try std.testing.expect(back.head_dirty);
    try std.testing.expectEqual(@as(?Id, id_of(capacity + 1)), back.id);
}

test "decode_trunk rejects every corrupt payload with Corrupted" {
    const gpa = std.testing.allocator;
    const id = id_of(6);
    const page = try new_trunk(gpa, 512, id, null);
    defer gpa.free(page);

    patch(page, id, 28, fl.trunk_capacity(512) + 1);
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));

    patch(page, id, 28, 2); // two live slots, both zero.
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));
    patch(page, id, 32, 11);
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id)); // slot 1 still zero.
    patch(page, id, 36, 12);
    _ = try fl.decode_trunk(page, id);

    patch(page, id, 40, 13); // dead slot past `count` must be zero.
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));
    patch(page, id, 40, 0);

    patch(page, id, 24, 6); // next_trunk points at itself.
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));
}

test "decode_trunk accepts a full trunk and rejects a non-trunk page" {
    const gpa = std.testing.allocator;
    const id = id_of(7);
    const page = try new_trunk(gpa, 512, id, id_of(2));
    defer gpa.free(page);
    const capacity = fl.trunk_capacity(512);
    for (0..capacity) |slot| {
        std.mem.writeInt(u32, page[32 + 4 * slot ..][0..4], @intCast(100 + slot), .little);
    }
    patch(page, id, 28, capacity);
    try std.testing.expectEqual(capacity, (try fl.decode_trunk(page, id)).count);

    h.encode(page, id, .{ .page_type = @enumFromInt(128), .lsn = 0 });
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));
}

test "decode_trunk surfaces header errors: unwritten, checksum, wrong id" {
    const gpa = std.testing.allocator;
    const id = id_of(8);
    const page = try new_trunk(gpa, 512, id, null);
    defer gpa.free(page);

    try std.testing.expectError(error.ChecksumMismatch, fl.decode_trunk(page, id_of(9)));
    page[100] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, fl.decode_trunk(page, id));
    @memset(page, 0);
    try std.testing.expectError(error.Unwritten, fl.decode_trunk(page, id));
}

test "free and allocate propagate a corrupt head trunk" {
    const gpa = std.testing.allocator;
    const id = id_of(2);
    const page = try new_trunk(gpa, 512, id, null);
    defer gpa.free(page);
    patch(page, id, 28, fl.trunk_capacity(512) + 1);
    const freed_page = try gpa.alloc(u8, 512);
    defer gpa.free(freed_page);

    try std.testing.expectError(error.Corrupted, fl.free(id, page, id_of(3), freed_page, 0));
    try std.testing.expectError(error.Corrupted, fl.allocate(id, page, 0));
}

/// Model test fixture: every page of a small file plus a membership array for "is free".
const Model = struct {
    page_size: u32,
    pages: []u8,
    is_free: []bool,
    head: ?Id,

    fn page_of(model: *Model, id: Id) []u8 {
        const raw: usize = @intFromEnum(id);
        assert(raw * model.page_size < model.pages.len);
        assert(id != .file_header);
        return model.pages[raw * model.page_size ..][0..model.page_size];
    }

    fn head_page(model: *Model) ?[]u8 {
        assert(model.is_free.len * model.page_size == model.pages.len);
        if (model.head) |head| assert(model.is_free[@intFromEnum(head)]);
        return if (model.head) |head| model.page_of(head) else null;
    }

    /// Walks the on-page list and checks it names exactly the free set, each id once.
    fn check_invariants(model: *Model, gpa: std.mem.Allocator) !void {
        assert(!model.is_free[0]); // Page 0 is the file header, never free.
        assert(model.is_free.len > 1);
        const seen = try gpa.alloc(bool, model.is_free.len);
        defer gpa.free(seen);
        @memset(seen, false);
        var trunk_id = model.head;
        var hops: usize = 0;
        while (trunk_id) |current| : (hops += 1) {
            try std.testing.expect(hops < model.is_free.len); // a longer walk is a cycle.
            const trunk = try fl.decode_trunk(model.page_of(current), current);
            try std.testing.expect(!seen[@intFromEnum(current)]);
            seen[@intFromEnum(current)] = true;
            const body = model.page_of(current);
            for (0..trunk.count) |slot| {
                const entry = raw32(body, 32 + 4 * slot);
                try std.testing.expect(!seen[entry]);
                seen[entry] = true;
            }
            trunk_id = trunk.next;
        }
        try std.testing.expectEqualSlices(bool, model.is_free, seen);
    }
};

fn run_model(gpa: std.mem.Allocator, page_size: u32, id_count: u32, seed: u64) !void {
    assert(h.page_size_valid(page_size));
    assert(id_count > 1);
    const pages = try gpa.alloc(u8, @as(usize, page_size) * id_count);
    defer gpa.free(pages);
    @memset(pages, 0);
    const is_free = try gpa.alloc(bool, id_count);
    defer gpa.free(is_free);
    @memset(is_free, false);
    var model = Model{ .page_size = page_size, .pages = pages, .is_free = is_free, .head = null };
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    for (0..10_000) |op| {
        const free_bias: u8 = if (op < 5_000) 70 else 30; // fill the list first, then drain it.
        if (random.uintLessThan(u8, 100) < free_bias) {
            const id_raw = random.intRangeLessThan(u32, 1, id_count);
            if (is_free[id_raw]) continue; // only live pages can be freed.
            const id = id_of(id_raw);
            const release = try fl.free(model.head, model.head_page(), id, model.page_of(id), op);
            model.head = release.head;
            is_free[id_raw] = true;
        } else {
            const allocation = try fl.allocate(model.head, model.head_page(), op);
            model.head = allocation.head;
            if (allocation.id) |id| {
                try std.testing.expect(is_free[@intFromEnum(id)]);
                is_free[@intFromEnum(id)] = false;
            } else {
                try std.testing.expect(std.mem.findScalar(bool, is_free, true) == null);
            }
        }
        try model.check_invariants(gpa);
    }
    assert(model.pages.len == @as(usize, page_size) * id_count);
}

test "model: seeded 10k ops against a membership array at 512 bytes (spills)" {
    try run_model(std.testing.allocator, 512, 400, 0x5eed_0001);
    try run_model(std.testing.allocator, 512, 400, 0x5eed_0002);
}

test "model: seeded 10k ops at 4096 bytes" {
    try run_model(std.testing.allocator, 4096, 300, 0x5eed_0003);
}

test "decode_trunk rejects a trunk listing itself and a non-zero last dead word" {
    const gpa = std.testing.allocator;
    const id = id_of(6);
    const page = try new_trunk(gpa, 512, id, null);
    defer gpa.free(page);
    patch(page, id, 32, 6);
    patch(page, id, 28, 1);
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));

    patch(page, id, 32, 40);
    _ = try fl.decode_trunk(page, id);
    patch(page, id, 512 - 4, 41); // last word of a trunk with one live slot.
    try std.testing.expectError(error.Corrupted, fl.decode_trunk(page, id));
}

test "matrix: fill, spill and drain at all 8 page sizes" {
    const gpa = std.testing.allocator;
    for (page_sizes) |page_size| {
        const capacity = fl.trunk_capacity(page_size);
        const first = try new_trunk(gpa, page_size, id_of(1), null);
        defer gpa.free(first);
        const spare = try gpa.alloc(u8, page_size);
        defer gpa.free(spare);
        for (0..capacity) |slot| {
            const freed = id_of(@intCast(10 + slot));
            const release = try fl.free(id_of(1), first, freed, spare, lsn_test);
            try std.testing.expectEqual(fl.Written.head_page, release.written);
        }
        try std.testing.expectEqual(capacity, (try fl.decode_trunk(first, id_of(1))).count);
        const spill_id = id_of(capacity + 100);
        const spill = try fl.free(id_of(1), first, spill_id, spare, lsn_test);
        try std.testing.expectEqual(fl.Written.freed_page, spill.written);
        const spilled = try fl.decode_trunk(spare, spill_id);
        try std.testing.expectEqual(@as(?Id, id_of(1)), spilled.next);
        const next = try fl.allocate(spill.head, spare, lsn_test);
        try std.testing.expectEqual(@as(?Id, spill_id), next.id);
        try std.testing.expectEqual(@as(?Id, id_of(1)), next.head);
        const top = try fl.allocate(next.head, first, lsn_test);
        try std.testing.expectEqual(@as(?Id, id_of(10 + capacity - 1)), top.id);
        try std.testing.expectEqual(capacity - 1, (try fl.decode_trunk(first, id_of(1))).count);
    }
}
