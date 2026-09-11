# ADR-0001 — `io: Io` injection in the strata public API

- **Status**: Accepted
- **Date**: 2026-09-11
- **Milestone**: plan `docs/plans/001-zig-0.16-and-tiger-baseline.md`, item "`io: Io` convention
  in the public API"
- **Applies to**: `docs/PRD.md` §4.2–§4.9, and all of Phase 1–6 implementation
- **Supersedes**: nothing. **Depends on**: memory ADR-001 (zero external dependencies,
  `citadel/realms/strata/memory/decisions.md` — a separate 3-digit series from this `docs/adr/`
  4-digit series; not the same document)

## Context

Zig 0.16 deleted blocking I/O from `std.fs`, `std.net`, `std.time` and `std.Thread` and reborn it
behind a single runtime vtable value, `std.Io`. Anything that can block, race, or be canceled now
takes an `io: Io` argument. strata is a **foundation library** with four planned consumers
(silica, zoltraak, synod, and its own tiny CLI in `src/main.zig`), and it is 100% unimplemented:
265 LOC of stubs, no real logic. The PRD was written against 0.15-era `std.fs` shapes
(`File.open(path, ...)`, `readAt(self, buf, offset)`, snapshot writers typed `anytype`).

Three questions have to be answered once, now, before Phase 1A writes its first line — because
each of them is a source-wide refactor if answered late:

1. **Who constructs the `Io`?** A library that calls `Io.Threaded.init` picks the runtime for its
   consumer, silently defeating the interface (and making sirocco's future `Io.VTable`
   implementation unusable under strata). It also breaks determinism: tests could not substitute
   a fault-injecting or `Io.failing`-derived double, and the PRD's crash-injection harness
   (`testing/crash.zig`, Phase 1D) depends on exactly that substitution.
2. **Per-call parameter, or cached field?** `citadel/core/rules/zig-0.16.md` allows both: leaf and
   free functions take `io` per call and must not stash it; a long-lived owning struct MAY cache
   an `io` field set once at construction, mirroring `std.http.Client`. strata has ten modules
   spanning both shapes, from a value-type file handle to a `Db` that lives for the process.
3. **Where does `io` sit in the parameter list, and what about `gpa`?** Tiger Style writes
   `init(target: *Parser, gpa: Allocator, options: Options)`; the kingdom `Io` rule says `io` is
   the first parameter after the receiver. Constructors have no receiver at all.

A secondary question rides along: §4.9's snapshot writer was specified as `anytype`, which
predates 0.16 having first-class `*Io.Writer`/`*Io.Reader` vtable stream interfaces.

## Decision

### 1. strata never constructs an `Io`

No `Io.Threaded.init`, no `Io.Evented`, no `Io.Threaded.global_single_threaded`, and no
package-level "default runtime" anywhere under `src/`. The binary chooses the implementation at
`main(init: std.process.Init)` and injects `init.io` downward: silica, zoltraak, synod, or
strata's own CLI. Tests take their `Io` from `std.testing.io` and nothing else — never a helper
shared between test and non-test code. This makes sirocco's eventual `Io.VTable` a drop-in for
every strata consumer at zero cost to strata.

### 2. One cached `Io` per object graph: `kv.Db`. Everything else takes it per call

| Module | Placement |
|---|---|
| `codec` | no `io` at all |
| `file` | per call on every method; `File.open(io, dir, sub_path, opts)` |
| `page` | per call (`PageManager` owns a `file.File`, not an `Io`) |
| `cache` | per call on `fetch`/`flushAll` only |
| `wal` | per call (`Writer`, `Reader`, `Recovery`, `Checkpoint`) |
| `btree` | per call on `tree`/`cursor`; none in `node.zig` |
| `lsm` | per call on `SsTable`/`Manifest`/`Compaction`; none on `MemTable`/`Bloom` |
| `kv` | **cached field**, set once in `Db.open(io, gpa, dir, sub_path, opts)` |
| `snapshot` | no `io` on `Writer`/`Reader` (take `*Io.Writer`/`*Io.Reader`); per call on `restore` |

Why, one bullet per row:
- `codec` — pure computation over `[]const u8`; nothing can block.
- `file` — `File` is a 16-byte leaf value over `Io.File`, whose own methods all take `io` per
  call; copyable, embeddable, no hidden runtime.
- `page` — a pass-through to `file`; header encode/checksum stays pure.
- `cache` — `release`/`unpin`/`markDirty`/`stats`/`discardAll` take no `io`, which is the
  *contract* that they cannot block.
- `wal` — owned by `Db` (or by a consumer's engine); every blocking entry point already has a
  call site holding `io`. `Recovery` passes `io` *into* the `Apply` vtable callback so the
  callee need not cache one either.
- `btree` — node code is pure slotted-page encoding over frame bytes; only page fault-in blocks.
- `lsm` — memtable and bloom filter are pure in-memory.
- `kv` — long-lived owning service object, the `std.http.Client` shape.
- `snapshot` — the caller consumes `io` when constructing the stream.

`Db` caches because a single `db.put("k","v")` fans out into WAL append, group commit, page
eviction and compaction: threading `io` through `get/put/delete/scan` would push an `Io` into
every hot call site, every `WriteBatch`, and every `Iterator` and `Snapshot` struct — the exact
dimensionality the kingdom rules tell us to remove from call sites. `Db.io` is assigned once in
`open` and never reassigned (asserted); using one `Db` under two different `Io` values is a
caller-contract violation, not a supported mode.

`File` does **not** cache, despite also being long-lived, because it is a *value*, not a service:
`std.Io.File` itself takes `io` per call, a cached copy would double the struct and, worse, would
let a `File` opened under one `Io` be used from a call site holding another — an aliasing bug
that per-call parameters make structurally impossible. The rule of thumb this ADR fixes:
**exactly one type in strata's public API stores an `Io`, and it is `kv.Db`.**

### 3. Parameter order

`io: Io` is the first parameter after the receiver. Where there is no receiver (constructors,
free functions), `io` is the **first** parameter — matching std's own no-receiver spelling,
`Io.Dir.openFileAbsolute(io, absolute_path, options)`. `gpa: Allocator` follows `io`:
`Db.open(io, gpa, dir, sub_path, options)`, `Writer.init(target, io, gpa, dir, options)`. This
overrides the parameter order of the Tiger Style example `init(target, gpa, options)` for
I/O-touching functions only, and is chosen for greppability: `io: Io` is always at index 0 or 1,
so `fn \w+\((self[^,]*, )?io: Io` enumerates every blocking function in the library.

### 4. Streams are vtables, not `anytype`

§4.9's snapshot `Writer`/`Reader` take `*Io.Writer`/`*Io.Reader`. These are already runtime vtable
interfaces, so the kingdom design rule ("vtable interfaces for runtime polymorphism, comptime
generics only inside hot paths") forbids re-deriving the same polymorphism with `anytype`. This
yields one machine-code path for file, socket and memory sinks, explicit error sets instead of
inferred ones, and unit tests over `Io.Writer.fixed`/`Io.Reader.fixed` with no filesystem at all.
Because the reader consumes untrusted bytes (zoltraak replica sync, synod `InstallSnapshot`), its
limits are part of the signature: `Reader.begin(in, .{ .chunk_len_max, .chunk_count_max })`.

### 5. No path strings, no `cwd` assumption

Every entry point takes `dir: Io.Dir` plus a `sub_path`, never a bare path string. strata never
calls `Io.Dir.cwd()` internally; the consumer passes the directory it has already opened.

## Consequences

**Binding.** This ADR governs Phase 1–6 (`docs/PRD.md` §6). A PR that adds a public function
touching filesystem, time, sleep, sync or process APIs without `io` in position 0/1, or that
stores an `Io` in any type other than `kv.Db`, is rejected on review regardless of test status.

**Good.**
- Consumers can swap `Io.Threaded` for sirocco's vtable without touching strata.
- The crash-injection harness (Phase 1D) and WAL recovery property tests (3E) become possible:
  a test `Io` can fail, short-write, or tear at a chosen offset without a real filesystem.
- `io`'s *absence* becomes documentation with teeth: `PageGuard.release()`, `Cursor.release()`,
  `MemTable.put`, and all of `codec` are statically knowable as non-blocking, which is what lets
  `defer guard.release()` be infallible.
- Determinism (Tiger Style §7): clock, PRNG, allocator and `Io` are all injected; no global state.

**Costs.**
- Signature churn is front-loaded but not free: every `file`/`page`/`cache`/`wal`/`btree`/`lsm`
  function carries one extra 16-byte parameter. Accepted; `Io` is two pointers, passed in
  registers, and the syscall it fronts dwarfs it.
- `Mmap` has no `std.Io` vtable slot in 0.16, so `file/mmap.zig` will call `posix.system`
  directly — confined to `file/` per the realm rule. It still takes `io: Io` so that call sites
  do not change if std grows a mapping slot later. This is the one place where the parameter is
  currently (partly) decorative, and it is a deliberate forward-compat choice.
- `Db`'s cached `io` is a real footgun surface (one `Db`, two runtimes). Mitigated by an assert
  on single assignment and by the ADR's "exactly one type stores an `Io`" rule.
- Group commit may not use `io.async` for the flusher when producer and consumer must make
  simultaneous progress: it needs `io.concurrent` and must handle
  `error.ConcurrencyUnavailable`. Cancelation (`error.Canceled`, one `l`) must appear in the WAL
  and KV error sets rather than being swallowed.

**Verification (no code exists yet — these land with the modules they guard).**
1. `tools/tidy.zig` ban list additions: `Io.Threaded`, `Io.Evented`, `global_single_threaded`,
   `std.fs.`, `std.time.` (already banned), `std.Thread.` sync types, and `Io.Dir.cwd()` anywhere
   in `src/` outside `src/main.zig`. A fixture per rule goes red.
2. A tidy rule that every `pub fn` whose body mentions `io.` or takes an `Io.File`/`Io.Dir`
   declares `io: Io` at parameter index 0 or 1. The textual "mentions `io.`" heuristic can
   false-positive on an unrelated local also named `io` and false-negative when `io` is threaded
   through a helper with no literal `io.` call; the tidy implementation will need to special-case
   both before this check goes on the ban list for real.
3. An `Io` field may appear only in `src/kv/db.zig` — grep `: Io,` across `src/` and compare
   against a one-entry allow list.
4. Every I/O test obtains `Io` from `std.testing.io`; `src/testing/crash.zig` (Phase 1D) wraps a
   caller-supplied `Io` and never constructs one.
5. Parity, once `file` lands: the same operation sequence through `strata.file.File` and through
   raw `Io.File` produces byte-identical files (differential test), proving the wrapper adds
   policy, not behaviour.
