//! strata's CLI binary: `strata version` / `strata --help`.

const std = @import("std");
const strata = @import("strata");

/// Minimal CLI: `strata version` / `strata --help`.
/// Diagnostic subcommands are added as modules land (see docs/PRD.md).
/// Precondition: `init.minimal.args` always yields at least argv[0] (OS-guaranteed).
/// Postcondition: `args` is read-only here, so that precondition still holds on return.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    std.debug.assert(args.len >= 1); // argv[0] is always the program path.
    defer std.debug.assert(args.len >= 1); // unchanged by any branch below.

    var stdout_buffer: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const out = &stdout_writer.interface;
    defer out.flush() catch {};

    const cmd = if (args.len > 1) args[1] else "--help";
    if (std.mem.eql(u8, cmd, "version")) {
        try out.print("strata {f}\n", .{strata.version});
    } else {
        try out.print(
            \\strata — Layers beneath the data — WAL, pages, and a key-value engine for Zig
            \\
            \\usage: strata <command>
            \\  version    print library version
            \\  --help     this text
            \\
        , .{});
    }
}

test "cli: version is exposed" {
    try std.testing.expectEqual(@as(u32, 0), strata.version.major);
}
