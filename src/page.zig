//! strata.page — Page header/format, page manager, freelist, file header.
//!
//! Landed: `page/header.zig` (ADR-0002 page format v1: 24-byte page header, page-id-seeded
//! CRC32C, page-0 file header codec).
//! Planned (see docs/PRD.md): `page/manager.zig`, `page/freelist.zig`.
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const header = @import("page/header.zig");
pub const Id = header.Id;

test "page: module compiles" {
    std.testing.refAllDecls(@This());
}
