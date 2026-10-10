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
//! Pages are read-only through the pool until dirty tracking lands (plan 003 item 8): `bytes`
//! is a const view, and a page changed behind the pool's back through `PageManager.write` or
//! freed through `PageManager.free` is not noticed while a frame still holds its old copy.
//! A failed load leaves the frame empty and the pool consistent; the evicted page stays gone.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const header = @import("../page/header.zig");
const manager = @import("../page/manager.zig");
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

pub const FetchError = manager.ReadError || error{PoolExhausted};

/// Counters since `init`. `hits + misses` is the number of `fetch` calls that passed their
/// preconditions; a miss that fails to load still counts. `evictions` counts pages dropped to
/// make room, whether or not the following load succeeded.
pub const Stats = struct {
    hits: u64,
    misses: u64,
    evictions: u64,
};

const Frame = struct {
    /// Raw `page.Id`, 0 when the frame holds no page (page 0 is never fetched).
    page_id: u32,
    pin_count: u32,
    /// CLOCK reference bit: set on every load and hit, cleared as the hand passes.
    referenced: bool,
};

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
        @memset(frames, .{ .page_id = 0, .pin_count = 0, .referenced = false });
        target.* = .{
            .pages = pages,
            .page_size = options.page_size,
            .frames_max = options.frames_max,
            .slab = slab,
            .frames = frames,
            .table = table,
            .hand = 0,
            .empty_count = options.frames_max,
            .counters = .{ .hits = 0, .misses = 0, .evictions = 0 },
        };
        assert(target.frames.len == options.frames_max);
        assert(target.slab.len == slab_len);
    }

    /// Frees the buffers `init` allocated; `gpa` must be the allocator given to `init`.
    /// Precondition: no guard is outstanding (every fetched page was released).
    pub fn deinit(self: *BufferPool, gpa: Allocator) void {
        assert(self.pinned_count() == 0);
        assert(self.frames.len == self.frames_max);
        self.table.deinit(gpa);
        gpa.free(self.frames);
        gpa.free(self.slab);
        self.* = undefined;
    }

    /// Pins page `id` and returns a guard over its frame. A hit costs no I/O; a miss evicts the
    /// first unpinned frame whose reference bit is clear (taking an empty frame first) and
    /// reads the page into it. Every frame pinned is `PoolExhausted`, returned at once, never
    /// waited on. A page that fails to load (`Unwritten`, `Corrupted`, `ChecksumMismatch`,
    /// `TornWrite`, I/O errors) leaves its frame empty, and the page it displaced stays gone.
    /// Preconditions: `0 < id < page_count` of the manager (the same contract as
    /// `PageManager.read`; ids that come from disk must be range-checked by the caller, since
    /// the checks here are asserts); the caller releases the guard exactly once.
    pub fn fetch(self: *BufferPool, io: Io, id: Id) FetchError!PageGuard {
        const raw = @intFromEnum(id);
        assert(raw >= 1);
        assert(raw < self.pages.page_count);
        if (self.table.get(raw)) |index| return self.pin_hit(index);

        self.counters.misses += 1;
        const index = try self.victim_find();
        self.victim_evict(index);
        _ = try self.pages.read(io, id, self.frame_bytes(index));
        return self.pin_load(index, raw);
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
        var empty: u32 = 0;
        for (self.frames, 0..) |frame, index| {
            if (frame.page_id == 0) {
                assert(frame.pin_count == 0);
                assert(!frame.referenced);
                empty += 1;
            } else {
                assert(frame.page_id < self.pages.page_count);
                assert(self.table.get(frame.page_id).? == index);
            }
        }
        assert(empty == self.empty_count);
        assert(self.table.count() == self.frames_max - empty);
    }

    fn frame_bytes(self: *BufferPool, index: u32) []u8 {
        assert(index < self.frames_max);
        assert(self.slab.len == @as(usize, self.frames_max) * self.page_size);
        const start = @as(usize, index) * self.page_size;
        return self.slab[start..][0..self.page_size];
    }

    fn pin_hit(self: *BufferPool, index: u32) PageGuard {
        const frame = &self.frames[index];
        assert(frame.page_id != 0);
        assert(frame.pin_count < std.math.maxInt(u32));
        frame.pin_count += 1;
        frame.referenced = true;
        self.counters.hits += 1;
        return .{ .pool = self, .frame_index = index, .released = false };
    }

    fn pin_load(self: *BufferPool, index: u32, raw: u32) PageGuard {
        const frame = &self.frames[index];
        assert(frame.page_id == 0);
        assert(frame.pin_count == 0);
        assert(raw >= 1);
        frame.* = .{ .page_id = raw, .pin_count = 1, .referenced = true };
        self.table.putAssumeCapacityNoClobber(raw, index);
        self.empty_count -= 1;
        return .{ .pool = self, .frame_index = index, .released = false };
    }

    /// Picks the frame to load into: an empty one if any, else the CLOCK victim. Two sweeps of
    /// the hand are enough (the first clears every reference bit it passes), so more than
    /// `2 * frames_max` visits means every frame is pinned.
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

    /// Drops the page held by frame `index`, if any, so the frame can be overwritten.
    fn victim_evict(self: *BufferPool, index: u32) void {
        const frame = &self.frames[index];
        assert(frame.pin_count == 0);
        if (frame.page_id == 0) return;
        const removed = self.table.remove(frame.page_id);
        assert(removed);
        frame.* = .{ .page_id = 0, .pin_count = 0, .referenced = false };
        self.empty_count += 1;
        self.counters.evictions += 1;
        // The table deletes by tombstone; sweeping them once per `frames_max` evictions keeps
        // probes short on the hit path without allocating.
        if (self.counters.evictions % self.frames_max == 0) self.table.rehash(table_context);
    }
};

/// A pin on one frame. Obtained from `BufferPool.fetch`; `release` exactly once, usually
/// `defer guard.release()`. The bytes are valid until `release`. Move-only by convention: a
/// copy shares the pin, and releasing both copies is a contract violation (asserted in
/// safe builds, an underflow of the pin count in unsafe ones).
pub const PageGuard = struct {
    pool: *BufferPool,
    frame_index: u32,
    released: bool,

    /// The whole page, header included, as read from disk. Const: see the file header.
    /// Precondition: not released.
    pub fn bytes(self: *const PageGuard) []const u8 {
        assert(!self.released);
        assert(self.pool.frames[self.frame_index].pin_count > 0);
        return self.pool.frame_bytes(self.frame_index);
    }

    /// The pinned page's id. Precondition: not released.
    pub fn id(self: *const PageGuard) Id {
        assert(!self.released);
        const raw = self.pool.frames[self.frame_index].page_id;
        assert(raw >= 1);
        return @enumFromInt(raw);
    }

    /// Drops this pin; the frame becomes evictable once its last pin is gone. No `io`, cannot
    /// fail. Precondition: not released already.
    pub fn release(self: *PageGuard) void {
        assert(!self.released);
        const frame = &self.pool.frames[self.frame_index];
        assert(frame.pin_count > 0);
        frame.pin_count -= 1;
        self.released = true;
    }
};

test {
    _ = @import("buffer_pool_test.zig"); // Contract tests live in their own file (800-line limit).
}
