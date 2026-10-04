# Plan 003 — Phase 2: page layer and CLOCK buffer pool

## Goal

Land PRD §4.3 `page` (checksummed page header, file header, freelist, `PageManager`) and §4.4
`cache` (CLOCK `BufferPool`, `PageGuard`) as tested code, proven at every page size from 512 B to
64 KiB (PRD §6 Phase 2A–2C). Defines strata's first on-disk format (ADR-0002). Ends with
**v0.4.0**.

## Why now

v0.3.0 shipped `codec`, `file` and the crash harness; `page` and `cache` are still
`error{NotImplemented}` stubs. They are the next layer up and the base of everything after it:
WAL checkpoint (§4.5, 3D) flushes pool pages, the B+Tree (§4.6) is slotted pages under the pool,
and silica's ROADMAP Phase 3 migration onto strata is page/cache/WAL. WAL first would serve synod
sooner, but synod's REALM.md orders its strata adapter last and optional — no consumer waits on
it. 1C mmap stays deferred: nothing reads a mapping until LSM SSTables (§4.7). ADR-0001's tidy
guards (its verification 1 and 3) never landed, and `BufferPool` is the first long-lived struct
tempted to cache an `Io`, so that guard goes first.

## Scope

No item is blocked — `.dependencies = .{}`, strata waits on no producer tag.

- [ ] **tidy: ADR-0001 `Io` guards** (`tools/tidy/checks_ban.zig`). Safety before features: ban
      `Io.Threaded`, `Io.Evented`, `global_single_threaded` under `src/`; allow an `Io`-typed
      struct field only in `src/kv/db.zig` and `src/testing/fault_io.zig` (an `Io` wrapper must
      hold its inner `Io`). Needles spelled with `++` so tidy does not flag itself. Verify: one
      red fixture per rule; `zig build tidy` exits 0 on the tree.
- [ ] **ADR-0002 — page format v1** (`docs/adr/0002-page-format.md`). The first on-disk format
      is decided before code (REALM.md: magic + version). Fixes: §4.3 header widths and order;
      CRC32C over the whole page with the field zeroed, seeded with the page id so a misdirected
      write fails; page 0 file header (magic `STRA`, format version, page_size, page_count,
      freelist_head, wal_lsn); `page.Id` width; power-of-two sizes 512–65536; how a never-written
      (zero) page decodes; freelist narrowed to a trunk-page list (bitmap deferred, reason given).
      Verify: ADR merged; `docs/PRD.md` §4.3 links it.
- [ ] **`page/header.zig` — page and file-header codecs** (`src/page/`). Pure, no `io`
      (ADR-0001). Encode stamps CRC32C via `codec.crc32c`; decode checks magic, version, type,
      checksum. `error.ChecksumMismatch` for a bad CRC, `error.Corrupted` for bad
      magic/version/type/page_size (REALM.md). Verify: round trip at 512/4096/65536; every
      single-bit flip of a 512 B page fails; a page decoded under another id fails; page_size 3000
      → `Corrupted`.
- [ ] **`page/freelist.zig` — trunk-page freelist** (`src/page/`). Pure push/pop over trunk-page
      bytes; the manager does the I/O. Ids per trunk derive from page_size and are asserted.
      Verify: seeded model test vs. a bounded array over 10k ops; spill to a new trunk and drain
      back; pop on empty → `null`; a count field past capacity → `Corrupted`.
- [ ] **`page/manager.zig` — create, open, read, write** (`src/page/`). `PageManager` owns a
      `file.File` and takes `io` per blocking call (ADR-0001). `create` writes page 0; `open`
      validates it against `Options.page_size` and takes an exclusive `tryLock`. No new methods
      on `file.File` (788/800 lines). Verify: `tmpDir` create→close→open round trip; second open
      → `WouldBlock`; size mismatch → `Corrupted`; byte flipped on disk → `ChecksumMismatch`.
- [ ] **`page/manager.zig` — allocate, free, sync, reopen** (`src/page/`). `allocate` pops the
      freelist or grows the file up to `Options.page_count_max` (a limit on growth, Tiger Style
      2), then `error.NoSpaceLeft`; `free` pushes; `sync` delegates to `File.sync` per policy.
      Verify: seeded model test (allocate/free/write/read vs. a map) with reopen between rounds;
      no id handed out twice; `page_count_max` enforced.
- [ ] **`cache/buffer_pool.zig` — CLOCK fetch and pin** (`src/cache/`). §4.4 shape: frames
      (page-aligned), page table and CLOCK hand all allocated in `init`, none after (Tiger Style
      3). `fetch` pins on hit; on miss evicts the first unpinned frame with a clear reference
      bit; all pinned → `error.PoolExhausted`, never a wait. Minimal `PageGuard`
      (`bytes`/`release`). Per-frame metadata `comptime`-asserted < 64 B (PRD §5). Verify:
      scripted hit/miss/eviction counts via `stats`; `FailingAllocator` armed after `init`.
- [ ] **`cache/guard.zig` + dirty write-back** (`src/cache/`). `fetchForUpdate`, `markDirty`,
      write-back on eviction, `flushAll`, `discardAll`; `deinit` asserts zero dirty frames.
      `release`/`markDirty` take no `io` and cannot fail (§4.4 contract). Verify: dirty page
      evicted then refetched returns new bytes; `flushAll` + reopen persists; a `FaultIo` failing
      the eviction write surfaces the error and leaves the frame dirty, not lost.
- [ ] **2C page-size matrix + torn-page sweep** (`src/page/`, `src/cache/`, `src/testing/`).
      Run the header, manager and pool suites at all 8 powers of two 512–65536, not one size
      (REALM.md). Feed the real page decoder to the comptime decoder slot of
      `src/testing/truncation_matrix_test.zig` (replacing its stand-in, per cycle 29). Verify:
      matrix green at 8 sizes; every torn or truncated page image → typed error.
- [ ] **Pool bench** (`bench/main.zig`). PRD §5's 5M ops/s pool-hit point get needs a floor
      before the B+Tree sits on it. Measure fetch+release ops/s on hit and on miss-with-eviction
      at 4 KiB. Verify: `zig build bench` prints both; figures added to `000-inherited.md`'s table.
- [ ] **Docs, module status, release v0.4.0** (`docs/`, `README.md`, `build.zig.zon`). After
      every box above. Drop `NotImplemented` from `src/page.zig`/`src/cache.zig`, re-export real
      declarations; README page/cache rows `Planned` → `Landed`; tick 2A–2C in
      `docs/plans/000-inherited.md`; `CHANGELOG.md` + `.version = "0.4.0"` in one PR, then tag.
      Verify: `gh release view v0.4.0` succeeds; `grep NotImplemented src/page.zig src/cache.zig`
      finds nothing.

## Out of scope

- **1C `file/mmap.zig`** — deferred again to the LSM plan; nothing maps a file before §4.7.
- WAL (Phase 3) — plan 004. Pages store `lsn` as given; WAL-before-data ordering is 3D's job.
- `O_DIRECT`: frames are page-aligned so the later flip is local, but `direct` stays rejected.
- A thread-safe pool (`Io.Mutex`), LRU/2Q policies, the bitmap half of §4.3's freelist.
- Format migration tooling — there is no prior format to migrate from.

## Risks

- **Format lock-in.** Format v1 ships in a tag; a later change costs a version bump and
  migration notes (REALM.md). Mitigation: ADR-0002 is reviewed by merge before any page byte.
- **Misdirected or stale writes pass a plain CRC.** A valid page at the wrong offset checksums
  fine. Mitigation: the page id seeds the checksum; a test copies a page to another id.
- **Matrix runtime.** 8 sizes × model tests × 64 KiB pages on a Linux-only test leg. Mitigation:
  bound op counts per size; keep the 64 KiB leg's working set small.
- **Pool contract drift.** `release` being infallible and `io`-free is the §4.4 contract the
  B+Tree will lean on; any write-back outside `fetch`/`flushAll` breaks it. Mitigation: assert
  it in review and keep `io` off those signatures.

## Done when

- `zig build test`, `zig build tidy`, `zig build bench` exit 0 on Zig 0.16.0; all CI jobs green
  on `main`.
- `docs/adr/0002-page-format.md` exists; `src/page/{header,freelist,manager}.zig` and
  `src/cache/{buffer_pool,guard}.zig` exist and are re-exported; no `NotImplemented` in
  `src/page.zig` or `src/cache.zig`.
- `git tag` contains `v0.4.0` and `gh release view v0.4.0` succeeds; milestone issue closed.

## Version impact

**MINOR** — 0.3.0 → **0.4.0** (`citadel/protocol/VERSIONING.md`: additive milestone). New
modules and a new on-disk format v1, no existing signature changed. No sibling `build.zig.zon`
names strata, so no `migration` issues follow.
