//! Buffer pool (PRD §4.4): a fixed set of page-sized frames over one `PageManager`, replaced by
//! the CLOCK policy. `fetch` returns a pinned `PageGuard`; a pinned frame is never evicted.
//!
//! Invariants: a frame holds either no page (`page_id == 0`) or a verified copy of exactly one
//! page, and the page table maps every held page id to its frame, nothing else; a frame with
//! `pin_count > 0` is never reused; `hand < frames_max`; every held page was read through
//! `PageManager.read`, so its header and checksum were verified when it was loaded.
//! Allocation: all of it happens in `init` (frame slab, frame metadata, page table); no method
//! allocates afterwards and the pool stores no allocator, `deinit` takes the same `gpa` back.
//! Memory per fetch: one page copy on a miss, none on a hit. The hot hit path is one hash probe
//! plus two field writes; a miss costs one page read and at most `2 * frames_max` frame visits
//! while the hand looks for a victim. Frame metadata is `comptime`-asserted under 64 bytes.
//! The pool is a leaf over the manager: `io` is passed to `fetch` and never cached (ADR-0001).
//! `release`, `stats` and `deinit` take no `io` and cannot block.
//! Dirty pages (PRD §4.4): `fetchForUpdate` pins a page behind a writable guard; `bytes_mut`,
//! `markDirty` and `set_lsn` mark the frame dirty (pure bookkeeping, no `io`, cannot fail). A
//! dirty frame is written back by `PageManager.write` in exactly two places: victim eviction
//! inside `fetch`/`fetchForUpdate`, before the page table entry is removed, and `flushAll`.
//! `release` never writes. A failed write-back surfaces from the call that needed it and leaves
//! the frame resident, dirty and unchanged, so the bytes are not lost and a later call retries.
//! WAL-before-data (plan 004): `set_durable_lsn` turns on a gate (off until its first call, so
//! v0.4 callers see no change). Once on, neither eviction nor `flushAll` writes a dirty frame
//! whose page lsn is above the durable bound: it stays dirty and resident, eviction scans past
//! it, `flushAll` skips it (counted in `Stats.gated`, not an error), and a pool whose every
//! unpinned frame is gated or pinned returns `PoolExhausted` until the bound moves.
//! Who stamps what: the caller owns the page type byte and the lsn (`set_lsn`);
//! `PageManager.write` stamps magic, version and the page-id-seeded
//! checksum from `header.peek` of the frame at write-back time, so a frame's checksum is stale
//! while it is dirty. The pool never calls `sync`; durability is the caller's call.
//! New pages (ADR-0004 section 13): `fetchNew` pins a page that `PageManager.allocate` just
//! returned, whose bytes on disk are `Unwritten` (grown) or stale (reused) and so are never read:
//! the frame is zero-filled, marked dirty and handed out writable. The caller formats it (a legal
//! page type byte is required before any write-back, else `InvalidHeader`).
//! `deinit` asserts zero pinned and zero dirty frames: `flushAll` (or `discardAll`) first.
//! A page changed behind the pool's back through `PageManager.write` or freed through
//! `PageManager.free` is not noticed while a frame still holds its old copy.
//! A failed load leaves the frame empty and the pool consistent; the evicted page stays gone,
//! after its write-back, if it was dirty, succeeded.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
const guard = @import("guard.zig");
const Id = header.Id;
const PageManager = manager.PageManager;

/// Frames start on this boundary (the slab is allocated at it; every frame is a power of two
/// in size, so frames of at least this size stay aligned too).
pub const frame_alignment_bytes: usize = 4096;

pub const Options = struct {
    /// Number of frames; at least 1. The pool never holds more pages than this.
    frames_max: u32,
    /// Must equal the manager's page size.
    page_size: u32,
};

/// A write error here comes only from writing back the victim frame (never from the page being
/// fetched): the victim stays resident and dirty. `Canceled` and every other `WriteError`
/// variant propagate unchanged, so a canceled flush is distinguishable from a full disk.
/// `InvalidHeader` covers a dirty victim whose type byte was left illegal for its page id
/// through `bytes_mut`: caught at write-back in every build mode, the frame stays dirty.
pub const FetchError = manager.ReadError || WriteBackError || error{PoolExhausted};

/// `fetchNew` reads nothing, so only the victim's write-back and a full pool can fail it.
pub const FetchNewError = WriteBackError || error{PoolExhausted};

/// `flushAll` stops at the first failed write; that frame and every later dirty one stay dirty.
pub const FlushError = WriteBackError;

pub const WriteBackError = manager.WriteError || error{InvalidHeader};

pub const PageGuard = guard.PageGuard;

/// Counters since `init`. `hits + misses` is the number of `fetch` calls that passed their
/// preconditions, and `fetchNew` counts like `fetch` (a hit on a resident frame, else a miss);
/// a miss that fails to load still counts. `evictions` counts pages dropped to
/// make room, whether or not the following load succeeded (a victim whose write-back fails is
/// not evicted). `writebacks` counts successful page writes, from eviction and `flushAll`.
/// `gated` counts dirty frames `flushAll` left unwritten because their lsn was above the
/// durable bound, once per frame per call (eviction scans past gated frames without counting).
pub const Stats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
    writebacks: u64,
    gated: u64,
};

pub const Frame = struct {
    /// Raw `page.Id`, 0 when the frame holds no page (page 0 is never fetched).
    page_id: u32,
    pin_count: u32,
    /// CLOCK reference bit: set on every load and hit, cleared as the hand passes.
    referenced: bool,
    /// The frame differs from the page on disk; implies `page_id != 0`.
    dirty: bool,
};

const frame_empty: Frame = .{ .page_id = 0, .pin_count = 0, .referenced = false, .dirty = false };

comptime {
    assert(@sizeOf(Frame) < 64); // PRD §5: per-frame metadata stays inside one cache line.
    assert(frame_alignment_bytes >= header.page_size_min);
}

const PageTable = std.AutoHashMapUnmanaged(u32, u32);
const table_context = std.hash_map.AutoContext(u32){};

pub const BufferPool = struct {
    pages: *PageManager,
    page_size: u32,
    frames_max: u32,
    /// `frames_max` pages back to back; frame `i` is bytes `[i * page_size, (i + 1) * page_size)`.
    slab: []align(frame_alignment_bytes) u8,
    frames: []Frame,
    /// Raw page id to frame index, for held pages only.
    table: PageTable,
    /// Next frame the CLOCK hand visits.
    hand: u32,
    /// Frames holding no page. Lets the victim search take an empty frame before evicting.
    empty_count: u32,
    /// Frames with `dirty` set, kept in step by `mark_dirty` and `write_back`.
    dirty_count: u32,
    /// WAL-before-data gate: once `gate_on`, a dirty frame whose page lsn is above `durable_lsn`
    /// is never written back. Off until the first `set_durable_lsn`.
    gate_on: bool,
    durable_lsn: u64,
    counters: Stats,

    /// Allocates every buffer the pool will ever use and builds it in place at `target`. The
    /// pool borrows `pages` and must outlive no longer than it; `target` must not move while
    /// guards exist. Preconditions: `options.frames_max >= 1`, `options.page_size` equals
    /// `pages.page_size`. `error.OutOfMemory` also covers `frames_max * page_size` overflowing
    /// the address space; on error nothing stays allocated.
    pub fn init(
        target: *BufferPool,
        gpa: Allocator,
        pages: *PageManager,
        options: Options,
    ) error{OutOfMemory}!void {
        assert(options.frames_max >= 1);
        assert(header.page_size_valid(options.page_size));
        assert(options.page_size == pages.page_size);
        const slab_len = std.math.mul(usize, options.frames_max, options.page_size) catch {
            return error.OutOfMemory;
        };
        const slab = try gpa.alignedAlloc(u8, .fromByteUnits(frame_alignment_bytes), slab_len);
        errdefer gpa.free(slab);

        const frames = try gpa.alloc(Frame, options.frames_max);
        errdefer gpa.free(frames);

        var table: PageTable = .empty;
        try table.ensureTotalCapacity(gpa, options.frames_max);
        @memset(slab, 0);
        @memset(frames, frame_empty);
        target.* = .{
            .pages = pages,
            .page_size = options.page_size,
            .frames_max = options.frames_max,
            .slab = slab,
            .frames = frames,
            .table = table,
            .hand = 0,
            .empty_count = options.frames_max,
            .dirty_count = 0,
            .gate_on = false,
            .durable_lsn = 0,
            .counters = .{ .hits = 0, .misses = 0, .evictions = 0, .writebacks = 0, .gated = 0 },
        };
        assert(target.frames.len == options.frames_max);
        assert(target.slab.len == slab_len);
    }

    /// Frees the buffers `init` allocated; `gpa` must be the allocator given to `init`.
    /// Preconditions: no guard is outstanding and no frame is dirty. Dropping dirty pages is a
    /// programmer error, asserted here: call `flushAll` to keep them or `discardAll` to drop
    /// them on purpose (frames the WAL gate holds back stay dirty: raise the bound first).
    /// Plain asserts: the kingdom has no `stdx.assert_always` yet, so in ReleaseFast a
    /// violation silently loses dirty data; build with ReleaseSafe (REALM.md).
    pub fn deinit(self: *BufferPool, gpa: Allocator) void {
        assert(self.pinned_count() == 0);
        assert(self.dirty_count == 0);
        assert(self.frames.len == self.frames_max);
        self.table.deinit(gpa);
        gpa.free(self.frames);
        gpa.free(self.slab);
        self.* = undefined;
    }

    /// Pins page `id` and returns a read-only guard (`bytes`) over its frame. A hit costs no
    /// I/O; a miss evicts the first unpinned frame whose reference bit is clear (taking an
    /// empty frame first), writing it back first if it is dirty, and reads the page into it.
    /// Every frame pinned or gated (WAL gate, `set_durable_lsn`) is `PoolExhausted`, returned at
    /// once, never waited on. A failed write-back returns its error with the victim still
    /// resident and dirty (`FetchError`). A
    /// page that fails to load (`Unwritten`, `Corrupted`, `ChecksumMismatch`, `TornWrite`, I/O
    /// errors) leaves its frame empty, and the clean page it displaced stays gone.
    /// Preconditions: `0 < id < page_count` of the manager (the same contract as
    /// `PageManager.read`; ids that come from disk must be range-checked by the caller, since
    /// the checks here are asserts); the caller releases the guard exactly once.
    pub fn fetch(self: *BufferPool, io: Io, id: Id) FetchError!PageGuard {
        assert(@intFromEnum(id) >= 1);
        const pinned = try self.fetch_pinned(io, id, false);
        assert(!pinned.updatable);
        return pinned;
    }

    /// Like `fetch`, but the guard is writable: `bytes_mut`, `markDirty` and `set_lsn` mark the
    /// frame dirty. Fetching alone dirties nothing. Same errors and preconditions as `fetch`.
    pub fn fetchForUpdate(self: *BufferPool, io: Io, id: Id) FetchError!PageGuard {
        assert(@intFromEnum(id) >= 1);
        const pinned = try self.fetch_pinned(io, id, true);
        assert(pinned.updatable);
        return pinned;
    }

    /// Pins a page that was just allocated, without reading it: the frame is zero-filled (header
    /// included), marked dirty and returned behind a writable guard. For an id that grew the
    /// file (`fetch` would say `Unwritten`) and for a reused id (the file holds a stale trunk and
    /// the pool may hold a stale frame, which is zeroed in place). The caller must write a legal
    /// page type byte (and lsn) before the frame is written back, or write-back is
    /// `InvalidHeader`. A miss evicts like `fetch` (`PoolExhausted`, or the victim's write error);
    /// a hit counts as a hit. Never allocates. Preconditions: `0 < id < page_count`, and no
    /// guard on `id` is outstanding (a page being re-created has no readers). The pinned-hit
    /// check is a plain assert, so only ReleaseSafe and Debug catch a violation.
    pub fn fetchNew(self: *BufferPool, io: Io, id: Id) FetchNewError!PageGuard {
        const raw = @intFromEnum(id);
        assert(raw >= 1);
        assert(raw < self.pages.page_count);
        var pinned: PageGuard = undefined;
        if (self.table.get(raw)) |index| {
            assert(self.frames[index].pin_count == 0);
            pinned = self.pin_hit(index, true);
        } else {
            self.counters.misses += 1;
            const index = try self.victim_find();
            try self.victim_evict(io, index);
            pinned = self.pin_load(index, raw, true);
        }
        @memset(self.frame_bytes(pinned.frame_index), 0);
        self.mark_dirty(pinned.frame_index);
        assert(self.frames[pinned.frame_index].dirty);
        return pinned;
    }

    /// Writes every dirty frame, pinned ones included, in frame order; each written frame
    /// becomes clean. A pinned dirty frame is written as it is now, so callers flush when no
    /// guard is mid-edit; a pinned page edited again through an old `bytes_mut` slice must call
    /// `markDirty` again, because the flush cleared the flag. Stops at the first failed write:
    /// that frame and every later dirty one stay dirty and a retry continues from there. Does
    /// not `sync` the file. Cost: one page write per dirty frame, `frames_max` frame visits.
    /// With the WAL gate on (`set_durable_lsn`), a dirty frame whose lsn is above the bound is
    /// skipped, not an error: it stays dirty and resident, `stats().gated` counts it, and a
    /// later call writes it once the bound has moved. So after a successful `flushAll` every
    /// dirty frame left is gated; with the gate off none is.
    pub fn flushAll(self: *BufferPool, io: Io) FlushError!void {
        assert(self.frames.len == self.frames_max);
        assert(self.dirty_count <= self.frames_max);
        const gated_before = self.counters.gated;
        for (0..self.frames_max) |index| {
            if (!self.frames[index].dirty) continue;
            if (self.gate_blocks(@intCast(index))) {
                self.counters.gated += 1; // Counted at once: a later failed write keeps it.
                continue;
            }
            try self.write_back(io, @intCast(index));
        }
        const skipped = self.counters.gated - gated_before;
        assert(self.dirty_count == skipped);
        assert(self.gate_on or skipped == 0);
    }

    /// Raises the WAL-before-data bound to `lsn` and turns the gate on (the first call). From
    /// then on write-back, from eviction and `flushAll`, skips a dirty frame whose page lsn is
    /// above the bound and leaves it dirty and resident; a page lsn equal to the bound passes.
    /// Pass the writer's `durable_lsn` after each sync. Pure bookkeeping: no `io`, cannot fail,
    /// nothing is written now. Precondition: `lsn` is not below the previous bound (the log's
    /// durable point never moves back); a plain assert, like the rest of the caller contract.
    pub fn set_durable_lsn(self: *BufferPool, lsn: u64) void {
        assert(!self.gate_on or lsn >= self.durable_lsn);
        assert(self.dirty_count <= self.frames_max);
        self.gate_on = true;
        self.durable_lsn = lsn;
        assert(self.gate_on);
        assert(self.durable_lsn == lsn);
    }

    /// Empties the pool without writing anything: every dirty change is lost, every frame is
    /// free and every page is a miss again. Counters are kept. Precondition: no guard is
    /// outstanding (their bytes would vanish; a plain assert, so ReleaseSafe is required to
    /// catch a violation, as for `deinit`).
    pub fn discardAll(self: *BufferPool) void {
        assert(self.pinned_count() == 0);
        assert(self.dirty_count <= self.frames_max);
        @memset(self.frames, frame_empty);
        self.table.clearRetainingCapacity();
        self.empty_count = self.frames_max;
        self.dirty_count = 0;
        self.hand = 0;
        assert(self.table.count() == 0);
        self.check_invariants();
    }

    /// Frames with at least one pin. O(frames_max); for tests, `deinit` and monitoring.
    pub fn pinned_count(self: *const BufferPool) u32 {
        assert(self.frames.len == self.frames_max);
        var count: u32 = 0;
        for (self.frames) |frame| {
            if (frame.pin_count > 0) count += 1;
        }
        assert(count <= self.frames_max);
        return count;
    }

    pub fn stats(self: *const BufferPool) Stats {
        assert(self.counters.evictions <= self.counters.misses);
        assert(self.counters.hits +% self.counters.misses >= self.counters.misses);
        return self.counters;
    }

    /// Asserts the structural invariants listed in the file header.
    pub fn check_invariants(self: *const BufferPool) void {
        assert(self.frames.len == self.frames_max);
        assert(self.slab.len == @as(usize, self.frames_max) * self.page_size);
        assert(self.hand < self.frames_max);
        assert(self.page_size == self.pages.page_size);
        assert(self.gate_on or self.durable_lsn == 0);
        var empty: u32 = 0;
        var dirty: u32 = 0;
        for (self.frames, 0..) |frame, index| {
            if (frame.dirty) dirty += 1;
            if (frame.page_id == 0) {
                assert(frame.pin_count == 0);
                assert(!frame.referenced);
                assert(!frame.dirty);
                empty += 1;
            } else {
                assert(frame.page_id < self.pages.page_count);
                assert(self.table.get(frame.page_id).? == index);
            }
        }
        assert(empty == self.empty_count);
        assert(dirty == self.dirty_count);
        assert(self.table.count() == self.frames_max - empty);
    }

    /// The highest page lsn among the dirty frames (read from the in-memory headers), or 0 when
    /// none is dirty. For a checkpoint, which must not run over a page the log does not
    /// describe yet. Cost: `frames_max` frame visits.
    pub fn dirty_lsn_max(self: *BufferPool) u64 {
        assert(self.frames.len == self.frames_max);
        assert(self.dirty_count <= self.frames_max);
        var highest: u64 = 0;
        for (self.frames, 0..) |frame, index| {
            if (!frame.dirty) continue;
            const bytes = self.frame_bytes(@intCast(index));
            highest = @max(highest, header.peek(bytes).lsn);
        }
        assert(self.dirty_count > 0 or highest == 0);
        return highest;
    }

    /// The bytes of frame `index`. Internal to the cache module: `PageGuard` hands them out.
    pub fn frame_bytes(self: *BufferPool, index: u32) []u8 {
        assert(index < self.frames_max);
        assert(self.slab.len == @as(usize, self.frames_max) * self.page_size);
        const start = @as(usize, index) * self.page_size;
        return self.slab[start..][0..self.page_size];
    }

    /// Sets the dirty flag of a pinned frame; idempotent. Internal to the cache module.
    pub fn mark_dirty(self: *BufferPool, index: u32) void {
        const frame = &self.frames[index];
        assert(frame.pin_count > 0);
        assert(frame.page_id != 0);
        if (frame.dirty) return;
        frame.dirty = true;
        self.dirty_count += 1;
        assert(self.dirty_count <= self.frames_max);
    }

    fn fetch_pinned(self: *BufferPool, io: Io, id: Id, updatable: bool) FetchError!PageGuard {
        const raw = @intFromEnum(id);
        assert(raw >= 1);
        assert(raw < self.pages.page_count);
        if (self.table.get(raw)) |index| return self.pin_hit(index, updatable);

        self.counters.misses += 1;
        const index = try self.victim_find();
        try self.victim_evict(io, index);
        _ = try self.pages.read(io, id, self.frame_bytes(index));
        return self.pin_load(index, raw, updatable);
    }

    /// Writes frame `index` through `PageManager.write` and marks it clean on success. On error
    /// nothing changes (the write stamps the frame header in place, which keeps it dirty and
    /// equivalent). A type byte illegal for the page id, which only a caller scribbling through
    /// `bytes_mut` can cause, is `InvalidHeader`: user data must not reach disk in release builds
    /// on the strength of an assert. Preconditions: the frame is dirty and holds a page.
    fn write_back(self: *BufferPool, io: Io, index: u32) WriteBackError!void {
        const frame = &self.frames[index];
        assert(frame.dirty);
        assert(frame.page_id != 0);
        const bytes = self.frame_bytes(index);
        const page_id: Id = @enumFromInt(frame.page_id);
        const sealed = header.peek(bytes);
        if (!header.type_valid(page_id, @intFromEnum(sealed.page_type))) return error.InvalidHeader;

        try self.pages.write(io, page_id, bytes, sealed);
        frame.dirty = false;
        self.dirty_count -= 1;
        self.counters.writebacks += 1;
    }

    /// True when the gate is on and frame `index` is dirty with a page lsn above the durable
    /// bound, so it must not be written back yet. A clean frame is never blocked: dropping it
    /// loses nothing.
    fn gate_blocks(self: *const BufferPool, index: u32) bool {
        assert(index < self.frames_max);
        const frame = self.frames[index];
        if (!self.gate_on or !frame.dirty) return false;
        assert(frame.page_id != 0);
        const start = @as(usize, index) * self.page_size;
        const sealed = header.peek(self.slab[start..][0..self.page_size]);
        return sealed.lsn > self.durable_lsn;
    }

    fn pin_hit(self: *BufferPool, index: u32, updatable: bool) PageGuard {
        const frame = &self.frames[index];
        assert(frame.page_id != 0);
        assert(frame.pin_count < std.math.maxInt(u32));
        frame.pin_count += 1;
        frame.referenced = true;
        self.counters.hits += 1;
        return .{ .pool = self, .frame_index = index, .updatable = updatable, .released = false };
    }

    fn pin_load(self: *BufferPool, index: u32, raw: u32, updatable: bool) PageGuard {
        const frame = &self.frames[index];
        assert(frame.page_id == 0);
        assert(frame.pin_count == 0);
        assert(raw >= 1);
        frame.* = .{ .page_id = raw, .pin_count = 1, .referenced = true, .dirty = false };
        self.table.putAssumeCapacityNoClobber(raw, index);
        self.empty_count -= 1;
        return .{ .pool = self, .frame_index = index, .updatable = updatable, .released = false };
    }

    /// Picks the frame to load into: an empty one if any, else the CLOCK victim. Two sweeps of
    /// the hand are enough (the first clears every reference bit it passes), so more than
    /// `2 * frames_max` visits means every frame is pinned or gated (dirty above the WAL bound).
    fn victim_find(self: *BufferPool) error{PoolExhausted}!u32 {
        assert(self.hand < self.frames_max);
        if (self.empty_count > 0) {
            const found = self.victim_find_empty();
            assert(found != null); // `empty_count > 0` means some frame holds no page.
            if (found) |index| return index;
        }
        for (0..@as(usize, self.frames_max) * 2) |_| {
            const index = self.hand;
            self.hand = if (index + 1 == self.frames_max) 0 else index + 1;
            const frame = &self.frames[index];
            if (frame.pin_count > 0) continue;
            if (self.gate_blocks(index)) continue; // Cannot be written back yet: not a victim.
            if (frame.referenced) {
                frame.referenced = false;
                continue;
            }
            return index;
        }
        return error.PoolExhausted;
    }

    /// Searches forward from the hand, so filling a cold pool is O(1) per load.
    fn victim_find_empty(self: *BufferPool) ?u32 {
        assert(self.empty_count > 0);
        assert(self.hand < self.frames_max);
        for (0..self.frames_max) |step| {
            const index: u32 = @intCast((@as(u64, self.hand) + step) % self.frames_max);
            if (self.frames[index].page_id != 0) continue;
            self.hand = if (index + 1 == self.frames_max) 0 else index + 1;
            return index;
        }
        return null;
    }

    /// Drops the page held by frame `index`, if any, so the frame can be overwritten. A dirty
    /// page is written back first, before its table entry goes; on a failed write the frame is
    /// left exactly as it was.
    fn victim_evict(self: *BufferPool, io: Io, index: u32) WriteBackError!void {
        const frame = &self.frames[index];
        assert(frame.pin_count == 0);
        assert(frame.page_id != 0 or !frame.dirty);
        assert(!self.gate_blocks(index)); // `victim_find` never hands out a gated frame.
        if (frame.page_id == 0) return;
        if (frame.dirty) try self.write_back(io, index);

        const removed = self.table.remove(frame.page_id);
        assert(removed);
        frame.* = frame_empty;
        self.empty_count += 1;
        self.counters.evictions += 1;
        // The table deletes by tombstone; sweeping them once per `frames_max` evictions keeps
        // probes short on the hit path without allocating.
        if (self.counters.evictions % self.frames_max == 0) self.table.rehash(table_context);
    }
};

test {
    _ = @import("buffer_pool_test.zig"); // Contract tests live in their own files (800-line limit).
    _ = @import("buffer_pool_dirty_test.zig");
    _ = @import("buffer_pool_gate_test.zig");
    _ = @import("buffer_pool_new_test.zig");
}
