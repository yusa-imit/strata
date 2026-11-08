//! kv error sets (ADR-0005 section 10): one explicit `Error`, the named subsets each public
//! `Db` call returns, and `map`, the only place lower-layer errors (`Io`, page, pool, tree,
//! WAL) are turned into kv errors. Callers never see a lower set.
//!
//! Invariants: every subset is a compile-time subset of `Error` (checked by a test). `map`
//! lists each lower variant that has a kv meaning; every other lower variant is an I/O failure
//! of a kind kv cannot act on and becomes `InputOutput`. Deviation from ADR-0005 section 10:
//! the final prong is `else`, so a new lower variant does not break the build, it degrades to
//! `InputOutput` (the lower sets are `Io` error sets with dozens of variants).

const std = @import("std");
const assert = std.debug.assert;

pub const Error = error{
    /// Untrusted bytes, half-created directories, a missing log, a log that does not match the
    /// page file.
    Corrupted,
    ChecksumMismatch,
    /// The database lock is held; `PageManager.create` found the file (a race).
    WouldBlock,
    /// `open` only.
    OutOfMemory,
    /// Disk full, or the `page_count_max` growth limit.
    NoSpaceLeft,
    AccessDenied,
    /// A canceled `Io` call. Inside a commit it also latches the `Db`.
    Canceled,
    /// Every other `Io` variant.
    InputOutput,
    KeyTooLarge,
    ValueTooLarge,
    /// A `WriteBatch` over `batch_ops_max` ops or `batch_bytes_max` key and value bytes.
    BatchTooLarge,
    HeightLimit,
    SegmentLimit,
    LsnExhausted,
    /// The writer, tree or `Db` is latched: reopen.
    Failed,
};

pub const OpenError = Error;
pub const GetError = Error;
pub const PutError = Error;
pub const DeleteError = Error;
pub const FlushError = Error;
pub const CheckpointError = Error;
/// Recording an op: limits only, nothing else is touched.
pub const BatchError = error{ KeyTooLarge, ValueTooLarge, BatchTooLarge };
/// `WriteBatch.init` allocates its op table and byte arena once.
pub const BatchInitError = error{OutOfMemory};
pub const CommitError = Error;

/// Maps a lower-layer error to its kv meaning; see the file header for the rule.
pub fn map(err: anyerror) Error {
    assert(@errorName(err).len >= 1);
    assert(@intFromError(err) != 0);
    return switch (err) {
        error.Corrupted, error.TornWrite, error.Unwritten, error.UnexpectedEof => error.Corrupted,
        error.ChecksumMismatch => error.ChecksumMismatch,
        error.WouldBlock, error.AlreadyExists => error.WouldBlock,
        error.OutOfMemory => error.OutOfMemory,
        error.NoSpaceLeft, error.FileTooBig, error.DiskQuota => error.NoSpaceLeft,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.Canceled => error.Canceled,
        error.KeyTooLarge => error.KeyTooLarge,
        error.ValueTooLarge => error.ValueTooLarge,
        error.HeightLimit => error.HeightLimit,
        error.SegmentLimit => error.SegmentLimit,
        error.LsnExhausted => error.LsnExhausted,
        error.Failed, error.InvalidHeader => error.Failed,
        // The floors `Db.open` asserts make these impossible (ADR-0005 section 8); if a
        // miscount ever lets one through, the latch is safer than a panic.
        error.PoolExhausted, error.FreesPendingLimit => error.Failed,
        else => error.InputOutput,
    };
}

test {
    _ = @import("errors_test.zig");
}
