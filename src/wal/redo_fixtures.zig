//! Shared fixtures for the `redo.zig` contract tests (`redo_test.zig`): an `Env` that owns a
//! temporary directory, a `PageManager` over a fresh page file and a `PageRedo` on it; builders
//! for `page_image` payloads (with a deliberately stale header checksum), page damage helpers
//! that work on the raw file, and a WAL writer wrapper for replay tests. Test-only; I/O through
//! `std.testing.io`, memory through `std.testing.allocator`.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Io = std.Io;
const fixtures = @import("../file/file_fixtures.zig");
const header = @import("../page/header.zig");
const fx = @import("../page/manager_fixtures.zig");
const manager = @import("../page/manager.zig");
const frame = @import("frame.zig");
const recovery = @import("recovery.zig");
const rfx = @import("recovery_fixtures.zig");
const redo = @import("redo.zig");
const wfx = @import("writer_fixtures.zig");

pub const sizes_all = fx.sizes_all;
pub const page_count_max = fx.page_count_max;
pub const consumer_type = fx.consumer_type;

const file_name = "pages.db";
const payload_id_size: u32 = 4;

/// How a page on disk is damaged before redo.
pub const Damage = enum { flip_body, flip_magic, zeroed, cut_short };
pub const damages = [_]Damage{ .flip_body, .flip_magic, .zeroed, .cut_short };

/// A temporary directory (it also holds WAL segments), a page file and a `PageRedo` on it.
/// Initialised in place: `redo` points at `pm`.
pub const Env = struct {
    tmp: testing.TmpDir,
    pm: manager.PageManager,
    redo: redo.PageRedo,
    size: u32,

    /// A file of `page_count` pages (1 is page 0 only); the new pages read as `Unwritten`.
    pub fn init(env: *Env, size: u32, page_count: u32) !void {
        assert(header.page_size_valid(size));
        assert(page_count >= 1);
        env.tmp = testing.tmpDir(.{ .iterate = true });
        errdefer env.tmp.cleanup();

        const create_options = fx.opts(size);
        try manager.PageManager.create(&env.pm, testing.io, env.tmp.dir, file_name, create_options);
        errdefer env.pm.close(testing.io);

        try env.pm.ensure_page_count(testing.io, page_count);
        try redo.PageRedo.init(&env.redo, testing.allocator, &env.pm);
        env.size = size;
    }

    pub fn deinit(env: *Env) void {
        assert(env.redo.buf.len == env.size);
        assert(env.pm.page_size == env.size);
        env.redo.deinit(testing.allocator);
        env.pm.close(testing.io);
        env.tmp.cleanup();
    }

    /// Applies one frame through the vtable with `io`.
    pub fn apply_with(
        env: *Env,
        io: Io,
        frame_type: frame.Type,
        lsn: frame.Lsn,
        payload: []const u8,
    ) recovery.ApplyError!void {
        assert(lsn >= frame.lsn_first);
        assert(env.redo.buf.len == env.size);
        const f: frame.Frame = .{ .lsn = lsn, .frame_type = frame_type, .payload = payload };
        try env.redo.apply_target().apply(io, f);
    }

    /// Applies a `page_image` for page `id` built from `seed`, with `testing.io`.
    pub fn apply_image(env: *Env, id: u32, seed: u32, lsn: frame.Lsn) !void {
        assert(id >= 1);
        assert(lsn >= frame.lsn_first);
        const payload = try image_payload(env.size, id, seed, consumer_type, stale_lsn);
        defer testing.allocator.free(payload);

        try env.apply_with(testing.io, .page_image, lsn, payload);
    }

    pub fn expect_apply_error(
        env: *Env,
        want: recovery.ApplyError,
        lsn: frame.Lsn,
        payload: []const u8,
    ) !void {
        assert(lsn >= frame.lsn_first);
        assert(@intFromError(want) != 0);
        const before = env.redo.stats;
        const got = env.apply_with(testing.io, .page_image, lsn, payload);
        try testing.expectError(want, got);
        try testing.expectEqual(before, env.redo.stats);
    }

    pub fn expect_stats(env: *const Env, applied: u64, skipped: u64, ignored: u64) !void {
        assert(env.redo.buf.len == env.size);
        assert(env.pm.page_size == env.size);
        const want: redo.Stats = .{ .applied = applied, .skipped = skipped, .ignored = ignored };
        try testing.expectEqual(want, env.redo.stats);
    }

    pub fn put_page(env: *Env, id: u32, seed: u32, lsn: u64) !void {
        assert(id >= 1);
        assert(id < env.pm.page_count);
        const buf = try testing.allocator.alloc(u8, env.size);
        defer testing.allocator.free(buf);

        try fx.write_pattern(&env.pm, id, buf, seed, lsn);
    }

    pub fn expect_page(env: *Env, id: u32, seed: u32, lsn: u64) !void {
        assert(id >= 1);
        assert(id < env.pm.page_count);
        try fx.expect_pattern(&env.pm, id, seed, lsn);
    }

    /// Damages page `id` on disk. `cut_short` ends the file inside the page: `id` must be last.
    pub fn damage(env: *Env, id: u32, kind: Damage) !void {
        assert(id >= 1);
        assert(id < env.pm.page_count);
        const base = @as(u64, env.size) * id;
        switch (kind) {
            .flip_body => try fx.flip_byte(env.pm.file, base + header.header_size + 1),
            .flip_magic => try fx.flip_byte(env.pm.file, base),
            .zeroed => {
                const zeros = try testing.allocator.alloc(u8, env.size);
                defer testing.allocator.free(zeros);

                @memset(zeros, 0);
                try env.pm.file.writeAtAll(testing.io, zeros, base);
            },
            .cut_short => {
                assert(id + 1 == env.pm.page_count);
                try env.pm.file.setLength(testing.io, base + env.size / 2);
            },
        }
    }

    /// The raw bytes of the whole page file, owned by the caller.
    pub fn snapshot(env: *Env) ![]u8 {
        assert(env.pm.page_count >= 1);
        const length: usize = @intCast(try env.pm.file.length(testing.io));
        assert(length >= env.size);
        const bytes = try testing.allocator.alloc(u8, length);
        errdefer testing.allocator.free(bytes);

        try env.pm.file.readAtAll(testing.io, bytes, 0);
        return bytes;
    }

    /// Replays the WAL in `dir` from the first frame into this env's `PageRedo`.
    pub fn replay(env: *Env, dir: Io.Dir) recovery.ReplayError!recovery.Result {
        assert(env.redo.buf.len == env.size);
        assert(env.pm.page_count >= 1);
        const opts = rfx.options(0, 4, .none);
        return recovery.Recovery.replay(
            testing.io,
            testing.allocator,
            dir,
            env.redo.apply_target(),
            opts,
        );
    }
};

/// Header lsn of every image the builders make: not any real lsn, and its checksum is stale.
pub const stale_lsn: u64 = 0x7777_0000_0000_0001;

/// A `page_image` payload for page `id` at page size `size`: the id, then a page whose payload
/// is `pattern(seed)` and whose header lsn was poked after the checksum was stamped. Owned.
pub fn image_payload(
    size: u32,
    id: u32,
    seed: u32,
    page_type: header.Type,
    lsn_in_image: u64,
) ![]u8 {
    assert(header.page_size_valid(size));
    assert(id >= 1);
    const payload = try testing.allocator.alloc(u8, payload_id_size + size);
    std.mem.writeInt(u32, payload[0..payload_id_size], id, .little);
    const page = payload[payload_id_size..];
    @memset(page, 0);
    fixtures.pattern(page[header.header_size..], seed);
    header.encode(page, @enumFromInt(id), .{ .page_type = page_type, .lsn = 1 });
    header.poke_lsn(page, lsn_in_image); // The checksum is now stale.
    assert(payload.len == payload_id_size + size);
    return payload;
}

/// One frame of a test WAL.
pub const Step = union(enum) {
    record,
    image: struct { id: u32, seed: u32 },
};

/// Writes `steps` as frames into a new log in `dir`, closes the writer, and returns the LSN of
/// every step in `lsns`.
pub fn write_log(dir: Io.Dir, size: u32, steps: []const Step, lsns: []frame.Lsn) !void {
    assert(steps.len == lsns.len);
    assert(header.page_size_valid(size));
    var w: wfx.Writer = undefined;
    try wfx.open_ok(&w, dir, wfx.opts(4, 1 << 20));
    defer w.deinit(testing.io, testing.allocator);

    for (steps, lsns) |step, *lsn| switch (step) {
        .record => lsn.* = try w.append(testing.io, .record, "note"),
        .image => |img| {
            const payload = try image_payload(size, img.id, img.seed, consumer_type, stale_lsn);
            defer testing.allocator.free(payload);

            lsn.* = try w.append(testing.io, .page_image, payload);
        },
    };
    try w.sync(testing.io);
}
