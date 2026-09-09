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
  needed no changes — already 0.16-clean; the formal library-sweep ban-list extension (item
  5) is still open. `build.zig.zon` `.minimum_zig_version` is now `"0.16.0"`; CI no longer
  pins a Zig version, resolving it from the manifest instead.

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
