//! strata.testing — Crash-injection harness (torn writes, truncation at arbitrary
//! offsets), differential model.
//!
//! Files (see docs/PRD.md):
//!   - `testing/crash.zig` (landed: crash sink with truncate and torn cuts, and the
//!     truncation-point enumerator; simulated cuts are a floor, not a proof of power-loss
//!     safety, since reordered or partially flushed sectors are not reproduced)
//!   - `testing/fault_io.zig` (landed: fault-injecting `std.Io` wrapper for positional reads
//!     and writes: short, zero, canceled)
//!   - `testing/model.zig` (planned)
//!
//! Status: crash and fault_io have landed; model is added as its PRD phase lands. Neither
//! landed file allocates after `init`.

const std = @import("std");

pub const crash = @import("testing/crash.zig");
pub const fault_io = @import("testing/fault_io.zig");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

test {
    _ = @import("testing/crash_test.zig");
    _ = @import("testing/fault_io_test.zig");
}

test "testing: module compiles" {
    std.testing.refAllDecls(@This());
}

test "testing: tmpDir round-trip write and read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const written = "hello strata";
    try tmp.dir.writeFile(io, .{ .sub_path = "roundtrip.txt", .data = written });

    const result = try tmp.dir.readFileAlloc(
        io,
        "roundtrip.txt",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings(written, result);

    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.readFileAlloc(io, "missing.txt", std.testing.allocator, .limited(64)),
    );
}
