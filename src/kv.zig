//! strata.kv — Embedded KV engine: Db open/get/put/delete/scan, WriteBatch, Snapshot, engine selection.
//!
//! Planned files (see docs/PRD.md):
//!   - `kv/db.zig`
//!   - `kv/batch.zig`
//!   - `kv/iterator.zig`
//!   - `kv/snapshot.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "kv: module compiles" {
    std.testing.refAllDecls(@This());
}
