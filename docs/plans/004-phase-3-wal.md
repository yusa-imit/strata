# Plan 004 — Phase 3: write-ahead log and crash recovery

## Goal

Land PRD §4.5 `wal` (frame, segment, reader, group-commit writer, recovery, checkpoint) as tested
code, with the pool's WAL-before-data gate and the full-page-image redo ADR-0002 §6 deferred here,
proven by seeded crash-recovery property tests (PRD §6 Phase 3A–3E). Defines strata's second
on-disk format (ADR-0003). Ends with **v0.5.0**.

## Why now

v0.4.0 shipped `page` and `cache`; `wal` is still an `error{NotImplemented}` stub. ROADMAP Phase 2
sets strata's bar at codec + file + page + cache + WAL, which gates the synod `LogStore` adapter,
and the B+Tree (Phase 4) cannot claim durability without redo. Two plan 003 debts come due: page
`lsn`s are ordered against nothing, so the pool may persist a page whose log record is not on
disk; and torn data pages have no repair path (ADR-0002 §6 left full-page images to plan 004).

## Scope

No item is blocked — `.dependencies = .{}`, strata waits on no producer tag. Order follows the
data: format, then the read path (`Writer.init` reuses it to find the tail), then the write path.

- [x] **ADR-0003 — WAL format v1** (`docs/adr/0003-wal-format.md`). Format before bytes
      (REALM.md). Fixes: `wal-NNNNNN.log` naming; segment header (magic, `format_version`, index,
      first LSN, CRC32C); frame `len | crc | lsn | type | payload` widths, CRC32C over every byte
      seeded with the LSN so a stale frame fails; LSN scheme (monotonic `u64`, 0 = none); frame
      types incl. `page_image`, `checkpoint`; torn-tail rule (bad frame at the newest segment's
      tail = truncate point, elsewhere = `Corrupted`, bounded look-ahead); all-zero header = EOF;
      `Reader.next()` null only for EOF (cycle 8); idempotent redo (`frame.lsn > page.lsn`);
      `SyncPolicy` caller-chosen; `io` per call; no allocation after `init`. Verify: ADR merged;
      PRD §4.5 links it.
- [x] **`wal/frame.zig` — frame codec** (`src/wal/`). Pure, no `io`. Typed decode errors:
      `TornWrite` (short image), `ChecksumMismatch`, `Corrupted` (bad type, `len` over
      `frame_bytes_max`). Replaces the stand-in decoder of `truncation_matrix_test.zig`, as its
      doc asks. Verify: golden hex frame; every bit flip of a 64 B frame fails; decode under
      another LSN fails; matrix green with the real decoder, its no-CRC mutant still caught.
- [x] **`wal/segment.zig` — segment files** (`src/wal/`). One segment over `file.File` (no new
      `File` methods: 788/800 lines): header codec, positional append, exclusive `tryLock`,
      index bounded by `Options.segments_max`; no `builtin.os.tag` (REALM.md). Verify: `tmpDir`
      create→close→open; foreign file → `Corrupted`; header bit flip → `ChecksumMismatch`;
      second open → `WouldBlock`; index over the limit → typed error, not an assert.
- [x] **`wal/reader.zig` — sequential read** (`src/wal/`). `open` lists segments (bounded) and
      checks index and first-LSN continuity; `next` crosses segments; frame buffer sized by
      `frame_bytes_max` at `open`. Verify: hand-built segments read back in order; index or LSN
      gap → `Corrupted`; every `CrashSink` cut of a 3-frame segment yields a frame prefix, then
      null or a typed error, never a damaged frame.
- [x] **`wal/writer.zig` — append, sync, rotate** (`src/wal/`). One caller, no batching yet.
      `init` finds the tail via the reader and refuses a torn one (`error.RecoveryRequired`:
      truncation is recovery's job); batch buffer allocated in `init`; `sync` per `SyncPolicy`;
      rotate at `segment_bytes_max`. Verify: reopen continues the LSN; `FaultIo` failing sync
      leaves `durable_lsn` unchanged; `FailingAllocator` armed after `init`; 4 KiB rotation.
- [ ] **Group commit — `Writer.commit`** (`src/wal/writer.zig`). Leader/follower: the first
      committer waits `group_commit_window` (`io.sleep`) or `group_commit_bytes_max`, syncs once,
      wakes followers via `Io.Mutex`/`Io.Condition`. No background flusher, so no `io.concurrent`
      or `ConcurrencyUnavailable` path in library code (ADR-0001 risk); `error.Canceled` stays
      in `CommitError`. Verify: 8 committers under `std.testing.io` → `stats.syncs` < commits,
      each returns with `durable_lsn >= upto`; a failed leader sync reaches its whole batch.
- [ ] **`wal/recovery.zig` — replay** (`src/wal/`). `Recovery.replay` from `options.from_lsn`
      through the §4.5 `Apply` vtable; truncates a torn tail per ADR-0003, returns the last good
      LSN; mid-log damage → `Corrupted`, never a silent skip. Verify: replay twice into a model
      = once (REALM.md idempotence); `Writer.init` succeeds after tail truncation; a bad frame
      followed by a valid one → `Corrupted`.
- [ ] **Pool WAL-before-data gate** (`src/cache/`). Safety: today a page whose `lsn` is past the
      durable WAL can be written back, and a crash leaves a page no log explains. Add
      `set_durable_lsn` (no `io`, cannot fail); write-back skips frames with `lsn` above it and
      leaves them dirty; all victims skipped → `PoolExhausted`. Off until first set, so v0.4
      callers see no change. Verify: scripted eviction skips the frame; `flushAll` leaves it
      dirty until the bound moves; 8-size matrix green.
- [ ] **Full-page-image redo** (`src/wal/redo.zig`). ADR-0002 §6's torn-page repair: a
      `PageRedo` `Apply` target writes a `page_image` frame through `PageManager` when the page
      fails to decode or has `lsn < frame.lsn`, else skips. When to log an image is the B+Tree's
      call (plan 005). Verify: torn page + image → restored; newer page untouched; replay twice
      = once; at 512 B, 4 KiB, 64 KiB.
- [ ] **`wal/checkpoint.zig` — checkpoint and reclaim** (`src/wal/`, `src/page/manager.zig`).
      Commit a `checkpoint` frame at C, `flushAll`, page `sync`, set file-header `wal_lsn = C`
      (new `PageManager.set_wal_lsn`), `sync`, delete segments wholly below C. A sync fences
      each step, so a crash anywhere recovers from the old or new `wal_lsn`. Verify: `FaultIo`
      failing each of the 5 steps → replay reaches the model state; active segment never deleted.
- [ ] **3E crash-recovery property tests** (`src/testing/wal_recovery_test.zig`). Seeded model:
      random appends, commits, pool page edits, checkpoints; crash at a random write (`FaultIo`
      stop, then a torn or truncated cut of the unsynced tail); recover; every committed LSN
      present, nothing past the last sync invented, pages match. Verify: 3 page sizes × fixed
      seeds green in `zig build test`; mutants (gate off, redo ignores LSN) fail the property.
- [ ] **Docs, module status, release v0.5.0** (`docs/`, `README.md`, `build.zig.zon`). After
      every box above. Drop `NotImplemented` from `src/wal.zig`, re-export real declarations;
      README wal row `Planned` → `Landed`; tick 3A–3E in `docs/plans/000-inherited.md`;
      `CHANGELOG.md` (with the WAL format v1 note) + `.version = "0.5.0"` in one PR, then tag.
      Verify: `gh release view v0.5.0` succeeds; `grep NotImplemented src/wal.zig` finds nothing.

## Out of scope

- WAL benches (PRD §5 append and replay targets) — plan 005, on the KV write path consumers see.
- Segment preallocation and recycling, compression, multiple writers per directory.
- Image-logging policy and the B+Tree itself (plan 005); **1C `file/mmap.zig`** (LSM plan).

## Risks

- **Format lock-in.** WAL v1 ships in a tag. Mitigation: ADR-0003 merges before any frame byte.
- **Tail vs. mid-log damage.** Calling mid-log damage a torn tail silently drops committed data.
  Mitigation: ADR-0003's bounded look-ahead; a test puts a valid frame after a bad one.
- **Flaky concurrency tests.** `std.testing.io` runs real threads. Mitigation: assert only
  order-free facts (`durable_lsn >= upto`, fewer syncs than commits) with bounded waits.
- **Checkpoint ordering.** Writes persist in order only across a sync (cycle 42). Mitigation: a
  sync between every step and a `FaultIo` test per step.
- **Item size.** If writer, checkpoint or 3E spills a cycle, split it (rotation, reclaim) out.

## Done when

- `zig build test` and `zig build tidy` exit 0 on Zig 0.16.0; all CI jobs green on `main`.
- `docs/adr/0003-wal-format.md` exists; `src/wal/{frame,segment,reader,writer,recovery,redo,
  checkpoint}.zig` exist and are re-exported; no `NotImplemented` in `src/wal.zig`.
- `git tag` contains `v0.5.0` and `gh release view v0.5.0` succeeds; milestone issue closed.

## Version impact

**MINOR** — 0.4.0 → **0.5.0** (`citadel/protocol/VERSIONING.md`: additive milestone). New `wal`
module and on-disk WAL format v1; `BufferPool.set_durable_lsn` and `PageManager.set_wal_lsn` are
additive; no existing signature or error set changes; page format v1 untouched. No sibling
`build.zig.zon` names strata, so no `migration` issues follow.
