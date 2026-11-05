//! strata.kv — Embedded KV engine: Db open/get/put/delete/scan, WriteBatch, Snapshot,
//! engine selection.
//!
//! Planned files (see docs/PRD.md):
//!   - `kv/db.zig`
//!   - `kv/batch.zig`
//!   - `kv/iterator.zig`
//!   - `kv/snapshot.zig`
//!
//! Landed so far: `kv/db.zig` (`Db`: create, open after a clean close, put, get, delete,
//! flush, close; ADR-0005). Recovery, batch and iterator follow.
//!
//! Status: in progress. Public declarations are added as PRD phases land.

const std = @import("std");

pub const db = @import("kv/db.zig");
pub const Db = db.Db;
pub const errors = @import("kv/errors.zig");
/// Module-level error set (ADR-0005 section 10).
pub const Error = errors.Error;

test "kv: module compiles" {
    std.testing.refAllDecls(@This());
}
