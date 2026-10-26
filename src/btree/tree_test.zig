//! Contract tests for `Tree` over the root leaf (plan 005 items 4 and 5, ADR-0004 sections 2, 7,
//! 8, 10): create allocates the fixed root, insert/get/overwrite at all eight page sizes,
//! key and value boundaries, the first root split, corrupted root pages
//! giving typed errors, no allocation after init, and a seeded model against a hash map. A full
//! root leaf splits (the old `NodeFull` is gone). Every error variant `Tree` declares itself
//! (`KeyTooLarge`, `ValueTooLarge`, `Corrupted` from each of its branches; `HeightLimit` is in
//! `split_tree_test.zig`) is provoked here; the page, pool and file layers' errors pass
//! through unchanged and only the representative ones (`ChecksumMismatch`, `Unwritten`,
//! `PoolExhausted`, `InvalidHeader`, `NoSpaceLeft`) are shown.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const tree_mod = @import("tree.zig");
const tfx = @import("tree_fixtures.zig");

const PageManager = manager.PageManager;
const BufferPool = buffer_pool.BufferPool;
const Tree = tree_mod.Tree;
const Edit = *const fn ([]u8) anyerror!void;

/// One construction path: a temp dir, a page file, a pool and a created tree, built in place.
const Fixture = struct {
    tmp: testing.TmpDir,
    pm: PageManager,
    pool: BufferPool,
    tree: Tree,

    fn start(self: *Fixture, gpa: Allocator, size: u32, frames: u32) !void {
        assert(header.page_size_valid(size));
        assert(frames >= 1);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        try PageManager.create(&self.pm, testing.io, self.tmp.dir, "tree.db", fx.opts(size));
        errdefer self.pm.close(testing.io);

        const options: buffer_pool.Options = .{ .frames_max = frames, .page_size = size };
        try BufferPool.init(&self.pool, gpa, &self.pm, options);
        errdefer self.pool.deinit(gpa);

        try Tree.create(&self.tree, testing.io, &self.pool);
    }

    fn stop(self: *Fixture, gpa: Allocator) void {
        assert(self.pool.pinned_count() == 0);
        assert(self.tree.root != .file_header);
        assert(self.pm.page_size == self.pool.page_size);
        self.pool.discardAll();
        self.pool.deinit(gpa);
        self.pm.close(testing.io);
        self.tmp.cleanup();
    }

    /// Writes everything out and empties the pool, so the next access reads from the file.
    fn cold(self: *Fixture) !void {
        assert(self.pool.pinned_count() == 0);
        try self.pool.flushAll(testing.io);
        self.pool.discardAll();
        assert(self.pool.dirty_count == 0);
    }

    fn root_u32(self: *const Fixture) u32 {
        assert(self.tree.root != .file_header);
        assert(self.tree.page_size >= header.page_size_min);
        return @intFromEnum(self.tree.root);
    }
};

fn key_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 8);
    assert(n < 100_000);
    buf[0] = 'k';
    var rest = n;
    for (0..5) |i| {
        buf[5 - i] = '0' + @as(u8, @intCast(rest % 10)); // A digit, so the cast cannot truncate.
        rest = @divTrunc(rest, 10);
    }
    assert(rest == 0 or n >= 100_000);
    return buf[0..6];
}

fn expect_get(t: *Tree, key: []const u8, want: ?[]const u8) !void {
    assert(key.len <= 4096);
    assert(t.page_size >= header.page_size_min);
    assert(t.root != .file_header);
    const got = try t.get(testing.io, key);
    if (want) |bytes| {
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, bytes, got.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), got);
    }
}

fn leaf_count(f: *Fixture) !u16 {
    assert(f.pool.pinned_count() == 0);
    assert(f.root_u32() >= 1);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    const leaf = try node.parse_leaf(guard.bytes());
    try leaf.check_invariants();
    return leaf.count;
}

/// Largest value length that stays inline for a `key_len`-byte key.
fn inline_value_max(page_size: u32, key_len: u32) u32 {
    assert(key_len <= node.key_len_max(page_size));
    assert(node.value_inline(page_size, key_len, 0));
    var value_len: u32 = 0;
    while (node.value_inline(page_size, key_len, value_len + 1)) value_len += 1;
    assert(!node.value_inline(page_size, key_len, value_len + 1));
    return value_len;
}

test "create: the root is the first allocated id and an empty valid leaf, not yet on disk" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2);
        defer f.stop(testing.allocator);

        try testing.expectEqual(@as(u32, 1), f.root_u32());
        try testing.expectEqual(size, f.tree.page_size);
        try testing.expectEqual(@as(u64, 0), f.pool.stats().writebacks);
        try testing.expectEqual(@as(u32, 1), f.pool.dirty_count);
        try testing.expectEqual(@as(u16, 0), try leaf_count(&f));
        try expect_get(&f.tree, "", null);
        try expect_get(&f.tree, "anything", null);
        try f.cold();
        try testing.expectEqual(@as(u16, 0), try leaf_count(&f)); // Durable after the flush.
        var reopened: Tree = undefined;
        try Tree.open(&reopened, &f.pool, f.tree.root);
        try expect_get(&reopened, "x", null);
    }
}

test "create: a full file is NoSpaceLeft and leaves the pool clean" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    const options: manager.Options = .{
        .page_size = 512,
        .page_count_max = 1,
        .sync_policy = .none,
    };
    try PageManager.create(&pm, testing.io, tmp.dir, "full.db", options);
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, .{ .frames_max = 1, .page_size = 512 });
    defer pool.deinit(testing.allocator);

    var t: Tree = undefined;
    try testing.expectError(error.NoSpaceLeft, Tree.create(&t, testing.io, &pool));
    try testing.expectEqual(@as(u32, 0), pool.dirty_count);
    try testing.expectEqual(@as(u32, 1), pm.page_count);
}

test "insert and get: out-of-order keys, overwrite longer and shorter, at all page sizes" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2);
        defer f.stop(testing.allocator);

        try f.tree.insert(testing.io, "pear", "green");
        try f.tree.insert(testing.io, "apple", "red");
        try f.tree.insert(testing.io, "kiwi", "brown");
        try testing.expectEqual(@as(u16, 3), try leaf_count(&f));
        try expect_get(&f.tree, "apple", "red");
        try expect_get(&f.tree, "kiwi", "brown");
        try expect_get(&f.tree, "pear", "green");
        try expect_get(&f.tree, "plum", null);
        try expect_get(&f.tree, "app", null); // A proper prefix is not the key.
        try expect_get(&f.tree, "applesauce", null);

        try f.tree.insert(testing.io, "kiwi", "a much longer value than before");
        try testing.expectEqual(@as(u16, 3), try leaf_count(&f));
        try expect_get(&f.tree, "kiwi", "a much longer value than before");
        try f.tree.insert(testing.io, "kiwi", "");
        try expect_get(&f.tree, "kiwi", "");
        try f.tree.insert(testing.io, "apple", "red"); // Same value again.
        try testing.expectEqual(@as(u16, 3), try leaf_count(&f));
        try expect_get(&f.tree, "pear", "green");

        try f.cold(); // Everything survives a flush and a cold read.
        try expect_get(&f.tree, "apple", "red");
        try expect_get(&f.tree, "kiwi", "");
        try testing.expectEqual(@as(u16, 3), try leaf_count(&f));
    }
}

test "insert: an edit stamps a valid checksum and keeps a non-zero page lsn" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    var guard = try f.pool.fetchForUpdate(testing.io, f.tree.root);
    guard.set_lsn(5);
    guard.release();
    try f.tree.insert(testing.io, "a", "1");
    try f.tree.insert(testing.io, "a", "22"); // An overwrite re-seals too.
    try testing.expectEqual(@as(u64, 5), header.peek(try page_bytes(&f)).lsn);
    try f.cold();
    var buf: [512]u8 = undefined;
    const h = try f.pm.read(testing.io, f.tree.root, &buf); // Decode verifies the checksum.
    try testing.expectEqual(header.Type.btree_leaf, h.page_type);
    try testing.expectEqual(@as(u64, 5), h.lsn);
    const leaf = try node.parse_leaf(&buf);
    try leaf.check_link(f.tree.root);
    try testing.expectEqual(@as(?header.Id, null), leaf.next);
    try expect_get(&f.tree, "a", "22");
}

test "open: a persisted root outside the file is Corrupted and leaves the target alone" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    var t: Tree = f.tree;
    const before = t;
    const past: header.Id = @enumFromInt(f.pm.page_count);
    try testing.expectError(error.Corrupted, Tree.open(&t, &f.pool, .file_header));
    try testing.expectError(error.Corrupted, Tree.open(&t, &f.pool, past));
    try testing.expectEqual(before.root, t.root);
    try Tree.open(&t, &f.pool, f.tree.root);
    try expect_get(&t, "none", null);
}

test "create: PoolExhausted (id leaked, target untouched) and InvalidHeader (dirty victim)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try PageManager.create(&pm, testing.io, tmp.dir, "c.db", fx.opts(512));
    defer pm.close(testing.io);

    var pool: BufferPool = undefined;
    try BufferPool.init(&pool, testing.allocator, &pm, .{ .frames_max = 1, .page_size = 512 });
    defer pool.deinit(testing.allocator);

    const first = try pm.allocate(testing.io);
    var pin = try pool.fetchNew(testing.io, first);
    var t: Tree = .{ .pool = &pool, .root = first, .page_size = 512 };
    const count_before = pm.page_count;
    try testing.expectError(error.PoolExhausted, Tree.create(&t, testing.io, &pool));
    try testing.expectEqual(first, t.root);
    try testing.expectEqual(count_before + 1, pm.page_count); // The allocated id leaks.
    pin.release();
    // The victim is dirty and unformatted (type byte 0), so evicting it for the root fails.
    try testing.expectError(error.InvalidHeader, Tree.create(&t, testing.io, &pool));
    try testing.expectEqual(first, t.root);
    try testing.expectEqual(@as(u32, 0), pool.pinned_count());
    pool.discardAll();
}

test "boundaries: empty key, longest key, longest inline value, and one past each" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2);
        defer f.stop(testing.allocator);

        const key_max = node.key_len_max(size);
        const long_key = try testing.allocator.alloc(u8, key_max + 1);
        defer testing.allocator.free(long_key);

        @memset(long_key, 'z');
        try f.tree.insert(testing.io, "", "empty");
        try f.tree.insert(testing.io, long_key[0..key_max], "");
        try expect_get(&f.tree, "", "empty");
        try expect_get(&f.tree, long_key[0..key_max], "");
        try testing.expectError(error.KeyTooLarge, f.tree.insert(testing.io, long_key, "v"));
        try testing.expectEqual(@as(u16, 2), try leaf_count(&f));

        const vmax = inline_value_max(size, 4);
        const value = try testing.allocator.alloc(u8, node.value_len_max + 1);
        defer testing.allocator.free(value);

        @memset(value, 'v');
        try f.tree.insert(testing.io, "four", value[0..vmax]);
        try expect_get(&f.tree, "four", value[0..vmax]);
        const big = f.tree.insert(testing.io, "four", value[0 .. vmax + 1]);
        try testing.expectError(error.ValueTooLarge, big);
        const huge = f.tree.insert(testing.io, "four", value); // Over the format limit too.
        try testing.expectError(error.ValueTooLarge, huge);
        try expect_get(&f.tree, "four", value[0..vmax]); // Rejections changed nothing.
        try testing.expectEqual(@as(u16, 3), try leaf_count(&f));
        try testing.expectError(error.KeyTooLarge, f.tree.get(testing.io, long_key));
    }
}

test "full leaf: a new key and a growing overwrite split it instead of failing" {
    for (fx.sizes_all) |size| {
        var f: tfx.Fixture = undefined;
        try f.start(testing.allocator, size, 8, 16);
        defer f.stop(testing.allocator);

        var key_buf: [8]u8 = undefined;
        var count: u32 = 0;
        while (count < 100_000) : (count += 1) {
            const key = key_of(&key_buf, count);
            try f.tree.insert(testing.io, key, "vvvv");
            var guard = try f.pool.fetch(testing.io, f.tree.root);
            defer guard.release();

            if (guard.bytes()[node.offset_type] != @intFromEnum(header.Type.btree_leaf)) break;
        }
        try testing.expect(count >= 4 and count < 100_000); // The root left leaf form: a split.
        try testing.expectEqual(@as(u32, 1), @intFromEnum(f.tree.root)); // Same root id.
        try testing.expectEqual(@as(u32, 4), f.pm.page_count); // Root plus two halves (plus 0).
        try f.tree.validate(testing.io, testing.allocator);
        const grow = [_]u8{'g'} ** 100; // Inline at every size (cell max at 512 is 118).
        try f.tree.insert(testing.io, "k00000", &grow); // Outgrows its leaf's free space.
        try expect_get(&f.tree, "k00000", &grow);
        try f.tree.insert(testing.io, "k00000", "w");
        try expect_get(&f.tree, "k00000", "w");
        try expect_get(&f.tree, key_of(&key_buf, count), "vvvv");
        try f.tree.validate(testing.io, testing.allocator);
    }
}

/// The root page's current in-memory bytes (valid until the next pool access).
fn page_bytes(f: *Fixture) ![]const u8 {
    assert(f.pool.pinned_count() == 0);
    assert(f.root_u32() >= 1);
    var guard = try f.pool.fetch(testing.io, f.tree.root);
    defer guard.release();

    return guard.bytes();
}

/// Re-reads the root, applies `edit`, rewrites it with a fresh checksum (so the codec accepts it).
fn craft_root(f: *Fixture, edit: Edit) !void {
    assert(f.pool.pinned_count() == 0);
    try f.cold();
    var buf: [header.page_size_max]u8 = undefined;
    const page = buf[0..f.pm.page_size];
    _ = try f.pm.read(testing.io, f.tree.root, page);
    try edit(page);
    const sealed = header.peek(page);
    try f.pm.write(testing.io, f.tree.root, page, sealed);
    assert(header.peek(page).page_type == sealed.page_type);
}

fn edit_count_huge(page: []u8) anyerror!void {
    assert(page.len >= 64);
    assert(page[node.offset_type] == @intFromEnum(header.Type.btree_leaf));
    node.put16(page, node.offset_count, 0xFFFF);
}

fn edit_type_internal(page: []u8) anyerror!void {
    assert(page.len >= 64);
    page[node.offset_type] = @intFromEnum(header.Type.btree_internal);
}

fn edit_self_link(page: []u8) anyerror!void {
    assert(page.len >= 64);
    node.put32(page, node.offset_link, 1); // The root is id 1: a leaf linking to itself.
}

fn edit_slot_garbage(page: []u8) anyerror!void {
    assert(page.len >= 64);
    node.put16(page, node.offset_slots, 9); // Inside the slot table, not a cell.
}

fn edit_level_one(page: []u8) anyerror!void {
    assert(page.len >= 64);
    page[node.offset_level] = 1;
}

fn edit_underflow_used(page: []u8) anyerror!void {
    assert(page.len == 512);
    assert(node.get16(page, node.offset_count) == 3);
    node.put16(page, node.offset_count, 4); // A fourth slot that points at the page end,
    node.put16(page, node.offset_slots + 6, @intCast(page.len - header.header_size));
}

fn edit_key_after_unsorted(page: []u8) anyerror!void {
    assert(page.len == 512);
    assert(page[page.len - 10] == 'c'); // Cell 2: [klen, vlen, key, value] ends at ps - 8.
    page[page.len - 10] = 'a'; // Keys a, b, a: the cell after "b" sorts before it.
}

fn edit_key_before_unsorted(page: []u8) anyerror!void {
    assert(page.len == 512);
    assert(page[page.len - 2] == 'a'); // Cell 0 ends at the page end.
    page[page.len - 2] = 'z'; // Keys z, b, c: the cell before "b" sorts after it.
}

fn edit_overflow_cell(page: []u8) anyerror!void {
    assert(page.len == 512);
    assert(node.get16(page, node.offset_count) == 0);
    const spill: node.Overflow = .{ .head = @enumFromInt(2), .len = 1000 };
    try node.leaf_insert(page, 0, "k", .{ .overflow = spill });
}

/// Crafts the root with `edit`, then proves `insert` of `key` is `Corrupted` and changes no byte.
fn expect_insert_corrupted(f: *Fixture, edit: Edit, key: []const u8) !void {
    assert(key.len <= 8);
    assert(f.pool.pinned_count() == 0);
    try craft_root(f, edit);
    const snapshot = try testing.allocator.dupe(u8, try page_bytes(f));
    defer testing.allocator.free(snapshot);

    try testing.expectError(error.Corrupted, f.tree.insert(testing.io, key, "2"));
    try testing.expectEqualSlices(u8, snapshot, try page_bytes(f));
    try testing.expectEqual(@as(u32, 0), f.pool.dirty_count); // Not even dirtied.
}

fn insert_abc(f: *Fixture, b_value: []const u8) !void {
    assert(b_value.len >= 1);
    assert(f.tree.page_size == 512);
    try f.tree.insert(testing.io, "a", "1");
    try f.tree.insert(testing.io, "b", b_value);
    try f.tree.insert(testing.io, "c", "1");
}

test "corruption: a slot table claiming fewer used bytes than a cell is Corrupted, not a trap" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    try insert_abc(&f, "twenty bytes of value"); // Cell "b" is 24 bytes; used_bytes will say 8.
    try expect_insert_corrupted(&f, edit_underflow_used, "b");
}

test "corruption: an overwrite whose neighbour breaks key order is Corrupted, page unchanged" {
    const edits = [_]Edit{ edit_key_after_unsorted, edit_key_before_unsorted };
    for (edits) |edit| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, 512, 2);
        defer f.stop(testing.allocator);

        try insert_abc(&f, "1");
        try expect_insert_corrupted(&f, edit, "b");
    }
}

test "corruption: an overflow cell is Corrupted for get and for an overwrite (not built yet)" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    try expect_insert_corrupted(&f, edit_overflow_cell, "k");
    try testing.expectError(error.Corrupted, f.tree.get(testing.io, "k"));
    try f.tree.check_invariants(testing.io); // The cell itself is well formed.
}

test "corruption: well-checksummed but malformed roots are Corrupted, never a panic" {
    const edits = [_]Edit{
        edit_count_huge,
        edit_type_internal,
        edit_self_link,
        edit_slot_garbage,
        edit_level_one,
    };
    for (edits) |edit| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, 512, 2);
        defer f.stop(testing.allocator);

        try f.tree.insert(testing.io, "a", "1");
        try craft_root(&f, edit);
        try testing.expectError(error.Corrupted, f.tree.get(testing.io, "a"));
        try testing.expectError(error.Corrupted, f.tree.insert(testing.io, "a", "2"));
        try testing.expectError(error.Corrupted, f.tree.insert(testing.io, "b", "2"));
        try testing.expectError(error.Corrupted, f.tree.check_invariants(testing.io));
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
    }
}

test "corruption: an unwritten or foreign root page gives the page layer's typed errors" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    const grown = try f.pm.allocate(testing.io); // Reads Unwritten.
    var stray: Tree = undefined;
    try Tree.open(&stray, &f.pool, grown);
    try testing.expectError(error.Unwritten, stray.get(testing.io, "a"));
    try testing.expectError(error.Unwritten, stray.insert(testing.io, "a", "1"));
    var buf: [512]u8 = undefined;
    @memset(buf[header.header_size..], 0x5A);
    try f.pm.write(testing.io, grown, &buf, .{ .page_type = fx.consumer_type, .lsn = 0 });
    try testing.expectError(error.Corrupted, stray.get(testing.io, "a")); // Not a leaf.
    try testing.expectError(error.Corrupted, stray.insert(testing.io, "a", "1"));
}

test "pool: PoolExhausted from a held pin is returned and nothing is half-written" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 1);
    defer f.stop(testing.allocator);

    try f.tree.insert(testing.io, "a", "1");
    const grown = try f.pm.allocate(testing.io);
    var pin = try f.pool.fetchNew(testing.io, grown);
    defer pin.release();

    try testing.expectError(error.PoolExhausted, f.tree.get(testing.io, "a"));
    try testing.expectError(error.PoolExhausted, f.tree.insert(testing.io, "b", "2"));
    try testing.expectEqual(@as(u32, 1), f.pool.pinned_count());
}

test "allocation: nothing allocates after init" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    var f: Fixture = undefined;
    try f.start(failing.allocator(), 512, 2);
    defer f.stop(failing.allocator());

    failing.fail_index = failing.alloc_index; // Armed: any further allocation fails.
    const allocs = failing.alloc_index;
    var key_buf: [8]u8 = undefined;
    for (0..20) |n| {
        const key = key_of(&key_buf, @intCast(n));
        try f.tree.insert(testing.io, key, "value");
        try expect_get(&f.tree, key, "value");
    }
    try f.tree.insert(testing.io, "k00003", "other");
    try f.cold();
    try expect_get(&f.tree, "k00003", "other");
    try testing.expectEqual(allocs, failing.alloc_index);
}

const Model = std.StringHashMapUnmanaged([]u8);

fn model_put(model: *Model, key: []const u8, value: []const u8) !void {
    assert(key.len <= 64);
    assert(value.len <= 64);
    assert(model.count() <= 100_000);
    const owned_value = try testing.allocator.dupe(u8, value);
    errdefer testing.allocator.free(owned_value);

    const slot = try model.getOrPut(testing.allocator, key);
    defer assert(model.count() >= 1);

    if (slot.found_existing) {
        testing.allocator.free(slot.value_ptr.*);
    } else {
        slot.key_ptr.* = try testing.allocator.dupe(u8, key);
    }
    slot.value_ptr.* = owned_value;
}

fn model_free(model: *Model) void {
    assert(model.count() <= 100_000);
    assert(model.capacity() >= model.count());
    var it = model.iterator();
    while (it.next()) |entry| {
        testing.allocator.free(entry.key_ptr.*);
        testing.allocator.free(entry.value_ptr.*);
    }
    model.deinit(testing.allocator);
}

fn model_compare(f: *Fixture, model: *const Model) !void {
    assert(model.count() <= 100_000);
    assert(f.pool.pinned_count() == 0);
    var it = model.iterator();
    while (it.next()) |entry| try expect_get(&f.tree, entry.key_ptr.*, entry.value_ptr.*);
}

test "model: seeded random inserts and gets agree with a hash map; tree invariants hold" {
    const steps_max: u32 = 1500;
    const sizes = [_]u32{ 512, 4096 };
    for (sizes, 0..) |size, size_index| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 3);
        defer f.stop(testing.allocator);

        var model: Model = .empty;
        defer model_free(&model);

        var prng = std.Random.DefaultPrng.init(0x5EED_0005 + size_index);
        const random = prng.random();
        var key_buf: [32]u8 = undefined;
        var value_buf: [64]u8 = undefined;
        for (0..steps_max) |step| {
            const key_len = random.uintAtMost(usize, 2);
            const key = key_buf[0..key_len];
            random.bytes(key);
            for (key) |*byte| byte.* = 'a' + byte.* % 6; // Few distinct keys: overwrites happen.
            const value = value_buf[0..random.uintAtMost(usize, 24)];
            random.bytes(value);
            if (random.boolean()) {
                try f.tree.insert(testing.io, key, value);
                try model_put(&model, key, value);
            } else {
                const want: ?[]const u8 = model.get(key);
                try expect_get(&f.tree, key, want);
            }
            if (step % 100 == 99) try model_compare(&f, &model);
            if (step % 500 == 499) try f.cold();
        }
        try model_compare(&f, &model);
        try f.tree.check_invariants(testing.io);
        try testing.expect(model.count() > 10);
        if (size == 512) try testing.expect(f.pm.page_count > 3); // The tiny leaf really splits.
    }
}
