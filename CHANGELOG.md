# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/) with the 0.x exception noted in
`citadel/protocol/VERSIONING.md` (MINOR may break during 0.x).

## [Unreleased]

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
