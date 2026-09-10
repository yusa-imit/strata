//! strata.testing — Crash-injection harness (torn writes, truncation at arbitrary
//! offsets), differential model.
//!
//! Planned files (see docs/PRD.md):
//!   - `testing/crash.zig`
//!   - `testing/model.zig`
//!
//! Status: stub. Public declarations are added as PRD phases land.

const std = @import("std");

/// Module-level error set. Extend as functionality lands; keep names descriptive
/// (`error.ChecksumMismatch`, not `error.Invalid`).
pub const Error = error{
    NotImplemented,
};

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
