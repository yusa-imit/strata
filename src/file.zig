//! strata.file — Platform file I/O: sync policies (fdatasync/fsync/F_FULLFSYNC),
//! O_DIRECT, preallocate, locks, mmap.
//!
//! Planned files (see docs/PRD.md):
//!   - `file/file.zig`
//!   - `file/mmap.zig`
//!   - `file/lock.zig`
//!
//! Status: `file/file.zig` core landed (open, positional read/write, length, setLength).
//! `file/mmap.zig` and `file/lock.zig` are planned; sync policies and `direct` are still stored
//! or rejected only. `Error` keeps `NotImplemented` for the unlanded surface.

const std = @import("std");

pub const file = @import("file/file.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "file: module compiles" {
    std.testing.refAllDecls(@This());
}
