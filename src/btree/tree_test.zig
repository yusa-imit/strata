//! Contract tests for `Tree` over the root leaf (plan 005 item 4, ADR-0004 sections 2, 7, 8, 10):
//! create allocates the fixed root, insert/get/overwrite without a split at all eight page sizes,
//! key and value boundaries, `NodeFull` leaving the page byte-identical, corrupted root pages
//! giving typed errors, no allocation after init, and a seeded model against a hash map. Every
//! declared error variant of `Tree` is provoked here.

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

const PageManager = manager.PageManager;
const BufferPool = buffer_pool.BufferPool;
const Tree = tree_mod.Tree;

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

test "create: the root is the first allocated id, an empty valid leaf, and nothing is read" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2);
        defer f.stop(testing.allocator);

        try testing.expectEqual(@as(u32, 1), f.root_u32());
        try testing.expectEqual(size, f.tree.page_size);
        try testing.expectEqual(@as(u16, 0), try leaf_count(&f));
        try expect_get(&f.tree, "", null);
        try expect_get(&f.tree, "anything", null);
        try f.cold();
        try testing.expectEqual(@as(u16, 0), try leaf_count(&f)); // Durable after the flush.
        var reopened: Tree = undefined;
        Tree.open(&reopened, &f.pool, f.tree.root);
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

test "insert: an edit stamps a valid checksum and keeps the page lsn" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    try f.tree.insert(testing.io, "a", "1");
    try f.cold();
    var buf: [512]u8 = undefined;
    const h = try f.pm.read(testing.io, f.tree.root, &buf);
    try testing.expectEqual(header.Type.btree_leaf, h.page_type);
    try testing.expectEqual(@as(u64, 0), h.lsn);
    const leaf = try node.parse_leaf(&buf);
    try leaf.check_link(f.tree.root);
    try testing.expectEqual(@as(?header.Id, null), leaf.next);
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

test "NodeFull: a full leaf rejects a new key and a growing overwrite, byte-identical" {
    for (fx.sizes_all) |size| {
        var f: Fixture = undefined;
        try f.start(testing.allocator, size, 2);
        defer f.stop(testing.allocator);

        var key_buf: [8]u8 = undefined;
        var count: u32 = 0;
        while (count < 100_000) : (count += 1) {
            const key = key_of(&key_buf, count);
            f.tree.insert(testing.io, key, "vvvv") catch |err| switch (err) {
                error.NodeFull => break,
                else => return err,
            };
        }
        try testing.expect(count >= 4 and count < 100_000);
        try testing.expectEqual(@as(u32, count), try leaf_count(&f));

        const snapshot = try testing.allocator.dupe(u8, try page_bytes(&f));
        defer testing.allocator.free(snapshot);

        const fresh = key_of(&key_buf, count);
        try testing.expectError(error.NodeFull, f.tree.insert(testing.io, fresh, "vvvv"));
        const grow = [_]u8{'g'} ** 100; // Inline at every size (cell max at 512 is 118).
        try testing.expectError(error.NodeFull, f.tree.insert(testing.io, "k00000", &grow));
        try testing.expectEqualSlices(u8, snapshot, try page_bytes(&f));
        try expect_get(&f.tree, "k00000", "vvvv");
        try f.tree.insert(testing.io, "k00000", "wwww"); // Same size still fits.
        try f.tree.insert(testing.io, "k00000", "w"); // Shrinking always fits.
        try expect_get(&f.tree, "k00000", "w");
        try testing.expectEqual(@as(u32, count), try leaf_count(&f));
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
fn craft_root(f: *Fixture, edit: *const fn ([]u8) void) !void {
    assert(f.pool.pinned_count() == 0);
    try f.cold();
    var buf: [header.page_size_max]u8 = undefined;
    const page = buf[0..f.pm.page_size];
    _ = try f.pm.read(testing.io, f.tree.root, page);
    edit(page);
    const sealed = header.peek(page);
    try f.pm.write(testing.io, f.tree.root, page, sealed);
    assert(header.peek(page).page_type == sealed.page_type);
}

fn edit_count_huge(page: []u8) void {
    assert(page.len >= 64);
    assert(page[node.offset_type] == @intFromEnum(header.Type.btree_leaf));
    node.put16(page, node.offset_count, 0xFFFF);
}

fn edit_type_internal(page: []u8) void {
    assert(page.len >= 64);
    page[node.offset_type] = @intFromEnum(header.Type.btree_internal);
}

fn edit_self_link(page: []u8) void {
    assert(page.len >= 64);
    node.put32(page, node.offset_link, 1); // The root is id 1: a leaf linking to itself.
}

fn edit_slot_garbage(page: []u8) void {
    assert(page.len >= 64);
    node.put16(page, node.offset_slots, 9); // Inside the slot table, not a cell.
}

fn edit_level_one(page: []u8) void {
    assert(page.len >= 64);
    page[node.offset_level] = 1;
}

test "corruption: a flipped byte on disk is ChecksumMismatch for get and insert, then recovers" {
    var f: Fixture = undefined;
    try f.start(testing.allocator, 512, 2);
    defer f.stop(testing.allocator);

    try f.tree.insert(testing.io, "a", "1");
    try f.cold();
    const base = @as(u64, 512) * f.root_u32();
    for ([_]u64{ 30, 100, 511 }) |at| {
        try fx.flip_byte(f.pm.file, base + at);
        try testing.expectError(error.ChecksumMismatch, f.tree.get(testing.io, "a"));
        try testing.expectError(error.ChecksumMismatch, f.tree.insert(testing.io, "b", "2"));
        try testing.expectEqual(@as(u32, 0), f.pool.pinned_count());
        try fx.flip_byte(f.pm.file, base + at);
        try expect_get(&f.tree, "a", "1");
        try f.cold();
    }
}

test "corruption: well-checksummed but malformed roots are Corrupted, never a panic" {
    const edits = [_]*const fn ([]u8) void{
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
    Tree.open(&stray, &f.pool, grown);
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
    try testing.expectEqual(@as(u32, model.count()), try leaf_count(f));
    var it = model.iterator();
    while (it.next()) |entry| try expect_get(&f.tree, entry.key_ptr.*, entry.value_ptr.*);
}

test "model: seeded random inserts and gets agree with a hash map; leaf invariants hold" {
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
        var full_seen: u32 = 0;
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
                if (f.tree.insert(testing.io, key, value)) |_| {
                    try model_put(&model, key, value);
                } else |err| switch (err) {
                    error.NodeFull => full_seen += 1,
                    else => return err,
                }
            } else {
                const want: ?[]const u8 = model.get(key);
                try expect_get(&f.tree, key, want);
            }
            try testing.expectEqual(@as(u32, model.count()), try leaf_count(&f));
            if (step % 100 == 99) try model_compare(&f, &model);
            if (step % 500 == 499) try f.cold();
        }
        try model_compare(&f, &model);
        try f.tree.check_invariants(testing.io);
        try testing.expect(model.count() > 10);
        if (size == 512) try testing.expect(full_seen > 0); // The tiny leaf really fills up.
    }
}
