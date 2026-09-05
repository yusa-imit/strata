//! strata.lsm — LSM tree: skiplist memtable, SSTable (blocks, index, bloom), compaction, manifest.
//!
//! Planned files (see docs/PRD.md):
//!   - `lsm/memtable.zig`
//!   - `lsm/sstable.zig`
//!   - `lsm/compaction.zig`
//!   - `lsm/manifest.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "lsm: module compiles" {
    std.testing.refAllDecls(@This());
}
