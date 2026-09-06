# Changelog

All notable changes to this project are documented in this file. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/) with the 0.x exception noted in
`citadel/protocol/VERSIONING.md` (MINOR may break during 0.x).

## [Unreleased]

### Fixed

- `src/root.zig` doc comment pointed at `docs/milestones.md`, renamed to
  `docs/plans/000-inherited.md`; now points at `docs/plans/`.

### Added

- This changelog.
- `tools/tidy.zig`: kingdom `tidy` lint, shape checks (line length ≤ 100 Unicode code
  points, every `.zig` file under `src/` opens with a `//!` doc header). Wired into
  `zig build test` via a new `zig build tidy` step so it cannot be skipped.
