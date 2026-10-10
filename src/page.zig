//! strata.page — Page header/format, page manager, freelist, file header.
//!
//! Landed: `page/header.zig` (ADR-0002 page format v1: 24-byte page header, page-id-seeded
//! CRC32C, page-0 file header codec).
//! `page/freelist.zig` (ADR-0002 section 7 trunk-page freelist codec).
//! `page/manager.zig` (`PageManager` create/open/read/write, allocate/free, sync).
//!
//! Status: partial. Public declarations are added as PRD phases land.

const std = @import("std");

pub const header = @import("page/header.zig");
pub const freelist = @import("page/freelist.zig");
pub const manager = @import("page/manager.zig");
pub const Id = header.Id;

test "page: module compiles" {
    std.testing.refAllDecls(@This());
}
