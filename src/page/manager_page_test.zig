//! Contract tests for `manager.zig` read and write (plan 003 item 5; ADR-0002 section 6):
//! round trip, `Unwritten`, bit rot, misdirected writes, truncation (`TornWrite`), torn sectors,
//! reopen persistence, and `FaultIo` injected I/O errors. Page 0 is owned by the manager, so
//! these tests craft a file whose page 0 claims `page_count > 1` and open it.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fixtures = @import("../file/file_fixtures.zig");
const FaultIo = @import("../testing/fault_io.zig").FaultIo;
const header = @import("header.zig");
const fx = @import("manager_fixtures.zig");

const PageManager = @import("manager.zig").PageManager;
const opts = fx.opts;
const id_of = fx.id_of;
const fh_of = fx.fh_of;
const craft = fx.craft;
const open_crafted = fx.open_crafted;
const raw_open = fx.raw_open;
const zero_range = fx.zero_range;
const expect_open_ok = fx.expect_open_ok;
const write_pattern = fx.write_pattern;
const expect_pattern = fx.expect_pattern;
const expect_read_error = fx.expect_read_error;
const expect_disk_equals = fx.expect_disk_equals;
const expect_page0_intact = fx.expect_page0_intact;
const expect_flip_read = fx.expect_flip_read;
const consumer_type = fx.consumer_type;
const sizes_three = fx.sizes_three;

// ---------------------------------------------------------------------------------------------
// read and write
// ---------------------------------------------------------------------------------------------

test "manager: a never-written page reads as Unwritten" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for (sizes_three) |size| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "unw-{d}.db", .{size});
        var pm: PageManager = undefined;
        try open_crafted(&pm, tmp.dir, name, size, 4);
        defer pm.close(testing.io);

        for (1..4) |id| try expect_read_error(&pm, @intCast(id), error.Unwritten);
    }
}

test "manager: write then read round-trips header and payload, other pages untouched" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    for (sizes_three, 0..) |size, i| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "wr-{d}.db", .{size});
        var pm: PageManager = undefined;
        try open_crafted(&pm, tmp.dir, name, size, 4);
        defer pm.close(testing.io);

        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);

        const lsn: u64 = 1000 + i;
        try write_pattern(&pm, 2, buf, 7, lsn);
        const stamped = try header.decode(buf, id_of(2)); // `write` stamped the header into buf
        try testing.expectEqual(consumer_type, stamped.page_type);
        try testing.expectEqual(lsn, stamped.lsn);
        try expect_pattern(&pm, 2, 7, lsn);
        try expect_disk_equals(&pm, 2, buf);
        try expect_read_error(&pm, 1, error.Unwritten);
        try expect_read_error(&pm, 3, error.Unwritten);
        try expect_page0_intact(&pm, 4);
    }
}

test "manager: rewriting a page replaces its bytes and header" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "rewrite.db", 512, 4);
    defer pm.close(testing.io);

    var buf: [512]u8 = undefined;
    try write_pattern(&pm, 1, &buf, 3, 10);
    try write_pattern(&pm, 3, &buf, 5, 30);
    try write_pattern(&pm, 1, &buf, 9, 11);
    try expect_pattern(&pm, 1, 9, 11);
    try expect_pattern(&pm, 3, 5, 30);
    try expect_read_error(&pm, 2, error.Unwritten);
}

test "manager: a flipped byte on disk is ChecksumMismatch, identity bytes are Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "bitrot.db", 4096, 4);
    defer pm.close(testing.io);

    const buf = try gpa.alloc(u8, 4096);
    defer gpa.free(buf);

    for (1..4) |id| try write_pattern(&pm, @intCast(id), buf, @intCast(id * 11), 500 + id);
    const raw = try raw_open(tmp.dir, "bitrot.db");
    defer raw.close(testing.io);

    const sum_offsets = [_]u64{ 4, 5, 8, 11, 12, 15, 16, 23, 24, 100, 2048, 4095 };
    for (sum_offsets) |at| try expect_flip_read(&pm, raw, 2, at, error.ChecksumMismatch);
    for ([_]u64{ 0, 3, 6, 7 }) |at| try expect_flip_read(&pm, raw, 2, at, error.Corrupted);
    try expect_pattern(&pm, 1, 11, 501); // neighbours were never affected
    try expect_pattern(&pm, 3, 33, 503);
}

test "manager: a valid page copied to another id is ChecksumMismatch there" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "misdirect.db", 512, 4);
    defer pm.close(testing.io);

    const buf = try gpa.alloc(u8, 512);
    defer gpa.free(buf);

    try write_pattern(&pm, 2, buf, 21, 77);
    const raw = try raw_open(tmp.dir, "misdirect.db");
    defer raw.close(testing.io);

    try raw.writeAtAll(testing.io, buf, 3 * 512); // misdirected: page 2's image lands in slot 3
    try raw.writeAtAll(testing.io, buf, 1 * 512); // and in slot 1
    try expect_read_error(&pm, 3, error.ChecksumMismatch);
    try expect_read_error(&pm, 1, error.ChecksumMismatch);
    try expect_pattern(&pm, 2, 21, 77);
}

test "manager: a file cut short after open reads TornWrite, whole page or mid-page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    for ([_]u32{ 512, 4096 }) |size| {
        var pm: PageManager = undefined;
        try open_crafted(&pm, tmp.dir, "torn.db", size, 4);
        defer pm.close(testing.io);

        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);

        for (1..4) |id| try write_pattern(&pm, @intCast(id), buf, @intCast(id), id);
        const raw = try raw_open(tmp.dir, "torn.db");
        defer raw.close(testing.io);

        const cuts = [_]u64{ size / 2, 1, 0 }; // bytes of page 3 that survive
        for (cuts) |kept| {
            try raw.setLength(testing.io, 3 * @as(u64, size) + kept);
            try expect_read_error(&pm, 3, error.TornWrite);
            try expect_pattern(&pm, 2, 2, 2);
        }
        try raw.setLength(testing.io, 2 * @as(u64, size) + 10); // cut inside page 2
        try expect_read_error(&pm, 2, error.TornWrite);
        try expect_read_error(&pm, 3, error.TornWrite);
        try expect_pattern(&pm, 1, 1, 1);
        try raw.setLength(testing.io, 4 * @as(u64, size)); // regrown: zeros, never written
        try expect_read_error(&pm, 3, error.Unwritten);
        try write_pattern(&pm, 3, buf, 3, 3);
        try expect_pattern(&pm, 3, 3, 3);
    }
}

test "manager: a torn or zeroed sector is never Unwritten unless the page is all zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "sector.db", 4096, 4);
    defer pm.close(testing.io);

    const buf = try gpa.alloc(u8, 4096);
    defer gpa.free(buf);

    const raw = try raw_open(tmp.dir, "sector.db");
    defer raw.close(testing.io);

    const Case = struct { from: u32, to: u32, want: anyerror };
    const cases = [_]Case{
        .{ .from = 512, .to = 1024, .want = error.ChecksumMismatch }, // later sector lost
        .{ .from = 3584, .to = 4096, .want = error.ChecksumMismatch }, // last sector lost
        .{ .from = 0, .to = 512, .want = error.Corrupted }, // zero magic before live bytes
        .{ .from = 0, .to = 4096, .want = error.Unwritten }, // the whole page zero
    };
    for (cases) |case| {
        try write_pattern(&pm, 2, buf, 4, 40);
        try zero_range(raw, 4096, 2, case.from, case.to);
        try expect_read_error(&pm, 2, case.want);
    }
    try write_pattern(&pm, 2, buf, 4, 40); // a rewrite heals every case
    try expect_pattern(&pm, 2, 4, 40);
}

test "manager: pages written before close are read back equal after reopen" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    for (sizes_three, 0..) |size, i| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "persist-{d}.db", .{size});
        const lsn_base: u64 = 9000 * (i + 1);
        const buf = try gpa.alloc(u8, size);
        defer gpa.free(buf);

        var pm: PageManager = undefined;
        try open_crafted(&pm, tmp.dir, name, size, 4);
        try write_pattern(&pm, 3, buf, 33, lsn_base + 3);
        try write_pattern(&pm, 1, buf, 11, lsn_base + 1);
        pm.close(testing.io);

        try PageManager.open(&pm, testing.io, tmp.dir, name, opts(size));
        defer pm.close(testing.io);

        try testing.expectEqual(@as(u32, 4), pm.page_count);
        try expect_pattern(&pm, 1, 11, lsn_base + 1);
        try expect_pattern(&pm, 3, 33, lsn_base + 3);
        try expect_read_error(&pm, 2, error.Unwritten);
        try expect_page0_intact(&pm, 4);
    }
}

// ---------------------------------------------------------------------------------------------
// I/O faults: errors from the file layer surface unchanged and never corrupt state
// ---------------------------------------------------------------------------------------------

test "manager: canceled write and read surface Canceled and a retry succeeds" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "cancel.db", 512, 4);
    defer pm.close(testing.io);

    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, .{ .write = .canceled, .read = .canceled, .after_calls = 0 });
    var buf: [512]u8 = undefined;
    fixtures.pattern(buf[header.header_size..], 5);
    const h: header.Header = .{ .page_type = consumer_type, .lsn = 8 };
    try testing.expectError(error.Canceled, pm.write(fio.io(), id_of(1), &buf, h));
    try testing.expectError(error.Canceled, pm.read(fio.io(), id_of(1), &buf));
    try expect_read_error(&pm, 1, error.Unwritten); // the canceled write put nothing on disk
    try write_pattern(&pm, 1, &buf, 5, 8);
    try expect_pattern(&pm, 1, 5, 8);
}

test "manager: short reads and writes are looped, not mistaken for a torn page" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var pm: PageManager = undefined;
    try open_crafted(&pm, tmp.dir, "short.db", 512, 4);
    defer pm.close(testing.io);

    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, .{
        .write = .{ .short = 7 },
        .read = .{ .short = 5 },
        .after_calls = 0,
    });
    var buf: [512]u8 = undefined;
    fixtures.pattern(buf[header.header_size..], 17);
    try pm.write(fio.io(), id_of(2), &buf, .{ .page_type = consumer_type, .lsn = 99 });
    try testing.expect(fio.write_calls >= 74); // ceil(512 / 7): the loop really ran

    var back: [512]u8 = undefined;
    const h = try pm.read(fio.io(), id_of(2), &back);
    try testing.expect(fio.read_calls >= 103); // ceil(512 / 5)
    try testing.expectEqual(@as(u64, 99), h.lsn);
    try testing.expectEqualSlices(u8, &buf, &back);
}

test "manager: open surfaces a read failure and releases the lock" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try craft(tmp.dir, "readfail.db", fh_of(512, 2), 2 * 512);
    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, .{ .write = .zero, .read = .canceled, .after_calls = 0 });
    var pm: PageManager = undefined;
    const opened = PageManager.open(&pm, fio.io(), tmp.dir, "readfail.db", opts(512));
    try testing.expectError(error.Canceled, opened);
    try expect_open_ok(tmp.dir, "readfail.db", 512, 2); // handle and lock were not leaked
}

test "manager: create surfaces a write failure" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var fio: FaultIo = undefined;
    FaultIo.init(&fio, testing.io, .{ .write = .canceled, .read = .zero, .after_calls = 0 });
    var pm: PageManager = undefined;
    const created = PageManager.create(&pm, fio.io(), tmp.dir, "writefail.db", opts(4096));
    try testing.expectError(error.Canceled, created);
    try testing.expect(fio.write_calls >= 1);
}
