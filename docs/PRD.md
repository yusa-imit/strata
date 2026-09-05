# strata — Product Requirements Document

> **strata**: 데이터 아래 켜켜이 쌓인 지층. Zig 왕국의 스토리지 커널 — WAL, 페이지, KV 엔진.
> Layer: **Foundation** · Consumers: silica (storage engine), zoltraak (AOF/RDB), zr (cache store), synod (LogStore)

---

## 1. 배경과 문제

silica는 B+Tree·버퍼 풀·WAL·체크포인트를 가진 완성도 높은 스토리지 엔진을 `src/storage/`에 갖고 있다. zoltraak는 `storage/{aof,persistence}.zig`로 AOF와 RDB 스냅샷을 따로 구현했다. zr의 `cache/store.zig`는 파일 기반 캐시다. synod는 내구성 있는 로그 저장소가 필요하다.

네 곳 모두 같은 프리미티브를 원한다: **"디스크에 안전하게 쓰고, 죽어도 복구되고, 빠르게 읽는다."**

strata는 silica의 스토리지 엔진에서 범용 부분을 **추출**해 독립 라이브러리로 만든다. silica는 이후 strata 위에 SQL 카탈로그/MVCC만 얹는다.

## 2. 목표 (Goals)

1. **내구성 프리미티브**: 세그먼트 WAL, 그룹 커밋, fsync 정책, 크래시 복구 — 크래시 주입 테스트로 검증
2. **페이지 계층**: 페이지 포맷(체크섬, 타입, 버전), 페이지 매니저, 프리리스트, 버퍼 풀(CLOCK/LRU, pin/unpin)
3. **인덱스 구조**: 페이지 기반 B+Tree(가변 키, 오버플로 페이지, 범위 커서), LSM(memtable + SSTable + 컴팩션)
4. **KV 엔진**: `Db.open/get/put/delete/scan`, WriteBatch, 스냅샷 읽기, TTL(선택) — RocksDB/LMDB 포지션
5. **스냅샷 포맷**: 스트리밍 스냅샷 writer/reader (zoltraak RDB 대체)
6. **플랫폼 파일 I/O 추상화**: fsync/fdatasync/F_FULLFSYNC, O_DIRECT, mmap, preallocate, 파일 락, 플랫폼별 차이 격리
7. **제로 의존성**: Zig std만 사용. 압축(LZ4/zstd)은 선택 기능(Phase 5)

## 3. 비목표 (Non-Goals)

- SQL, 스키마, 쿼리 플래닝 — silica 몫
- 분산 복제 — synod 몫 (strata는 로컬 내구성만)
- 네트워크 — 없음

## 4. 아키텍처

```
┌──────────────────────────────────────────────────┐
│ kv: Db · WriteBatch · Iterator · Snapshot         │
├────────────────────────┬─────────────────────────┤
│ btree: BPlusTree       │ lsm: MemTable · SSTable  │
│   Cursor · Overflow    │   Compaction · Bloom     │
├────────────────────────┴─────────────────────────┤
│ cache: BufferPool (CLOCK) · PageGuard             │
├──────────────────────────────────────────────────┤
│ wal: Segment · Writer(group commit) · Reader ·    │
│      Checkpoint · Recovery                        │
├──────────────────────────────────────────────────┤
│ page: Header · PageManager · Freelist             │
├──────────────────────────────────────────────────┤
│ snapshot: Writer · Reader (streaming, versioned)  │
├──────────────────────────────────────────────────┤
│ file: File(fsync policy) · Mmap · Lock · Prealloc │
├──────────────────────────────────────────────────┤
│ codec: varint · fixed · crc32c · xxhash64         │
└──────────────────────────────────────────────────┘
```

### 4.1 `codec`
- `varint` (LEB128 u64/i64 zigzag), `fixed` (LE u16/u32/u64), `crc32c` (SSE4.2/ARMv8 CRC 하드웨어 가속 + 소프트웨어 폴백), `xxhash64`

### 4.2 `file`
```zig
pub const SyncPolicy = enum { none, fdatasync, fsync, full_fsync /* macOS F_FULLFSYNC */ };
pub const File = struct {
    pub fn open(path, .{ .create, .direct, .sync_policy }) !File;
    pub fn readAt(self, buf, offset) !usize;
    pub fn writeAt(self, data, offset) !usize;
    pub fn sync(self) !void;               // policy에 따라
    pub fn preallocate(self, len) !void;   // fallocate / F_PREALLOCATE
    pub fn lock(self, .exclusive) !void;   // flock / LockFileEx
};
pub const Mmap = struct { ... };           // 읽기 전용 SSTable 매핑
```

### 4.3 `page`
- 페이지 헤더: `magic(4) | page_type(1) | flags(1) | version(2) | checksum(4) | lsn(8) | payload...`
- 크기 512B–64KB (comptime 또는 open 시 결정), 기본 4KB
- `PageManager`: allocate/free/read/write, 프리리스트 (연결 리스트 + 비트맵 하이브리드), 파일 헤더(magic `STRA`, page_size, page_count, freelist_head, wal_lsn)

### 4.4 `cache`
- `BufferPool`: CLOCK 교체, pin/unpin 참조 카운트, dirty 추적, write-back, 페이지 정렬 할당
- `PageGuard`: RAII 스타일 pin 해제 (`defer guard.release()`)
- 통계: hit/miss/evictions (관측성 훅)

### 4.5 `wal`
- 세그먼트 파일 (`wal-000001.log`), 프레임: `len | crc | lsn | type | payload`
- `Writer`: 그룹 커밋 (배치 윈도우 N µs 또는 M 바이트), fsync 정책 위임
- `Reader`: 순차 재생, 손상 프레임에서 안전 중단 (torn write 감지)
- `Checkpoint`: 더티 페이지 flush → 세그먼트 회수
- `Recovery`: 마지막 체크포인트 이후 재생, idempotent apply

### 4.6 `btree`
- 가변 길이 키/값, slotted page, 내부 노드 `[key, child]`, 리프 `[key, value] + next_leaf`
- split/merge/rebalance, 오버플로 페이지(큰 값), 범위 커서(prev/next/seek), 벌크 로드
- `validate()` — 정렬, 팬아웃, 연결 리스트 불변식

### 4.7 `lsm`
- `MemTable` (skiplist), `SSTable` (블록 + 인덱스 + 블룸 + 푸터), 레벨/티어 컴팩션, 매니페스트
- 읽기 경로: memtable → immutable → L0..Ln, 블룸 필터 스킵

### 4.8 `kv`
```zig
var db = try Db.open(allocator, "data/", .{ .engine = .btree /* or .lsm */, .sync = .fdatasync });
defer db.close();
try db.put("k", "v");
const v = try db.get("k");             // ?[]const u8 (borrowed until next write)
var batch = db.batch(); try batch.put(...); try batch.delete(...); try batch.commit();
var it = try db.scan(.{ .start = "a", .end = "z" }); while (try it.next()) |kv| { ... }
const snap = db.snapshot(); defer snap.release();
```

### 4.9 `snapshot`
- 스트리밍 포맷: 헤더(버전, 엔진, 페이지 크기) + 청크(타입, len, crc) + 트레일러(총 crc, 엔트리 수)
- writer는 어떤 `anytype` writer로도 출력(파일, 소켓) → zoltraak 복제 초기 동기화, synod InstallSnapshot에 재사용

## 5. 성능 목표

| 지표 | 목표 |
|---|---|
| WAL append (그룹 커밋, fdatasync, NVMe) | 200k ops/s |
| B+Tree point get (버퍼 풀 히트) | 5M ops/s (단일 스레드) |
| B+Tree 순차 insert | 1M ops/s |
| LSM 랜덤 write | 500k ops/s |
| 복구 시간 | 1GB WAL < 5s |
| 버퍼 풀 오버헤드 | 페이지당 < 64B 메타데이터 |

## 6. 마일스톤

### Phase 1 — Codec & File
- 1A `codec/{varint,fixed,crc32c,xxhash}.zig` — 하드웨어 CRC 감지 포함
- 1B `file/file.zig` — 플랫폼별 sync/preallocate/lock
- 1C `file/mmap.zig`
- 1D 크래시 주입 테스트 하네스 `testing/crash.zig` (쓰기 도중 프로세스 kill 시뮬레이션: torn write 생성기)

### Phase 2 — Page & Cache
- 2A `page/header.zig`, `page/manager.zig`, `page/freelist.zig`
- 2B `cache/buffer_pool.zig` (CLOCK), `cache/guard.zig`
- 2C 페이지 크기 512/4096/65536 매트릭스 테스트

### Phase 3 — WAL & Recovery
- 3A `wal/frame.zig`, `wal/segment.zig`
- 3B `wal/writer.zig` — 그룹 커밋
- 3C `wal/reader.zig`, `wal/recovery.zig`
- 3D `wal/checkpoint.zig`
- 3E 크래시 복구 프로퍼티 테스트 (임의 지점 crash → 복구 후 불변식)

### Phase 4 — B+Tree & KV (btree engine)
- 4A `btree/node.zig` — slotted page 인코딩
- 4B `btree/tree.zig` — insert/get/delete, split/merge
- 4C `btree/cursor.zig`, `btree/overflow.zig`
- 4D `kv/db.zig` (btree 백엔드), `kv/batch.zig`, `kv/iterator.zig`
- 4E B+Tree fuzz 캠페인

### Phase 5 — LSM engine
- 5A `lsm/memtable.zig` (skiplist), `lsm/sstable.zig`
- 5B `lsm/compaction.zig`, `lsm/manifest.zig`
- 5C `kv/db.zig` LSM 백엔드 선택
- 5D 블록 압축 (LZ4, 선택)

### Phase 6 — Snapshot & Integration
- 6A `snapshot/{writer,reader}.zig`
- 6B synod `LogStore` 어댑터 (WAL 기반)
- 6C zoltraak AOF를 strata WAL로 이식 (PoC)
- 6D silica 스토리지 엔진의 page/cache/wal을 strata로 교체 (PoC)

## 7. 설계 원칙

- **모든 디스크 바이트에 체크섬** — 예외 없음
- **fsync는 정책이지 가정이 아니다** — 호출자가 `SyncPolicy`를 고른다
- **복구는 멱등** — 같은 WAL을 두 번 재생해도 결과 동일
- **호출자 버퍼, 빌려주는 값** — `get()`은 다음 쓰기까지 유효한 슬라이스 반환, 복사는 호출자 선택
- **`@panic` 금지** — `error.Corrupted`, `error.ChecksumMismatch`, `error.TornWrite`
- **파일 포맷은 버전 필드 포함** — 마이그레이션 경로 확보

## 8. 테스트 전략

- 크래시 주입: 임의 오프셋에서 쓰기 절단 → 복구 → 불변식/데이터 검증
- 프로퍼티: 랜덤 op 시퀀스를 인메모리 모델(HashMap)과 비교 (differential)
- 페이지 크기 매트릭스, 큰 값(오버플로), 빈 DB, 가득 찬 프리리스트
- 벤치: `bench/` 각 계층별, CI에서 회귀 감지(±10%)

## 9. 리스크

| 리스크 | 완화 |
|---|---|
| silica에서 추출 시 API 불일치 | Phase 6D를 PoC 브랜치로, silica는 어댑터 층 유지 |
| macOS fsync 시맨틱 (F_FULLFSYNC 필요) | `SyncPolicy.full_fsync` 명시 + 문서화 |
| LSM 컴팩션 복잡도 | Phase 5는 btree KV가 안정된 뒤 착수 |
