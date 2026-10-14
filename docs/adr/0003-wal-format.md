# ADR-0003: WAL format v1

- **Status**: Accepted
- **Date**: 2026-10-13
- **Milestone**: plan `docs/plans/004-phase-3-wal.md`, item "ADR-0003 — WAL format v1"
- **Applies to**: `docs/PRD.md` §4.5 (`wal`), §4.4 (the pool's WAL-before-data gate), §4.3
  (`wal_lsn` in the file header, `lsn` in every page header)
- **Supersedes**: PRD §4.5's six-digit `wal-000001.log` example; names become eight hex digits
  (§1). **Depends on**: ADR-0001 (`io` per call, codecs pure), ADR-0002 (§2 seeded checksum,
  §6 `Unwritten` and torn pages, §8 `lsn` semantics left to plan 004), and REALM.md (every byte
  checksummed, magic + version, typed `Corrupted`/`ChecksumMismatch`/`TornWrite`, idempotent
  recovery, no `builtin.os.tag` outside `file/`).

## Context

The WAL is strata's second on-disk format, and it ships in the v0.5.0 tag. A page is read at a
known offset. A log is different: it is read forward from an untrusted position, and its end is
discovered, not stored. These forces shape the design:

1. **The end of a log is ambiguous.** After a crash, the newest bytes may be torn, zero, or
   missing. Bytes at the tail that will not decode are a normal crash state. The same bytes in the
   middle of the log mean committed data was lost. Confusing the two either drops committed data
   silently or refuses a legal crash (plan 004, risk 2).
2. **Position must be part of validity.** As with pages (ADR-0002 §2), a frame with a valid CRC
   that sits at the wrong place is stale data. It must not verify.
3. **Recovery needs O(1) seeks and a bounded scan.** Redo starts at a checkpoint, not at segment
   1. Deciding torn-or-damaged needs a look-ahead whose cost has a ceiling.
4. **Throughput is per frame.** PRD §5 targets 200k appends/s, and consumers log 30–100 B
   records (zoltraak commands, synod entries). Every header byte is about 1% of bandwidth.
5. **The tools already exist.** `codec.fixed` provides little-endian integers. `codec.crc32c`
   provides `checksum` and a split-invariant `Hasher`. `file.File` provides positional I/O,
   `sync` under a caller-chosen `SyncPolicy`, `setLength`, `preallocate` and `tryLock`.

## Decision

All integers are **little-endian** and go through `codec.fixed`. There is no implicit padding
anywhere. Format v1 is everything in this document.

### 1. Directory and segment names

A WAL is a directory owned by one writer. Segment files are named `wal-` + **exactly 8 lowercase
hex digits** + `.log`, for example `wal-00000001.log`. The digits are the segment `index`, a
`u32` in `[1, segment_index_max = 2³² − 1]`; index 0 is never valid. Each name is 16 bytes.

- Any file that does not match the pattern exactly is ignored. That includes uppercase digits and
  7 or 9 digits.
- A matching name with index 0 is `Corrupted`.
- The live segments are read in index order.
- Their count is bounded by `Options.segments_max` (default 1024). More live segments is
  `error.SegmentLimit`: a typed limit, not corruption.

*Why 8 hex digits.* Six decimal digits allow 999,999 segments over the lifetime of a log. That is
61 TiB at 64 MiB per segment, or about 40 days at PRD §5's peak rate. That is a server
showstopper. A `u32` index lasts about 256 PiB. Every 8-hex-digit string is a `u32`, so
`parse_name` has no overflow case.

### 2. Segment header: 24 bytes

| Offset | Width | Field | v1 rule |
|---:|---:|---|---|
| 0 | 4 | `magic` | bytes `'S' 'T' 'W' 'L'`, compared as bytes (≠ page magic `STRA`) |
| 4 | 2 | `format_version` | `u16`, must equal `1` |
| 6 | 2 | `reserved` | must be `0` |
| 8 | 4 | `index` | `u32`, must equal the index in the file name |
| 12 | 4 | `checksum` | CRC32C, §4 |
| 16 | 8 | `first_lsn` | `u64`, LSN of the first frame slot, `1 ≤ first_lsn < 2⁶³` |
| 24 | | frames | §3, packed back to back |

`segment_header_size: u32 = 24`. Every field is naturally aligned and the size equals the sum of
the widths. The writer creates a segment in this order: exclusive create, write the header,
`sync` the file, sync the directory. Only then may any frame be written to it (§9).

### 3. Frame: 17-byte header, no alignment

| Offset | Width | Field | v1 rule |
|---:|---:|---|---|
| 0 | 4 | `len` | `u32` payload byte count, `≤ payload_bytes_max` |
| 4 | 4 | `crc` | CRC32C, §4 |
| 8 | 8 | `lsn` | `u64`, must equal the LSN implied by the frame's position (§5) |
| 16 | 1 | `type` | §6 |
| 17 | `len` | payload | owned by the type |

- `frame_header_size: u32 = 17`.
- `frame_bytes_max: u32 = 1 << 20`, which includes the header.
- `payload_bytes_max = 1048559`.
- A frame never spans two segments.

The limit is a format constant, not an option. A reader therefore never meets a valid frame that
is larger than the 1 MiB buffer it allocated at `open`. A 64 KiB page image fits 16 times over.
Values larger than the limit are split by the consumer, or later by a continuation type (§6).

**No alignment.** Frames are packed. Nothing casts WAL bytes in place: the reader copies each
frame into its own buffer, and payloads are parsed with `codec.fixed`. Padding to 8 bytes would
cost up to 7 B per frame (7–20% on PRD-sized records), and every pad byte would still need a
zero check and the checksum.

### 4. Checksums: CRC32C seeded with position, stored field read as zero

The incremental `Hasher` is fed the seed and then the bytes, with the checksum field as zeros:

```
segment: crc32c(u64le(index)        ‖ hdr[0..12] ‖ 00 00 00 00 ‖ hdr[16..24])
frame:   crc32c(u64le(lsn_expected) ‖ f[0..4]    ‖ 00 00 00 00 ‖ f[8 .. 17+len])
```

- **Segment header.** The index is a `u32` zero-extended to 8 bytes. ADR-0002 §2's proof applies
  word for word: a segment renamed, or copied, under another index fails **with certainty**.
- **Frame.** `lsn_expected` comes from the frame's position (§5), not from its stored field. A
  stale frame (an older log generation, a misdirected write, or the wrong offset) fails the CRC
  with probability 1 − 2⁻³². Because the LSN is 64 bits, the CRC alone is not certain. The
  stored-`lsn` check after the CRC (§7, step 5) makes rejection certain.

### 5. LSN: byte position in the frame stream

`Lsn = u64`. **0 means none** (`page.lsn`, `wal_lsn`, `redo_lsn`). `lsn_first = 1`. The LSN of
a frame is its position in the concatenation of all frames, ignoring segment headers:

```
lsn_at(segment, offset) = segment.first_lsn + (offset - segment_header_size)
next_lsn                = frame.lsn + frame_header_size + frame.len
next_segment.first_lsn  = end LSN of the previous segment     (continuity, §8)
```

LSNs are unique, strictly increasing, and `< 2⁶³`. A writer asserts this; on disk, a violation is
`Corrupted`.

*Why bytes and not a counter.*
- **O(1) seek.** Find the segment with the greatest `first_lsn ≤ L`; the offset follows from the
  formula. A counter needs a scan or an index.
- **Exact expectation everywhere.** The expected LSN of any byte offset is known, so the
  look-ahead (§8) can verify a candidate frame at any offset after a damaged one. With a counter,
  the number of lost frames is unknown, and so is the expected LSN.
- **Free accounting.** "Bytes since checkpoint" is a subtraction.

All comparisons work unchanged with byte LSNs:
- Redo is idempotent: apply iff `frame.lsn > page.lsn` (§10).
- The pool writes a page back iff `page.lsn ≤ durable_lsn` (§9).
- Reclaim deletes by LSN range (§10).

### 6. Frame types (`u8`)

| Value | Name | Payload |
|---:|---|---|
| 0 | none | never valid; an all-zero header is never a frame |
| 1 | `record` | opaque bytes, `0 ≤ len ≤ payload_bytes_max` |
| 2 | `page_image` | `page_id: u32` at 17, then the page bytes; `len − 4` must be a valid page size |
| 3 | `checkpoint` | `redo_lsn: u64`; `len == 8`; `1 ≤ redo_lsn ≤ frame.lsn` |
| 4–15 | wal layer | reserved (commit marker, continuation) |
| 16–127 | strata | reserved (B+Tree and LSM logical records) |
| 128–255 | consumer | opaque, same rules as `record`; saves a tag byte per multiplexed record |

**`page_image`** is the full-page image that repairs torn pages (ADR-0002 §6).
- The page size is implied by `len`, so the format is page-size independent. Its validity is
  `page_size_valid(len − 4)`: `len` is 516, 1028, …, or 65540.
- The bytes are the page as it was in memory. Its own header checksum may be stale (`poke_lsn`).
  Redo re-stamps it (§10).
- Any `page_id`, including 0, is valid in the format. Whether a target can apply an image to
  page 0 is its own business (Open question 2).

**`checkpoint`** marks a durable redo start. v1 writers write `redo_lsn = frame.lsn` (sharp
checkpoint: pages are flushed after the frame). The field allows a later fuzzy checkpoint
(`redo_lsn < lsn`) without a format change.

No `padding` type is defined: frames are unaligned and v1 does not recycle segments. No `commit`
type is defined either: the atomic unit is one frame (§9). Values 4–15 keep both possible.

### 7. Frame decode order (`wal/frame.zig`, pure)

`decode(image, lsn_expected)` receives the bytes from the frame's offset up to EOF, capped at
`frame_bytes_max`. It consumes exactly `17 + len` bytes and checks, in order:

1. `image.len < 17` → `TornWrite`.
2. `len > payload_bytes_max` → `Corrupted`. This check comes before any read sized by `len`.
3. `image.len < 17 + len` → `TornWrite`.
4. The seeded CRC ≠ the stored `crc` → `ChecksumMismatch`.
5. The stored `lsn` ≠ `lsn_expected` → `Corrupted`.
6. `type` is 0 or reserved (4–127), or a type rule from §6 fails → `Corrupted`.

As in ADR-0002 §6, fields are trusted only after the checksum. A bit flip in `type` therefore
reports `ChecksumMismatch`. A well-checksummed unknown type is a writer bug or a newer format.

`intact(image, lsn_expected)` is true iff steps 1–4 pass: the bytes are exactly what some writer
wrote at this position. §8 depends on the difference:
- A frame that is **not intact** can be a crash artifact.
- An intact frame that fails steps 5–6 is never a crash artifact.

### 8. Reading a log: EOF, torn tail, look-ahead

**Opening.** The reader lists the segment names (bounded by `segments_max`) and decodes every
header with the index from its name.

Header decode order:
1. The whole file is zero, including a zero-length file → `Unwritten`.
2. Fewer than 24 bytes → `TornWrite`.
3. Bad magic or version → `Corrupted`.
4. Checksum mismatch → `ChecksumMismatch`.
5. A stored index different from the name's, a non-zero `reserved`, or `first_lsn` out of range
   → `Corrupted`.

What the reader does with each result:
- `Unwritten` or `TornWrite` is legal **only for the newest segment** (the highest index). It
  means the segment was being created at the crash. An `Unwritten` newest segment is absent: the
  log ends at its predecessor, or is empty if it is segment 1. It is `Corrupted` if it is not
  segment 1 and its predecessor is missing.
- In any other segment, both results are `Corrupted`.
- `first_lsn` must strictly increase with index.

`open(from_lsn)` seeks as described in §5:
- Indices must be contiguous from the segment that contains `from_lsn` up to the newest.
- Gaps below that segment are left over from reclaim and are ignored (§10).
- If `from_lsn` lies below the oldest segment, or past the end of the log, → `Corrupted`.

**The seek target is trusted.** If the frame at `from_lsn` is not intact, the result is
`ChecksumMismatch`, or `Corrupted`. It is **never** `TornWrite`: a redo start is a durable
checkpoint (§10).

**`next()`** works at offset `X` of segment `s` with file length `N` and `E = lsn_at(s, X)`:

| Situation | Result |
|---|---|
| `X == N`, or every byte of `[X, N)` is zero, and `s` is newest | `null`: clean EOF |
| same, `s` not newest | go to `s + 1`; it needs `first_lsn == E`, else `Corrupted` |
| `decode` succeeds | the `Frame`; advance to `X + 17 + len` |
| intact but step 5 or 6 fails, anywhere | `Corrupted` |
| not intact, `s` newest, not the seek target, no valid frame in look-ahead | `TornWrite` |
| not intact, any other case | `ChecksumMismatch` if step 4 failed, else `Corrupted` |

- **`null` means only clean EOF.** That is the end of the newest segment, or zeros up to it.
  Zero bytes after the tail are unwritten space, such as growth or preallocation. In older
  segments they mean "end of frames", so a later version can preallocate without a format change.
- **`TornWrite` is returned iff truncating at `E` is safe.** Recovery truncates on exactly this
  error. `ChecksumMismatch` and `Corrupted` are never truncated. A torn write cannot produce
  them, because rotation syncs a segment before its successor exists (§9).
- **Look-ahead.** The scan covers every offset `Y` in `(X, N − 17]` of the newest segment. A
  valid frame is found when the stored `lsn` at `Y + 8` equals `lsn_at(s, Y)` and
  `intact(Y, lsn_at(s, Y))` holds. The bound is the segment length, `≤ segment_bytes_limit`. The
  filter costs one `u64` compare per offset, and the CRC runs only on LSN matches. The scan runs
  only on the failure path, at most once per open. Covering the rest of the segment, rather than
  one frame, also catches a damaged run of several small frames.

### 9. Durability: what "committed" means

- **Written:** the frame's bytes are at `lsn_at` in their segment.
- **Durable:** a `File.sync` of that segment returned successfully after the write.
- `durable_lsn` is the highest durable frame LSN (0 if none). `commit(upto)` returns only when
  `durable_lsn ≥ upto`. Group commit is a writer schedule (item 6), not a format feature.

**Durability is prefix-closed.**
- One sync covers every earlier write to its segment.
- Rotation syncs the old segment before the new one is created.
- Frame `L` durable therefore means every frame `< L` is durable.

**Atomicity.** The atomic unit is one frame. There is no commit record. Recovery returns a prefix
of the appended frames. Every committed frame is in it, and any intact frame on disk is in it,
committed or not. There are never holes: a hole fails as in §8.

**Failed sync.** A failed `sync` never advances `durable_lsn` and is **never retried**: the
kernel may already have dropped the dirty pages (fsyncgate). The writer latches the error until
it is reopened through recovery.

**SyncPolicy.** `SyncPolicy` is the caller's choice, made once per log as `Options.sync_policy`
at `init`. Each segment `File` carries it as data. It is deliberately not a per-`commit`
argument: one `durable_lsn` must mean one thing. Under `.none`, "durable" means "handed to the
OS": process crashes are covered, power loss is not. Every blocking call takes `io` (ADR-0001).
Nothing allocates after `init`: the reader buffer is `frame_bytes_max`, and the writer batch is
`group_commit_bytes_max ≥ frame_bytes_max` (asserted).

**Rotation.** Before appending an `n`-byte frame to a segment of length `L`: if the segment
already holds a frame and `L + n > Options.segment_bytes_max`, the writer:
1. syncs the segment;
2. creates `index + 1` (index past `segment_index_max` → `error.SegmentIndexExhausted`; more than
   `segments_max` live segments → `error.SegmentLimit`, so the caller must checkpoint);
3. writes the header with `first_lsn` = the old segment's end LSN;
4. syncs the new file, then the directory;
5. appends the frame.

A lone oversized frame may exceed the option. A file longer than `segment_bytes_limit = 2³²` is
`Corrupted`, and `segment_bytes_max ≤ segment_bytes_limit − frame_bytes_max` is asserted.
Preallocating and recycling segments are out of scope (plan 004); the zero-tail rule (§8) leaves
room for them.

### 10. Checkpoint, redo, reclaim

**Checkpoint (item 10).**
1. Commit a `checkpoint` frame at LSN `C`.
2. `flushAll`.
3. Sync the pages.
4. Set the file-header `wal_lsn = C` (ADR-0002 §5; this ADR fixes its meaning: the LSN of the
   checkpoint frame recovery starts from, 0 = none).
5. Sync.

**Recovery.**
- `wal_lsn == 0`: replay from `lsn_first`; segment 1 must exist.
- Otherwise: the frame at `C` must be an intact `checkpoint` frame, else `Corrupted`. This check
  also catches a page file paired with a foreign WAL. Replay starts at its `redo_lsn = R`.
- On `TornWrite`, recovery truncates and returns the last good LSN:
  - a torn frame: `setLength(offset of E)`, then `sync`;
  - a torn newest header: delete the file, then sync the directory.
- A crash during truncation re-creates the same torn state, so recovery is idempotent.

**Idempotent redo.** An `Apply` target applies a frame iff `frame.lsn > target.lsn`.
- `PageRedo` writes a `page_image` when the page fails to decode with any `DecodeError`, or when
  `page.lsn < frame.lsn`.
- It re-stamps the page through `PageManager.write` with `lsn = frame.lsn`, so a second replay
  sees equality and skips.
- A `len − 4` that differs from the file's page size → `Corrupted`.

**Reclaim.** Segment `k` may be deleted iff `k` is not the newest and `(k+1).first_lsn ≤ R`,
which means every frame in `k` has LSN below the redo start. Deletion goes in ascending order,
followed by one directory sync. A crash part-way leaves a gap only below `R`'s segment, which §8
ignores. The active segment is never deleted.

### 11. Golden bytes: segment 1 with two frames (72 bytes)

Segment 1 (`first_lsn = 1`) holds a `record` with payload `"strata"` at LSN 1, then a
`checkpoint` at LSN 24 (= 1 + 17 + 6) with `redo_lsn = 24`. Its end LSN is 49.

```
off  bytes                     field
  0  53 54 57 4c               magic "STWL"
  4  01 00 | 00 00             format_version 1 | reserved
  8  01 00 00 00               index 1
 12  38 e5 d5 f9               checksum 0xF9D5E538 (seed u64le 1)
 16  01 00 00 00 00 00 00 00   first_lsn 1
 24  06 00 00 00               len 6
 28  2f b8 bd a7               crc 0xA7BDB82F (seed u64le 1)
 32  01 00 00 00 00 00 00 00   lsn 1
 40  01                        type record
 41  73 74 72 61 74 61         "strata"
 47  08 00 00 00               len 8
 51  27 b8 c6 43               crc 0x43C6B827 (seed u64le 24)
 55  18 00 00 00 00 00 00 00   lsn 24
 63  03                        type checkpoint
 64  18 00 00 00 00 00 00 00   redo_lsn 24
```

Negative pins:
- The same header under index 2 checksums to `0xBF3E9465` → `ChecksumMismatch`.
- Frame 1's bytes decoded at `lsn_expected = 2` checksum to `0x2E5419B8` → `ChecksumMismatch`.
  (The same record *written* at LSN 2, stored `lsn` 2, has crc `0x86C71EBB`.)

### 12. Versioning

- `format_version: u16 = 1` is stored per segment, and frames inherit it. A v1 reader accepts
  exactly 1. Because the version is per segment, a v2 writer can rotate and then write v2
  segments behind v1 ones.
- **These changes bump the version** (CHANGELOG plus a `docs/` migration note): any offset,
  width, checksum rule, LSN rule, limit, or field meaning.
- **These do not:** assigning a reserved type value. Old readers reject such a frame as
  `Corrupted` after the checksum, so it is never truncated.
- Migration is usually trivial because a WAL is transient: checkpoint under the old version, then
  reclaim every segment. No tooling exists, because there is no earlier format.

### 13. API shape (`src/wal/frame.zig`, `src/wal/segment.zig`; pure, no `io`)

```zig
pub const Lsn = u64; // 0 = none
pub const lsn_first: Lsn = 1;
pub const frame_header_size: u32 = 17;
pub const frame_bytes_max: u32 = 1 << 20;
pub const payload_bytes_max: u32 = frame_bytes_max - frame_header_size;
pub const Type = enum(u8) { record = 1, page_image = 2, checkpoint = 3, _ };
/// `payload` borrows from the decoded image; valid until the caller's buffer is reused.
pub const Frame = struct { lsn: Lsn, frame_type: Type, payload: []const u8 };
pub const DecodeError = error{ TornWrite, ChecksumMismatch, Corrupted };
pub fn encode(out: []u8, lsn: Lsn, frame_type: Type, payload: []const u8) u32; // bytes used
pub fn decode(image: []const u8, lsn_expected: Lsn) DecodeError!Frame;
pub fn intact(image: []const u8, lsn_expected: Lsn) bool;
pub fn checksum(frame_bytes: []const u8, lsn_expected: Lsn) u32;

pub const segment_header_size: u32 = 24;
pub const segment_bytes_limit: u64 = 1 << 32;
pub const segment_index_max: u32 = std.math.maxInt(u32);
pub const format_version: u16 = 1;
pub const magic: [4]u8 = "STWL".*;
pub const Header = struct { index: u32, first_lsn: Lsn };
pub const HeaderError = error{ Unwritten, TornWrite, ChecksumMismatch, Corrupted };
pub fn format_name(index: u32, out: *[16]u8) void;
pub fn parse_name(file_name: []const u8) error{Corrupted}!?u32; // null: not ours; index 0: Corrupted
pub fn encode_header(out: *[segment_header_size]u8, header: Header) void;
pub fn decode_header(bytes: []const u8, index: u32) HeaderError!Header;
```

### Rejected alternatives

| Alternative | Why not |
|---|---|
| Length-only framing, no CRC | Fails REALM's "every byte"; it is the matrix's no-CRC mutant. |
| Unseeded CRC over the frame | A stale frame verifies. Seeding costs 8 hashed bytes and makes misplacement a `ChecksumMismatch`, as for pages. |
| Varint `len`/`lsn` | Saves 3–10 B, but a torn varint has no fixed header size, the look-ahead loses its fixed `lsn` offset, and decode branches. |
| 8 B-aligned frames or padding | Up to 7 B per frame of checksummed zeros, and nothing consumes the alignment (§3). |
| Sector-aligned frames | Isolates tears, but a 40 B record costs 512 B: 10–50× write amplification. |
| CRC-chained frames | Each seed is the previous CRC, which is lost when that frame is damaged. The look-ahead cannot verify what follows, so mid-log damage looks like a torn tail. |
| Counter LSN | No O(1) seek, and the expected LSN after a damaged frame is unknown (§5). |
| LSN implied, not stored | Saves 8 B, but the look-ahead then needs a CRC per offset. |
| Per-frame "durable hint" | Turns a reordered unsynced write into a truncation instead of `Corrupted`, but silently drops a rotted last synced batch. Safety first. |

## Consequences

**Binding.** PRD §4.5 is edited in the same PR to link this ADR and to use the eight-hex-digit
name. WAL bytes are written only through `wal/frame.zig` and `wal/segment.zig`. A change to any
table above without a `format_version` bump is rejected on review.

**Good.**
- Each failure maps to one typed error. Torn tail → `TornWrite`, the only error recovery
  truncates. Bit rot or a stale or misplaced frame → `ChecksumMismatch`. A structural violation
  → `Corrupted`. A renamed segment → `ChecksumMismatch`, with certainty. No path panics.
- O(1) redo seek, and a bounded look-ahead that runs only on the failure path.
- 17 B per frame. LSNs double as byte accounting.

**Costs.**
- A segment can sustain a reordered crash: a later unsynced frame persists and an earlier one
  does not. That state is reported as `Corrupted`, not truncated. It fails closed: the cost is
  availability, never silent loss. `CrashSink` does not model it.
- Damage to the last frames with nothing valid after them cannot be told apart from a torn write,
  so it is truncated. This ambiguity is irreducible, and it is limited to the tail.
- Records are capped at 1 MiB in v1, and a multi-frame operation is not atomic (Open question 1).

**Per item.**
- **2 `frame.zig`:**
  - §7 order; the golden frames 1 and 2 from §11.
  - Every bit flip of a 64 B frame is rejected.
  - LSN ± 1 → `ChecksumMismatch`.
  - A forged CRC with a wrong stored `lsn` → `Corrupted`.
  - `len = payload_bytes_max + 1` → `Corrupted`.
  - Type 0, 4 or 127; `page_image` with `len − 4 = 3000`; `redo_lsn` of 0 or above `lsn` → each
    `Corrupted`.
  - Replace the stand-in decoder in `truncation_matrix_test.zig`, with a `corrupted` tally
    bucket: torn cuts may now land in any of the three errors.
- **3 `segment.zig`:**
  - `format_name`/`parse_name` (rejects uppercase and 7- or 9-digit names).
  - The golden header from §11.
  - Index 2 → `ChecksumMismatch`; all-zero → `Unwritten`; a short non-zero file → `TornWrite`.
  - Create order from §2.
  - Directory sync: needed, but `File` has no room for it (Open question 4).
- **4 `reader.zig`:**
  - The §8 tables and seek; one `frame_bytes_max` buffer allocated at `open`.
  - The golden segment reads back.
  - A zero tail → `null`.
  - A bad frame followed by a valid one → `ChecksumMismatch`/`Corrupted`, not `TornWrite`. This
    refines item 7's "→ `Corrupted`".
  - A bad frame at the seek target → never `TornWrite`.
- **5 `writer.zig`:**
  - Find the tail through the reader; `TornWrite` → `RecoveryRequired`.
  - Rewrite an `Unwritten` newest segment.
  - Rotation per §9; `SegmentLimit` and `SegmentIndexExhausted`.
  - Latch a failed sync.
- **6 Group commit:** `durable_lsn` is inclusive and prefix-closed. A failed leader sync fails
  its whole batch.
- **7 `recovery.zig`:** start per §10; truncation per §8 and §10. Replay run twice into the model
  equals one replay.
- **8 Pool gate:** write back iff `page.lsn ≤ durable_lsn`.
- **9 `redo.zig`:**
  - The §10 apply rule; the restored page carries `lsn = frame.lsn`.
  - Page ids `≥ page_count` need the manager to grow the file first (`write` asserts the range).
  - A size mismatch → `Corrupted`.
- **10 `checkpoint.zig`:** `redo_lsn = C`; `wal_lsn = C`; reclaim in ascending order; never
  delete the newest segment.
- **11 3E:**
  - Properties: the result is a prefix; every committed LSN is present; nothing is invented.
  - Mutants that must fail: redo that ignores the LSN, and a look-ahead switched off.
- **12 Release:** the CHANGELOG notes "WAL format v1 (ADR-0003)".

## Open questions (recommendations)

1. **Multi-frame atomicity.** For example, a B+Tree split logged as several page images. The
   B+Tree ADR (plan 005) decides. Recommendation: one logical frame per operation, or assign a
   `commit` type in the 4–15 range, which needs no version bump.
2. **Page 0 has no torn-write repair.** `PageManager.write` asserts `id ≥ 1`. The format already
   accepts `page_id = 0`. Recommendation: `PageRedo` returns `Corrupted` for page 0 until a
   follow-up adds a page-0 image path. No writer logs page 0 before that.
3. **WAL lost beside an existing page file.** A fresh log starting at LSN 1 would be skipped by
   redo. Recommendation: `kv.Db.open` treats a missing or empty WAL with `wal_lsn ≠ 0` as
   `Corrupted`. There is no reseeding option in v1.
4. **Directory sync.** It is required at rotation, after create, and after a header delete.
   Recommendation: a free function in `file/` (`platform.zig`), not a new `File` method.
