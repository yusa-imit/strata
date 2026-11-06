//! Tests for `kv/errors.zig`: every named subset is a subset of `Error`, and `map` sends each
//! source variant group to the kv variant ADR-0005 section 10 names.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const errors = @import("errors.zig");

const Error = errors.Error;

test "errors: every subset is a subset of Error" {
    inline for (.{
        errors.OpenError,
        errors.GetError,
        errors.PutError,
        errors.DeleteError,
        errors.FlushError,
        errors.CheckpointError,
    }) |Set| {
        const info = @typeInfo(Set).error_set.?;
        try testing.expect(info.len >= 1);
        inline for (info) |variant| {
            const widened: Error = @field(Error, variant.name);
            try testing.expectEqualStrings(variant.name, @errorName(widened));
        }
    }
}

test "errors: map sends each lower variant group to its kv variant" {
    const Case = struct { from: anyerror, want: Error };
    const cases = [_]Case{
        .{ .from = error.Corrupted, .want = error.Corrupted },
        .{ .from = error.TornWrite, .want = error.Corrupted },
        .{ .from = error.Unwritten, .want = error.Corrupted },
        .{ .from = error.UnexpectedEof, .want = error.Corrupted },
        .{ .from = error.ChecksumMismatch, .want = error.ChecksumMismatch },
        .{ .from = error.WouldBlock, .want = error.WouldBlock },
        .{ .from = error.AlreadyExists, .want = error.WouldBlock },
        .{ .from = error.OutOfMemory, .want = error.OutOfMemory },
        .{ .from = error.NoSpaceLeft, .want = error.NoSpaceLeft },
        .{ .from = error.FileTooBig, .want = error.NoSpaceLeft },
        .{ .from = error.AccessDenied, .want = error.AccessDenied },
        .{ .from = error.PermissionDenied, .want = error.AccessDenied },
        .{ .from = error.Canceled, .want = error.Canceled },
        .{ .from = error.KeyTooLarge, .want = error.KeyTooLarge },
        .{ .from = error.ValueTooLarge, .want = error.ValueTooLarge },
        .{ .from = error.HeightLimit, .want = error.HeightLimit },
        .{ .from = error.SegmentLimit, .want = error.SegmentLimit },
        .{ .from = error.LsnExhausted, .want = error.LsnExhausted },
        .{ .from = error.Failed, .want = error.Failed },
        .{ .from = error.InvalidHeader, .want = error.Failed },
        .{ .from = error.PoolExhausted, .want = error.Failed },
        .{ .from = error.FreesPendingLimit, .want = error.Failed },
        .{ .from = error.InputOutput, .want = error.InputOutput },
        .{ .from = error.SystemResources, .want = error.InputOutput },
        .{ .from = error.PayloadTooLarge, .want = error.InputOutput },
    };
    assert(cases.len == 25);
    for (cases) |case| try testing.expectEqual(case.want, errors.map(case.from));
}
