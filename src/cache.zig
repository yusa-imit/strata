//! strata.cache — Buffer pool (CLOCK), pin/unpin guards, dirty tracking, stats.
//!
//! Landed: `cache/buffer_pool.zig` (`BufferPool` CLOCK fetch and pin over a `PageManager`,
//! minimal read-only `PageGuard`, `Stats`).
//! Planned: dirty tracking, `fetchForUpdate`, write-back and `flushAll` (plan 003 item 8).
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const buffer_pool = @import("cache/buffer_pool.zig");
pub const BufferPool = buffer_pool.BufferPool;
pub const PageGuard = buffer_pool.PageGuard;
pub const Options = buffer_pool.Options;
pub const Stats = buffer_pool.Stats;
pub const FetchError = buffer_pool.FetchError;

test "cache: module compiles" {
    std.testing.refAllDecls(@This());
}
