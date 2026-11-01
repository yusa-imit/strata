# strata

> Layers beneath the data — WAL, pages, and a key-value engine for Zig

strata는 플랫폼 파일 I/O 추상화(fsync 정책, mmap, 락), 체크섬이 붙은 페이지 계층과 CLOCK 버퍼 풀, 세그먼트 WAL과 그룹 커밋·체크포인트·크래시 복구, 페이지 기반 B+Tree와 LSM 트리, 그리고 그 위의 임베디드 KV 엔진(RocksDB/LMDB 포지션)과 스트리밍 스냅샷 포맷을 제공한다. silica 스토리지 엔진의 범용 부분을 추출한 것이며, zoltraak의 AOF/RDB, zr의 캐시 스토어, synod의 LogStore가 이 위로 이식된다.

[![CI](https://github.com/yusa-imit/strata/workflows/CI/badge.svg)](https://github.com/yusa-imit/strata/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16.x-orange.svg)](https://ziglang.org)

---

## Status

**Phases 1 to 4a landed (v0.6.0)** — `codec`, `file` (without mmap), `page`, `cache`, `wal`,
`btree` and the `testing` crash harness are real, tested code. `lsm`, `kv` and `snapshot` are
still stubs (a doc comment and an `Error` set). 안정 릴리즈 전까지 API는 변경될 수 있다.

## Modules

| Module | Purpose | Status |
|---|---|---|
| `strata.codec` | varint (LEB128/zigzag), fixed-width LE, CRC32C (hw-accelerated), xxhash64. | Landed |
| `strata.file` | Platform file I/O: sync policies (fdatasync/fsync/F_FULLFSYNC), O_DIRECT, preallocate, locks, mmap. | Landed (mmap planned) |
| `strata.page` | Page header/format, page manager, freelist, file header. | Landed |
| `strata.cache` | Buffer pool (CLOCK), pin/unpin guards, dirty tracking, stats. | Landed |
| `strata.wal` | Segmented write-ahead log: frames, group-commit writer, reader, checkpoint, recovery. | Landed |
| `strata.btree` | Page-based B+Tree: slotted nodes, split/merge, overflow pages, range cursors, WAL-logged insert/delete. | Landed (bulk load planned) |
| `strata.lsm` | LSM tree: skiplist memtable, SSTable (blocks, index, bloom), compaction, manifest. | Planned |
| `strata.kv` | Embedded KV engine: Db open/get/put/delete/scan, WriteBatch, Snapshot, engine selection. | Planned |
| `strata.snapshot` | Streaming snapshot writer/reader with versioned chunked format. | Planned |
| `strata.testing` | Crash-injection harness (torn writes, truncation at arbitrary offsets), differential model. | Landed (model planned) |

## Install

```bash
zig fetch --save https://github.com/yusa-imit/strata/archive/refs/tags/v0.6.0.tar.gz
```

v0.6.0 adds the B+Tree (ADR-0004 format v1: slotted leaf and internal pages, overflow chains,
cursors, WAL-logged insert and delete). v0.5.0 added the segmented write-ahead log (ADR-0003
WAL format v1: segment files, group-commit writer, reader, recovery replay, full-page-image
redo, checkpoint with segment reclaim) and the buffer pool's WAL-before-data gate on top of the
v0.4.0 page layer and CLOCK buffer pool (see `CHANGELOG.md`).
Modules marked `Planned` above ship nothing yet.

```zig
// build.zig
const strata = b.dependency("strata", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("strata", strata.module("strata"));
```

## Build

```bash
zig build            # library + CLI
zig build test       # unit tests
zig build bench      # benchmarks
zig build docs       # API docs → zig-out/docs
```

## Part of the Zig Kingdom

strata is a foundation component consumed by: silica, zoltraak, zr, synod.
See [citadel](https://github.com/yusa-imit/citadel) for the full map.

## License

MIT — see [LICENSE](LICENSE).
