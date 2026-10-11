//! `PageGuard` (PRD §4.4): one pin on one `BufferPool` frame. `fetch` returns a read-only guard,
//! `fetchForUpdate` a writable one; `release` drops the pin, usually `defer guard.release()`.
//!
//! Invariants: a live guard holds one pin, so its frame is never evicted or reused until
//! `release`; `bytes` is valid exactly that long; only a guard from `fetchForUpdate`
//! (`updatable`) may dirty its frame, and a dirty frame is written back by the pool, never by
//! the guard. Move-only by convention: a copy shares the pin, and releasing both copies is a
//! contract violation (asserted in safe builds, an underflow of the pin count in unsafe ones).
//! Allocation: none. No method takes `io`, blocks, or can fail: marking dirty and releasing are
//! pure bookkeeping (PRD §4.4), the write itself happens in `fetch` or `flushAll`.
//! Mutation: `bytes_mut` marks the frame dirty when it is called, not when it is written
//! through; after a `flushAll` that ran while the guard was held, call `markDirty` again before
//! further edits through an old slice. The caller owns the header's page type byte and lsn
//! (`set_lsn`); the checksum is stamped at write-back, so it is stale while the frame is dirty.

const std = @import("std");
const assert = std.debug.assert;
const header = @import("../page/header.zig");
const buffer_pool = @import("buffer_pool.zig");
const BufferPool = buffer_pool.BufferPool;
const Id = header.Id;

pub const PageGuard = struct {
    pool: *BufferPool,
    frame_index: u32,
    /// True for guards from `fetchForUpdate`.
    updatable: bool,
    released: bool,

    /// The whole page, header included, as it is in memory now (edits through a writable guard
    /// on the same frame are visible). Precondition: not released.
    pub fn bytes(self: *const PageGuard) []const u8 {
        assert(!self.released);
        assert(self.pool.frames[self.frame_index].pin_count > 0);
        return self.pool.frame_bytes(self.frame_index);
    }

    /// The whole page, writable, and marks the frame dirty. Never touch the first 24 bytes
    /// except the page type (which must stay a legal type for the page id) and the lsn
    /// (prefer `set_lsn`). Preconditions: not released; the guard is `updatable`.
    pub fn bytes_mut(self: *PageGuard) []u8 {
        assert(self.updatable);
        self.markDirty();
        return self.pool.frame_bytes(self.frame_index);
    }

    /// Marks the frame dirty so the pool writes it back; idempotent. No `io`, cannot fail.
    /// Preconditions: not released; the guard is `updatable`.
    pub fn markDirty(self: *PageGuard) void {
        assert(!self.released);
        assert(self.updatable);
        self.pool.mark_dirty(self.frame_index);
        assert(self.pool.frames[self.frame_index].dirty);
    }

    /// Stores `lsn` in the page header and marks the frame dirty. Same preconditions as
    /// `markDirty`.
    pub fn set_lsn(self: *PageGuard, lsn: u64) void {
        assert(self.updatable);
        const page = self.bytes_mut();
        header.poke_lsn(page, lsn);
        assert(header.peek(page).lsn == lsn);
    }

    /// The pinned page's id. Precondition: not released.
    pub fn id(self: *const PageGuard) Id {
        assert(!self.released);
        const raw = self.pool.frames[self.frame_index].page_id;
        assert(raw >= 1);
        return @enumFromInt(raw);
    }

    /// Drops this pin; the frame becomes evictable once its last pin is gone, and a dirty
    /// frame stays dirty until the pool writes it. No `io`, cannot fail. Precondition: not
    /// released already.
    pub fn release(self: *PageGuard) void {
        assert(!self.released);
        const frame = &self.pool.frames[self.frame_index];
        assert(frame.pin_count > 0);
        frame.pin_count -= 1;
        self.released = true;
    }
};
