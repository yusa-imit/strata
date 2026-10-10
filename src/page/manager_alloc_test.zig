//! Contract tests for `PageManager.allocate`, `free` and `sync` (plan 003 item 6): growth up to
//! `page_count_max`, LIFO reuse through the trunk freelist, trunk spill and drain, persistence
//! across reopen, corrupt freelists, and a seeded model that reopens between rounds and checks
//! the whole freelist chain after every step.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const header = @import("header.zig");
const freelist = @import("freelist.zig");
const fx = @import("manager_fixtures.zig");

const PageManager = @import("manager.zig").PageManager;
const Options = @import("manager.zig").Options;
const Id = header.Id;

const roomy_max: u32 = 256;

fn opts_room(page_size: u32, page_count_max: u32) Options {
    assert(header.page_size_valid(page_size));
    assert(page_count_max >= 2);
    return .{ .page_size = page_size, .page_count_max = page_count_max, .sync_policy = .none };
}

fn id_at(raw: u32) Id {
    assert(raw >= 1);
    assert(raw <= roomy_max);
    return @enumFromInt(raw);
}

fn id_raw(id: Id) u32 {
    assert(id != .file_header);
    assert(@intFromEnum(id) >= 1);
    return @intFromEnum(id);
}

fn alloc_raw(pm: *PageManager) !u32 {
    assert(pm.page_count >= 1);
    assert(pm.page_count <= roomy_max);
    return id_raw(try pm.allocate(testing.io));
}

fn free_raw(pm: *PageManager, raw: u32) !void {
    assert(raw >= 1);
    assert(raw < pm.page_count);
    try pm.free(testing.io, id_at(raw));
}

test "allocate: a fresh file grows one page at a time and the new pages read as unwritten" {
    for (fx.sizes_three) |size| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "a.db", opts_room(size, 16));
        defer pm.close(testing.io);

        for (1..5) |expected| {
            try testing.expectEqual(@as(u32, @intCast(expected)), try alloc_raw(&pm));
            try testing.expectEqual(@as(u32, @intCast(expected + 1)), pm.page_count);
            try testing.expectEqual(@as(u64, size) * pm.page_count, try pm.file.length(testing.io));
            try fx.expect_page0_intact(&pm, pm.page_count);
            try fx.expect_read_error(&pm, @intCast(expected), error.Unwritten);
        }
        try testing.expectEqual(@as(?Id, null), pm.freelist_head);
    }
}

test "allocate: growth stops at page_count_max with NoSpaceLeft and changes nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "max.db", opts_room(512, 3));
    defer pm.close(testing.io);

    try testing.expectEqual(@as(u32, 1), try alloc_raw(&pm));
    try testing.expectEqual(@as(u32, 2), try alloc_raw(&pm));
    try testing.expectError(error.NoSpaceLeft, pm.allocate(testing.io));
    try testing.expectEqual(@as(u32, 3), pm.page_count);
    try testing.expectEqual(@as(u64, 3 * 512), try pm.file.length(testing.io));
    try fx.expect_page0_intact(&pm, 3);

    try free_raw(&pm, 2); // Freed pages are reused even when growth is exhausted.
    try testing.expectEqual(@as(u32, 2), try alloc_raw(&pm));
    try testing.expectError(error.NoSpaceLeft, pm.allocate(testing.io));
}

test "free: the first freed page becomes the trunk and is handed back last (LIFO)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "lifo.db", opts_room(512, 16));
    defer pm.close(testing.io);

    for (1..5) |_| _ = try alloc_raw(&pm);
    try free_raw(&pm, 1);
    try testing.expectEqual(@as(?Id, id_at(1)), pm.freelist_head);
    try free_raw(&pm, 3);
    try free_raw(&pm, 2);
    try testing.expectEqual(@as(?Id, id_at(1)), pm.freelist_head); // 3 and 2 live in trunk 1.
    try fx.expect_page0_intact(&pm, 5);

    try testing.expectEqual(@as(u32, 2), try alloc_raw(&pm));
    try testing.expectEqual(@as(u32, 3), try alloc_raw(&pm));
    try testing.expectEqual(@as(u32, 1), try alloc_raw(&pm)); // The empty trunk itself.
    try testing.expectEqual(@as(?Id, null), pm.freelist_head);
    try testing.expectEqual(@as(u32, 5), pm.page_count); // Nothing grew.
    try testing.expectEqual(@as(u32, 5), try alloc_raw(&pm));
}

test "free: a full trunk spills into a new one and the whole list drains back" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const capacity = freelist.trunk_capacity(512);
    const total: u32 = capacity + 4; // One full trunk plus a second, partly filled one.
    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "spill.db", opts_room(512, roomy_max));
    defer pm.close(testing.io);

    for (0..total) |_| _ = try alloc_raw(&pm);
    for (1..total + 1) |raw| try free_raw(&pm, @intCast(raw));
    // Trunk 1 holds 2..capacity+1 (full); the next freed page, capacity+2, becomes the head.
    try testing.expectEqual(@as(?Id, id_at(capacity + 2)), pm.freelist_head);
    try check_chain(&pm, total, &.{});

    var seen = [_]bool{false} ** (roomy_max + 1);
    for (0..total) |_| {
        const got = try alloc_raw(&pm);
        try testing.expect(got >= 1 and got <= total);
        try testing.expect(!seen[got]); // No id is handed out twice.
        seen[got] = true;
    }
    try testing.expectEqual(@as(?Id, null), pm.freelist_head);
    try testing.expectEqual(total + 1, pm.page_count);
    try testing.expectEqual(total + 1, try alloc_raw(&pm)); // Empty list: the file grows.
}

test "reopen: page count and freelist survive close and open" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const options = opts_room(512, 16);
    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "re.db", options);
    for (1..6) |_| _ = try alloc_raw(&pm);
    try free_raw(&pm, 2);
    try free_raw(&pm, 4);
    try pm.sync(testing.io);
    pm.close(testing.io);

    try PageManager.open(&pm, testing.io, tmp.dir, "re.db", options);
    defer pm.close(testing.io);

    try testing.expectEqual(@as(u32, 6), pm.page_count);
    try testing.expectEqual(@as(?Id, id_at(2)), pm.freelist_head);
    try testing.expectEqual(@as(u32, 4), try alloc_raw(&pm));
    try testing.expectEqual(@as(u32, 2), try alloc_raw(&pm));
    try testing.expectEqual(@as(u32, 6), try alloc_raw(&pm));
}

test "sync: succeeds under every policy and keeps the state" {
    for (fx.policies) |policy| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();

        var options = opts_room(512, 8);
        options.sync_policy = policy;
        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, "s.db", options);
        defer pm.close(testing.io);

        _ = try alloc_raw(&pm);
        try pm.sync(testing.io);
        try testing.expectEqual(@as(u32, 2), pm.page_count);
    }
}

/// Crafts a 4-page file whose freelist head is `head`, with page 2 a trunk holding `entry` (or
/// empty when 0) linking to `next`; page 3 stays all zeros; opens it.
fn open_with_freelist(pm: *PageManager, dir: Io.Dir, head: u32, entry: u32, next: u32) !void {
    assert(head <= 3);
    const size: u32 = 512;
    assert(entry < roomy_max);
    var page: [512]u8 = undefined;
    var fh = fx.fh_of(size, 4);
    fh.freelist_head = if (head == 0) null else id_at(head);
    header.encode_file_header(&page, fh);
    try fx.write_file(dir, "c.db", &page, 4 * size);
    const f = try fx.raw_open(dir, "c.db");
    defer f.close(testing.io);

    freelist.format_trunk(&page, id_at(2), if (next == 0) null else id_at(next), 0);
    if (entry != 0) {
        std.mem.writeInt(u32, page[32..][0..4], entry, .little);
        std.mem.writeInt(u32, page[28..][0..4], 1, .little);
        header.encode(&page, id_at(2), .{ .page_type = .free_trunk, .lsn = 0 });
    }
    try f.writeAtAll(testing.io, &page, 2 * size);
    try PageManager.open(pm, testing.io, dir, "c.db", opts_room(size, 16));
}

test "allocate and free: a trunk entry or link outside the file is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_with_freelist(&pm, tmp.dir, 2, 9, 0); // Entry 9 is past page_count 4.
    try testing.expectError(error.Corrupted, pm.allocate(testing.io));
    try testing.expectEqual(@as(?Id, id_at(2)), pm.freelist_head); // State unchanged.
    pm.close(testing.io);

    try open_with_freelist(&pm, tmp.dir, 2, 0, 9); // next_trunk 9 is past page_count 4.
    try testing.expectError(error.Corrupted, pm.allocate(testing.io));
    pm.close(testing.io);
}

test "free: a malformed head trunk fails and leaves the manager and page 0 unchanged" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_with_freelist(&pm, tmp.dir, 3, 0, 0); // Head 3 is an unwritten page.
    try testing.expectError(error.Corrupted, pm.free(testing.io, id_at(1)));
    try testing.expectEqual(@as(?Id, id_at(3)), pm.freelist_head);
    pm.close(testing.io);

    try open_with_freelist(&pm, tmp.dir, 2, 0, 0);
    defer pm.close(testing.io);

    try fx.flip_byte(pm.file, 2 * 512 + 100);
    try testing.expectError(error.ChecksumMismatch, pm.free(testing.io, id_at(1)));
    try testing.expectEqual(@as(?Id, id_at(2)), pm.freelist_head);
    try testing.expectEqual(@as(u32, 4), pm.page_count);
}

test "allocate: a head trunk that was never written is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_with_freelist(&pm, tmp.dir, 3, 0, 0); // Page 3 is all zeros on disk.
    defer pm.close(testing.io);

    try testing.expectError(error.Corrupted, pm.allocate(testing.io));
    try testing.expectEqual(@as(u32, 4), pm.page_count);
}

test "allocate: a flipped byte in the head trunk is ChecksumMismatch" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_with_freelist(&pm, tmp.dir, 2, 0, 0);
    defer pm.close(testing.io);

    try fx.flip_byte(pm.file, 2 * 512 + 100);
    try testing.expectError(error.ChecksumMismatch, pm.allocate(testing.io));
}

/// Walks the freelist chain on disk and checks that trunks and entries are distinct, in range,
/// disjoint from `live`, and that live plus free is exactly pages `1 ..< page_count`.
fn check_chain(pm: *PageManager, expected_pages: u32, live: []const u32) !void {
    const gpa = testing.allocator;
    assert(pm.page_count >= 1);
    assert(pm.page_count <= roomy_max + 1);
    const state = try gpa.alloc(u8, pm.page_count);
    defer gpa.free(state);

    @memset(state, 0);
    for (live) |raw| {
        try testing.expect(raw >= 1 and raw < pm.page_count);
        try testing.expectEqual(@as(u8, 0), state[raw]);
        state[raw] = 1;
    }
    const page = try gpa.alloc(u8, pm.page_size);
    defer gpa.free(page);

    var cursor = pm.freelist_head;
    var trunks: u32 = 0;
    while (cursor) |trunk_id| : (trunks += 1) {
        try testing.expect(trunks < pm.page_count); // A cycle would never end.
        try testing.expect(id_raw(trunk_id) < pm.page_count);
        try testing.expectEqual(@as(u8, 0), state[id_raw(trunk_id)]);
        state[id_raw(trunk_id)] = 2;
        try pm.file.readAtAll(testing.io, page, @as(u64, pm.page_size) * id_raw(trunk_id));
        const trunk = try freelist.decode_trunk(page, trunk_id);
        for (0..trunk.count) |slot| {
            const entry = std.mem.readInt(u32, page[32 + slot * 4 ..][0..4], .little);
            try testing.expect(entry >= 1 and entry < pm.page_count);
            try testing.expectEqual(@as(u8, 0), state[entry]);
            state[entry] = 2;
        }
        cursor = trunk.next;
    }
    try testing.expectEqual(expected_pages + 1, pm.page_count);
    for (state[1..]) |mark| try testing.expect(mark != 0); // Every page is live or free.
}

const model_seed: u64 = 0x57A7_A003_0006;
const model_steps: u32 = 600;
const reopen_every: u32 = 50;

test "model: seeded allocate, free, write and reopen keep live and free pages a partition" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const size: u32 = 512;
    const options = opts_room(size, roomy_max);
    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "model.db", options);
    var live: std.ArrayList(u32) = .empty;
    defer live.deinit(testing.allocator);

    var prng = std.Random.DefaultPrng.init(model_seed);
    const rng = prng.random();
    var buf: [512]u8 = undefined;
    var stamp = [_]u32{0} ** (roomy_max + 1);
    var step: u32 = 0;
    while (step < model_steps) : (step += 1) {
        const grow = live.items.len == 0 or (rng.boolean() and live.items.len < 200);
        if (grow) {
            const got = try alloc_raw(&pm);
            try testing.expect(std.mem.findScalar(u32, live.items, got) == null);
            try live.append(testing.allocator, got);
            stamp[got] = step;
            try fx.write_pattern(&pm, got, &buf, got * 7 + step, step);
        } else {
            const slot = rng.uintLessThan(usize, live.items.len);
            const victim = live.swapRemove(slot);
            try free_raw(&pm, victim);
        }
        if (live.items.len > 0) {
            const probe = live.items[rng.uintLessThan(usize, live.items.len)];
            try fx.expect_pattern(&pm, probe, probe * 7 + stamp[probe], stamp[probe]);
        }
        try check_chain(&pm, pm.page_count - 1, live.items);
        if (step % reopen_every == reopen_every - 1) {
            pm.close(testing.io);
            try PageManager.open(&pm, testing.io, tmp.dir, "model.db", options);
            try check_chain(&pm, pm.page_count - 1, live.items);
        }
    }
    pm.close(testing.io);
    try testing.expect(live.items.len > 0);
}
