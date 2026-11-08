//! strata.kv.WriteBatch: records puts and deletes, then applies them as one atomic group through
//! `Db.commit_ops` (ADR-0005 sections 7 and 8): the ops' `page_images` frames, then one `commit`
//! frame. After a crash none of the batch or all of it is visible.
//!
//! Allocation: `init` allocates the op table (`batch_ops_max` entries) and one byte arena
//! (`batch_bytes_max` bytes) from the `Db`'s options with the caller's `gpa`, once; `put`,
//! `delete`, `clear` and `commit` never allocate. `deinit` frees both with the same `gpa`, and
//! the batch stores no allocator. Keys and values are copied into the arena, so the caller's
//! slices may change or die right after `put` or `delete` returns. Ops keep their record order
//! and apply in it: the last write to a key wins.
//! Ownership: the batch borrows the `Db` by pointer and must not outlive it: `deinit` every
//! batch before `Db.close`. It holds no `Io` (the `Db` has it).
//! Limits: recording an op that would make the count exceed `batch_ops_max`, or the sum of key
//! and value lengths exceed `batch_bytes_max`, is `BatchTooLarge`; an over-long key or value is
//! `KeyTooLarge` or `ValueTooLarge`. A refused op leaves the batch unchanged.
//! Reuse: a successful `commit` clears the batch, so the same object records the next one. A
//! failed `commit` leaves it as recorded (retry, or `clear`); a failure after the group logged a
//! frame latches the `Db`, see `Db.commit_ops`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const db_mod = @import("db.zig");
const errors = @import("errors.zig");

pub const BatchError = errors.BatchError;
pub const BatchInitError = errors.BatchInitError;
pub const CommitError = errors.CommitError;

const Db = db_mod.Db;
const BatchOp = db_mod.BatchOp;

pub const WriteBatch = struct {
    db: *Db,
    /// Capacity `batch_ops_max`; the first `ops_len` entries are recorded.
    ops: []BatchOp,
    /// Capacity `batch_bytes_max`; the first `bytes_len` bytes are keys and values.
    arena: []u8,
    ops_len: u32,
    bytes_len: u32,
    key_len_max: u32,
    value_len_max: u32,

    /// Allocates the op table and the byte arena sized by `db`'s options; the only allocation.
    /// Errors: `OutOfMemory` (nothing stays allocated).
    pub fn init(target: *WriteBatch, gpa: Allocator, db: *Db) BatchInitError!void {
        const options = db.state.options;
        assert(options.batch_ops_max >= 1);
        assert(options.batch_bytes_max >= 1);
        const ops = try gpa.alloc(BatchOp, options.batch_ops_max);
        errdefer gpa.free(ops);

        const arena = try gpa.alloc(u8, options.batch_bytes_max);
        target.* = .{
            .db = db,
            .ops = ops,
            .arena = arena,
            .ops_len = 0,
            .bytes_len = 0,
            .key_len_max = db.key_len_max(),
            .value_len_max = options.value_len_max,
        };
        assert(target.ops.len == options.batch_ops_max);
        assert(target.arena.len == options.batch_bytes_max);
    }

    /// Frees what `init` allocated; `gpa` must be the one `init` got.
    pub fn deinit(self: *WriteBatch, gpa: Allocator) void {
        assert(self.ops.len >= 1);
        assert(self.arena.len >= 1);
        gpa.free(self.ops);
        gpa.free(self.arena);
        self.* = undefined;
    }

    /// Records `put(key, value)`; see the file header for the limits.
    pub fn put(self: *WriteBatch, key: []const u8, value: []const u8) BatchError!void {
        assert(self.ops_len <= self.ops.len);
        if (key.len > self.key_len_max) return error.KeyTooLarge; // Same order as `Db.put`.
        if (value.len > self.value_len_max) return error.ValueTooLarge;
        try self.record(.put, key, value);
    }

    /// Records `delete(key)`; a key that is absent at commit time is not an error.
    pub fn delete(self: *WriteBatch, key: []const u8) BatchError!void {
        assert(self.ops_len <= self.ops.len);
        try self.record(.delete, key, "");
    }

    /// Drops every recorded op; the capacity stays.
    pub fn clear(self: *WriteBatch) void {
        assert(self.ops_len <= self.ops.len);
        assert(self.bytes_len <= self.arena.len);
        self.ops_len = 0;
        self.bytes_len = 0;
    }

    /// Applies every recorded op as one group (`Db.commit_ops`), then clears the batch. An empty
    /// batch is a no-op. On error the batch is unchanged.
    pub fn commit(self: *WriteBatch) CommitError!void {
        assert(self.ops_len <= self.ops.len);
        assert(self.bytes_len <= self.arena.len);
        try self.db.commit_ops(self.ops[0..self.ops_len]);
        self.clear();
    }

    fn record(
        self: *WriteBatch,
        kind: @FieldType(BatchOp, "kind"),
        key: []const u8,
        value: []const u8,
    ) BatchError!void {
        assert(self.ops_len <= self.ops.len);
        assert(self.bytes_len <= self.arena.len);
        if (key.len > self.key_len_max) return error.KeyTooLarge;
        if (self.ops_len == self.ops.len) return error.BatchTooLarge;
        const need: u64 = @as(u64, key.len) + value.len;
        if (need > self.arena.len - self.bytes_len) return error.BatchTooLarge;

        const key_at: usize = self.bytes_len;
        const value_at: usize = key_at + key.len;
        @memcpy(self.arena[key_at..value_at], key);
        @memcpy(self.arena[value_at..][0..value.len], value);
        self.ops[self.ops_len] = .{
            .kind = kind,
            .key = self.arena[key_at..value_at],
            .value = self.arena[value_at..][0..value.len],
        };
        self.ops_len += 1;
        self.bytes_len += @intCast(need);
        assert(self.bytes_len <= self.arena.len);
    }
};
