# ADR-0005: kv layout v1

- **Status**: Proposed (accepted on merge)
- **Date**: 2026-11-05
- **Milestone**: plan `docs/plans/006-phase-4b-kv-engine.md`, item "ADR-0005 — kv layout v1"
- **Applies to**: `docs/PRD.md` §4.8 (`kv`), §4.5 (one new frame type), §4.4 (the pool gate as
  the batch boundary)
- **Supersedes**: PRD §4.8's `Options` block (default field values; `engine = .lsm`). It also
  supersedes ADR-0004's rejection of a `commit` frame type, for kv logs only (§8).
- **Depends on**: ADR-0001 (§2: `kv.Db` is the one type that caches an `Io`), ADR-0002 (page 0,
  `wal_lsn`, `Unwritten`, freelist, §6 sector atomicity), ADR-0003 (§1 names, §6 reserved types
  4–15, §9 durability, §10 checkpoint and redo, OQ1–OQ3), ADR-0004 (§2 limits, §8 fixed root,
  §9 rules A–C, OQ4).

## Context

`kv.Db` is the first caller that pairs a page file with its WAL. It defines strata's fourth
on-disk format. Here the format is a *layout*: which files exist, what they are called, and
what must hold between them. These forces shape it:

1. **The root id has no home.** ADR-0004 §8 says the caller persists the root. A meta page
   would need a page-0 or meta image path, which ADR-0003 OQ2 forbids for v1.
2. **Create is several writes.** A page file, a log directory, a first segment and a root leaf
   cannot be made durable in one write. A crash leaves a prefix of that sequence on disk.
3. **A missing log looks like an empty log.** `Recovery.replay` accepts an empty log at
   `from_lsn = 0`, and `Writer.init` *creates* segment 1 in an empty directory. A deleted WAL
   would silently reset the database (ADR-0003 OQ3).
4. **The atomic unit is one frame of 1 MiB.** A worst-case op images `2·height_max + 1` pages
   (ADR-0004 §9). At large pages, one frame holds one such op (§8 table).
5. **Rule B frees on `durable_lsn`.** `Tree.release_frees` frees every queued id once
   `writer.durable_lsn >= frees_lsn`. Any multi-op unit must keep that true at the unit's
   boundary, not the frame's.
6. **Allocation is fixed at open.** `Tree.create/open` take `frees` and `value_buf`, and `attach`
   takes `track`, all caller storage. `BufferPool.init`, `Writer.init` and `PageRedo.init`
   allocate once. `Db` owns all of it.

## Decision

Format v1 is everything in this document. Every name below is a byte string. Platform
branching stays in `file/`: `kv` calls `file/platform.zig` (`sync_dir`) and std `Io.Dir`, and
never reads `builtin.os.tag`.

### 1. Directory layout and lock

```
<dir>/<sub_path>/            the database directory (one Db)
    pages.db                 page file, ADR-0002 format v1
    wal/                     log directory, ADR-0003 format v1
        wal-00000001.log     segments, ADR-0003 §1 names
```

- **Names.** The page file is exactly `pages.db`, and the log directory is exactly `wal`. Other
  entries in the database directory are ignored once `pages.db` exists. Segment naming is
  ADR-0003 §1, unchanged.
- **Lock.** The exclusive lock is the one `PageManager.create`/`open` already takes on
  `pages.db` (`tryLock(.exclusive)`; held → `error.WouldBlock`). The lock is held from the
  first step of `Db.open` to `Db.close`. The `Writer`'s segment lock is a second backstop, not
  the database lock. There is no lock file; `file.zig` lists a cross-process lock file as later
  work. **Why:** the page file is the one file every open must take first, so its lock orders
  every other step.
- **Empty.** `Db.open` *creates* iff `sub_path` does not exist, or exists and has no entries at
  all. It *opens* iff `pages.db` exists. Anything else is `error.Corrupted`: a directory with
  entries but no `pages.db` cannot be told apart from a half-create that lost the page file's
  name (§3). The emptiness check reads at most one directory entry (bound 1).
- **Who makes directories.** `Db.open` makes `sub_path` (one level, no recursive `-p`; a missing
  parent is the std error, mapped by §10) and `wal`. It opens both with iteration, as
  `Writer.init` and `Recovery.replay` require, and closes both in `close`. `Writer.init`
  creates the segments. `kv` never takes a path string other than `sub_path` (ADR-0001 §5).

*Testable:* opening a non-empty foreign directory is `Corrupted` and its bytes are unchanged; a
second `Db.open` on a held database is `WouldBlock`; `ls` after create shows exactly
`pages.db` and `wal/wal-00000001.log`.

### 2. Root id: page 1

The root id is **page 1**: the first `allocate` of `create`, on a fresh page file (page count 1,
empty freelist), which `PageManager.allocate` grows to id 1. `Db` asserts `tree.root == 1`
after `Tree.create`. The root is never freed: ADR-0004 §8 root collapse copies the child into
the root. So page 1 is never a trunk, and a `validate` walk that finds it on the freelist gives
`Corrupted`.

On open, after redo (§4 step 6), `Db` fetches page 1 through the pool. Its type must be
`btree_leaf` (16) or `btree_internal` (17) and it must parse (`parse_leaf`, or
`parse_internal` at its own level). Otherwise the database is `Corrupted`: `Unwritten`, another
type, or a parse failure all count. `Tree.open` reads no page, so this check is `Db`'s.

**Why:** there is no meta page, so no page-0 image is needed (ADR-0003 OQ2). A fixed id costs
nothing, because ADR-0004 §8 already keeps the root id fixed.

*Testable:* a page file whose page 1 is a freelist trunk, an overflow page, or `Unwritten`
gives `Corrupted`. After any number of splits and collapses, `root == 1`.

### 3. Create is durable before `open` returns

Steps under a syncing policy (`.none` issues no sync, as in ADR-0003 §9):

| # | Step | Sync |
|---:|---|---|
| C1 | make `sub_path` if absent | `sync_dir(dir)` (the caller's parent) |
| C2 | `PageManager.create(pages.db)`: lock, page 0 (`wal_lsn 0`) | file sync (inside) |
| C3 | make `wal` | `sync_dir(sub_path)`: `pages.db` and `wal` are durable names |
| C4 | `Writer.init(wal)`: segment 1 | segment sync and `sync_dir(wal)` (inside) |
| C5 | `Tree.create` unlogged: page 1 = empty leaf; `pool.flushAll` | `PageManager.sync` |
| C6 | `attach`, gate on (§7), return | — |

The **completion marker** is a valid root at page 1. C5 runs only after C4's syncs, so a valid
root implies a durable log directory with a live segment. Half-created states:

| Crash after | On disk | `Db.open` |
|---|---|---|
| C1 | `sub_path` absent or empty | create again (not a half state) |
| C2 partial | `pages.db` empty or shorter than page 0 | `Corrupted` (ADR-0002 §5) |
| C2, before C3's sync | `wal` without `pages.db` | `Corrupted` (§1: entries, no page file) |
| C2–C4 | `page_count == 1` | `Corrupted` (no root) |
| C5 partial | `page_count >= 2`, page 1 `Unwritten` or torn | `Corrupted` (§2; no repair) |
| C5 | complete database | opens |

A torn page 0 at C2 cannot be `ChecksumMismatch`. The file was empty and page 0's non-zero
bytes are its first 48 bytes. Under ADR-0002 §6's atomic first sector, page 0 is either absent
or whole. There is no automatic cleanup: a half-created directory is the operator's to delete,
because removing files `kv` cannot prove it made would be data loss.

*Testable:* one crash test per row, cut through the durable-boundary `FaultIo` (plan item 9).

### 4. Open order

1. `PageManager.open(pages.db)`: lock, page 0, `page_size == options.page_size` (else
   `Corrupted`).
2. `page_count >= 2`, else `Corrupted`.
3. Open `wal/`, then a `reader.Reader.open` probe: `live_count >= 1`, else `Corrupted`. A
   missing `wal` is `Corrupted`. This holds **whatever `wal_lsn` is**: by §3, a complete
   database always has a log, and reclaim never deletes the newest segment. It closes ADR-0003
   OQ3 for `wal_lsn = 0` too.
4. `R = checkpoint.redo_start(io, gpa, wal_dir, pm.wal_lsn, segment_options)`. `wal_lsn != 0`
   with the frame gone, or not a `checkpoint`, is `Corrupted` (its existing rule).
5. Commit-bounded replay (§8): pass 1 `Recovery.replay(from = R)` into `CommitScan` finds the
   last commit point `K` and repairs a torn tail. Then `Recovery.truncate_after(K)`. Pass 2
   `Recovery.replay(from = R)` into `PageRedo` (`PageRedo.init` / `apply_target`) applies every
   frame `<= K`.
6. `PageManager.sync`: redo writes are not synced by `PageRedo`. Then the root check (§2).
7. `Writer.init(wal)`. `RecoveryRequired` here means another process touched the log under our
   lock, and is `Corrupted`. Assert `writer.last_lsn == K`.
8. `BufferPool.init`, `pool.set_durable_lsn(K)` (gate on), `Tree.open(pool, root = 1, frees,
   value_buf)`, `attach(writer, track)`, `Checkpoint.init`.

`frame.Type.commit` and `Recovery.truncate_after` are proposed additions (§8); they do not
exist in v0.6.0.

**Idempotence.** Steps 1–4 change nothing. Step 5 is idempotent: redo by page lsn, tail repair
and truncation re-create the same state when crashed. A crash between 5 and 6 replays again.
**Why this order:** redo must finish before the pool can cache a page, and before the writer
appends past the old tail.

*Testable:* reopen twice gives the same page file bytes as reopening once. A deleted `wal/`, or
an emptied `wal/`, beside `wal_lsn = 0` and beside `wal_lsn != 0`, is `Corrupted` with the page
file unchanged. After a checkpoint, `PageRedo` stats count only frames past `wal_lsn`.

### 5. `Db.io`, ownership and allocation

```zig
pub const Db = struct {
    io: Io,              // set once in open; never reassigned (ADR-0001 §2)
    gpa: Allocator,      // used by close only: frees what open allocated
    state: *State,       // one gpa.create in open; holds everything that borrows by pointer
};
```

- **State.** `PageManager`, `BufferPool`, `Writer`, `Tree`, `Checkpoint`, both `Io.Dir`s and the
  buffers live in one `State`, allocated once. They borrow each other by pointer (pool → pages,
  tree → pool, checkpoint → all three), so they must not move. `State` keeps a copy of `io`,
  and every public method asserts `self.io` equals `self.state.io`, comparing `userdata` and
  `vtable`. The PRD signature `open(io, gpa, dir, sub_path, options) OpenError!Db` stays.
- **Allocation.** `Db.open` allocates `State` and the following, from `Options` alone:
  pool slab and frames, writer frame buffer, `PageRedo` page (freed in `open`), `frees`,
  `track`, `value_buf`, and batch storage. Nothing allocates after `open` returns. `gpa` is
  stored only to free these in `close`; it is never used for growth.
- **Options: no default values.** Every field is spelled at the call site.

```zig
pub const Engine = enum { btree };        // .lsm is added with Phase 5's own layout
pub const Options = struct {
    engine: Engine,
    sync_policy: file.SyncPolicy,         // page file and log share it
    page_size: u32,                       // power of two, 512 ... 65536
    page_count_max: u32,                  // PageManager growth limit
    pool_frames_max: u32,                 // >= pool_frames_min(ps, options), asserted
    key_len_max: u32,                     // clamped, §6
    value_len_max: u32,                   // <= node.value_len_max (1 MiB), sizes value_buf
    batch_ops_max: u32,                   // >= 1; one put/delete is a batch of 1, §8
    batch_bytes_max: u32,                 // >= key_len_max + value_len_max, §8
    wal_segments_max: u32,                // >= 2 (§7 headroom)
    wal_segment_bytes_max: u64,           // Writer.Options.segment_bytes_max rule
};
```

Derived, not options (one construction path):
- `track.len = max(2·height_max + 1, chain(value_len_max))`;
- `frees.len = batch_ops_max·(height_max + chain(value_len_max)) + chain(value_len_max)`;
- `group_commit_window = .zero`: one caller per `Db`, so nobody joins a window.

Here `chain(v) = ⌈v / overflow_capacity(ps)⌉`.

*Testable:* `FailingAllocator` armed after `open` passes the whole op suite. `FailingAllocator`
failing at each allocation index of `open` returns `OutOfMemory` with nothing left open or
locked. Tidy `io-field` allows only `src/kv/db.zig`.

### 6. Key and value limits per page size

`key_len_max_eff = min(options.key_len_max, node.key_len_max(ps))`, reported by
`Db.key_len_max()`. A longer key in `put`, `delete`, `get` or a `Range` bound is
`KeyTooLarge`, before any page changes. `value_len_max <= node.value_len_max` is asserted, and
a longer value is `ValueTooLarge`. Numbers from ADR-0004 §2:

| ps | `node.key_len_max` | eff. with PRD 1024 | overflow cap | `chain(1 MiB)` | `height_max` |
|---:|---:|---:|---:|---:|---:|
| 512 | 108 | 108 | 480 | 2185 | 16 |
| 1 KiB | 236 | 236 | 992 | 1058 | 16 |
| 2 KiB | 492 | 492 | 2016 | 521 | 16 |
| 4 KiB | 1004 | 1004 | 4064 | 259 | 16 |
| 8 KiB | 1024 | 1024 | 8160 | 129 | 16 |
| 16 KiB | 1024 | 1024 | 16352 | 65 | 16 |
| 32 KiB | 1024 | 1024 | 32736 | 33 | 15 |
| 64 KiB | 1024 | 1024 | 65504 | 17 | 7 |

**Why clamp and not reject the option:** a consumer picks one `key_len_max` across page sizes
(ADR-0004 OQ4), and the effective value is queryable, so nothing is hidden.

*Testable:* at 512 B a 108 B key round-trips and a 109 B key is `KeyTooLarge`. At 4 KiB the
same holds for 1004 and 1005 B keys.

### 7. When a write is durable, and frees

`put`, `delete` and `WriteBatch.commit` return only after `Writer.commit(io, K)` returned for
their commit frame `K` (§8). Then `pool.set_durable_lsn(K)` raises the gate. **The gate is the
last durable commit point**, never `writer.durable_lsn`: pages of an unfinished batch stay in
the pool.

| `SyncPolicy` | Process crash | OS crash | Power loss |
|---|---|---|---|
| `.none` | survives | lost (since last OS writeback) | lost |
| `.fdatasync` | survives | survives | survives on Linux; macOS: `fsync`, drive cache (PRD §9) |
| `.fsync` | survives | survives | as `.fdatasync`, plus metadata |
| `.full_fsync` | survives | survives | survives (macOS `F_FULLFSYNC`; elsewhere `fsync`) |

"Survives" means every write whose call returned is visible after `open`. A write whose call
returned an error may or may not be visible. No partial batch is ever visible.

- **Latch.** A failed append or sync latches the writer (ADR-0003 §9). An error after the first
  op of a group touched a page latches the `Db` too: `pool.discardAll()`, then every later
  call is `Failed` until reopen. Reopen recovers to the last commit point.
- **`release_frees` cadence.** It runs once at the **start** of each `put`, `delete`,
  `WriteBatch.commit`, `checkpoint` and `flush`, before anything else. No group is open then,
  so every queued id's `frees_lsn <= K <= durable_lsn` (rule B). Assert
  `tree.frees_lsn <= writer.durable_lsn`. Its error returns before the op does anything; ids
  stay queued for the retry (plan item 1). `close` frees nothing: pending ids leak, which is
  safe (ADR-0002 §7).
- **Log bound.** At the start of each mutating op, if `writer.live_count >= wal_segments_max −
  1`, `Db` first runs `checkpoint` (run plus reclaim), so the checkpoint frame always has
  room. **Why:** without the headroom, `SegmentLimit` could block the checkpoint that clears it.

*Testable:* a "commit skips sync" mutant fails the crash model. A "gate = writer.durable_lsn"
mutant fails the mid-batch rotation test. A failing `free_at` leaves the next `put`'s pages
untouched.

### 8. `WriteBatch` atomicity: a `commit` frame

**The one-frame bound is too small, and at large pages, not small ones.** With worst-case
`2·height_max + 1` distinct pages per op against `images_per_frame_max(ps)`:

| ps | images/frame | pages/op | ops per frame |
|---:|---:|---:|---:|
| 512 | 2032 | 33 | 61 |
| 4 KiB | 255 | 33 | 7 |
| 16 KiB | 63 | 33 | 1 |
| 64 KiB | 15 | 15 | 1 |

At 512 B, 61 ops would do. A batch of 2 at 16 KiB and above, and of 8 at the PRD default
4 KiB, would be `BatchTooLarge`. That is a showstopper for a write batch, so **v1 uses the
fallback** named in plan 006 Risks.

**Frame type 4 `commit`** (ADR-0003 §6 range 4–15, no WAL version bump):

| Offset | Width | Field | Rule |
|---:|---:|---|---|
| 17 | 8 | `first_lsn` | `u64`, first frame of the group; `lsn_first <= first_lsn < lsn` |

`len == 8`. `frame.payload_valid` and `Writer.append` learn it. v0.6.0 readers reject type 4 as
`Corrupted`: they fail closed and never replay half a batch.

- **Group.** A group is one `put`, one `delete`, or one `WriteBatch.commit`. Ops run through the
  unchanged tree: one `page_images` frame per op, overflow chains first (rule C). Then `Db`
  appends one `commit` frame with `first_lsn` = the writer's `next_lsn` at group start, and
  commits it. An empty batch appends nothing.
- **Commit points** are `commit` frames and `checkpoint` frames. `Checkpoint.run` runs only
  between groups (asserted), so every frame before a checkpoint is committed.
- **Log invariant.** Every frame `<= K` (the last commit point) belongs to a committed group.
  Frames after `K` are one unfinished group. Recovery (§4 step 5) applies `<= K` and truncates
  the rest, so the invariant survives the next append.
- **Validation.** Pass 1 checks each `commit` frame's `first_lsn` against the end of the
  previous commit point, or `R`'s successor, or `lsn_first`. A mismatch is `Corrupted`
  (holes, foreign frames).
- **No eviction before commit.** The gate (§7) keeps a group's dirty pages, chains included,
  resident. So they bound the pool:

```
pages_group_max(ps) = batch_ops_max·(2·height_max + 1) + ⌈batch_bytes_max / cap⌉ + batch_ops_max
pool_frames_min     = max(pages_group_max + 2·height_max + 2,    one group + an op's pins + cursor
                          track.len + 2·height_max + 2)          Tree.attach floor
```

| ps | `batch_ops_max` 64, `batch_bytes_max` 1 MiB: `pool_frames_min` | memory |
|---:|---:|---:|
| 512 | 2112 + 2185 + 64 + 34 = 4395 | 2.1 MiB |
| 4 KiB | 2112 + 259 + 64 + 34 = 2469 | 9.6 MiB |
| 64 KiB | 960 + 17 + 64 + 16 = 1057 | 66 MiB |

- **`BatchTooLarge`** is returned by `WriteBatch.put/delete` when recording would make
  `ops > batch_ops_max` or `Σ(key.len + value.len) > batch_bytes_max`. The batch is
  unchanged, and no page has been touched. `commit` re-checks every key and value limit for
  all ops before the first op applies. `HeightLimit` mid-group latches (§7). `FreesPendingLimit`
  and `PoolExhausted` cannot occur: `frees.len` (§5) and `pool_frames_min` cover the group, and
  both are asserted.
- **Order.** Ops apply in record order; the last write to a key wins.

**Why not tree op groups:** a static one-frame bound gives 1 op at ≥ 16 KiB. The commit point
moves atomicity from frame size to pool size, which the caller sizes. It also needs no new tree
API, because the gate already exists.

*Testable:* a crash cut anywhere inside a group, including between its frames, shows none of
it. After `commit` returns, all of it is visible. Op `batch_ops_max + 1` is `BatchTooLarge`
with the page file and log byte-identical. A mid-batch rotation followed by a crash replays
nothing of the batch.

### 9. `Db.scan` and `Iterator`

```zig
pub const Range = struct { start: []const u8, end: ?[]const u8 };  // [start, end); null = +inf
pub fn scan(self: *Db, range: Range) ScanError!Iterator;           // seeks a btree.Cursor
pub fn next(self: *Iterator) ScanError!?Entry;                     // forward only
pub fn deinit(self: *Iterator) void;                               // releases the leaf pin
```

- `start >= end` yields no entries; it is caller data, not a contract violation. A bound longer
  than `key_len_max_eff` is `KeyTooLarge`.
- An `Entry` (key, whole value) borrows a pool frame or `value_buf`. It is valid until the next
  `next`, `get`, `scan` or `deinit`, because `get` shares `value_buf` with the cursor (`Tree`
  doc).
- `Db.generation: u64` increments on every `put`, `delete`, `WriteBatch.commit`, `checkpoint`
  and `flush`. `Iterator` records it at `scan`, and `next` asserts equality: a write during a
  live scan is a contract violation, not an error.
- At most one live `Iterator` per `Db` (`scans_live <= 1`, asserted). The pool floor counts one
  cursor leaf (ADR-0004 §9). `next` returning `null` releases the pin; `deinit` is idempotent.

*Testable:* empty, one-key, full and past-the-end ranges equal the sorted model at 512 B, 4 KiB
and 64 KiB. A 1 MiB overflow value comes back whole. A `put` between `next` calls trips the
assertion (death test, or the safety-checked build in CI).

### 10. Versioning and errors

**kv layout v1** is §1 (names), §2 (root = page 1) and the commit-point rule (§8). It reuses
page format v1 (ADR-0002, ADR-0004) and WAL format v1 (ADR-0003) unchanged, except that it
assigns reserved frame type 4. It has no magic or version of its own: each file carries
ADR-0002/ADR-0003 magic, version and checksum, and the layout is only naming. A meta file
would add a create step and a half state.

A layout change takes a **new page file name** (e.g. `pages2.db`). A v1 reader then sees
entries without `pages.db` and fails closed with `Corrupted` (§1). A change to page or WAL
bytes follows those ADRs. Phase 5's LSM engine takes its own names.

**Errors** (`src/kv/errors.zig`): one explicit set. Lower sets are mapped by exhaustive
`switch` (no `else`), so a new lower variant breaks the build. The item 4 implementer verifies
which error `PageManager.allocate` returns at `page_count_max`; it maps to `NoSpaceLeft`.

```zig
pub const Error = error{
    Corrupted, ChecksumMismatch,          // untrusted bytes, half states, missing log
    WouldBlock,                           // lock held; PageManager.create AlreadyExists (race)
    OutOfMemory,                          // open only
    NoSpaceLeft,                          // disk full; page_count_max growth limit
    AccessDenied, Canceled,               // from Io; Canceled inside a commit also latches
    InputOutput,                          // every other Io variant
    KeyTooLarge, ValueTooLarge, BatchTooLarge, HeightLimit,
    SegmentLimit, LsnExhausted,           // log limits that survive §7 headroom
    Failed,                               // latched writer, tree or Db: reopen
};
// OpenError, GetError, PutError, DeleteError, ScanError, CommitError, FlushError,
// CheckpointError: named subsets of Error, each listed in db.zig.
```

`PoolExhausted` and `FreesPendingLimit` are absent: §8's floors make them assertions.

*Testable:* each subset is a compile-time subset of `Error`. Each mapping switch has a test per
source variant group.

### 11. Test obligations (feed plan 006 items 4–10)

- **Item 4, `db.zig` create and ops.** §1 names and `WouldBlock`; foreign dir `Corrupted`; §3
  create order (syscall trace via `FaultIo`); §5 `FailingAllocator` after open and at each open
  index; §6 limit edges at 512 B and 4 KiB; round trip at 3 sizes; reopen after `close`.
- **Item 5, recovery and checkpoint.** §3 one test per half-state row; §4 reopen twice = once;
  `wal/` deleted or emptied beside `wal_lsn` 0 and ≠ 0; page 1 trunk, overflow or `Unwritten`;
  replay after checkpoint skips older frames; §7 auto-checkpoint keeps
  `live_count < wal_segments_max`.
- **Item 6, commit frame.** Golden `commit` frame; `first_lsn` out of rule, a hole and a foreign
  group all `Corrupted`; v0.6.0 decode of type 4 is `Corrupted`; truncation is crash-idempotent;
  the three `ops_max` copies folded.
- **Item 7, `batch.zig`.** §8 cut inside a group; `BatchTooLarge` by ops and by bytes with
  bytes unchanged; mid-batch rotation crash; `HeightLimit` mid-group latches, reopen is
  pre-batch.
- **Item 8, `iterator.zig`.** §9 range cases at 3 sizes; overflow whole; generation assert; one
  live scan.
- **Item 9, `FaultIo`.** Unsynced write → old bytes; `sync_dir` drops unsynced names (§3 C2/C3
  rows).
- **Item 10, crash model.** Random put, delete, batch, scan, checkpoint and reopen. Mutants:
  commit skips sync, gate = `durable_lsn`, replay past `K`, no truncate, redo ignores lsn.

### Rejected alternatives

- **Meta page holding the root.** Needs a meta or page-0 image path (ADR-0003 OQ2); a fixed id
  costs nothing.
- **Root id in page 0 `reserved`.** A page format change, rewritten in place, no image path.
- **One `page_images` frame per batch.** 1 op at ≥ 16 KiB, 7 at 4 KiB (§8 table).
- **`commit` frame without truncation.** Uncommitted frames mid-log need lookahead or buffered
  groups.
- **Gate on `writer.durable_lsn`.** A rotation sync lets a batch's pages reach disk before its
  commit.
- **`release_frees` after commit.** Its error would follow a durable op; the caller cannot tell.
- **A `LOCK` file.** One more create step and half state; the page file lock already orders open.
- **Auto-delete a half-created dir.** Cannot prove `kv` made those files; deleting could lose
  data.
- **Empty `wal/` reseeded on open.** Silently resets a database (ADR-0003 OQ3).
- **`Db.open(target: *Db, ...)`.** Changes the PRD signature; one `State` allocation keeps `Db`
  movable.
- **Option defaults.** Hidden choices; Tiger Style passes options at the call site.

## Consequences

**Binding.**
- PRD §4.8 links this ADR in the same PR.
- The item 4 PR replaces §4.8's `Options` block with §5's and adds `Iterator.deinit`.
- `pages.db`, `wal`, page 1 and frame type 4 are written only through `src/kv/db.zig` and
  `wal/frame.zig`. A name or rule change without a new page file name is rejected on review.

**Plan 006 impact.**
- Item "Tree op groups" becomes "commit frame and commit-bounded recovery". Its scope: type 4
  in `wal/frame.zig` and `Writer.append`; the `CommitScan` `Apply`; a new
  `Recovery.truncate_after(io, dir, lsn, options)` that `setLength`s the segment holding `lsn`,
  deletes newer segments in descending order, then syncs the file and the directory. Folding
  the three `ops_max` copies stays in that item.
- `group_begin`/`group_end` are not built. This is the fallback plan 006 Risks already names.
- The CHANGELOG notes that v0.6.0 rejects a kv log as `Corrupted`.

**Good.**
- Batches of `batch_ops_max` ops are atomic at every page size.
- A deleted WAL can never reset a database silently.
- Every half state is typed, and `open` is idempotent.
- No meta page and no page-0 image path.

**Costs.**
- Every write appends a 25-byte `commit` frame on top of its page images.
- `open` reads the log from `R` twice, plus once more in `Writer.init`; the PRD §5 replay
  floor (< 5 s per GB) applies per pass.
- A batch's pages pin pool memory until commit: 66 MiB at 64 KiB with 64 ops.
- Half-created directories need a human to remove them.

## Open questions (recommendations)

1. **Triple log read on open.** Recommendation: if the replay bench misses its floor at three
   passes, let `Writer.init` take a known tail position, as an additive `Options` field.
2. **Smaller pool floor.** The worst case assumes no page overlap inside a group.
   Recommendation: keep it static for v1; a tighter bound needs a proof, not a measurement.
3. **Group commit across callers.** One caller per `Db` makes the window zero. Recommendation:
   revisit with concurrent access, after `Snapshot` (6A).
4. **`HeightLimit` mid-batch.** It latches the `Db`. Recommendation: accept for v1 (64 KiB
   trees at height 7 only); a prepare-all-ops pass is the fix if a consumer hits it.
