# Plan 005 — Phase 4a: B+Tree engine and its WAL integration

## Goal

Land PRD §4.6 `btree` (slotted node, insert/get/delete with split and merge, cursor, overflow,
`validate`) over the buffer pool, every tree edit recoverable through the WAL (`PageRedo`), proven
by seeded model tests at three page sizes and a bench against PRD §5 (PRD §6 Phase 4A–4C, 4E).
Defines strata's third on-disk format (ADR-0004). Ends with **v0.6.0**.

## Why now

v0.5.0 shipped `wal`; `btree` is still an `error{NotImplemented}` stub and the next PRD phase.
Plan 004 left two debts here: when to log a `page_image` (`redo.zig` defers it to the tree) and
multi-frame atomicity (ADR-0003 Open question 1: a split touches several pages). **`kv` (4D) is
plan 006**: `Db` is a second concern (cached `io`, WAL/page-file pairing per ADR-0003 OQ3,
`WriteBatch` atomicity, WAL benches) atop a tree that must first be proven alone.

## Scope

No item is blocked — `.dependencies = .{}`. Order: format, pure node codec, tree, durability,
proof. `node.zig` takes no `io`; every tree or cursor method that can fault in a page does (PRD
§4.6). Descent uses an explicit stack bounded by `height_max`, never recursion.

- [x] **ADR-0004 — B+Tree page format v1** (`docs/adr/0004-btree-format.md`). Format before
      bytes (REALM.md). Fixes: leaf, internal, overflow types in ADR-0002's 16–31 range (no page
      bump, §8); slotted layout, `u16` offsets relative to the payload so 64 KiB fits (ADR-0002's
      open `u16` cost); `key_len_max` and inline value limit per page size (≥ 4 cells at 512 B);
      overflow chain; leaf links; a fixed root id (root split moves cells down: no meta page);
      `height_max`; logging policy and atomicity (recommend one multi-image frame per op in the
      WAL's strata 16–127 range, under `frame_bytes_max`); frees deferred until the op is
      durable (Risks). Verify: ADR merged; PRD §4.6 links it.
- [x] **`btree/node.zig` — leaf cells** (`src/btree/`). Pure. Parse/encode a leaf over frame
      bytes, binary search, insert/remove a cell, compact free space; register the types in
      `page/header.zig`. Disk bytes are untrusted: a bad offset or length is `Corrupted`, never
      an assert. Verify: golden leaf hex at 512 B; round trip at 512 B, 4 KiB, 64 KiB; a seeded
      random-bytes sweep yields typed errors only; the slot table never overlaps a cell.
- [x] **`btree/internal.zig`, `btree/split.zig` — internal cells, split point**
      (`src/btree/`). Pure. `[key, child]` cells plus the rightmost child; `split_point` by bytes, not count, so variable-length keys
      split evenly. Verify: golden internal hex; splitting a full node at all 8 page sizes leaves
      both halves ordered and under capacity; a child id 0 → `Corrupted`.
- [ ] **`btree/tree.zig` — create, get, insert into the root leaf** (`src/btree/`, `src/cache/`).
      First `BufferPool.fetchNew(io, id)`: an allocated page reads `Unwritten` or stale, so
      `fetch` fails on it (memory follow-up, cycle 44: it blocks the tree). `get` borrows until
      the next write. Verify: `fetchNew` on a grown and a reused id; insert/get/overwrite without
      a split; a `FailingAllocator` armed after `init` never trips.
- [ ] **Split and `validate`** (`src/btree/tree.zig`). Leaf and internal splits up the stack;
      the root split keeps the root id; height over `height_max` → typed error. `validate(io,
      gpa)` checks order, separator bounds, fill, leaf links and types, walk bounded by
      `page_count`. Verify: 10k sequential and 10k random inserts at 512 B and 4 KiB pass
      `validate`; a hand-broken separator → `Corrupted`.
- [ ] **Delete, merge, rebalance** (`src/btree/tree.zig`). Byte-fill underflow borrows from or
      merges with a sibling; a one-child root collapses into the root id. Freed ids go to a
      bounded `frees_pending` (`frees_pending_max`), handed to `PageManager.free` only by
      `release_frees(io)`. Verify: insert all, delete all in seeded order → empty root leaf,
      `validate` every 100 ops; every allocated page freed exactly once (counter model).
- [ ] **`btree/cursor.zig` — seek, next, prev** (`src/btree/`). The cursor keeps its bounded
      descent stack, pins at most one leaf, `release` cannot fail; an entry borrows until the next
      step or write. Verify: forward and backward full scans equal the sorted model; seek to an
      absent, the first and a past-last key; an empty tree → null both ways.
- [ ] **`btree/overflow.zig` — large values** (`src/btree/`). Values over the inline limit go to
      a chain bounded by `value_len_max`, freed via `frees_pending`; `get` assembles into a buffer
      allocated at `init`. Verify: 1 MiB value at 512 B and 64 KiB; a chain cycle or bad length
      → `Corrupted`; page count balances after delete.
- [ ] **WAL integration: tree edits recover** (`src/btree/`, `src/wal/redo.zig`). With a
      `wal.Writer` attached, an op appends one frame imaging every page it dirtied, then
      `set_lsn`s them; `release_frees` waits for `durable_lsn`; `PageRedo` applies each image iff
      its page is older. No writer = unlogged. Verify: crash before write-back → replay → same
      `get`s; a cut frame restores the pre-op tree, never half a split; replay twice = once.
- [ ] **4E seeded model tests** (`src/testing/btree_model_test.zig`). Random get/insert/delete/
      seek/scan against a sorted bounded-array reference, 3 page sizes × fixed seeds, `validate`
      every N ops, `flushAll` mid-run (it cleans pinned frames, cycle 44); a crash variant on
      plan 004's `FaultIo`/`CrashSink` fixtures recovers to the last durable op. Verify: green
      in `zig build test`; mutants (split drops the separator, redo ignores lsn) fail.
- [ ] **B+Tree bench** (`bench/btree.zig`). PRD §5 floors, 4 KiB, ReleaseFast, unlogged: point
      get on a hot pool ≥ 5M ops/s (pool hit is 197M), sequential insert ≥ 1M ops/s; a logged
      insert figure is recorded, not gated (Risks). Figures go into `000-inherited.md`. Verify:
      `zig build bench` prints them; a missed floor is fixed here or split out before release.
- [ ] **Docs, module status, release v0.6.0** (`docs/`, `README.md`, `build.zig.zon`). Drop
      `NotImplemented` from `src/btree.zig`; README btree row `Landed`; tick 4A–4C, 4E; CHANGELOG
      (B+Tree format v1, new page and frame types) + `.version = "0.6.0"` in one PR, then tag.
      Verify: `gh release view v0.6.0` succeeds; `grep NotImplemented src/btree.zig` is empty.

## Out of scope

- `kv` `Db`/`WriteBatch`/`Iterator` (4D), WAL benches (append 200k ops/s, 1 GB replay < 5 s) and
  `bulkLoad` — plan 006, on the write path consumers see.
- Concurrent access and latching (one caller at a time, documented); delta or logical redo
  records; a page-0 image path (ADR-0003 OQ2); coverage-guided fuzzing (needs a CI fuzz job;
  4E ticks on the seeded campaign); **1C `file/mmap.zig`** and LSM.

## Risks

- **Format lock-in.** B+Tree v1 ships in a tag. Mitigation: ADR-0004 merges before any node byte.
- **Unlogged freelist.** `PageManager.free` writes trunks straight to disk. A free that persists
  before the op's images makes a page both live and free after a crash: a double allocation.
  Mitigation: deferred frees; a crash then leaks the page, which ADR-0002 calls safe.
- **Frame size.** A worst-case op images about 2·height + 1 pages; 1 MiB holds 15 at 64 KiB.
  Mitigation: ADR-0004 derives `height_max` per page size, comptime-asserted to fit.
- **Write amplification.** A small logged insert writes a whole page image, far from 1M ops/s.
  Mitigation: gate the floor unlogged, record the logged figure; delta records later take a
  reserved frame type, no WAL version bump.
- **Item size.** If split, delete or WAL integration spills a cycle, split it out (internal
  split, `PageRedo` frame type).

## Done when

- `zig build test` and `zig build tidy` exit 0 on Zig 0.16.0; all CI jobs green on `main`.
- `docs/adr/0004-btree-format.md` exists; `src/btree/{node,tree,cursor,overflow}.zig` exist and
  are re-exported; no `NotImplemented` in `src/btree.zig`.
- `zig build bench` prints B+Tree get ≥ 5M and sequential insert ≥ 1M ops/s, recorded in
  `docs/plans/000-inherited.md`.
- `git tag` contains `v0.6.0` and `gh release view v0.6.0` succeeds; milestone issue closed.

## Version impact

**MINOR** — 0.5.0 → **0.6.0** (`citadel/protocol/VERSIONING.md`: additive milestone). New
`btree` module and B+Tree format v1 (ADR-0004) on reserved page types (no page `format_version`
bump, ADR-0002 §8) and one reserved WAL frame type (no WAL bump, ADR-0003 §12; v0.5.0 rejects
such a log as `Corrupted`, noted in the CHANGELOG). `BufferPool.fetchNew` is additive; no
signature or error set changes. No sibling `build.zig.zon` names strata: no `migration` issues.
