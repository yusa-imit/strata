//! strata.kv — Embedded KV engine: Db open/get/put/delete/scan, WriteBatch, Snapshot,
//! engine selection.
//!
//! Planned files (see docs/PRD.md):
//!   - `kv/db.zig`
//!   - `kv/batch.zig`
//!   - `kv/iterator.zig` (landed)
//!   - `kv/snapshot.zig`
//!
//! Landed so far: `kv/db.zig` (`Db`: create, open with crash recovery, put, get, delete,
//! checkpoint, flush, close; ADR-0005) and `kv/batch.zig` (`WriteBatch`) and `kv/iterator.zig`
//! (`Db.scan`, `Range`, `Iterator`).
//!
//! Status: in progress. Public declarations are added as PRD phases land.

const std = @import("std");

pub const db = @import("kv/db.zig");
pub const Db = db.Db;
pub const batch = @import("kv/batch.zig");
pub const WriteBatch = batch.WriteBatch;
pub const iterator = @import("kv/iterator.zig");
pub const Range = iterator.Range;
pub const Iterator = iterator.Iterator;
pub const errors = @import("kv/errors.zig");
/// Module-level error set (ADR-0005 section 10).
pub const Error = errors.Error;

test "kv: module compiles" {
    std.testing.refAllDecls(@This());
}
