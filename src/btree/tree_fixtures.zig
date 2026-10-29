//! Shared test support for the B+Tree tests that need a growing tree: one construction path (a
//! temp dir, a page file with a chosen `page_count_max`, a pool, a created tree), key helpers
//! and a hash-map reference model. Test code only.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const buffer_pool = @import("../cache/buffer_pool.zig");
const node = @import("node.zig");
const tree_mod = @import("tree.zig");

const PageManager = manager.PageManager;
const BufferPool = buffer_pool.BufferPool;
const Tree = tree_mod.Tree;
const Id = header.Id;

/// Capacity of the fixture tree's pending-free list.
pub const frees_max: u32 = 2400; // A full 1 MiB chain at 512 B (2185 pages) plus slack.

/// Value storage shared by every fixture tree (tests run one at a time); 1 MiB, never touched
/// until a test stores an overflow value.
pub var value_buf: [node.value_len_max]u8 = undefined;

pub const sizes_all = [_]u32{ 512, 1024, 2048, 4096, 8192, 16384, 32768, 65536 };

pub const Fixture = struct {
    tmp: testing.TmpDir,
    pm: PageManager,
    pool: BufferPool,
    tree: Tree,
    frees: [frees_max]Id,

    pub fn start(self: *Fixture, gpa: Allocator, size: u32, frames: u32, pages_max: u32) !void {
        assert(header.page_size_valid(size));
        assert(frames >= 1 and pages_max >= 2);
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        const options: manager.Options = .{
            .page_size = size,
            .page_count_max = pages_max,
            .sync_policy = .none,
        };
        try PageManager.create(&self.pm, testing.io, self.tmp.dir, "tree.db", options);
        errdefer self.pm.close(testing.io);

        const pool_options: buffer_pool.Options = .{ .frames_max = frames, .page_size = size };
        try BufferPool.init(&self.pool, gpa, &self.pm, pool_options);
        errdefer self.pool.deinit(gpa);

        try Tree.create(&self.tree, testing.io, &self.pool, &self.frees, &value_buf);
    }

    pub fn stop(self: *Fixture, gpa: Allocator) void {
        assert(self.pool.pinned_count() == 0);
        assert(self.tree.root != .file_header);
        self.pool.discardAll();
        self.pool.deinit(gpa);
        self.pm.close(testing.io);
        self.tmp.cleanup();
    }

    /// Writes everything out and empties the pool, so the next access reads from the file.
    pub fn cold(self: *Fixture) !void {
        assert(self.pool.pinned_count() == 0);
        try self.pool.flushAll(testing.io);
        self.pool.discardAll();
        assert(self.pool.dirty_count == 0);
    }
};

/// Fixed-width key `k` + 5 digits (6 bytes), so numeric order is byte order.
pub fn key_of(buf: []u8, n: u32) []const u8 {
    assert(buf.len >= 6);
    assert(n < 100_000);
    buf[0] = 'k';
    var rest = n;
    for (0..5) |i| {
        buf[5 - i] = '0' + @as(u8, @intCast(rest % 10)); // A digit, so the cast cannot truncate.
        rest = @divTrunc(rest, 10);
    }
    assert(rest == 0);
    return buf[0..6];
}

pub fn expect_get(t: *Tree, key: []const u8, want: ?[]const u8) !void {
    assert(t.page_size == t.pool.page_size);
    assert(key.len <= 4096);
    assert(t.root != .file_header);
    const got = try t.get(testing.io, key);
    if (want) |bytes| {
        try testing.expect(got != null);
        try testing.expectEqualSlices(u8, bytes, got.?);
    } else {
        try testing.expectEqual(@as(?[]const u8, null), got);
    }
}

pub const Model = std.StringHashMapUnmanaged([]u8);

pub fn model_put(model: *Model, key: []const u8, value: []const u8) !void {
    assert(key.len <= 1024);
    assert(value.len <= 1 << 20);
    const owned_value = try testing.allocator.dupe(u8, value);
    errdefer testing.allocator.free(owned_value);

    const slot = try model.getOrPut(testing.allocator, key);
    if (slot.found_existing) {
        testing.allocator.free(slot.value_ptr.*);
    } else {
        slot.key_ptr.* = testing.allocator.dupe(u8, key) catch |err| {
            model.removeByPtr(slot.key_ptr);
            return err;
        };
    }
    slot.value_ptr.* = owned_value;
}

pub fn model_free(model: *Model) void {
    assert(model.capacity() >= model.count());
    var it = model.iterator();
    while (it.next()) |entry| {
        testing.allocator.free(entry.key_ptr.*);
        testing.allocator.free(entry.value_ptr.*);
    }
    model.deinit(testing.allocator);
    model.* = .empty;
}

/// Every model entry reads back from the tree, and the whole tree validates.
pub fn model_compare(t: *Tree, model: *const Model) !void {
    assert(t.pool.pinned_count() == 0);
    var it = model.iterator();
    while (it.next()) |entry| try expect_get(t, entry.key_ptr.*, entry.value_ptr.*);
    try t.validate(testing.io, testing.allocator);
    try testing.expectEqual(@as(u32, 0), t.pool.pinned_count());
}
