//! strata.wal — Segmented write-ahead log: frames, group-commit writer, reader,
//! checkpoint, recovery.
//!
//! Landed: `wal/frame.zig` (ADR-0003 frame codec: 17-byte header, LSN-seeded CRC32C) and
//! `wal/segment.zig` (ADR-0003 segment files: names, 24-byte header, exclusive create/open,
//! positional append) and `wal/reader.zig` (sequential read across segments with the ADR-0003
//! section 8 torn-tail rule) and `wal/writer.zig` (append, sync and rotate over the newest
//! segment; refuses a torn tail with `RecoveryRequired`; syncs the directory after creating a
//! segment) and `wal/recovery.zig` (replay into an `Apply` target; truncates a torn tail) and
//! `wal/redo.zig` (`PageRedo`, the `Apply` target that restores torn or stale pages from
//! `page_image` frames through `PageManager`) and `wal/checkpoint.zig` (`Checkpoint`: sharp
//! checkpoint with `wal_lsn` update and segment reclaim; `redo_start`: the replay start derived
//! from `wal_lsn`).
//!
//! Status: landed (plan 004, WAL format v1 per `docs/adr/0003-wal-format.md`). Group commit
//! is `Writer.commit`; its machinery lives in `wal/group_commit.zig`, which is internal.

const std = @import("std");

pub const frame = @import("wal/frame.zig");
pub const Frame = frame.Frame;
pub const segment = @import("wal/segment.zig");
pub const reader = @import("wal/reader.zig");
pub const Reader = reader.Reader;
pub const writer = @import("wal/writer.zig");
pub const Writer = writer.Writer;
pub const recovery = @import("wal/recovery.zig");
pub const Apply = recovery.Apply;
pub const Recovery = recovery.Recovery;
pub const redo = @import("wal/redo.zig");
pub const PageRedo = redo.PageRedo;
pub const checkpoint = @import("wal/checkpoint.zig");
pub const Checkpoint = checkpoint.Checkpoint;

test "wal: module compiles" {
    std.testing.refAllDecls(@This());
}
