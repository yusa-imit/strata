# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/) with the 0.x exception noted in
`citadel/protocol/VERSIONING.md` (MINOR may break during 0.x).

## [Unreleased]

### Added
- `btree/delete_tree.zig`: `Tree.delete` removes a key, borrows from or merges with a sibling on
  byte-fill underflow, collapses a one-child root into the fixed root id, and queues freed pages
  in a bounded `frees_pending` handed to the page manager only by `Tree.release_frees`;
  `BufferPool.discard` drops a freed page's frame.
- `btree/split_tree.zig`, `btree/descend.zig`, `btree/validate.zig`: `Tree.insert` splits full
  leaves and internal nodes (root id fixed, `error.HeightLimit`), `get` descends from the root,
  and `Tree.validate(io, gpa)` checks order, separator bounds, levels, leaf links and sharing.
  `Tree.insert` no longer returns `NodeFull`.
- ADR-0004 `docs/adr/0004-btree-format.md`: B+Tree page format v1 (page types 16–18, slotted
  layout, per-page-size limits, one-frame-per-op logging, deferred frees).
- `btree/node.zig`: B+Tree leaf codec (`parse_leaf`, `Leaf.entry/search`, `leaf_insert`,
  `leaf_remove`) with the ADR-0004 limits; page types `btree_leaf`, `btree_internal` and
  `btree_overflow` (16–18) are now legal in `page/header.zig`.
- `btree/internal.zig`: B+Tree internal-node codec (`parse_internal`, `format_internal`,
  `Internal.entry/child_index/child_at`, `internal_insert`, `internal_remove`, `set_child`,
  `set_right_child`) and `btree/split.zig`: byte-balanced `split_point` for leaf and internal
  nodes.
- `btree/tree.zig`: `Tree` over the buffer pool with a fixed root id: `create`, `open`, `get`
  (borrowed slice) and `insert` with overwrite into the root leaf; a full leaf is `NodeFull`
  until splits land. `cache`: `BufferPool.fetchNew(io, id)` pins a just-allocated page
  zero-filled and dirty without reading it (`FetchNewError`).

### Changed
- `Tree.create` and `Tree.open` take a required `frees: []Id` (caller-provided storage for the
  pending-free list). Pending frees are not persisted: ids still pending when the process
  stops are lost until a later recovery item, so call `Tree.release_frees` first.

## [0.5.0] - 2026-10-20

WAL format v1 (`docs/adr/0003-wal-format.md`) is on-disk API from this tag: `wal-NNNNNNNN.log`
segments with a 24-byte header, 17-byte frames, CRC32C seeded with the expected LSN, byte-position
LSNs. A later change to it needs a version bump and migration notes.

### Added

- `wal`: `wal.zig` drops its `NotImplemented` placeholder and re-exports `Frame`, `Reader`,
  `Writer`, `Apply`, `Recovery`, `PageRedo` and `Checkpoint` next to the submodules (plan 004,
  item 12).
- `testing`: `wal_recovery_test.zig` (+ `wal_recovery_fixtures.zig`): seeded crash-recovery
  property over the real WAL writer, buffer pool, checkpoint and redo at 512 B, 4 KiB and 64 KiB
  pages with 12 fixed seeds each. A random op stream runs over a `FaultIo` that cancels writes
  from a random call on, a `CrashSink` truncate or torn cut hits the unsynced tail, and cold
  recovery must replay every acknowledged LSN in order, invent nothing, leave every page equal
  to the model and replay idempotently. Checked by hand, not by a committed test: a redo that
  never applies fails it at every page size, the pool gate switched off fails it at 64 KiB.
- `wal`: `wal.checkpoint`, `Checkpoint.run`: sharp checkpoint (commit a `checkpoint` frame at `C`,
  `flushAll` with the pool bound at `C`, page sync, `set_wal_lsn(C)`, sync) and reclaim of the
  segments wholly below `C` (ascending, never the active one, one directory sync); a sync
  fences each step, so a crash anywhere recovers from the old or the new `wal_lsn`.
  `checkpoint.redo_start` derives the replay start from `wal_lsn` (0 = whole log, else the
  intact `checkpoint` frame there, else `Corrupted`). `Writer.oldest_index` and
  `Writer.segments_reclaimed` keep `live_count` true after a reclaim; `reclaim` deletes only
  below the last checkpoint whose step 5 returned (`NotCheckpointed` otherwise). "Old or new
  `wal_lsn`" relies on atomic 512 B sector writes for page 0 (ADR-0003 open question 6)
  (plan 004, item 10).
- `cache`: `BufferPool.dirty_lsn_max()`. `testing`: `FaultIo` `Plan.delete_fail_after` and
  forwarded, counted file deletion.
- `page`: `PageManager.set_wal_lsn(io, lsn)` rewrites page 0 with the checkpoint LSN
  (monotonic; the caller syncs).
- `wal`: `wal.redo`, `PageRedo`: an `Apply` target that restores a `page_image` frame through
  `PageManager` when the page is torn, unwritten or has `lsn < frame.lsn` (else skips), re-stamps
  it with `lsn = frame.lsn`, grows the file for a page id past `page_count`, ignores other frame
  types; page 0, a size mismatch or a bad image is `Corrupted`, I/O errors and the file limit
  are `Failed` (plan 004, item 9).
- `page`: `PageManager.ensure_page_count(io, count)` grows the file to `count` pages without
  touching the freelist (new pages read as `Unwritten`); `NoSpaceLeft` past `page_count_max`.
- `cache`: WAL-before-data gate on `BufferPool`: `set_durable_lsn(lsn)` (no `io`, cannot fail,
  monotonic) turns it on; eviction and `flushAll` then skip dirty frames whose page lsn is above
  the bound and leave them dirty; eviction scans past them, all victims pinned or gated is
  `PoolExhausted`; `flushAll` skips without error and counts them in the new `Stats.gated`. Off
  until the first call, so existing callers see no change (plan 004, item 8).
- `wal`: `wal.recovery`, `Recovery.replay`: reads the log from `from_lsn` (skipping and checking
  earlier frames; `Corrupted` when no frame starts there), applies each intact frame through an
  `Apply` vtable, truncates a torn tail (`setLength` + sync) or deletes a partial newest header
  (+ directory sync), never repairs `ChecksumMismatch`/`Corrupted`; returns the last intact LSN
  (plan 004, item 7).
- `docs`: ADR-0003, WAL format v1 (24-byte segment header, 17-byte frames with a CRC32C seeded
  by LSN, byte-position LSNs, torn-tail rule, golden bytes); PRD §4.5 links it and uses
  eight-hex-digit segment names (plan 004, item 1).
- `wal`: `wal.frame`, the WAL frame codec (17-byte header, CRC32C seeded with the expected
  LSN, `record`/`page_image`/`checkpoint` types, typed `TornWrite`/`ChecksumMismatch`/
  `Corrupted`; golden bytes pinned from ADR-0003 section 11). The truncation matrix now sweeps
  real WAL frames instead of a test-only stand-in (plan 004, item 2).
- `wal`: `wal.segment`, WAL segment files (`wal-` + 8 hex digits + `.log` names, 24-byte
  header with an index-seeded CRC32C, exclusive `create`, locked `open` with typed
  `Unwritten`/`TornWrite`/`ChecksumMismatch`/`Corrupted`, positional `append`, and the typed
  `SegmentLimit`/`SegmentIndexExhausted` limits; golden header pinned from ADR-0003 section 11;
  the directory sync stays an open item, ADR-0003 question 4) (plan 004, item 3).
- `wal`: `wal.reader`, sequential WAL read across segments (`Reader.open` lists and validates
  the directory, bounded by `segments_max`, with index and first-LSN continuity; `next` crosses
  segments and returns frames in order, `null` only at a clean end; ADR-0003 section 8 torn-tail
  rule with its bounded look-ahead, `TornWrite` only in the newest segment; one `gpa`
  allocation in `open`, none after); the next segment is opened (and locked) before the
  previous one is closed, and a failure closes the current segment (plan 004, item 4).
- `wal`: `wal.writer`, the WAL appender (`Writer.init` finds the tail through `Reader`,
  creates segment 1 in an empty directory, rewrites an `Unwritten` newest segment and refuses
  a torn tail with `RecoveryRequired`; `append` frames one record at a time and rotates at
  `segment_bytes_max`, `sync` moves the inclusive, prefix-closed `durable_lsn` only after the
  file sync succeeded; a failed write or sync latches the writer (`Failed`) until reopened;
  typed `PayloadTooLarge`, `InvalidFrame`, `LsnExhausted`, `SegmentLimit`,
  `SegmentIndexExhausted`; one `gpa` allocation in `init`, none after). `file/platform.zig`
  gains `sync_dir`, called after every segment create (ADR-0003 open question 4), and
  `testing.fault_io` can fail syncs (`Plan.sync_fail_after`) (plan 004, item 5).
- `wal`: `Writer.commit(io, upto)`, group commit (`wal/group_commit.zig`): the first committer
  whose LSN is not durable leads, waits `group_commit_window` (`io.sleep`) unless
  `group_commit_bytes_max` bytes are pending, syncs once and wakes the followers through
  `Io.Mutex`/`Io.Condition`; a failed leader sync returns its error to the whole batch and
  latches the writer; `error.Canceled` stays in `CommitError`; `Writer.stats` counts `syncs`
  and `commits`; no allocation, no `io.concurrent`. `testing.fault_io` forwards the futex and
  `sleep` slots (plan 004, item 6).

## [0.4.0] - 2026-10-13

### Added

- `bench`: `pool_hit` and `pool_miss_evict` (fetch + release at 4 KiB over a scratch file;
  about 197 M ops/s on a hit, 1.26 M ops/s on a miss with clean eviction, Apple aarch64) in
  `bench/pool.zig` (plan 003, item 10).
- `cache`: dirty tracking and write-back. `fetchForUpdate` returns a writable `PageGuard`
  (`bytes_mut`, `markDirty`, `set_lsn`, none take `io` or can fail); dirty victims are written
  back inside eviction before their table entry goes, and a failed write-back surfaces from
  `fetch` with the frame still resident and dirty; `flushAll`, `discardAll`, `Stats.writebacks`;
  `deinit` asserts zero dirty frames. `PageGuard` moves to `cache/guard.zig`. `page.header` gains
  `peek` and `poke_lsn` for in-memory pages (plan 003, item 8).
- `cache.buffer_pool`: CLOCK `BufferPool` over a `PageManager` (`init`/`deinit`/`fetch`/`stats`),
  read-only `PageGuard` (`bytes`/`id`/`release`), `PoolExhausted` when every frame is pinned;
  all buffers allocated in `init` (plan 003, item 7).
- `page.manager`: `allocate` (pop the freelist or grow the file up to `page_count_max`, then
  `NoSpaceLeft`), `free` (push, spilling into a new trunk) and `sync`; ids read from disk are
  range-checked and a bad head trunk is `Corrupted`/`ChecksumMismatch` (plan 003, item 6).
- `page.manager`: `PageManager` `create`/`open`/`read`/`write` over a `file.File` with an
  exclusive lock, ADR-0002 §5 open sequence and typed `Corrupted`/`ChecksumMismatch`/
  `Unwritten`/`TornWrite` errors
  (plan 003, item 5).
- `page.freelist`: trunk-page freelist codec (`format_trunk`, `decode_trunk`, `free`,
  `allocate`, `trunk_capacity`); pure push/pop over the head trunk, spill to a new trunk when
  full, `Corrupted` for bad counts, dead slots and self-links (plan 003, item 4).
- `page.header`: page header and page-0 file header codecs with the page-id-seeded CRC32C,
  `Unwritten`/`Corrupted`/`ChecksumMismatch` decode errors and `peek_page_size` for open
  (plan 003, item 3).
- ADR-0002 fixes on-disk page format v1: 24-byte page header, CRC32C seeded with the page id,
  `u32` page ids, page-0 file header, `Unwritten` decode for zero pages, and a trunk-page
  freelist (plan 003, item 2).
- `tidy` bans `Io.Threaded`, `Io.Evented` and `global_single_threaded` under `src/` and
  restricts `Io` struct fields (ADR-0001; plan 003, item 1).

## [0.3.0] - 2026-10-05

### Added

- `codec.fixed`: bounds-checked little-endian `u16`/`u32`/`u64` `read`/`write` over caller
  buffers (`error.BufferTooSmall`), and `codec.varint`: canonical LEB128 `u64` plus zigzag
  `i64` with a 10-byte cap and typed `Truncated`/`Overlong`/`BufferTooSmall` errors (plan 002,
  item 2).
- `codec.crc32c`: Castagnoli CRC32C with `checksum`, a streaming `Hasher`, and a named
  `Path` (`software` table-driven, `hardware` SSE4.2/ARMv8). The hardware path is chosen at
  compile time from the target CPU features (`-Dcpu=`), so a generic x86_64 build runs the
  software path (plan 002, item 3).
- `codec.xxhash`: asserted XXH64 wrapper (`hash`, streaming `Hasher`) with a frozen digest
  spelling, 8 little-endian bytes via `digest_write`/`digest_read`. The seed is part of any
  persisted format and has no default. Checked against published vectors and an independent
  from-the-spec reference (plan 002, item 4).
- `file.file`: `File` leaf value over `std.Io` with `open`, `close`, `readAt`/`readAtAll`,
  `writeAt`/`writeAtAll`, `length` and `setLength`, plus `SyncPolicy` and `OpenOptions`. Short
  reads return the count, `readAtAll` past EOF is `error.UnexpectedEof`, `direct` is
  `error.UnsupportedDirectIo` until a later item; truncation happens after the requested lock
  is held.
- `file.file` durability: `File.sync` dispatches on `SyncPolicy` (`none` is a no-op, `fdatasync`
  on Linux, `fsync`, and `F_FULLFSYNC` on macOS with a fallback only for filesystems that do not
  support it; real I/O errors are never downgraded). `File.preallocate` grows without ever
  shrinking (`fallocate` with keep-size on Linux, `F_PREALLOCATE` on macOS, then `setLength`).
  `File.lock`/`tryLock`/`unlock` wrap the `Io` file locks; a contended `tryLock` returns
  `error.WouldBlock`. Platform branching lives only in `src/file/platform.zig` (plan 002
  item 6).
- `testing.crash`: `CrashSink`, a positional `writeAt` sink that persists only what survives a
  `Cut` (`truncate` after N bytes, or `torn` inside a 512-byte sector with seeded garbage in the
  rest of the sector), and `TruncationPoints`, an iterator over all `len + 1` cut points under a
  `count_max` bound. `testing.fault_io`: `FaultIo`, an `Io` wrapper that injects short, zero-count
  and `error.Canceled` positional reads and writes, to exercise `File.writeAtAll`/`readAtAll`
  loops. Simulated cuts are a floor, not a proof of power-loss safety (plan 002, item 7).
- Truncation matrix (test-only): a CRC32C-framed record is replayed through `CrashSink` at every
  truncation and torn cut, for record sizes spanning 8 B to 64 KiB around the 512-byte sector
  boundary; each damaged prefix must be `TornWrite` or `ChecksumMismatch`, and a decoder that
  skips the checksum fails the sweep (plan 002, item 8).
- Codec benchmark baseline: `zig build bench -- [filter]` measures CRC32C (software, and
  hardware when the target CPU has it), xxhash64 and varint encode/decode over seeded inputs
  and prints GB/s, ops/s and ns/op per line. The harness's kernels and report formatting are
  also unit-tested by `zig build test` (plan 002, item 9).

### Changed

- Dropped the `NotImplemented` placeholder error from `codec`, `file` and `testing`: each landed
  module's real surface carries its own typed errors. The seven Phase 2+ stubs keep it.
  `strata.version` now reports 0.3.0 (it had stayed at 0.1.0 through v0.2.0).
- `tools/tidy.zig` split into `tools/tidy/*.zig` modules, each under the 800-line limit, and
  `tools` joins tidy's `scan_roots`, so the lint now lints itself with no exemption (plan 002,
  item 1). `zig build test` now also runs tidy's own unit tests.

## [0.2.0] - 2026-09-16

### Changed

- Migrated to Zig 0.16.0 (plan 001, items 4/7): `src/main.zig` now takes
  `init: std.process.Init` and threads `io: std.Io` through its filesystem/stdout calls
  (`argsAlloc`/`argsFree` → `init.minimal.args.toSlice`, `GeneralPurposeAllocator` →
  `init.arena`, `std.fs.File.stdout()` → `std.Io.File.stdout()`). `tools/tidy.zig` and
  `bench/main.zig` needed the same rewrite (`std.fs.Dir` → `std.Io.Dir`, `std.fs.cwd()` →
  `std.Io.Dir.cwd()`, `std.posix.exit` → `std.process.exit`, `std.time.Timer` →
  `std.Io.Clock.Timestamp`, `mem.indexOf` → `mem.find`) since both are compiled as part of
  `zig build test`/`zig build bench`. The library (`src/root.zig` and its ten stub modules)
  needed no changes — already 0.16-clean. `build.zig.zon` `.minimum_zig_version` is now
  `"0.16.0"`; CI no longer pins a Zig version, resolving it from the manifest instead.

### Fixed

- `src/root.zig` doc comment pointed at `docs/milestones.md`, renamed to
  `docs/plans/000-inherited.md`; now points at `docs/plans/`.
- README/CHANGELOG reconciled with reality (plan 001, item: README/CHANGELOG reconciled):
  Zig badge `0.15.x` → `0.16.x`; the module table now labels all ten modules `Planned`
  (none are landed — every one is still a stub); the install snippet pointed at a `v0.1.0`
  tag that was never published, repointed at the eventual `v0.2.0`.

### Added

- This changelog.
- `tools/tidy.zig`: kingdom `tidy` lint, shape checks (line length ≤ 100 Unicode code
  points, every `.zig` file under `src/` opens with a `//!` doc header). Wired into
  `zig build test` via a new `zig build tidy` step so it cannot be skipped.
- `tools/tidy.zig`: function-length ratchet (≤ 70 lines clean, 71–72 tolerated only via
  a shrink-only exception table in `tools/tidy_baseline.txt`, 73+ always fails); ban
  list (`catch unreachable` without a `// proof:` comment, `std.debug.print` outside
  `src/main.zig`/`bench/`, `std.time.*` in `src/` outside `src/main.zig`); a
  strata-specific `// wire-format`-scoped check banning `usize` inside on-disk format
  structs (fixed-width `u32`/`u64` only).
- `tools/tidy.zig`: ban list extended (plan 001, item 5 — 0.16 library sweep, frozen) with
  5 more 0.15-only spellings, confirmed absent from `src`/`bench`/`tests` by the sweep: a
  bare `ArrayList` `.{}` init instead of `.empty`, `mem.indexOf`/`mem.lastIndexOf` instead
  of `mem.find`/`mem.findLast`, `std.net.*`, every removed `std.Thread.*` sync primitive
  (`Mutex`/`Condition`/`Semaphore`/`RwLock`/`ResetEvent`/`WaitGroup`/`Pool`), and
  `fs.cwd()` instead of `Io.Dir.cwd()`.
- `src/testing.zig`: a real `std.testing.tmpDir` round-trip test (plan 001, item: 0.16
  tests) — writes and reads back a file through `std.testing.io` and the 0.16 `Io.Dir`
  API, plus a negative-space check that a missing file returns `error.FileNotFound`.
  The first I/O-touching test in the repo (the prior 12 were `refAllDecls` compile-checks
  only); exercises the `Io` + `tmpDir` harness before `src/file.zig` needs it in Phase 1A.
- `docs/adr/0001-io-injection.md` (plan 001, item: `io: Io` convention in the public API):
  strata never constructs an `Io`; exactly one type, `kv.Db`, caches it (set once at
  `open`, never reassigned) — every other module takes `io: Io` per call, first parameter
  after the receiver (first parameter for no-receiver constructors). `docs/PRD.md` §4.2 and
  §4.4–§4.9 rewritten to match: `file`/`page`/`cache`/`wal`/`btree`/`lsm` signatures now sit
  on `Io.Dir`/`Io.File` instead of `std.fs`; `snapshot.Writer`/`Reader` take `*Io.Writer`/
  `*Io.Reader` instead of `anytype`. Binding on all of Phase 1–6 implementation to come.
- `tools/tidy.zig`: assertion-density check (plan 001, item: assertion baseline) — every
  `src/` file with at least one function-with-a-body must average ≥ 2 assertions
  (`assert(`/`assert_always(`, ignoring `//` comment text) per function; a stub file with
  no such function is silent. `zig build test`/`zig build tidy` now print a per-file
  density report unconditionally, so the figure stays visible as Phase 1 code lands.
  `src/main.zig`'s `main` gets a paired precondition/postcondition assertion on `args` as
  the worked example (today's only real function body in `src/`).
- `tools/tidy.zig`: file-length check (the 800-line hard limit from
  `citadel/core/rules/tiger-style.md`'s mechanical checks table, previously unenforced
  locally) — a whole-file check wired into `lintFile` alongside the other per-file checks.
  No baseline exemption: a file over 800 lines fails outright. `tools/` itself stays
  outside `scan_roots` (`src`, `bench`, `tests` only), so `tools/tidy.zig` — now past 800
  lines itself — is not yet checked by its own rule; tracked as a known gap in STATE.md.
