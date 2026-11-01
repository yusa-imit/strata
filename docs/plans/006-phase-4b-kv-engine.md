# Plan 006 — Phase 4b: kv engine on the B+Tree

## Goal

Land PRD §4.8 `kv` on the btree engine (inherited 4D): `Db` open/close/get/put/delete/scan, an
atomic `WriteBatch`, recovery on open via `wal.Recovery` + `PageRedo`, `checkpoint`; no
`Snapshot`. Proven by a seeded crash model that drops unsynced bytes, plus the WAL figures PRD §5
still owes. Defines strata's fourth on-disk format, kv layout v1 (ADR-0005). Ends with **v0.7.0**.

## Why now

v0.6.0 shipped a logged B+Tree, but nothing pairs a page file with its WAL: tests wire
`PageManager`, `BufferPool`, `Writer`, `Tree` and `PageRedo` by hand, and the root id has no home
(ADR-0004 §8 leaves it to the caller). `kv.Db` is that caller, the one type allowed to cache an
`io` (ADR-0001 §2), and the surface consumers adopt (ROADMAP Phase 3). Safety first: the B+Tree
test debts of cycles 67-75 are paid before a format ships on top of the tree.

## Scope

No item is blocked (`.dependencies = .{}`). Only `src/kv/db.zig` may cache an `Io` (tidy
`io-field`); `kv` never branches on `builtin.os.tag`; every `kv` buffer (frames, `frees`,
`track`, `value_buf`, batch) is allocated in `Db.open`.

- [ ] **B+Tree durability debts** (`src/btree/tree_wal_delete_test.zig`, `src/btree/tree.zig`).
      kv recovery stands on untested paths: replay onto the *live* page file after `free_at`
      stamped a trunk (rule B, path c); a failing `free_at` in `release_frees` returns the error
      and keeps unfreed ids queued (no double free on retry); attached ops assert
      `pool.gate_on`. Verify: the new tests fail on a mutant (trunk lsn not kept at max).
- [ ] **Crafted-page `Corrupted` tests** (`src/btree/delete_tree_test.zig`, `cursor_test.zig`).
      Disk bytes are untrusted and cycles 68-70 reviews found real defects here: one sealed
      crafted page per `Corrupted` branch of `plan_merge`, `plan_level`, cursor `next/prev/
      step_back/left_sibling`; scans assert height 3. Verify: one named test per branch.
- [ ] **ADR-0005 — kv layout v1** (`docs/adr/0005-kv-layout.md`). Format before bytes. Fixes: the
      directory (page file, `wal/`, names, exclusive lock); the root id (recommend page 1, first
      allocation of `create`, type-checked on open: no meta page, no page-0 image, ADR-0003 OQ2);
      create durable before `open` returns, a half-created directory → `Corrupted`; the open
      order (`redo_start` → `Recovery.replay` into `PageRedo` → `Writer.init` → `Tree.open` +
      `attach`); WAL missing beside `wal_lsn ≠ 0` → `Corrupted` (ADR-0003 OQ3); `Db.io` set once,
      asserted; `key_len_max` clamped per page size (ADR-0004 OQ4); when `put` is durable per
      `SyncPolicy`; `release_frees` cadence; batch atomicity (recommend one `page_images` frame
      per batch under a static op bound); `Iterator` lifetime. Verify: merged; PRD §4.8 links it.
- [ ] **`kv/db.zig` — create, put, get, delete, flush, close** (`src/kv/`). `Db.open` on an
      empty dir builds page file, WAL and a logged root tree; `put`/`delete` commit per
      `SyncPolicy`, raise the pool gate, `release_frees`. Verify: round trip at 512 B, 4 KiB,
      64 KiB; reopen after `close` sees every key; `FailingAllocator` armed after `open` holds.
- [ ] **Recovery on open, `Db.checkpoint`** (`src/kv/db.zig`). An existing directory replays
      from `redo_start`, then attaches; `checkpoint` runs `wal.Checkpoint` and reclaims segments
      so the log stays bounded. Verify: crash (pool dropped, no flush) → reopen → same `get`s;
      reopen twice = once; after a checkpoint reopen replays only frames past `wal_lsn`; a
      deleted WAL beside `wal_lsn ≠ 0` and a wrong-type root page are `Corrupted`.
- [ ] **Tree op groups** (`src/btree/tree.zig`). Batch atomicity needs several ops in one frame:
      `group_begin`/`group_end` keep tracked pages unevictable until one `page_images` frame
      images them all. Fold the three `ops_max` copies first (cycle 74 review). Split from the
      batch (Risks: item size). Verify: a 32-op group cut mid-frame replays to the pre-group
      tree; replay twice = once; an empty group appends nothing; ungrouped tests stay green.
- [ ] **`kv/batch.zig` — `WriteBatch`** (`src/kv/`). Holds `*Db`, no `io`; records into the
      buffer from `open` under the ADR's op and byte bounds; `commit` applies one group, commits
      once. Verify: a crash cut inside the batch frame shows none of it, after `commit` all of
      it; one past the bound → `BatchTooLarge` before any page changes.
- [ ] **`kv/iterator.zig` — `Db.scan`** (`src/kv/`). Half-open `Range` over `Cursor`, forward;
      an entry borrows until the next `next`; a write during a live scan is a contract violation
      asserted by a generation counter. Verify: equals the sorted model for empty, one-key, full
      and past-the-end ranges at 3 page sizes; overflow values come back whole.
- [ ] **Durable-boundary `FaultIo`** (`src/testing/`). Today `FaultIo` fails calls and
      `CrashSink` is a bare `writeAt` sink: neither forgets what was never synced. Add a mode
      that records pre-images of positional writes in a caller-given undo buffer, drops a file's
      entries at its `fileSync`, and on `crash()` restores them (no allocation; full → typed
      error). Verify: unsynced write → old bytes, synced → new; the WAL property test passes on it.
- [ ] **kv seeded crash model** (`src/testing/kv_model_test.zig`). Random put/delete/batch/scan/
      checkpoint/reopen vs a bounded model, 3 page sizes × fixed seeds, crashing through the item
      above: recovery equals the last *committed* state (the durable-boundary variant plan 005
      deferred). Verify: green; mutants (commit skips sync, redo ignores lsn) fail.
- [ ] **WAL benches** (`bench/wal.zig`, `bench/main.zig`). PRD §5, ReleaseFast: 128 B appends
      under group commit with `.fdatasync` ≥ 200k ops/s; `Recovery.replay` of a 1 GB log into a
      counting `Apply` < 5 s. Figures and sync policy into `000-inherited.md`. Verify: `zig build
      bench` prints both; a missed floor is fixed here or split out before release.
- [ ] **Docs, module status, release v0.7.0** (`docs/`, `README.md`, `build.zig.zon`). Drop
      `NotImplemented` from `src/kv.zig`; README kv row `Landed`; tick 4D; CHANGELOG (kv layout
      v1, `Db`/`WriteBatch`/`Iterator`, tree op groups) + `.version = "0.7.0"` in one PR, then
      tag. Verify: `gh release view v0.7.0` succeeds; `grep NotImplemented src/kv.zig` is empty.

## Out of scope

- `Tree.bulk_load` (PRD §4.6): off 4D's path; with a fixed root id and rules A–C it needs its
  own design (unlogged build, sync, checkpoint). Next plan, with the ADR-0004 OQ3 append split.
- `Snapshot` (6A), the LSM engine (Phase 5), **1C `file/mmap.zig`**, reverse `Iterator`,
  concurrent access (one caller per `Db`), leaked-page reclaim (ADR-0004 OQ2), delta records,
  a page-0 image path, a CI fuzz job. Cycle 75 style suggestions go to stabilize.

## Risks

- **Format lock-in.** kv layout v1 ships in a tag. Mitigation: ADR-0005 merges before `Db` writes
  a byte, and reuses page and WAL formats v1 unchanged.
- **Small batches.** A worst-case op images 2·height + 1 pages, so a static bound inside one
  1 MiB frame admits few ops at small pages. Mitigation: the ADR states the bound per page size;
  if too small, a `commit` frame type (reserved 4–15, ADR-0003 OQ1, no WAL bump) replaces groups.
- **Item size.** `Db.open`, recovery and the WAL benches are the largest; a spill splits them
  (create vs ops, replay vs checkpoint, append vs replay) rather than stretching a cycle.
- **Disk and fsync.** The 1 GB fixture meets a host that NOOPed at 16–18 GB free (cycles 64-66):
  check free space, delete in `defer`, tick only on a measured run. macOS `fdatasync` is not
  `F_FULLFSYNC` (PRD §9): record the policy beside the figure.

## Done when

- `zig build test` and `zig build tidy` exit 0 on Zig 0.16.0; all CI jobs green on `main`; the
  tidy `io-field` allow list is unchanged (`src/kv/db.zig`, `src/testing/fault_io.zig`).
- `docs/adr/0005-kv-layout.md` exists and `grep -n 0005-kv-layout docs/PRD.md` hits §4.8;
  `src/kv/{db,batch,iterator}.zig` exist and are re-exported; no `NotImplemented` in `src/kv.zig`.
- `zig build bench` prints WAL append ≥ 200k ops/s and 1 GB replay < 5 s, recorded in
  `docs/plans/000-inherited.md`.
- `git tag` contains `v0.7.0` and `gh release view v0.7.0` succeeds; milestone issue closed.

## Version impact

**MINOR** — 0.6.0 → **0.7.0** (`citadel/protocol/VERSIONING.md`: additive milestone). New `kv`
module and kv layout v1 (ADR-0005) over unchanged page and WAL formats v1. `kv.Error` loses
`NotImplemented`, a stub with no callers (`0.x` MINOR may break anyway). Tree op groups and the
`FaultIo` mode are additive; no existing signature or error set changes. A `commit` frame type,
if chosen, takes a reserved id (no WAL bump; v0.6.0 rejects such a log as `Corrupted`, noted in
the CHANGELOG). No sibling `build.zig.zon` names strata (plan 005): no `migration` issues.
