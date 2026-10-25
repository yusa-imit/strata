//! strata.cache — Buffer pool (CLOCK), pin/unpin guards, dirty tracking, stats.
//!
//! Landed: `cache/buffer_pool.zig` (`BufferPool` CLOCK fetch and pin over a `PageManager`,
//! `fetchForUpdate`, `fetchNew`, write-back on eviction, `flushAll`, `discardAll`, `Stats`) and
//! `cache/guard.zig` (`PageGuard`: read-only and writable pins, `markDirty`, `release`).
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const buffer_pool = @import("cache/buffer_pool.zig");
pub const BufferPool = buffer_pool.BufferPool;
pub const guard = @import("cache/guard.zig");
pub const PageGuard = guard.PageGuard;
pub const Options = buffer_pool.Options;
pub const Stats = buffer_pool.Stats;
pub const FetchError = buffer_pool.FetchError;
pub const FetchNewError = buffer_pool.FetchNewError;
pub const FlushError = buffer_pool.FlushError;

test "cache: module compiles" {
    std.testing.refAllDecls(@This());
}
