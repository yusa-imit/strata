# strata

> Layers beneath the data — WAL, pages, and a key-value engine for Zig

strata는 플랫폼 파일 I/O 추상화(fsync 정책, mmap, 락), 체크섬이 붙은 페이지 계층과 CLOCK 버퍼 풀, 세그먼트 WAL과 그룹 커밋·체크포인트·크래시 복구, 페이지 기반 B+Tree와 LSM 트리, 그리고 그 위의 임베디드 KV 엔진(RocksDB/LMDB 포지션)과 스트리밍 스냅샷 포맷을 제공한다. silica 스토리지 엔진의 범용 부분을 추출한 것이며, zoltraak의 AOF/RDB, zr의 캐시 스토어, synod의 LogStore가 이 위로 이식된다.

[![CI](https://github.com/yusa-imit/strata/workflows/CI/badge.svg)](https://github.com/yusa-imit/strata/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.15.x-orange.svg)](https://ziglang.org)

---

## Status

**Bootstrap** — API 설계 및 Phase 1 구현 중. 안정 릴리즈 전까지 API는 변경될 수 있다.

## Modules

| Module | Purpose |
|---|---|
| `strata.codec` | varint (LEB128/zigzag), fixed-width LE, CRC32C (hw-accelerated), xxhash64. |
| `strata.file` | Platform file I/O: sync policies (fdatasync/fsync/F_FULLFSYNC), O_DIRECT, preallocate, locks, mmap. |
| `strata.page` | Page header/format, page manager, freelist, file header. |
| `strata.cache` | Buffer pool (CLOCK), pin/unpin guards, dirty tracking, stats. |
| `strata.wal` | Segmented write-ahead log: frames, group-commit writer, reader, checkpoint, recovery. |
| `strata.btree` | Page-based B+Tree: slotted nodes, split/merge, overflow pages, range cursors, bulk load. |
| `strata.lsm` | LSM tree: skiplist memtable, SSTable (blocks, index, bloom), compaction, manifest. |
| `strata.kv` | Embedded KV engine: Db open/get/put/delete/scan, WriteBatch, Snapshot, engine selection. |
| `strata.snapshot` | Streaming snapshot writer/reader with versioned chunked format. |
| `strata.testing` | Crash-injection harness (torn writes, truncation at arbitrary offsets), differential model. |

## Install

```bash
zig fetch --save https://github.com/yusa-imit/strata/archive/refs/tags/v0.1.0.tar.gz
```

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
