# Plan 002 — Phase 1: codec primitives, file I/O, crash harness

## Goal

Land the bottom two PRD layers as real, tested code — `codec` (§4.1) and `file` (§4.2, per
ADR-0001) — plus the crash-injection harness (`src/testing/crash.zig`, §6 Phase 1D) later
durability tests depend on. Ends with **v0.3.0**, strata's first tag to ship functionality.

## Why now

v0.2.0 armed the tooling and shipped zero storage logic: all ten modules are still ~20-line
`pub const Error = error{NotImplemented}` stubs with one `refAllDecls` test each (STATE.md).
`codec` has zero internal dependencies and everything above it is blocked on it — page checksums
(§4.3), WAL frame CRCs (§4.5), SSTable footers (§4.7), snapshot trailers (§4.9) — REALM.md
admits no exception to "every disk-written byte is checksummed". `file` is the only module
allowed to branch on `builtin.os.tag`, so every fsync-policy decision is blocked on it too. 1D is
pulled ahead of 1C (mmap): WAL and B+Tree need torn-write injection long before anything needs a
mapping, and nothing in the kingdom maps a file today.

## Scope

No item is blocked — `.dependencies = .{}`, strata waits on no producer tag.

- [ ] **`tools/tidy.zig` self-hosting gap** (`tools/`). Fix the Tiger Style gap before adding
      features: the lint that will guard Phase 1 does not lint itself — `scan_roots` excludes
      `tools/` and `tidy.zig` is 2100 lines against its own 800-line rule (open since cycle 5).
      Split into modules under 800 lines (checks / scanner / reporter); add `"tools"` to
      `scan_roots`, adjust `assert(scan_roots.len == 3)`. No exemption table — PR #13 refused one
      on purpose. Verify: `zig build tidy` exits 0 with `tools/` in scope, no file over 800.
- [ ] **`codec/fixed.zig` + `codec/varint.zig`** (`src/codec/`). Paired: both pure byte-slice
      codecs, same test shape. `fixed`: LE `u16/u32/u64` read/write, bounds-checked with
      `error.BufferTooSmall`. `varint`: LEB128 `u64` and zigzag `i64`, hard cap 10 bytes, typed
      errors on truncated/overlong input, never `@panic` (REALM.md). Verify: boundary vectors 0,
      1, 127, 128, 2^14-1, 2^21, `maxInt(u64)` round-trip; truncated/overlong buffers each error.
- [ ] **`codec/crc32c.zig`** (`src/codec/`). Castagnoli CRC32C: table-driven software path plus a
      hardware path (SSE4.2 `crc32`, ARMv8 `crc32cx`) selected by CPU *feature* detection
      (`std.Target.<arch>.featureSetHas`), not `builtin.os.tag` — keeps REALM.md's "platform
      branching only in `file/`" rule intact; note this in the `//!` header. Software path may
      wrap `std.hash.crc.Crc32Iscsi`. Verify: RFC 3720 B.4 vectors (32×`0x00` → `0x8A9136AA`,
      32×`0xFF` → `0x62A8AB43`, `0x00..0x1F` → `0x46DD794E`), check value
      `crc32c("123456789") == 0xE3069283`; hw/sw parity over lengths 0..256 plus random buffers.
- [ ] **`codec/xxhash.zig`** (`src/codec/`). xxhash64 for bloom filters (§4.7) and memtable
      bucketing — an asserted wrapper over `std.hash.XxHash64` plus a frozen on-disk digest
      spelling (LE `u64` via `codec.fixed`) and a documented seed contract. Verify: reference
      vectors at seed 0 and non-zero; one-shot vs streaming parity; digest byte order asserted.
- [ ] **`file/file.zig` core — open, close, positional I/O** (`src/file/`). `SyncPolicy`,
      `OpenOptions`, `File` exactly as PRD §4.2: a copyable leaf value type that never caches `io`
      (ADR-0001), `io: Io` first for `open`, first after the receiver elsewhere, on
      `Io.Dir`/`Io.File`. This cycle: `open`/`close`/`readAt`/`readAtAll`/`writeAt`/`writeAtAll`/
      `length`/`setLength`. `direct: true` returns `error.UnsupportedDirectIo` for now. Verify:
      `std.testing.tmpDir` + `std.testing.io` round-trips at offset 0, non-zero offset, past EOF;
      `readAtAll` short read returns `error.UnexpectedEof`, `readAt` returns the short count.
- [ ] **`file/file.zig` durability — sync, preallocate, lock** (`src/file/`). The one
      platform-branch cycle `file/` is allowed: `sync` exhaustively switches on `SyncPolicy`
      (`none` no-op, `fdatasync`, `fsync`, `full_fsync` → `F_FULLFSYNC` on macOS), `preallocate`
      uses `fallocate`/`F_PREALLOCATE` falling back to `setLength`, `lock`/`unlock` wrap
      `flock`/`LockFileEx`. fsync is policy, never a silent skip (REALM.md). Verify: `tmpDir` test
      per policy asserting data survives reopen; exclusive lock taken twice returns
      `error.WouldBlock`; compile-time exhaustiveness test over `SyncPolicy`.
- [ ] **`testing/crash.zig` — torn-write generator** (`src/testing/`). PRD §8's first pillar,
      prerequisite for Phase 3E/4E — lands before mmap. A `File`-shaped sink that stops after N
      bytes (clean truncation) or writes a partial 512-byte sector (torn write), plus
      `forEachTruncation` enumerating every cut point under a `count_max` bound. Deterministic:
      seeded PRNG and injected `io` only, no wall clock. Verify: sink writes exactly N bytes;
      enumerator visits `len + 1` points and no more.
- [ ] **Truncation matrix over a checksummed record** (`src/testing/`, `tests/`). Proves the
      harness catches corruption: write a `codec`-checksummed record through the crash sink at
      every truncation point and assert each prefix is rejected as a typed error
      (`error.TornWrite`/`error.ChecksumMismatch`), never silently accepted, never `@panic`
      (REALM.md). Include lengths spanning 512B and 64KB. Verify: matrix green; a deliberately
      unchecked decode path fails the test.
- [ ] **Codec bench baseline** (`bench/main.zig`). PRD §8 wants ±10% regression detection with no
      baseline yet; codec is the only measurable layer this milestone. Measure crc32c GB/s (hw
      and sw), xxhash64 GB/s, varint ops/s. Verify: `zig build bench` exits 0 in ReleaseFast,
      prints all four figures, recorded in `docs/plans/000-inherited.md`'s table.
- [ ] **Docs, module status, release v0.3.0** (`docs/`, `README.md`, `build.zig.zon`). Only after
      every box above ticks. Drop `NotImplemented` from `src/codec.zig`/`src/file.zig`, re-export
      real declarations; flip README's codec/file/testing rows `Planned` → `Landed`; tick
      1A/1B/1D in `docs/plans/000-inherited.md`; re-audit STATE.md's Tiger Style table now that
      real logic exists. `CHANGELOG.md` + `.version = "0.3.0"` in one PR, then tag. Verify:
      `git tag` contains `v0.3.0`; `gh release view v0.3.0` succeeds; no `NotImplemented` left.

## Out of scope

- **1C `file/mmap.zig`** — deferred to plan 003; nothing reads a mapping until LSM SSTables
  (§4.7).
- A working `O_DIRECT`/`F_NOCACHE` path — this milestone only types the option and returns
  `error.UnsupportedDirectIo`/`error.PageSizeUnaligned`; alignment-aware I/O needs the page layer.
- `page`, `cache`, `wal`, `btree`, `lsm`, `kv`, `snapshot` — Phase 2+ and still stubs afterwards.
- Compression (§6 Phase 5D), the differential HashMap model (Phase 3E), consumer adapters for
  silica/zoltraak/synod (Phase 6).

## Risks

- **CI runs one architecture.** Linux tests + 6 cross-compile targets — macOS/Windows legs
  *compile* but never *execute*, so `F_FULLFSYNC`/`F_PREALLOCATE`/`LockFileEx` ship untested.
  Mitigation: keep those branches thin, assert both sides of every `switch`, document coverage.
- **Hardware CRC path may not execute on the runner.** A CPU lacking SSE4.2 makes the hw/sw
  parity test silently test sw twice. Mitigation: assert *which* path ran; skip loudly, not quietly.
- **Crash-harness fidelity.** Simulated truncation is not power loss; it cannot reproduce
  reordered or partial-flush sectors. A floor, not a proof — say so in the module `//!` doc.
- **Tidy split churn.** Restructuring `tools/tidy.zig` while feature PRs queue behind it invites
  conflicts; it goes first, alone, for exactly that reason.

## Done when

- `zig build`, `zig build test`, `zig build tidy` exit 0 on Zig 0.16.0 with `tools/` inside
  `scan_roots` and no file over 800 lines.
- `src/codec/{fixed,varint,crc32c,xxhash}.zig`, `src/file/file.zig`, `src/testing/crash.zig`
  exist, are re-exported, carry no `NotImplemented`; test count well above the 11 stubs.
- All 7 CI jobs green on `main`; `zig build bench` prints the four codec baselines.
- `git tag` contains `v0.3.0` and `gh release view v0.3.0` succeeds.

## Version impact

**MINOR** — 0.2.0 → **0.3.0** (`citadel/protocol/VERSIONING.md`: a milestone of additive
features is MINOR). New surface on a pre-1.0 foundation repo with no consumers — no sibling
`build.zig.zon` names strata — so removing `NotImplemented` breaks nothing that ever compiled,
and MINOR may break during 0.x anyway. Not MAJOR: no toolchain move or shipped-API signature
change. No consumer `migration` issues follow.
