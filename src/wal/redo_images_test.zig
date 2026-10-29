//! Contract tests for `PageRedo` on `page_images` frames (plan 005 item 9, ADR-0004 section 9):
//! every image is applied under the `page_image` rules (restore a damaged page, skip a page at
//! or past the frame's lsn, grow the file, re-stamp with `frame.lsn`), the whole frame is
//! validated before anything is grown or written, stats count per image, and replaying a log
//! twice equals replaying it once through the real `Recovery.replay`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const fault_io = @import("../testing/fault_io.zig");
const fx = @import("../page/manager_fixtures.zig");
const frame = @import("frame.zig");
const rx = @import("redo_fixtures.zig");
const wfx = @import("writer_fixtures.zig");

const Env = rx.Env;
const Spec = rx.Spec;

const prefix_size: usize = 8;
const id_size: usize = 4;

/// Offset of entry `index`'s id in a payload at page size `size`.
fn entry_at(size: u32, index: usize) usize {
    assert(size >= 512);
    assert(index < 64);
    return prefix_size + index * (id_size + size);
}

/// A two-entry `page_images` payload: page `id_a` with `seed_a`, then `id_b` with `seed_b`.
fn pair(size: u32, id_a: u32, seed_a: u32, id_b: u32, seed_b: u32) ![]u8 {
    assert(size >= 512);
    assert(id_a != id_b);
    const specs = [_]Spec{ .{ .id = id_a, .seed = seed_a }, .{ .id = id_b, .seed = seed_b } };
    return rx.images_payload(size, &specs);
}

/// Applies a `page_images` frame expecting `want`, and checks that nothing changed: the stats,
/// the page count and the bytes of the whole page file.
fn expect_untouched(env: *Env, want: anyerror, lsn: frame.Lsn, payload: []const u8) !void {
    assert(lsn >= frame.lsn_first);
    assert(@intFromError(want) != 0);
    const before = try env.snapshot();
    defer testing.allocator.free(before);

    const stats = env.redo.stats;
    const count = env.pm.page_count;
    const got = env.apply_with(testing.io, .page_images, lsn, payload);
    try testing.expectError(want, got);
    try testing.expectEqual(stats, env.redo.stats);
    try testing.expectEqual(count, env.pm.page_count);
    const after = try env.snapshot();
    defer testing.allocator.free(after);

    try testing.expectEqualSlices(u8, before, after);
}

test "redo images: every image is applied, stamped with the frame lsn, counted per image" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 8);
        defer env.deinit();

        const payload = try rx.images_payload(size, &.{
            .{ .id = 2, .seed = 21 },
            .{ .id = 5, .seed = 51 },
            .{ .id = 7, .seed = 71 },
        });
        defer testing.allocator.free(payload);

        try env.apply_with(testing.io, .page_images, 90, payload);
        try env.expect_page(2, 21, 90);
        try env.expect_page(5, 51, 90);
        try env.expect_page(7, 71, 90);
        try env.expect_stats(3, 0, 0);
        try fx.expect_read_error(&env.pm, 3, error.Unwritten); // Pages between stay as they were.
        try fx.expect_page0_intact(&env.pm, 8);
    }
}

test "redo images: a page past page_count grows the file once for the whole frame" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 2);
        defer env.deinit();

        const payload = try rx.images_payload(size, &.{
            .{ .id = 1, .seed = 1 },
            .{ .id = 4, .seed = 4 },
            .{ .id = 9, .seed = 9 },
        });
        defer testing.allocator.free(payload);

        try env.apply_with(testing.io, .page_images, 12, payload);
        try testing.expectEqual(@as(u32, 10), env.pm.page_count);
        try testing.expectEqual(@as(u64, size) * 10, try env.pm.file.length(testing.io));
        try env.expect_page(1, 1, 12);
        try env.expect_page(4, 4, 12);
        try env.expect_page(9, 9, 12);
        try fx.expect_read_error(&env.pm, 6, error.Unwritten);
        try fx.expect_page0_intact(&env.pm, 10);
        try env.expect_stats(3, 0, 0);
    }
}

test "redo images: damaged and older pages are redone, newer and equal pages are skipped" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 6);
        defer env.deinit();

        try env.put_page(1, 5, 100); // Newer than the frame: skipped.
        try env.put_page(2, 5, 60); // Equal: skipped.
        try env.put_page(3, 5, 40); // Older: redone.
        try env.put_page(4, 5, 500); // Newer, but damaged: redone.
        try env.damage(4, .flip_body);
        // Page 5 was never written: redone.
        const payload = try rx.images_payload(size, &.{
            .{ .id = 1, .seed = 6 },
            .{ .id = 2, .seed = 6 },
            .{ .id = 3, .seed = 6 },
            .{ .id = 4, .seed = 6 },
            .{ .id = 5, .seed = 6 },
        });
        defer testing.allocator.free(payload);

        try env.apply_with(testing.io, .page_images, 60, payload);
        try env.expect_page(1, 5, 100);
        try env.expect_page(2, 5, 60);
        try env.expect_page(3, 6, 60);
        try env.expect_page(4, 6, 60);
        try env.expect_page(5, 6, 60);
        try env.expect_stats(3, 2, 0);
    }
}

test "redo images: applying the same frame twice equals once and the second pass skips" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 1);
        defer env.deinit();

        const payload = try pair(size, 3, 3, 4, 4);
        defer testing.allocator.free(payload);

        try env.apply_with(testing.io, .page_images, 33, payload);
        const once = try env.snapshot();
        defer testing.allocator.free(once);

        try env.apply_with(testing.io, .page_images, 33, payload);
        const twice = try env.snapshot();
        defer testing.allocator.free(twice);

        try testing.expectEqualSlices(u8, once, twice);
        try env.expect_stats(2, 2, 0);
    }
}

test "redo images: a frame with any bad entry is Corrupted and nothing is grown or written" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 3);
        defer env.deinit();

        // The first entry is fine and needs growth; the bad entry comes second.
        const good = try pair(size, 6, 1, 8, 2);
        defer testing.allocator.free(good);

        const second = entry_at(size, 1);
        const mutable = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(mutable);

        std.mem.writeInt(u32, mutable[second..][0..4], 6, .little); // Repeated.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        std.mem.writeInt(u32, mutable[second..][0..4], 5, .little); // Unsorted.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        std.mem.writeInt(u32, mutable[second..][0..4], 0, .little); // Page 0.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        @memcpy(mutable, good);
        mutable[second + id_size] ^= 1; // Magic of the second image.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        @memcpy(mutable, good);
        mutable[second + id_size + 4] = 1; // A page type that is only legal at page 0.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        @memcpy(mutable, good);
        std.mem.writeInt(u32, mutable[0..4], 3, .little); // Count beyond the bytes.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        std.mem.writeInt(u32, mutable[0..4], 1, .little); // Count short of the bytes.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        std.mem.writeInt(u32, mutable[0..4], 0, .little); // Count 0.
        try expect_untouched(&env, error.Corrupted, 10, mutable);
        try expect_untouched(&env, error.Corrupted, 10, good[0 .. good.len - 1]); // Truncated.
        try expect_untouched(&env, error.Corrupted, 10, good[0..7]); // Under the prefix.
        try expect_untouched(&env, error.Corrupted, 10, good[0..0]); // Empty.
    }
}

test "redo images: a page size that differs from the manager's is Corrupted" {
    for (rx.sizes_all) |size| {
        var env: Env = undefined;
        try env.init(size, 3);
        defer env.deinit();

        const wrong: u32 = if (size == 512) 1024 else size / 2;
        const other = try pair(wrong, 2, 1, 3, 2);
        defer testing.allocator.free(other);

        try expect_untouched(&env, error.Corrupted, 10, other);
        const lied = try rx.images_payload(size, &.{.{ .id = 2, .seed = 1 }});
        defer testing.allocator.free(lied);

        std.mem.writeInt(u32, lied[4..8], wrong, .little); // Header says one size, bytes another.
        try expect_untouched(&env, error.Corrupted, 10, lied);
        std.mem.writeInt(u32, lied[4..8], 1000, .little); // Not a page size at all.
        try expect_untouched(&env, error.Corrupted, 10, lied);
    }
}

test "redo images: growth past the file limit is Failed before any image is written" {
    var env: Env = undefined;
    try env.init(512, 3);
    defer env.deinit();

    const ids = [_]u32{ rx.page_count_max, std.math.maxInt(u32) };
    for (ids) |last| {
        const specs = [_]Spec{ .{ .id = 2, .seed = 1 }, .{ .id = last, .seed = 2 } };
        const payload = try rx.images_payload(512, &specs);
        defer testing.allocator.free(payload);

        try expect_untouched(&env, error.Failed, 10, payload);
        try fx.expect_read_error(&env.pm, 2, error.Unwritten);
    }
    try env.expect_stats(0, 0, 0);
}

test "redo images: an I/O error is Failed and the stats count only the images done" {
    var env: Env = undefined;
    try env.init(512, 4);
    defer env.deinit();

    const payload = try pair(512, 1, 1, 2, 2);
    defer testing.allocator.free(payload);

    var writes: fault_io.FaultIo = undefined;
    const plan: fault_io.Plan = .{ .write = .canceled, .read = .none, .after_calls = 0 };
    fault_io.FaultIo.init(&writes, testing.io, plan);
    const got = env.apply_with(writes.io(), .page_images, 9, payload);
    try testing.expectError(error.Failed, got);
    try env.expect_stats(0, 0, 0);
    try env.apply_with(testing.io, .page_images, 9, payload); // The retry works.
    try env.expect_stats(2, 0, 0);
}

test "redo images: replaying a log with page_images frames twice equals once" {
    for ([_]u32{ 512, 4096, 65536 }) |size| {
        var once: Env = undefined;
        try once.init(size, 1);
        defer once.deinit();

        const first = try pair(size, 2, 1, 4, 2);
        defer testing.allocator.free(first);

        const second = try pair(size, 3, 3, 4, 4);
        defer testing.allocator.free(second);

        var lsns: [3]frame.Lsn = undefined;
        {
            var w: wfx.Writer = undefined;
            try wfx.open_ok(&w, once.tmp.dir, wfx.opts(4, 1 << 20));
            defer w.deinit(testing.io, testing.allocator);

            lsns[0] = try w.append(testing.io, .page_images, first);
            lsns[1] = try w.append(testing.io, .record, "note");
            lsns[2] = try w.append_parts(testing.io, .page_images, &.{ second[0..9], second[9..] });
            try w.sync(testing.io);
        }
        const result = try once.replay(once.tmp.dir);
        try testing.expectEqual(lsns[2], result.last_lsn);
        try once.expect_stats(4, 0, 1);
        try once.expect_page(2, 1, lsns[0]);
        try once.expect_page(3, 3, lsns[2]);
        try once.expect_page(4, 4, lsns[2]);

        const image_once = try once.snapshot();
        defer testing.allocator.free(image_once);

        _ = try once.replay(once.tmp.dir);
        try once.expect_stats(4, 4, 2); // The second pass applied nothing.
        const image_twice = try once.snapshot();
        defer testing.allocator.free(image_twice);

        try testing.expectEqualSlices(u8, image_once, image_twice);
    }
}
