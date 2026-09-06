//! strata — Layers beneath the data — WAL, pages, and a key-value engine for Zig
//!
//! Library root. Consumers `@import("strata")` and reach modules as
//! `strata.<module>`. Every module is independent; import only what you use.
//!
//! See docs/PRD.md for the full design and docs/plans/ for progress.

const std = @import("std");

pub const version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub const codec = @import("codec.zig");
pub const file = @import("file.zig");
pub const page = @import("page.zig");
pub const cache = @import("cache.zig");
pub const wal = @import("wal.zig");
pub const btree = @import("btree.zig");
pub const lsm = @import("lsm.zig");
pub const kv = @import("kv.zig");
pub const snapshot = @import("snapshot.zig");
pub const testing = @import("testing.zig");

test {
    std.testing.refAllDecls(@This());
}
