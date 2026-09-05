# strata — Milestones

> 마일스톤은 **이름(테마)** 으로 관리한다. 버전 번호는 릴리즈 시점에 `build.zig.zon` 현재 버전 + 1 로 결정한다.
> 상세 요구사항: `docs/PRD.md`. 진행 상황은 이 파일의 체크박스가 단일 진실이다.

## 현재 상태

- **Phase**: Bootstrap 완료 → Phase 1 착수
- **버전**: 0.1.0 (미릴리즈)
- **CI**: 초기 워크플로우 등록

## Phase 1 — Codec & File

- [ ] 1A `codec/{varint,fixed,crc32c,xxhash}.zig`
- [ ] 1B `file/file.zig` — sync/preallocate/lock
- [ ] 1C `file/mmap.zig`
- [ ] 1D `testing/crash.zig` — torn-write generator

## Phase 2 — Page & Cache

- [ ] 2A `page/{header,manager,freelist}.zig`
- [ ] 2B `cache/buffer_pool.zig` (CLOCK), `cache/guard.zig`
- [ ] 2C page-size matrix tests

## Phase 3 — WAL & Recovery

- [ ] 3A `wal/frame.zig`, `wal/segment.zig`
- [ ] 3B `wal/writer.zig` — group commit
- [ ] 3C `wal/reader.zig`, `wal/recovery.zig`
- [ ] 3D `wal/checkpoint.zig`
- [ ] 3E crash-recovery property tests

## Phase 4 — B+Tree & KV

- [ ] 4A `btree/node.zig` — slotted page
- [ ] 4B `btree/tree.zig` — insert/get/delete, split/merge
- [ ] 4C `btree/cursor.zig`, `btree/overflow.zig`
- [ ] 4D `kv/{db,batch,iterator}.zig` (btree engine)
- [ ] 4E B+Tree fuzz campaign

## Phase 5 — LSM

- [ ] 5A `lsm/memtable.zig`, `lsm/sstable.zig`
- [ ] 5B `lsm/compaction.zig`, `lsm/manifest.zig`
- [ ] 5C `kv/db.zig` LSM engine option
- [ ] 5D block compression (optional)

## Phase 6 — Snapshot & Integration

- [ ] 6A `snapshot/{writer,reader}.zig`
- [ ] 6B synod LogStore adapter
- [ ] 6C zoltraak AOF on strata WAL (PoC)
- [ ] 6D silica page/cache/wal on strata (PoC)


## 성능 목표

`docs/PRD.md` §5 참조. 각 Phase 완료 시 `zig build bench` 결과를 아래에 기록한다.

| 날짜 | 지표 | 측정값 | 목표 | 비고 |
|---|---|---|---|---|
| | | | | |
