//! strata.file — Platform file I/O: sync policies (fdatasync/fsync/F_FULLFSYNC),
//! O_DIRECT, preallocate, locks, mmap.
//!
//! Files (see docs/PRD.md):
//!   - `file/file.zig` (landed: open, positional read/write, length, setLength, sync policies,
//!     preallocate, advisory locks)
//!   - `file/platform.zig` (landed: the only OS-branching file; sync/reserve primitives)
//!   - `file/mmap.zig` (planned)
//!
//! Status: `direct` is still rejected (`error.UnsupportedDirectIo`) and `file/mmap.zig` is
//! planned (plan 003). `file.File` owns its own typed error sets, so this module declares none.

const std = @import("std");

pub const file = @import("file/file.zig");

test "file: module compiles" {
    std.testing.refAllDecls(@This());
}
