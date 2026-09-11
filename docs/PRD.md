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

- 모든 파일 I/O는 `std.Io` 위에 선다: 경로 문자열 대신 `Io.Dir` + `sub_path`, 핸들은 `Io.File`.
  strata는 라이브러리이므로 `Io`를 **만들지 않는다** — 바이너리가 `main(init)`의 `init.io`를 주입한다 (ADR-0001).
- `io: Io`는 수신자 바로 다음 인자. 수신자가 없는 생성 함수(`open`, `map`)는 `io`가 **첫 인자**
  (std의 `Io.Dir.openFileAbsolute(io, path, opts)`와 같은 모양). `gpa`는 `io` 뒤에 온다.
- `File`은 `io`를 필드로 캐시하지 **않는다** — 호출마다 받는 리프 값 타입이다 (std의 `Io.File`과 동형).
- 플랫폼 분기(`builtin.os.tag`)는 `file/`에만 존재한다.

```zig
const Io = std.Io;

pub const SyncPolicy = enum(u8) { none, fdatasync, fsync, full_fsync /* macOS F_FULLFSYNC */ };

pub const OpenOptions = struct {
    mode: Io.File.Mode = .read_write,
    create: bool = false,
    truncate: bool = false,
    direct: bool = false,                  // O_DIRECT / F_NOCACHE
    lock: Io.File.Lock = .none,            // none · shared · exclusive
    sync_policy: SyncPolicy = .fdatasync,
};

pub const OpenError = Io.File.OpenError || error{ UnsupportedDirectIo, PageSizeUnaligned };
pub const ReadError = Io.File.ReadPositionalError || error{UnexpectedEof};
pub const WriteError = Io.File.WritePositionalError || error{NoSpaceLeft};
pub const SyncError = Io.File.SyncError;

/// 리프 값 타입: `io`를 캐시하지 않는다 (ADR-0001). 복사 가능, 16바이트 내외.
pub const File = struct {
    handle: Io.File,
    sync_policy: SyncPolicy,
    direct: bool,

    pub fn open(io: Io, dir: Io.Dir, sub_path: []const u8, options: OpenOptions) OpenError!File;
    pub fn close(self: File, io: Io) void;

    pub fn readAt(self: File, io: Io, buf: []u8, offset: u64) ReadError!usize;
    pub fn readAtAll(self: File, io: Io, buf: []u8, offset: u64) ReadError!void;   // 짧은 읽기는 error.UnexpectedEof
    pub fn writeAt(self: File, io: Io, data: []const u8, offset: u64) WriteError!usize;
    pub fn writeAtAll(self: File, io: Io, data: []const u8, offset: u64) WriteError!void;

    pub fn sync(self: File, io: Io) SyncError!void;                 // sync_policy에 따라 no-op/fdatasync/fsync/F_FULLFSYNC
    pub fn preallocate(self: File, io: Io, len: u64) PreallocateError!void;  // fallocate / F_PREALLOCATE
    pub fn setLength(self: File, io: Io, len: u64) Io.File.SetLengthError!void;
    pub fn length(self: File, io: Io) Io.File.LengthError!u64;
    pub fn lock(self: File, io: Io, l: Io.File.Lock) Io.File.LockError!void;  // flock / LockFileEx
    pub fn unlock(self: File, io: Io) void;
};

/// 읽기 전용 SSTable 매핑. 0.16 `std.Io`에는 매핑 슬롯이 없어 내부는 `posix.system`으로
/// 직접 구현하지만, 시그니처는 지금부터 `io`를 받는다 — std가 슬롯을 추가해도 호출부는 그대로다.
pub const Mmap = struct {
    bytes: []const u8,

    pub fn map(io: Io, f: File, offset: u64, len_max: usize) MapError!Mmap;
    pub fn unmap(self: *Mmap, io: Io) void;
    pub fn prefetch(self: Mmap, io: Io, offset: u64, len: usize) void;
};
```

### 4.3 `page`
- 페이지 헤더: `magic(4) | page_type(1) | flags(1) | version(2) | checksum(4) | lsn(8) | payload...`
- 크기 512B–64KB (comptime 또는 open 시 결정), 기본 4KB
- `PageManager`: allocate/free/read/write, 프리리스트 (연결 리스트 + 비트맵 하이브리드), 파일 헤더(magic `STRA`, page_size, page_count, freelist_head, wal_lsn)
- `io` 캐시 없음: `PageManager`는 `file.File`을 소유하고 블로킹 메서드
  (`read`/`write`/`allocate`/`free`/`sync`)마다 `io: Io`를 받아 그대로 아래로 넘긴다.
  헤더 인코딩/체크섬은 순수 함수라 `io`를 받지 않는다 (ADR-0001).

### 4.4 `cache`
- `BufferPool`: CLOCK 교체, pin/unpin 참조 카운트, dirty 추적, write-back, 페이지 정렬 할당
- `PageGuard`: RAII 스타일 pin 해제 (`defer guard.release()`)
- 통계: hit/miss/evictions (관측성 훅)
- `io` 캐시 없음 — 디스크를 건드릴 수 있는 메서드만 `io: Io`를 받는다. **`io`가 없는 시그니처는
  "이 호출은 절대 블록하지 않는다"는 계약**이다: `release`/`unpin`/`markDirty`/`stats`는 순수
  장부 작업이고, 더티 페이지 write-back은 오직 `fetch`(축출 경로)와 `flushAll` 안에서만 일어난다.

```zig
pub const Options = struct {
    frames_max: u32,              // 한계는 시그니처의 일부 — 전부 init에서 할당
    page_size: u32 = 4096,
};

pub const BufferPool = struct {
    pages: *page.PageManager,

    pub fn init(target: *BufferPool, gpa: Allocator, pages: *page.PageManager, options: Options) !void; // io 없음: 순수 메모리
    pub fn deinit(self: *BufferPool, gpa: Allocator) void;        // io 없음: 더티 프레임 0을 assert (먼저 flushAll/discardAll)

    pub fn fetch(self: *BufferPool, io: Io, id: page.Id) FetchError!PageGuard;          // 미스 시 read + 축출 시 write-back
    pub fn fetchForUpdate(self: *BufferPool, io: Io, id: page.Id) FetchError!PageGuard;
    pub fn flushAll(self: *BufferPool, io: Io) FlushError!void;
    pub fn discardAll(self: *BufferPool) void;                    // io 없음: 쓰지 않고 버린다
    pub fn stats(self: *const BufferPool) Stats;                  // io 없음
};

pub const PageGuard = struct {
    pub fn bytes(self: *PageGuard) []u8;
    pub fn markDirty(self: *PageGuard) void;                      // io 없음
    pub fn release(self: *PageGuard) void;                        // io 없음, 실패 불가 — `defer guard.release()`
};
```

### 4.5 `wal`
- 세그먼트 파일 (`wal-000001.log`), 프레임: `len | crc | lsn | type | payload`
- `Writer`: 그룹 커밋 (배치 윈도우 N µs 또는 M 바이트), fsync 정책 위임
- `Reader`: 순차 재생, 손상 프레임에서 안전 중단 (torn write 감지)
- `Checkpoint`: 더티 페이지 flush → 세그먼트 회수
- `Recovery`: 마지막 체크포인트 이후 재생, idempotent apply
- `io` 캐시 없음 — `Writer`/`Reader`는 `Db`가 소유하는 하위 부품이고, 블로킹 진입점마다 호출자가
  이미 `io`를 갖고 있다. 그룹 커밋의 배치 윈도·대기·깨우기는 `std.time`/`std.Thread`가 아니라
  `Io.Clock`/`io.sleep`/`Io.Mutex`/`Io.Condition`으로 구현한다 (전부 `io`를 인자로 받는다).

```zig
pub const Options = struct {
    group_commit_window: Io.Duration = .fromMicroseconds(200),
    group_commit_bytes_max: u32 = 1 << 20,
    segment_bytes_max: u64 = 64 << 20,
    segments_max: u32 = 1024,
    sync_policy: file.SyncPolicy = .fdatasync,
};

pub const Writer = struct {
    pub fn init(target: *Writer, io: Io, gpa: Allocator, dir: Io.Dir, options: Options) InitError!void;
    pub fn deinit(self: *Writer, io: Io, gpa: Allocator) void;
    pub fn append(self: *Writer, io: Io, record: Record) AppendError!Lsn;
    pub fn commit(self: *Writer, io: Io, upto: Lsn) CommitError!void;   // 그룹 커밋 윈도 대기 + sync
    pub fn sync(self: *Writer, io: Io) SyncError!void;
    pub fn rotate(self: *Writer, io: Io) RotateError!Segment.Index;
};

pub const Reader = struct {
    pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, options: ReaderOptions) OpenError!Reader;
    // `null`은 오직 깨끗한 EOF(다음 프레임이 전혀 쓰이지 않은 자리)만 의미한다. 손상되거나
    // 잘린(torn) 프레임은 `NextError.TornWrite`/`.ChecksumMismatch`로 반환 — null과 절대 겹치지
    // 않는다, 두 경우를 호출자가 구분 못 하면 복구 멱등성(§7)을 검증할 수 없다. @panic 금지.
    pub fn next(self: *Reader, io: Io) NextError!?Frame;
    pub fn close(self: *Reader, io: Io, gpa: Allocator) void;
};

/// 재생 대상은 vtable 인터페이스 — 재생기는 `io`를 콜백으로 **넘겨준다**(콜백이 캐시하지 않도록).
pub const Apply = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, io: Io, frame: Frame) anyerror!void,
    };
};

pub const Recovery = struct {
    pub fn replay(io: Io, gpa: Allocator, dir: Io.Dir, target: Apply, options: ReplayOptions) ReplayError!Lsn;
};

pub const Checkpoint = struct {
    pub fn run(io: Io, pool: *cache.BufferPool, w: *Writer, options: CheckpointOptions) RunError!Lsn;
};
```

### 4.6 `btree`
- 가변 길이 키/값, slotted page, 내부 노드 `[key, child]`, 리프 `[key, value] + next_leaf`
- split/merge/rebalance, 오버플로 페이지(큰 값), 범위 커서(prev/next/seek), 벌크 로드
- `validate()` — 정렬, 팬아웃, 연결 리스트 불변식
- `io` 캐시 없음. 경계는 명확하다: **`node.zig`(slotted page 인코딩)는 이미 메모리에 있는
  프레임 바이트 위의 순수 함수라 `io`를 받지 않고**, 페이지를 fault-in 할 수 있는 `tree`/`cursor`
  메서드는 전부 `io`를 받아 `BufferPool`로 넘긴다.

```zig
pub const BPlusTree = struct {
    pool: *cache.BufferPool,
    root: page.Id,

    pub fn get(self: *BPlusTree, io: Io, key: []const u8) GetError!?[]const u8;   // 다음 쓰기까지 유효
    pub fn insert(self: *BPlusTree, io: Io, key: []const u8, value: []const u8) InsertError!void;
    pub fn delete(self: *BPlusTree, io: Io, key: []const u8) DeleteError!bool;
    pub fn cursor(self: *BPlusTree) Cursor;                       // io 없음 — 순수 상태 생성
    pub fn validate(self: *BPlusTree, io: Io, gpa: Allocator) ValidateError!void;
    pub fn bulkLoad(io: Io, gpa: Allocator, pool: *cache.BufferPool, src: *Cursor, options: BulkOptions) BulkError!page.Id;
};

pub const Cursor = struct {
    pub fn seek(self: *Cursor, io: Io, key: []const u8) SeekError!void;
    pub fn next(self: *Cursor, io: Io) StepError!?Entry;
    pub fn prev(self: *Cursor, io: Io) StepError!?Entry;
    pub fn release(self: *Cursor) void;                           // io 없음, 실패 불가
};

// node.zig — 순수: encode/decode/split point 계산 모두 `io` 없음.
pub fn parseLeaf(bytes: []const u8, page_size: u32) ParseError!Leaf;
```

### 4.7 `lsm`
- `MemTable` (skiplist), `SSTable` (블록 + 인덱스 + 블룸 + 푸터), 레벨/티어 컴팩션, 매니페스트
- 읽기 경로: memtable → immutable → L0..Ln, 블룸 필터 스킵
- `io` 캐시 없음. `MemTable`과 `Bloom`은 **순수 인메모리라 `io`를 아예 받지 않고**, 파일/매핑을
  직접 만지는 `SsTable`·`Manifest`·`Compaction`만 호출마다 `io`를 받는다. 컴팩션이 병렬 머지를
  원하면 `io.concurrent`를 쓰고 `error.ConcurrencyUnavailable`을 처리한다 (`io.async`는 인라인 실행 가능).

```zig
pub const MemTable = struct {                                     // io 없음 — 순수 인메모리
    pub fn init(target: *MemTable, gpa: Allocator, options: MemOptions) !void;
    pub fn put(self: *MemTable, key: []const u8, value: []const u8) PutError!void;
    pub fn get(self: *const MemTable, key: []const u8) ?[]const u8;
    pub fn frozen(self: *const MemTable) bool;                    // bytes_max 도달
};

pub const SsTable = struct {
    pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, sub_path: []const u8, options: SstOptions) OpenError!SsTable;
    pub fn get(self: *SsTable, io: Io, key: []const u8) GetError!?[]const u8;
    pub fn iterate(self: *SsTable, io: Io, range: Range) IterError!Iterator;
    pub fn close(self: *SsTable, io: Io, gpa: Allocator) void;

    pub const Builder = struct {
        pub fn create(io: Io, gpa: Allocator, dir: Io.Dir, sub_path: []const u8, options: SstOptions) !Builder;
        pub fn add(self: *Builder, io: Io, key: []const u8, value: []const u8) AddError!void;  // 블록이 차면 flush
        pub fn finish(self: *Builder, io: Io) FinishError!Footer;                              // 푸터 + crc + sync
    };
};

pub const Bloom = struct { ... };                                 // io 없음 — 순수 비트셋

pub const Manifest = struct {
    pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, options: ManifestOptions) OpenError!Manifest;
    pub fn append(self: *Manifest, io: Io, edit: Edit) AppendError!void;   // 기록 후 sync
    pub fn close(self: *Manifest, io: Io, gpa: Allocator) void;
};

pub const Compaction = struct {
    pub fn run(io: Io, gpa: Allocator, manifest: *Manifest, job: Job) RunError!Result;
};
```

### 4.8 `kv`

- `Db`는 이 라이브러리에서 **유일하게 `io: Io`를 필드로 캐시하는 타입**이다 — 열려 있는 동안 살아 있는
  서비스 객체이고(`std.http.Client`와 같은 모양), `put` 하나가 내부적으로 WAL append·그룹 커밋·
  페이지 축출·컴팩션을 유발한다. `get/put/delete/scan`에 `io`를 달면 모든 핫 콜사이트와 모든
  이터레이터 구조체로 `Io`가 번져 나간다. `open`에서 한 번 받고, 아래 계층에는 `self.io`를 넘긴다.
- `io`는 `open` 시점에 한 번만 설정되고 교체되지 않는다 (재할당 금지, assert). 하나의 `Db`를
  서로 다른 `Io` 아래에서 섞어 쓰는 것은 계약 위반이다.

```zig
pub const Options = struct {
    engine: enum { btree, lsm } = .btree,
    sync_policy: file.SyncPolicy = .fdatasync,
    page_size: u32 = 4096,
    pool_frames_max: u32 = 4096,
    key_len_max: u32 = 1 << 10,
    value_len_max: u32 = 1 << 20,
};

pub const Db = struct {
    io: Io,                    // open에서 한 번 설정 — 교체 금지 (ADR-0001)
    gpa: Allocator,

    pub fn open(io: Io, gpa: Allocator, dir: Io.Dir, sub_path: []const u8, options: Options) OpenError!Db;
    pub fn close(self: *Db) void;                                  // 캐시된 self.io 사용
    pub fn get(self: *Db, key: []const u8) GetError!?[]const u8;    // 다음 쓰기까지 유효(빌려주는 값)
    pub fn put(self: *Db, key: []const u8, value: []const u8) PutError!void;
    pub fn delete(self: *Db, key: []const u8) DeleteError!bool;
    pub fn batch(self: *Db) WriteBatch;
    pub fn scan(self: *Db, range: Range) ScanError!Iterator;
    pub fn snapshot(self: *Db) Snapshot;
    pub fn flush(self: *Db) FlushError!void;
    pub fn checkpoint(self: *Db) CheckpointError!Lsn;
};
// WriteBatch · Iterator · Snapshot 은 `*Db`를 들고 있으므로 자체 `io`도, `io` 인자도 없다.
```

```zig
// 호출부(바이너리만 Io를 고른다):  pub fn main(init: std.process.Init) !void { ... }
var db = try Db.open(init.io, init.gpa, Io.Dir.cwd(), "data/", .{ .engine = .btree, .sync_policy = .fdatasync });
defer db.close();
try db.put("k", "v");                            // io 인자 없음 — db.io 사용
const v = try db.get("k");                       // ?[]const u8 (다음 쓰기까지 빌려줌)
var b = db.batch(); try b.put("a", "1"); try b.delete("c"); try b.commit();
var it = try db.scan(.{ .start = "a", .end = "z" }); while (try it.next()) |kv| { ... }
const snap = db.snapshot(); defer snap.release();
```

### 4.9 `snapshot`
- 스트리밍 포맷: 헤더(버전, 엔진, 페이지 크기) + 청크(타입, len, crc) + 트레일러(총 crc, 엔트리 수)
- `anytype` 대신 **`*Io.Writer` / `*Io.Reader`** 를 받는다: 0.16의 이 두 타입이 이미 vtable
  인터페이스라 컴파일타임 제네릭이 필요 없고(왕국 설계 규칙: 런타임 다형성은 vtable), 싱크(파일·
  소켓·메모리)마다 코드가 복제되지 않으며, 에러 집합이 추론이 아니라 명시가 되고,
  `Io.Writer.fixed`/`Io.Reader.fixed` 위에서 파일 없이 단위 테스트할 수 있다.
- `io: Io`는 **스트림을 만드는 호출자 쪽에서** 소비된다 (`f.writer(io, &buf)` → `&fw.interface`).
  따라서 `snapshot.Writer`/`Reader` 자체는 `io`를 받지 않는다. 파일을 직접 여는 `restore`만 받는다.
- 신뢰할 수 없는 입력(zoltraak 복제, synod InstallSnapshot)을 읽으므로 **한계가 시그니처에 있다**:
  `chunk_len_max`/`chunk_count_max` 없이는 Reader를 만들 수 없다.

```zig
pub const Header = struct { magic: [4]u8, version: u16, engine: u8, page_size: u32 };
pub const Trailer = struct { crc: u32, chunk_count: u64 };
pub const Options = struct { chunk_len_max: u32 = 1 << 20, chunk_count_max: u64 = 1 << 32 };

pub const Writer = struct {
    out: *Io.Writer,                                   // Io가 아니라 스트림 — 파일·소켓·버퍼 무엇이든
    pub fn begin(out: *Io.Writer, header: Header) Io.Writer.Error!Writer;
    pub fn chunk(self: *Writer, kind: Chunk.Kind, payload: []const u8) Io.Writer.Error!void;
    pub fn finish(self: *Writer) Io.Writer.Error!Trailer;   // 트레일러 기록 (flush는 호출자 몫)
};

pub const Reader = struct {
    in: *Io.Reader,
    pub fn begin(in: *Io.Reader, options: Options) ReadError!Reader;   // 매직/버전 검증
    pub fn next(self: *Reader) ReadError!?Chunk;       // 페이로드는 다음 next까지 유효
    pub fn finish(self: *Reader) ReadError!Trailer;    // 총 crc/개수 검증, 불일치는 error.Corrupted
};

// Db 통합: 소스 쪽 io는 Db가 이미 갖고 있다.
pub fn writeSnapshot(db: *Db, out: *Io.Writer, options: Options) WriteError!Trailer;         // on Db
pub fn restore(io: Io, gpa: Allocator, dir: Io.Dir, sub_path: []const u8, in: *Io.Reader, options: Options) RestoreError!void;
```

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
