//! strata.file — Platform file I/O: sync policies (fdatasync/fsync/F_FULLFSYNC), O_DIRECT, preallocate, locks, mmap.
//!
//! Planned files (see docs/PRD.md):
//!   - `file/file.zig`
//!   - `file/mmap.zig`
//!   - `file/lock.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test "file: module compiles" {
    std.testing.refAllDecls(@This());
}
