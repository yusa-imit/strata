//! Fixtures for the seeded B+Tree model tests (`btree_model_test.zig`, plan 005 item 4E): a
//! trivially correct reference model (a sorted, fixed-capacity array of `(key, len, salt)`
//! triples searched linearly) and a `Driver` that runs a seeded random op stream against a `Tree`
//! and the model in lockstep. Values are regenerated from `(key, len, salt)`, so the model never
//! stores bytes. Test code only.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const cursor_mod = @import("../btree/cursor.zig");
const tfx = @import("../btree/tree_fixtures.zig");
const tree_mod = @import("../btree/tree.zig");

const Tree = tree_mod.Tree;
const Cursor = cursor_mod.Cursor;

/// Keys are `key_of(n)` for `n < key_space`; also the model's capacity.
pub const key_space: u32 = 512;

/// Steps a cursor takes forward or backward from a seek.
const walk_max: u32 = 3;

pub const Entry = struct { key: u32, len: u32, salt: u32 };

/// The reference: entries sorted by key, strictly ascending, found by linear search.
pub const Model = struct {
    items: [key_space]Entry,
    len: u32,

    pub fn init(self: *Model) void {
        self.len = 0;
        assert(self.items.len == key_space);
        assert(self.len == 0);
    }

    /// Index of the first entry with key >= `key` (`len` when none): the lower bound.
    pub fn lower_bound(self: *const Model, key: u32) u32 {
        assert(self.len <= key_space);
        assert(key < key_space);
        var index: u32 = 0;
        while (index < self.len and self.items[index].key < key) index += 1;
        return index;
    }

    pub fn find(self: *const Model, key: u32) ?Entry {
        assert(key < key_space);
        const index = self.lower_bound(key);
        if (index == self.len) return null;
        assert(index < self.len);
        if (self.items[index].key != key) return null;
        return self.items[index];
    }

    /// Inserts or overwrites; keeps the array strictly ascending.
    pub fn put(self: *Model, entry: Entry) void {
        assert(entry.key < key_space);
        assert(entry.len > 0);
        const index = self.lower_bound(entry.key);
        if (index < self.len and self.items[index].key == entry.key) {
            self.items[index] = entry;
            return;
        }
        assert(self.len < key_space); // A new key fits: keys are unique and bounded.
        var at = self.len;
        while (at > index) : (at -= 1) self.items[at] = self.items[at - 1];
        self.items[index] = entry;
        self.len += 1;
    }

    /// True when the key was present.
    pub fn remove(self: *Model, key: u32) bool {
        assert(key < key_space);
        const index = self.lower_bound(key);
        if (index == self.len or self.items[index].key != key) return false;
        var at = index;
        while (at + 1 < self.len) : (at += 1) self.items[at] = self.items[at + 1];
        self.len -= 1;
        assert(self.len < key_space);
        return true;
    }

    pub fn expect_sorted(self: *const Model) !void {
        assert(self.len <= key_space);
        assert(self.items.len == key_space);
        for (1..@max(self.len, 1)) |index| { // Empty and single-entry models have no pair.
            try testing.expect(self.items[index - 1].key < self.items[index].key);
        }
    }
};

/// The bytes of an entry's value: a pattern of `(key, salt, position)`.
pub fn fill(buf: []u8, entry: Entry) []const u8 {
    assert(entry.len > 0);
    assert(buf.len >= entry.len);
    const base: u32 = entry.key *% 31 +% entry.salt *% 7;
    for (buf[0..entry.len], 0..) |*byte, index| {
        byte.* = @truncate(base +% @as(u32, @truncate(index)) *% 13);
    }
    return buf[0..entry.len];
}

pub const Mix = enum { full, writes };

pub const Driver = struct {
    prng: std.Random.DefaultPrng,
    model: Model,
    page_size: u32,
    mix: Mix,
    /// Run `check_invariants` after every mutation.
    check_each: bool,
    ops_done: u32,
    large_puts: u32,
    want: []u8,
    put_buf: []u8,
    key_buf: [16]u8,

    pub fn init(
        self: *Driver,
        gpa: Allocator,
        page_size: u32,
        seed: u64,
        mix: Mix,
    ) Allocator.Error!void {
        assert(page_size >= 512);
        assert(seed != 0);
        const scratch_len: usize = 2 * @as(usize, page_size) + 128;
        const want = try gpa.alloc(u8, scratch_len);
        errdefer gpa.free(want);

        const put_buf = try gpa.alloc(u8, scratch_len);
        self.* = .{
            .prng = std.Random.DefaultPrng.init(seed),
            .model = undefined,
            .page_size = page_size,
            .mix = mix,
            .check_each = true,
            .ops_done = 0,
            .large_puts = 0,
            .want = want,
            .put_buf = put_buf,
            .key_buf = undefined,
        };
        self.model.init();
    }

    pub fn deinit(self: *Driver, gpa: Allocator) void {
        assert(self.want.len == self.put_buf.len);
        assert(self.model.len <= key_space);
        gpa.free(self.want);
        gpa.free(self.put_buf);
    }

    fn below(self: *Driver, limit: u32) u32 {
        assert(limit > 0);
        assert(limit <= 1 << 20);
        return self.prng.random().uintLessThan(u32, limit);
    }

    fn pick_len(self: *Driver) u32 {
        assert(self.page_size >= 512);
        const roll = self.below(100);
        const random = self.prng.random();
        if (roll < 6) { // A chain of one to three overflow pages.
            self.large_puts += 1;
            return random.intRangeAtMost(u32, self.page_size + 1, 2 * self.page_size + 100);
        }
        if (roll < 30) return random.intRangeAtMost(u32, 1, @divFloor(self.page_size, 8));
        return random.intRangeAtMost(u32, 1, 40);
    }

    /// One random op against `t` and the model; every result is compared. Returns after the op.
    pub fn step(self: *Driver, t: *Tree, io: Io) !void {
        assert(t.pool.pinned_count() == 0);
        assert(self.model.len <= key_space);
        const roll = self.below(100);
        const key = self.below(key_space);
        var mutated = true;
        switch (self.mix) {
            .writes => {
                if (roll < 60) try self.op_insert(t, io, key);
                if (roll >= 60) try self.op_delete(t, io, key);
            },
            .full => if (roll < 25) {
                try self.expect_get(t, io, key);
                mutated = false;
            } else if (roll < 60) {
                try self.op_insert(t, io, key);
            } else if (roll < 80) {
                try self.op_delete(t, io, key);
            } else {
                try self.op_seek(t, io, key);
                mutated = false;
            },
        }
        self.ops_done += 1;
        if (mutated and self.check_each) try t.check_invariants(io);
        try testing.expectEqual(@as(u32, 0), t.pool.pinned_count());
    }

    pub fn expect_get(self: *Driver, t: *Tree, io: Io, key: u32) !void {
        assert(key < key_space);
        assert(self.want.len >= self.page_size);
        const got = try t.get(io, tfx.key_of(&self.key_buf, key));
        const entry = self.model.find(key) orelse {
            try testing.expect(got == null);
            return;
        };
        try testing.expect(got != null);
        try testing.expectEqual(@as(usize, entry.len), got.?.len);
        try testing.expect(std.mem.eql(u8, fill(self.want, entry), got.?));
    }

    fn op_insert(self: *Driver, t: *Tree, io: Io, key: u32) !void {
        assert(key < key_space);
        assert(self.put_buf.len >= self.page_size);
        const entry: Entry = .{ .key = key, .len = self.pick_len(), .salt = self.ops_done + 1 };
        const value = fill(self.put_buf, entry);
        try t.insert(io, tfx.key_of(&self.key_buf, key), value);
        self.model.put(entry);
        try self.expect_get(t, io, key); // Read your own write.
    }

    fn op_delete(self: *Driver, t: *Tree, io: Io, key: u32) !void {
        assert(key < key_space);
        assert(t.pool.pinned_count() == 0);
        const present = self.model.remove(key);
        const removed = try t.delete(io, tfx.key_of(&self.key_buf, key));
        try testing.expectEqual(present, removed);
        try self.expect_get(t, io, key);
    }

    /// A seek lands on the model's lower bound; steps forward and backward from it agree.
    fn op_seek(self: *Driver, t: *Tree, io: Io, key: u32) !void {
        assert(key < key_space);
        assert(t.pool.pinned_count() == 0);
        const bound = self.model.lower_bound(key);
        var c: Cursor = undefined;
        Cursor.init(&c, t);
        defer c.release();

        try c.seek(io, tfx.key_of(&self.key_buf, key));
        try self.expect_entry(c.current(), bound);
        var at = bound;
        for (0..walk_max) |_| {
            if (at >= self.model.len) break;
            at += 1;
            try self.expect_entry(try c.next(io), at);
        }
        try c.seek(io, tfx.key_of(&self.key_buf, key));
        at = bound;
        for (0..walk_max) |_| {
            if (at == 0) break;
            at -= 1;
            try self.expect_entry(try c.prev(io), at);
        }
    }

    fn expect_entry(self: *Driver, got: ?cursor_mod.Entry, index: u32) !void {
        assert(index <= self.model.len);
        assert(self.want.len >= self.page_size);
        if (index >= self.model.len) {
            try testing.expect(got == null);
            return;
        }
        const entry = self.model.items[index];
        try testing.expect(got != null);
        var key_buf: [16]u8 = undefined;
        try testing.expectEqualSlices(u8, tfx.key_of(&key_buf, entry.key), got.?.key);
        try testing.expectEqual(@as(usize, entry.len), got.?.value.len);
        try testing.expect(std.mem.eql(u8, fill(self.want, entry), got.?.value));
    }

    /// Every entry, forward and backward, equals the model; nothing stays pinned.
    pub fn scan_full(self: *Driver, t: *Tree, io: Io) !void {
        assert(self.model.len <= key_space);
        assert(t.pool.pinned_count() == 0);
        var c: Cursor = undefined;
        Cursor.init(&c, t);
        defer c.release();

        var index: u32 = 0;
        var got = try c.first(io);
        while (index < self.model.len) : (index += 1) { // Bounded by the model's length.
            try self.expect_entry(got, index);
            got = try c.next(io);
        }
        try testing.expect(got == null);
        index = self.model.len;
        got = try c.last(io);
        while (index > 0) : (index -= 1) { // Bounded by the model's length.
            try self.expect_entry(got, index - 1);
            got = try c.prev(io);
        }
        try testing.expect(got == null);
    }

    /// Whole-tree equality with the model: point reads of all keys, both scans, validate.
    pub fn expect_equal(self: *Driver, t: *Tree, io: Io) !void {
        assert(self.model.len <= key_space);
        assert(t.pool.pinned_count() == 0);
        try self.model.expect_sorted();
        for (0..key_space) |key| try self.expect_get(t, io, @intCast(key));
        try self.scan_full(t, io);
        try t.validate(io, testing.allocator);
    }
};
