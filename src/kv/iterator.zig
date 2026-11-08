//! strata.kv.Iterator: the forward range scan of `Db.scan` (ADR-0005 section 9), a thin layer
//! over `btree.Cursor` that stops at an exclusive upper bound.
//!
//! Invariants: a `Range` is half-open, `[start, end)`, `end == null` meaning +infinity; `start
//! >= end` yields nothing and is caller data, not an error. The iterator is `live` from `scan`
//! until `next` returns null, an error, or `deinit` (idempotent), and only then does it pin a
//! leaf. At most one is live per `Db` (`Shared.scans_live <= 1`, asserted by `scan`). A write
//! (`put`, `delete`, `commit_ops`, `checkpoint`, `flush`) bumps `Shared.generation`; `next`
//! asserts it is the value `scan` saw, so a write during a live scan is a contract violation.
//! `Db.get` during a scan is fine, but it shares `value_buf` with the cursor: an `Entry` is valid
//! only until the next `next`, `get`, `scan` or `deinit`.
//! Borrowing: the `Range` bytes are borrowed and must outlive the iterator. Allocation: none;
//! the `Io` is the `Db`'s, borrowed by pointer.

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const cursor_mod = @import("../btree/cursor.zig");
const tree_mod = @import("../btree/tree.zig");
const errors = @import("errors.zig");

pub const ScanError = errors.ScanError;
pub const Entry = cursor_mod.Entry;

/// `[start, end)` in bytewise key order; `end == null` is +infinity.
pub const Range = struct { start: []const u8, end: ?[]const u8 };

/// The counters one `Db` shares with its iterator; lives in the `Db` state, never moves.
pub const Shared = struct {
    /// Incremented by every write; `u64` cannot wrap in any real run.
    generation: u64,
    /// Live iterators, 0 or 1.
    scans_live: u32,

    pub const init: Shared = .{ .generation = 0, .scans_live = 0 };

    /// Records a write: every live iterator is now invalid.
    pub fn bump(self: *Shared) void {
        assert(self.scans_live <= 1);
        self.generation += 1;
        assert(self.generation != 0);
    }
};

const Phase = enum {
    /// Seeked: the cursor holds the first entry of the range, not yet handed out.
    fresh,
    running,
    done,
};

pub const Iterator = struct {
    /// Points at the `Db` state's one `Io` (ADR-0001: only `Db` stores an `Io` by value).
    io: *const Io,
    shared: *Shared,
    cursor: cursor_mod.Cursor,
    end: ?[]const u8,
    generation: u64,
    phase: Phase,

    /// Starts a scan of `range` on `tree`. Preconditions: both bounds are within the key limit
    /// and no other iterator is live on `shared`. An empty range pins nothing and counts as
    /// not live.
    pub fn open(
        io: *const Io,
        tree: *tree_mod.Tree,
        shared: *Shared,
        range: Range,
    ) ScanError!Iterator {
        assert(shared.scans_live == 0); // One live iterator per `Db`.
        assert(range.start.len <= tree.page_size); // A key limit check came first (`Db.scan`).
        var result: Iterator = .{
            .io = io,
            .shared = shared,
            .cursor = undefined,
            .end = range.end,
            .generation = shared.generation,
            .phase = .done,
        };
        if (range.end) |end| {
            if (std.mem.order(u8, range.start, end) != .lt) return result; // Empty range.
        }
        cursor_mod.Cursor.init(&result.cursor, tree);
        result.cursor.seek(io.*, range.start) catch |err| return errors.map(err);
        shared.scans_live += 1;
        result.phase = .fresh;
        assert(shared.scans_live == 1);
        return result;
    }

    /// The next entry in key order, or null at the end of the range (the pin is released and
    /// every later call returns null too). The entry borrows until the next `next`, `get`,
    /// `scan` or `deinit`. Asserts that no write happened since `scan`. On error the iterator
    /// is finished.
    pub fn next(self: *Iterator) ScanError!?Entry {
        if (self.phase == .done) return null;
        assert(self.shared.scans_live == 1);
        assert(self.generation == self.shared.generation); // A write during a live scan.
        const step: cursor_mod.Error!?Entry = switch (self.phase) {
            .fresh => self.cursor.current(),
            .running => self.cursor.next(self.io.*),
            .done => unreachable, // Returned above.
        };
        self.phase = .running;
        const found = step catch |err| {
            self.finish();
            return errors.map(err);
        };
        const entry = found orelse {
            self.finish();
            return null;
        };
        if (self.end) |end| {
            if (std.mem.order(u8, entry.key, end) != .lt) {
                self.finish();
                return null;
            }
        }
        return entry;
    }

    /// Releases the pin and the live slot. Idempotent; an `Entry` handed out is invalid after.
    pub fn deinit(self: *Iterator) void {
        self.finish();
        assert(self.phase == .done);
        assert(self.shared.scans_live <= 1);
    }

    fn finish(self: *Iterator) void {
        if (self.phase != .done) {
            assert(self.shared.scans_live == 1);
            self.cursor.release();
            self.shared.scans_live -= 1;
            self.phase = .done;
        }
        assert(self.phase == .done);
        assert(self.shared.scans_live <= 1);
    }
};

test {
    _ = @import("iterator_test.zig");
}
