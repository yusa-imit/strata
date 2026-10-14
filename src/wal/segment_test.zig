//! Contract tests for `segment.zig` names, header codec and limits (ADR-0003 sections 1, 2, 4,
//! 8 and 9), kept in their own file like `frame_test.zig`. Segment files are in
//! `segment_file_test.zig`.
//!
//! Every expected value is derived independently of the codec: `fx.reference_checksum` rebuilds
//! the ADR section 4 byte string by hand, `fx.forge` lays out headers field by field without any
//! validation (so invalid-but-well-checksummed headers can be built), and the golden header is
//! a committed hex literal copied from ADR section 11.

const std = @import("std");
const testing = std.testing;
const fx = @import("segment_fixtures.zig");
const s = @import("segment.zig");

const Lsn = fx.Lsn;
const header_size = fx.header_size;
const golden_header = fx.golden_header;
const indices_sample = fx.indices_sample;
const lsns_sample = fx.lsns_sample;
const lsn_last = fx.lsn_last;
const canonical = fx.canonical;
const raw_layout = fx.raw_layout;
const reference_checksum = fx.reference_checksum;
const forge = fx.forge;
const header_of = fx.header_of;
const name_of = fx.name_of;
const opts = fx.opts;

// ---------------------------------------------------------------------------------------------
// Names (ADR section 1).
// ---------------------------------------------------------------------------------------------

test "name: format_name writes eight lowercase hex digits" {
    try testing.expectEqualStrings("wal-00000001.log", &name_of(1));
    try testing.expectEqualStrings("wal-0000abcd.log", &name_of(0xabcd));
    try testing.expectEqualStrings("wal-deadbeef.log", &name_of(0xdeadbeef));
    try testing.expectEqualStrings("wal-10000000.log", &name_of(0x10000000));
    try testing.expectEqualStrings("wal-ffffffff.log", &name_of(s.segment_index_max));
    try testing.expectEqual(@as(u32, 16), s.name_size);
}

test "name: parse_name inverts format_name for boundary indices and every digit position" {
    for (indices_sample) |index| {
        const name = name_of(index);
        try testing.expectEqual(@as(?u32, index), try s.parse_name(&name));
    }
    for (0..8) |digit| {
        const shift: u5 = @intCast(digit * 4);
        for ([_]u32{ 1, 9, 10, 15 }) |nibble| {
            const index = nibble << shift;
            const name = name_of(index);
            try testing.expectEqual(@as(?u32, index), try s.parse_name(&name));
        }
    }
}

test "name: parse_name ignores names that do not match exactly" {
    const ignored = [_][]const u8{
        "wal-0000000A.log", // uppercase hex
        "wal-0000000F.log",
        "wal-0000001.log", // 7 digits
        "wal-000000001.log", // 9 digits
        "wal-.log", // no digits
        "wal-00000001.log2", // longer suffix
        "wal-00000001.lo", // shorter suffix
        "wal-00000001.LOG", // uppercase suffix
        "wal-00000001.txt",
        "wal-00000001.log.tmp",
        "wal-00000001.log~",
        "Wal-00000001.log", // prefix case
        "wal_00000001.log", // prefix separator
        "xal-00000001.log",
        "al-00000001.logx", // same length, wrong prefix
        "wal-0000000g.log", // not hex
        "wal-0000 001.log",
        "wal-+0000001.log",
        "wal--0000001.log",
        "wal-0x000001.log",
        "wal-000000\xc3\xa9.log", // multi-byte character, 16 bytes long
        "wal-0000000\x00.log", // NUL in the digits
        "wal-00000001.log\x00", // trailing NUL
        "wal-00000001",
        "00000001.log",
        "wal",
        "wal-",
        ".log",
        "x",
        "wal-00000001.log/",
        "sub/wal-00000001.log",
        "wal-00000000.logx", // index 0 only counts when the whole name matches
    };
    for (ignored) |name| {
        try testing.expectEqual(@as(?u32, null), try s.parse_name(name));
    }
}

test "name: any single corrupted byte of a valid name is ignored" {
    const good = name_of(0x0a1b2c3d);
    try testing.expectEqual(@as(?u32, 0x0a1b2c3d), try s.parse_name(&good));
    for (0..s.name_size) |i| {
        for ([_]u8{ '!', 'G', 'Z', ' ', 0, 0xff }) |bad| {
            var name = good;
            name[i] = bad;
            try testing.expectEqual(@as(?u32, null), try s.parse_name(&name));
        }
    }
}

test "name: a matching name with index 0 is Corrupted, not ignored" {
    try testing.expectError(error.Corrupted, s.parse_name("wal-00000000.log"));
    try testing.expectEqual(@as(?u32, 1), try s.parse_name("wal-00000001.log"));
    try testing.expectEqual(@as(?u32, null), try s.parse_name("wal-0000000.log"));
}

// ---------------------------------------------------------------------------------------------
// Header codec (ADR sections 2, 4 and 8).
// ---------------------------------------------------------------------------------------------

test "header: golden bytes encode, forge and decode identically" {
    const encoded = header_of(1, 1);
    try testing.expectEqualSlices(u8, &golden_header, &encoded);
    try testing.expectEqualSlices(u8, &golden_header, &forge(canonical(1, 1), 1));
    try testing.expectEqual(@as(u32, 0xF9D5E538), reference_checksum(&golden_header, 1));

    const decoded = try s.decode_header(&golden_header, 1);
    try testing.expectEqual(@as(u32, 1), decoded.index);
    try testing.expectEqual(@as(Lsn, 1), decoded.first_lsn);
    try testing.expectEqual(@as(u32, 24), s.segment_header_size);
    try testing.expectEqual(@as(u16, 1), s.format_version);
    try testing.expectEqualSlices(u8, "STWL", &s.magic);
}

test "header: the golden header under index 2 is a ChecksumMismatch" {
    try testing.expectEqual(@as(u32, 0xBF3E9465), reference_checksum(&golden_header, 2));
    try testing.expectError(error.ChecksumMismatch, s.decode_header(&golden_header, 2));
    try testing.expectError(error.ChecksumMismatch, s.decode_header(&golden_header, 0xffffffff));
}

test "header: encode equals the reference and round-trips for the index and lsn boundaries" {
    for (indices_sample) |index| {
        for (lsns_sample) |first_lsn| {
            const out = header_of(index, first_lsn);
            try testing.expectEqualSlices(u8, &forge(canonical(index, first_lsn), index), &out);
            const decoded = try s.decode_header(&out, index);
            try testing.expectEqual(index, decoded.index);
            try testing.expectEqual(first_lsn, decoded.first_lsn);
        }
    }
}

test "header: all-zero input of any length up to 24 is Unwritten" {
    const zeros: [header_size]u8 = @splat(0);
    for (0..header_size + 1) |n| {
        try testing.expectError(error.Unwritten, s.decode_header(zeros[0..n], 1));
    }
    try testing.expectError(error.Unwritten, s.decode_header(&zeros, 0xffffffff));
}

test "header: a non-zero prefix is TornWrite when short, Corrupted when full" {
    const good = header_of(1, 1);
    for (1..header_size) |n| {
        try testing.expectError(error.TornWrite, s.decode_header(good[0..n], 1));
    }
    const leading_zeros = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try testing.expectError(error.TornWrite, s.decode_header(&leading_zeros, 1));
    var one_bit: [header_size]u8 = @splat(0);
    one_bit[23] = 1; // zero except the last byte: not Unwritten, so it must fail to decode
    try testing.expectError(error.Corrupted, s.decode_header(&one_bit, 1));
}

test "header: every single-bit flip is rejected, in ADR order" {
    for ([_]u32{ 1, 0xffffffff }) |index| {
        const good = header_of(index, 24);
        for (0..header_size) |byte| {
            for (0..8) |bit| {
                var bad = good;
                bad[byte] ^= @as(u8, 1) << @intCast(bit);
                // Magic and version (bytes 0..6) are checked before the checksum; every other
                // byte, the reserved field included, is covered by it.
                const want: anyerror = if (byte < 6) error.Corrupted else error.ChecksumMismatch;
                try testing.expectError(want, s.decode_header(&bad, index));
            }
        }
    }
}

test "header: a renamed segment fails with certainty under every other index" {
    for (indices_sample) |base| {
        const image = header_of(base, 1);
        for (0..32) |bit| {
            const other = base ^ (@as(u32, 1) << @intCast(bit));
            if (other == 0) continue;
            try testing.expectError(error.ChecksumMismatch, s.decode_header(&image, other));
        }
        for ([_]u32{ base -% 1, base +% 1 }) |other| {
            if (other == 0 or other == base) continue;
            try testing.expectError(error.ChecksumMismatch, s.decode_header(&image, other));
        }
    }
    const one = header_of(1, 1);
    for (2..2000) |other| {
        try testing.expectError(error.ChecksumMismatch, s.decode_header(&one, @intCast(other)));
    }
}

test "header: a stored index that differs from the expected one is Corrupted when sealed" {
    // The checksum is seeded with the expected index (5) but the stored field says 6.
    const forged = forge(canonical(6, 1), 5);
    try testing.expectError(error.Corrupted, s.decode_header(&forged, 5));
    // The same bytes under their own index fail the seeded checksum instead.
    try testing.expectError(error.ChecksumMismatch, s.decode_header(&forged, 6));
    const consistent = forge(canonical(5, 1), 5);
    try testing.expectEqual(@as(u32, 5), (try s.decode_header(&consistent, 5)).index);
}

test "header: magic and version are Corrupted even when well-checksummed" {
    var fields = canonical(3, 9);
    fields.magic = "STRA".*; // the page magic
    try testing.expectError(error.Corrupted, s.decode_header(&forge(fields, 3), 3));
    fields.magic = "stwl".*;
    try testing.expectError(error.Corrupted, s.decode_header(&forge(fields, 3), 3));
    for ([_]u16{ 0, 2, 0x0100, 0xffff }) |version| {
        fields = canonical(3, 9);
        fields.version = version;
        try testing.expectError(error.Corrupted, s.decode_header(&forge(fields, 3), 3));
    }
}

test "header: a non-zero reserved field is Corrupted when sealed, a mismatch when not" {
    for ([_]u16{ 1, 0x8000, 0xffff }) |reserved| {
        var fields = canonical(3, 9);
        fields.reserved = reserved;
        try testing.expectError(error.Corrupted, s.decode_header(&forge(fields, 3), 3));
        var unsealed = raw_layout(fields);
        std.mem.writeInt(u32, unsealed[12..16], 0x12345678, .little);
        try testing.expectError(error.ChecksumMismatch, s.decode_header(&unsealed, 3));
    }
}

test "header: first_lsn outside [1, 2^63) is Corrupted, the edges are accepted" {
    const bad = [_]Lsn{ 0, 1 << 63, (1 << 63) + 1, std.math.maxInt(u64) };
    for (bad) |first_lsn| {
        const forged = forge(canonical(2, first_lsn), 2);
        try testing.expectError(error.Corrupted, s.decode_header(&forged, 2));
    }
    for ([_]Lsn{ 1, 2, lsn_last }) |first_lsn| {
        const forged = forge(canonical(2, first_lsn), 2);
        try testing.expectEqual(first_lsn, (try s.decode_header(&forged, 2)).first_lsn);
    }
}

test "header: ADR order — magic, then version, then checksum, then reserved" {
    var fields = canonical(4, 4);
    fields.magic = "XXXX".*;
    fields.version = 7;
    var image = forge(fields, 4);
    image[12] ^= 0xff; // also a bad checksum
    try testing.expectError(error.Corrupted, s.decode_header(&image, 4));

    fields = canonical(4, 4);
    fields.version = 7;
    image = forge(fields, 4);
    image[12] ^= 0xff;
    try testing.expectError(error.Corrupted, s.decode_header(&image, 4));

    fields = canonical(4, 4);
    fields.reserved = 1;
    fields.first_lsn = 0;
    image = forge(fields, 4);
    try testing.expectError(error.Corrupted, s.decode_header(&image, 4));
    image[12] ^= 0xff;
    try testing.expectError(error.ChecksumMismatch, s.decode_header(&image, 4));
}

// ---------------------------------------------------------------------------------------------
// Limits (ADR sections 1 and 9).
// ---------------------------------------------------------------------------------------------

test "limits: index_next steps by one and stops at segments_max live segments" {
    const options = opts(.none); // segments_max 8
    try testing.expectEqual(@as(u32, 2), try s.index_next(1, 1, options));
    try testing.expectEqual(@as(u32, 100), try s.index_next(99, 7, options));
    try testing.expectError(error.SegmentLimit, s.index_next(99, 8, options));
    try testing.expectError(error.SegmentLimit, s.index_next(99, 9, options));
    try testing.expectError(error.SegmentLimit, s.index_next(1, 8, options));
    const one: s.Options = .{ .segments_max = 1, .sync_policy = .none };
    try testing.expectError(error.SegmentLimit, s.index_next(1, 1, one));
}

test "limits: index_next past segment_index_max is SegmentIndexExhausted" {
    const options = opts(.none);
    try testing.expectEqual(s.segment_index_max, try s.index_next(0xfffffffe, 1, options));
    try testing.expectError(error.SegmentIndexExhausted, s.index_next(0xffffffff, 1, options));
    // Both limits at once: the permanent one is reported, since a checkpoint cannot fix it.
    try testing.expectError(error.SegmentIndexExhausted, s.index_next(0xffffffff, 8, options));
}

test "limits: live_count_check allows up to segments_max and no more" {
    const options = opts(.none);
    try s.live_count_check(0, options);
    try s.live_count_check(1, options);
    try s.live_count_check(8, options);
    try testing.expectError(error.SegmentLimit, s.live_count_check(9, options));
    try testing.expectError(error.SegmentLimit, s.live_count_check(0xffffffff, options));
    const big: s.Options = .{ .segments_max = 0xffffffff, .sync_policy = .none };
    try s.live_count_check(0xffffffff, big);
}
