//! Contract tests for `manager.zig` create and open (plan 003 item 5; ADR-0002 sections 4-5):
//! round trip at all 8 page sizes, `AlreadyExists`, the exclusive lock (`WouldBlock`), and every
//! way page 0 can be wrong (`Corrupted`, `ChecksumMismatch`). Read and write live in
//! `manager_page_test.zig`; the seeded model and fuzz target in `manager_model_test.zig`.
//! Expected values come from literals, the pure header codec, and raw `file.File` handles that
//! bypass the manager; files the manager must reject are crafted byte by byte.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const header = @import("header.zig");
const fx = @import("manager_fixtures.zig");

const Id = header.Id;
const PageManager = @import("manager.zig").PageManager;
const opts_with = fx.opts_with;
const opts = fx.opts;
const id_of = fx.id_of;
const fh_of = fx.fh_of;
const write_file = fx.write_file;
const craft = fx.craft;
const raw_open = fx.raw_open;
const expect_open_error = fx.expect_open_error;
const expect_create_error = fx.expect_create_error;
const expect_open_ok = fx.expect_open_ok;
const expect_fresh = fx.expect_fresh;
const expect_disk_fresh = fx.expect_disk_fresh;
const expect_flip_open = fx.expect_flip_open;
const page_count_max = fx.page_count_max;
const sizes_all = fx.sizes_all;
const policies = fx.policies;

// ---------------------------------------------------------------------------------------------
// create and open
// ---------------------------------------------------------------------------------------------

test "manager: create then close then open round-trips the fresh file at all 8 page sizes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    for (sizes_all, 0..) |size, i| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "rt-{d}.db", .{size});
        const options = opts_with(size, policies[i % policies.len]);
        var pm: PageManager = undefined;
        {
            try PageManager.create(&pm, io, tmp.dir, name, options);
            defer pm.close(io);

            try expect_fresh(&pm, size);
        }
        try expect_disk_fresh(tmp.dir, name, size);
        {
            try PageManager.open(&pm, io, tmp.dir, name, options);
            defer pm.close(io);

            try expect_fresh(&pm, size);
        }
    }
}

test "manager: create on an existing strata file is AlreadyExists and leaves it intact" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    var pm: PageManager = undefined;
    try PageManager.create(&pm, io, tmp.dir, "dup.db", opts(4096));
    pm.close(io);

    try expect_create_error(error.AlreadyExists, tmp.dir, "dup.db", 4096);
    try expect_create_error(error.AlreadyExists, tmp.dir, "dup.db", 512);
    try expect_disk_fresh(tmp.dir, "dup.db", 4096);
    try expect_open_ok(tmp.dir, "dup.db", 4096, 1); // The failed creates released the lock.
}

test "manager: create on a foreign non-empty file is AlreadyExists and does not touch it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    try write_file(tmp.dir, "foreign.db", "not a strata file", 17);
    try expect_create_error(error.AlreadyExists, tmp.dir, "foreign.db", 4096);

    const raw = try raw_open(tmp.dir, "foreign.db");
    defer raw.close(io);

    var back: [17]u8 = undefined;
    try testing.expectEqual(@as(u64, 17), try raw.length(io));
    try raw.readAtAll(io, &back, 0);
    try testing.expectEqualStrings("not a strata file", &back);
}

test "manager: a second open of an open file is WouldBlock until the first closes" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const io = testing.io;
    var first: PageManager = undefined;
    try PageManager.create(&first, io, tmp.dir, "lock.db", opts(4096));
    try expect_open_error(error.WouldBlock, tmp.dir, "lock.db", 4096); // create holds the lock
    try expect_open_error(error.WouldBlock, tmp.dir, "lock.db", 4096); // and still does
    first.close(io);

    var second: PageManager = undefined;
    try PageManager.open(&second, io, tmp.dir, "lock.db", opts(4096));
    try expect_open_error(error.WouldBlock, tmp.dir, "lock.db", 4096); // open holds it too
    second.close(io);
    try expect_open_ok(tmp.dir, "lock.db", 4096, 1);
}

test "manager: open with a different page_size than the file's is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const pairs = [_][2]u32{
        .{ 512, 4096 }, .{ 4096, 512 }, .{ 4096, 65536 }, .{ 65536, 4096 }, .{ 1024, 2048 },
    };
    for (pairs, 0..) |pair, i| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "mismatch-{d}.db", .{i});
        var pm: PageManager = undefined;
        try PageManager.create(&pm, testing.io, tmp.dir, name, opts(pair[0]));
        pm.close(testing.io);

        try expect_open_error(error.Corrupted, tmp.dir, name, pair[1]);
        try expect_open_ok(tmp.dir, name, pair[0], 1); // Correct size works: lock released.
    }
}

test "manager: open on a missing file is FileNotFound and creates nothing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try expect_open_error(error.FileNotFound, tmp.dir, "missing.db", 4096);
    try testing.expectError(error.FileNotFound, tmp.dir.openFile(testing.io, "missing.db", .{}));
}

test "manager: open on empty, tiny, truncated-prefix and non-strata files is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    try write_file(tmp.dir, "empty.db", "", 0);
    try expect_open_error(error.Corrupted, tmp.dir, "empty.db", 4096);
    try write_file(tmp.dir, "one.db", "S", 1);
    try expect_open_error(error.Corrupted, tmp.dir, "one.db", 512);
    const text = "hello, this is plain text";
    try write_file(tmp.dir, "text.db", text, text.len);
    try expect_open_error(error.Corrupted, tmp.dir, "text.db", 512);

    const page = try gpa.alloc(u8, 512);
    defer gpa.free(page);

    header.encode_file_header(page, fh_of(512, 1));
    try write_file(tmp.dir, "short.db", page[0..511], 511); // one byte short of a whole prefix
    try expect_open_error(error.Corrupted, tmp.dir, "short.db", 512);
    try write_file(tmp.dir, "exact.db", page, 512); // the same image, whole: accepted
    try expect_open_ok(tmp.dir, "exact.db", 512, 1);
}

test "manager: open on a zero-filled file is Corrupted at every size and length" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const lengths = [_]u64{ 100, 512, 700, 4096, 8192, 65536 };
    for (lengths, 0..) |len, i| {
        var name_buf: [24]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "zero-{d}.db", .{i});
        try write_file(tmp.dir, name, "", len);
        try expect_open_error(error.Corrupted, tmp.dir, name, 512);
        try expect_open_error(error.Corrupted, tmp.dir, name, 4096);
    }
}

test "manager: open on seeded random garbage is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var prng = std.Random.DefaultPrng.init(0x57A7_A003_0001);
    const rng = prng.random();
    var garbage: [4096]u8 = undefined;
    const lengths = [_]usize{ 511, 512, 513, 4096 };
    for (0..16) |round| {
        rng.bytes(&garbage);
        const len = lengths[round % lengths.len];
        try write_file(tmp.dir, "garbage.db", garbage[0..len], len);
        try expect_open_error(error.Corrupted, tmp.dir, "garbage.db", 4096);
        try expect_open_error(error.Corrupted, tmp.dir, "garbage.db", 512);
    }
}

test "manager: open on a page 0 whose size field is not a valid page size is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var page: [512]u8 = undefined;
    header.encode_file_header(&page, fh_of(512, 1));
    const bad_sizes = [_]u32{ 0, 256, 3000, 131072 };
    for (bad_sizes) |bad| {
        std.mem.writeInt(u32, page[24..28], bad, .little); // checksum now stale: peek fails first
        try write_file(tmp.dir, "badsize.db", &page, 512);
        try expect_open_error(error.Corrupted, tmp.dir, "badsize.db", 512);
    }
}

test "manager: open when the file ends inside page 0 is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const gpa = testing.allocator;
    const page = try gpa.alloc(u8, 4096);
    defer gpa.free(page);

    header.encode_file_header(page, fh_of(4096, 1));
    const cuts = [_]usize{ 512, 513, 1000, 4095 };
    for (cuts) |cut| {
        try write_file(tmp.dir, "cut.db", page[0..cut], cut);
        try expect_open_error(error.Corrupted, tmp.dir, "cut.db", 4096);
    }
    try write_file(tmp.dir, "cut.db", page, 4096);
    try expect_open_ok(tmp.dir, "cut.db", 4096, 1);
}

test "manager: a flipped byte in page 0 is ChecksumMismatch, identity bytes are Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try craft(tmp.dir, "flip.db", fh_of(4096, 3), 3 * 4096);
    const raw = try raw_open(tmp.dir, "flip.db");
    defer raw.close(testing.io);

    const sum_offsets = [_]u64{
        5, 8, 11, 12, 15, 16, 23, 28, 32, 36, 40, 47, 48, 100, 2000, 4095,
    };
    for (sum_offsets) |at| {
        try expect_flip_open(raw, tmp.dir, "flip.db", 4096, at, error.ChecksumMismatch);
    }
    const corrupt_offsets = [_]u64{ 0, 3, 4, 6, 7, 24, 25, 26 }; // magic, type, version, size
    for (corrupt_offsets) |at| {
        try expect_flip_open(raw, tmp.dir, "flip.db", 4096, at, error.Corrupted);
    }
}

test "manager: a well-checksummed page 0 with an invalid field is Corrupted" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const Patch = struct { offset: usize, value: u8 };
    const patches = [_]Patch{
        .{ .offset = 28, .value = 0 }, // page_count 0
        .{ .offset = 32, .value = 3 }, // freelist_head == page_count
        .{ .offset = 32, .value = 9 }, // freelist_head > page_count
        .{ .offset = 36, .value = 1 }, // file header reserved
        .{ .offset = 100, .value = 1 }, // non-zero tail
        .{ .offset = 5, .value = 1 }, // header flags
        .{ .offset = 12, .value = 1 }, // header reserved
        .{ .offset = 4, .value = 2 }, // free_trunk type at id 0
    };
    for (patches) |patch| {
        var page: [512]u8 = undefined;
        header.encode_file_header(&page, fh_of(512, 3));
        page[patch.offset] = patch.value; // `encode` would normalise this, so restamp by hand
        std.mem.writeInt(u32, page[8..12], header.checksum(&page, .file_header), .little);
        try write_file(tmp.dir, "field.db", &page, 8 * 512);
        try expect_open_error(error.Corrupted, tmp.dir, "field.db", 512);
    }
}

test "manager: open requires the file to hold page_count pages, a longer file is fine" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]u32{ 512, 4096 }) |size| {
        const full: u64 = 3 * @as(u64, size);
        const lengths = [_]u64{ size, 2 * @as(u64, size), full - 1 };
        for (lengths) |len| {
            try craft(tmp.dir, "len.db", fh_of(size, 3), len);
            try expect_open_error(error.Corrupted, tmp.dir, "len.db", size);
        }
        const accepted = [_]u64{ full, full + 1, 4 * @as(u64, size), 10 * @as(u64, size) };
        for (accepted) |len| {
            try craft(tmp.dir, "len.db", fh_of(size, 3), len);
            try expect_open_ok(tmp.dir, "len.db", size, 3); // count comes from page 0, not length
        }
    }
}

test "manager: open reports the freelist head and wal lsn stored in page 0" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const fh: header.FileHeader = .{
        .page_size = 512,
        .page_count = 5,
        .freelist_head = id_of(4),
        .wal_lsn = 0x0123_4567_89AB_CDEF,
    };
    try craft(tmp.dir, "meta.db", fh, 5 * 512);

    var pm: PageManager = undefined;
    try PageManager.open(&pm, testing.io, tmp.dir, "meta.db", opts(512));
    defer pm.close(testing.io);

    try testing.expectEqual(@as(u32, 5), pm.page_count);
    try testing.expectEqual(@as(?Id, id_of(4)), pm.freelist_head);
    try testing.expectEqual(@as(u64, 0x0123_4567_89AB_CDEF), pm.wal_lsn);
    try testing.expectEqual(page_count_max, pm.page_count_max);
}

test {
    _ = @import("manager_page_test.zig"); // Read, write, truncation, fault tests.
    _ = @import("manager_model_test.zig"); // Seeded model test and fuzz target.
}
