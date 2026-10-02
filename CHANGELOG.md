# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/) with the 0.x exception noted in
`citadel/protocol/VERSIONING.md` (MINOR may break during 0.x).

## [Unreleased]

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

### Changed

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
