# ADR-0002: Page format v1

- **Status**: Accepted
- **Date**: 2026-10-08
- **Milestone**: plan `docs/plans/003-phase-2-page-cache.md`, item "ADR-0002 — page format v1"
- **Applies to**: `docs/PRD.md` §4.3 (`page`), §4.4 (`cache` frames hold these bytes), and every
  later layer that stores pages (§4.5 checkpoint, §4.6 B+Tree)
- **Supersedes**: the field order of PRD §4.3's 20-byte header, and the §4.3 "linked list +
  bitmap hybrid" freelist (narrowed here to a trunk list). **Depends on**: ADR-0001 (header
  codecs are pure and take no `io`), and REALM.md's rules that every format has magic, version
  and checksum and that corruption is a typed error.

## Context

strata's first on-disk format ships in the v0.4.0 tag. After that, changing a byte costs a version
bump and a migration note (REALM.md). So every offset is decided here, before the first page byte
is written. Five forces shape it:

1. **Checksums must catch misplacement, not just bit rot.** A plain CRC over a page proves the
   bytes match each other. It does not prove they belong at that offset. A misdirected or stale
   write of a valid page passes a plain CRC.
2. **Sparse growth produces zero pages.** `PageManager.allocate` grows the file with
   `File.setLength`, so a page can exist on disk and never have been written. After a crash
   between growth and first write, the all-zero image is a legitimate state. It is not damage.
3. **Page sizes run from 512 B to 64 KiB** (PRD §4.3, REALM.md matrix rule). 65536 does not fit in
   a `u16`, and every capacity formula must hold at all 8 powers of two.
4. **Width compounds upward.** `page.Id` is repeated in B+Tree child pointers, freelist slots and
   the pool's page table, where PRD §5 caps metadata at < 64 B per frame.
5. **The tools already exist.** `codec.fixed` gives little-endian `u16/u32/u64` encoding.
   `codec.crc32c` gives `checksum(bytes)` and an incremental `Hasher` (`init`, `update`, `final`)
   whose output is the same however the input is split.

## Decision

All multi-byte integers are **little-endian**, encoded and decoded with `codec.fixed`. Offsets are
in bytes from the start of the page. Format v1 is everything in this document.

### 1. Page header: 24 bytes, payload 8-byte aligned

| Offset | Width | Field | v1 rule |
|---:|---:|---|---|
| 0 | 4 | `magic` | bytes `'S' 'T' 'R' 'A'` (u32 LE value `0x41525453`), compared as bytes |
| 4 | 1 | `page_type` | see the table below |
| 5 | 1 | `flags` | must be `0` in v1 |
| 6 | 2 | `version` | `u16`, must equal `format_version = 1` |
| 8 | 4 | `checksum` | `u32` CRC32C, see §2 |
| 12 | 4 | `reserved` | must be `0` in v1 |
| 16 | 8 | `lsn` | `u64`, stored as given (see §8) |
| 24 | page_size − 24 | payload | owned by the page type |

`header_size: u32 = 24`. The first five fields keep the PRD's order and widths. Placed straight
after them, `lsn` would sit at offset 12, which is misaligned. Adding 4 reserved bytes moves `lsn`
to offset 16 and starts the payload at offset 24. Every `u64` in a payload is then 8-aligned
whenever the payload's own offsets are. Slotted B+Tree pages and frame-pointer casts depend on
this. The cost is 4 bytes per page: 0.8% at 512 B and 0.1% at 4 KiB. *Rejected:* the PRD's
packed 20 bytes (misaligned `lsn` and payload); moving `lsn` to offset 4 (breaks the PRD order and
saves nothing).

**`page_type` values (`u8`).** Ranges are reserved so that adding a type never moves a number.

| Value | Name | Status |
|---:|---|---|
| 0 | none | never valid; a typed page is never zero |
| 1 | `file_header` | valid only at id 0, and id 0 must have it |
| 2 | `free_trunk` | §7 |
| 3–15 | page layer | reserved |
| 16–31 | B+Tree | reserved for the §4.6 ADR (leaf, internal, overflow) |
| 32–127 | strata | reserved |
| 128–255 | consumer | accepted as-is; layout owned by the consumer (e.g. silica heap pages) |

`flags` and `reserved` must both be zero. A decoder that sees a reserved or unassigned type, or a
non-zero `flags` or `reserved`, returns `error.Corrupted`. It fails closed.

### 2. Checksum: CRC32C seeded with the page id, field read as zero

The checksum covers all `page_size` bytes of the page, with bytes 8..12 treated as zero. The page
id is fed into the hash before the page bytes. Decode never mutates its input, so the zeroed field
is fed as a constant instead of being written into the buffer:

```zig
pub fn checksum(page: []const u8, id: Id) u32 {
    var id_bytes: [8]u8 = @splat(0);
    // u64 little-endian, zero-extended from the u32 id (written with codec.fixed).
    var hasher = codec.crc32c.Hasher.init();
    hasher.update(&id_bytes);
    hasher.update(page[0..8]); // magic, page_type, flags, version
    hasher.update(&.{ 0, 0, 0, 0 }); // the checksum field, as zero
    hasher.update(page[12..]); // reserved, lsn, payload
    return hasher.final();
}
```

`encode` stores the result at bytes 8..12 as a little-endian `u32`. `decode` recomputes it with
the id it was asked for and compares.

**Why seeding with the id is exact, not probabilistic.** CRC is affine over GF(2). Take two images
that differ only in the id prefix, with ids A ≠ B. Their checksums differ by `d(x)·x^k mod G`,
where `d` is the polynomial of `A xor B`. Ids are `u32` (§3), so `d` is non-zero and has degree
< 32. `G(0) = 1`, so `x^k` is invertible mod `G`, and a degree < 32 polynomial is never a multiple
of the degree-32 `G`. Result: an intact page read under any other id fails **with certainty**.
Plain bit rot is still caught with probability 1 − 2⁻³² beyond CRC32C's guaranteed bounds.

*Rejected:* storing the id in the header. It costs 4–8 bytes per page for the same detection. Its
only gain is the diagnostic "which page landed here", which we give up. Also rejected: xxhash64
(no hardware path, 8-byte field), and a trailer checksum (splits page metadata across two
sectors).

### 3. `page.Id` is `u32`, and id 0 doubles as the on-disk null

```zig
pub const Id = enum(u32) { file_header = 0, _ };
```

At most `page_count_limit = maxInt(u32)` pages, so the largest id is 2³² − 2. That gives a
maximum file size of **2 TiB at 512 B pages, 16 TiB at 4 KiB, and 256 TiB at 64 KiB**. The largest
byte offset is (2³² − 1)·2¹⁶ < 2⁴⁸, well inside `file.offset_max` (2⁶³ − 1). The 512 B ceiling
only applies to test- and embedded-sized pages.

The `u32` choice halves child pointers in B+Tree internal nodes (higher fanout), doubles the ids
per freelist trunk, and shrinks the pool's page-table entries. It is also what makes the §2
detection exact. SQLite has made the same trade for 20 years. *Rejected:* `u64` ids. Widening
later is a format v2 change.

Page 0 can never be freed, allocated, or linked to (asserted in `free`). Every on-disk link field
(`freelist_head`, `next_trunk`) therefore encodes "none" as `0`. In the Zig API, links are `?Id`.
Only the codec maps `0 ↔ null`, so no caller compares against a magic number.

### 4. Page sizes

`page_size` is a power of two in `[page_size_min, page_size_max] = [512, 65536]`. That is 8 sizes,
fixed per file at `create`. It is stored as a `u32` in the file header, because 65536 does not fit
in a `u16`. Validation is `@popCount(n) == 1 and n >= 512 and n <= 65536`:

- An invalid size in a caller's `Options` is a contract violation and is **asserted**.
- An invalid size read from disk is `error.Corrupted`.
- A valid on-disk size that differs from `Options.page_size` is also `error.Corrupted` (plan 003,
  manager item). The file is not the file the caller described.
- Every codec function asserts `page.len` is a valid size; the slice length *is* the page size.

### 5. Page 0: an ordinary page with the file header in its payload

Page 0 uses the same 24-byte header with `page_type = file_header` and the same seeded checksum
(id 0). There is one codec and one checksum rule, and a strata file starts with the bytes `STRA`
at offset 0. The header's `version` field *is* the file's format version, so it is not stored
twice.

| Offset | Width | Field | Rule |
|---:|---:|---|---|
| 0 | 24 | page header | `page_type = 1`, `version = 1` |
| 24 | 4 | `page_size` | §4 |
| 28 | 4 | `page_count` | pages in the file including page 0; ≥ 1 |
| 32 | 4 | `freelist_head` | first trunk id; `0` = empty; else `< page_count` |
| 36 | 4 | `reserved` | must be `0` (keeps `wal_lsn` 8-aligned) |
| 40 | 8 | `wal_lsn` | `u64`, stored as given; `0` at `create`; meaning owned by plan 004 |
| 48 | page_size − 48 | tail | must be all zero |

`file_header_size: u32 = 48`, comptime-asserted `<= page_size_min`.

**Open sequence (bounded by design).**

1. Read the first `page_size_min` bytes.
2. Check `magic`, `version` and `page_type == file_header`, then validate the unverified
   `page_size` against §4. The read size never comes from unchecked bytes.
3. Read the full `page_size` bytes and run the complete decode, including the checksum.
4. The manager then checks the cross-field invariants above, and that
   `file length >= page_count * page_size`. A longer file is allowed: it is growth that crashed
   before page 0 was updated, and the extra space is reused. Any violation is `error.Corrupted`.

An `error.Unwritten` page 0 (§6) is mapped to `error.Corrupted` by `open`. A file without a header
is not a strata file. `create` writes and syncs page 0 before it returns.

Non-zero tails and reserved fields are rejected so that encoding is canonical: one logical state
has exactly one byte image. This is what lets differential tests compare whole files.

### 6. Never-written pages decode to `error.Unwritten`

```zig
pub const DecodeError = error{ Unwritten, Corrupted, ChecksumMismatch };
```

`decode` checks in this order:

1. **All `page_size` bytes are zero → `error.Unwritten`.** This scan only runs when `magic` is
   zero, so the cost is on the failure path only.
2. `magic != "STRA"` → `Corrupted`. A zero magic with any non-zero byte after it (a torn or
   garbled page) also lands here.
3. `version != 1` → `Corrupted`.
4. Checksum mismatch → `ChecksumMismatch`.
5. Only after the checksum passes: `page_type` unassigned or reserved, non-zero
   `flags`/`reserved`, or `file_header` at an id other than 0 (or 0 without it) → `Corrupted`.

Magic and version come before the checksum because they decide how a checksum is interpreted (a v2
may checksum differently). Every other field is trusted only after the checksum. So a bit flip in
`page_type` reports `ChecksumMismatch`, and a well-checksummed unknown type means a writer bug or
a newer format, which is `Corrupted`.

**Why a distinct error, not `Corrupted` and not a union outcome.**
- An all-zero page is a legal crash state (force 2). WAL redo (plan 004) must tell "never written,
  apply the full image" apart from "damaged". Folding it into `Corrupted` would make recovery
  string-match on context.
- A union return such as `union { page: Header, unwritten }` raises the dimensionality of every
  call site, including the pool's hot `fetch` miss path, where the only correct reaction is to
  fail. As an error, Zig's exhaustive `switch` still forces each caller to decide, and the success
  type stays `Header`.
- A zero page can never decode as valid. Its magic is not `STRA`, and its stored checksum (0) is
  not what the seeded CRC of the image gives.

**Torn pages.** Only 512 B sector writes are atomic. A larger page torn mid-write is a mix of new
and old (or zero) sectors. If the first sector survived, the result is `ChecksumMismatch`. If a
zero first sector sits in front of non-zero bytes, it is `Corrupted`. Neither is ever `Unwritten`.
A page image cut short by end-of-file is a manager-level `error.TornWrite`. The decoder itself
only ever receives exactly `page_size` bytes (asserted). Repair of torn pages (full-page WAL
images) belongs to plan 004.

### 7. Freelist: a trunk-page list only

**Trunk payload** (`page_type = free_trunk`):

| Offset | Width | Field | Rule |
|---:|---:|---|---|
| 24 | 4 | `next_trunk` | `0` = last trunk; must not equal the trunk's own id |
| 28 | 4 | `count` | live entries, `count <= capacity` |
| 32 | 4·capacity | `ids[]` | `ids[0..count]` are non-zero; `ids[count..]` are all zero |

`trunk_capacity(page_size) = (page_size - 32) / 4`, exact at every valid size: 120 at 512 B, 1016
at 4 KiB, 16376 at 64 KiB. Comptime-asserted for all 8 sizes.

Decode errors, all `Corrupted`: `count > capacity`, a zero id in a live slot, a non-zero dead slot,
or `next_trunk` pointing to itself. Range checks against `page_count` (`ids[i]`, `next_trunk`) are
done by the manager, which knows `page_count`.

**Push (`free(id)`).**
- If the list is empty, or the head trunk is full: the freed page itself becomes the new trunk,
  with `count = 0` and `next_trunk = old head`, and `freelist_head = id`. That is one trunk write
  plus a page 0 write.
- Otherwise: `ids[count] = id`, then `count += 1`. That is one trunk write. Freed non-trunk pages
  are never rewritten.

Freeing never needs a page, so it never fails for lack of space.

**Pop (`allocate`).**
- Empty list → `null`, and the manager grows the file, bounded by `Options.page_count_max`.
- Head with `count > 0` → return `ids[count-1]`, zero that slot, and decrement `count` (LIFO: the
  most recently freed page is the most likely to still be cached).
- Head with `count == 0` → the trunk page itself is returned, and `freelist_head = next_trunk`.

Push and pop only ever touch the head, so there is no chain walk. Any verification walk is bounded
by `page_count` (Tiger Style 2), and exceeding that bound means a cycle, which is `Corrupted`.

**Why the bitmap is deferred.** A bitmap adds a second structure that must stay consistent with
the trunk list across crashes, and that consistency needs the WAL that plan 004 has not landed. It
also needs either a fixed region sized for `page_count_limit`, or its own chain of growable pages.
Its real benefits are contiguous extent allocation and O(1) double-free detection. The first has
no consumer before the LSM work, which does not allocate through `PageManager`. The second is
covered by the seeded model test and assertions. The trunk list has O(1) push and pop and zero
space overhead, because free pages store the list themselves. Adding a bitmap later is a format v2
change.

### 8. Version, migration policy, and `lsn`

- `format_version: u16 = 1`, written in every page header. A v1 reader accepts exactly 1.
- **These changes bump the version and require a migration note** (CHANGELOG entry plus a
  `docs/` note naming the converter or explaining why there is none): any change to an offset, a
  width, the checksum rule, the meaning of an existing field, or a capacity formula.
- **This change does not bump it:** assigning a value inside a reserved `page_type` range. Older
  readers fail closed on that page with `Corrupted`. The existing layouts are unchanged.
- No migration tooling exists, because there is no earlier format to migrate from.
- `lsn` (page header) and `wal_lsn` (file header) are opaque `u64` values. The page layer stores
  them as given and never compares them. `0` means "no LSN" (never logged). WAL-before-data
  ordering (a page's `lsn` ≤ the flushed WAL LSN) and the meaning of `wal_lsn` are decided by
  plan 004.

### 9. API shape (`src/page/header.zig`, pure, no `io`, per ADR-0001)

```zig
pub const header_size: u32 = 24;
pub const file_header_size: u32 = 48;
pub const page_size_min: u32 = 512;
pub const page_size_max: u32 = 65536;
pub const format_version: u16 = 1;
pub const magic: [4]u8 = "STRA".*;
pub const Type = enum(u8) { file_header = 1, free_trunk = 2, _ };
pub const Header = struct { page_type: Type, lsn: u64 };
pub const FileHeader = struct {
    page_size: u32,
    page_count: u32,
    freelist_head: ?Id,
    wal_lsn: u64,
};

/// Stamps magic, version, flags = 0, reserved = 0, then the checksum over `page`.
/// The caller has already filled the payload. Infallible.
pub fn encode(page: []u8, id: Id, header: Header) void;
pub fn decode(page: []const u8, id: Id) DecodeError!Header;
pub fn checksum(page: []const u8, id: Id) u32;
pub fn page_size_valid(page_size: u32) bool;
```

## Consequences

**Binding.** `docs/PRD.md` §4.3 is edited in the same PR to link this ADR, show the 24-byte
order, and narrow the freelist to trunk pages. A PR that writes page bytes other than through
`page/header.zig`, or that changes any table above without bumping `format_version`, is rejected
on review.

**Good.**
- Bit rot, torn writes, truncation, misdirected writes, and never-written pages each map to one
  typed error: `ChecksumMismatch`, `ChecksumMismatch`/`Corrupted`, `TornWrite`, `ChecksumMismatch`
  (certain, §2), and `Unwritten`. No corruption path panics.
- Canonical encoding (zeroed reserved fields, tails and dead slots) makes whole-file differential
  and golden tests possible.
- Aligned payloads and `u32` ids leave room for the B+Tree's fanout and keep the pool under its
  per-frame budget.

**Costs.**
- 4 bytes per page of padding. A 2 TiB ceiling at 512 B pages.
- The page id is not recoverable from a misplaced page: we detect misplacement but cannot say
  where the page came from.
- Rejecting non-zero reserved bytes means even an additive file-header field needs a version bump.
  This is the intended price of failing closed.
- Duplicate ids in the freelist are not detectable by decode without a bitmap. They are guarded by
  `free` assertions and the model test until a bitmap or WAL check exists.
- In-page offsets at 64 KiB need 17 bits, so a `u16` slot offset cannot address byte 65536. The
  B+Tree ADR must settle this, not this one.
- Page 0 is rewritten whenever growth or a trunk change happens. Before plan 004, a crash between
  the trunk write and the page 0 write can leak a page. A leak is safe; a double allocation would
  not be. Writes are ordered trunk first, then page 0, to keep it that way.

## Verification

These tests land with the later plan-003 items:

1. **`page/header.zig`**:
   - Round trip at 512, 4096 and 65536.
   - A golden byte image (fixed id, type, `lsn` and payload) committed as a hex literal, which
     pins every offset and the checksum rule.
   - Every single-bit flip of a 512 B page is rejected.
   - A valid page decoded under any other id → `ChecksumMismatch` (§2), with a seeded sweep over
     id pairs.
   - All-zero pages at all 8 sizes → `Unwritten`.
   - Zero magic with a non-zero tail → `Corrupted`.
   - `version = 2`, a well-checksummed unknown type, non-zero `flags`/`reserved`, and a
     `file_header` at id ≠ 0 → each `Corrupted`.
   - `page_size_valid` rejects 3000, 256 and 131072, and accepts the 8 powers of two.
   - File header `page_size = 3000` on disk → `Corrupted`.
2. **`page/freelist.zig`**:
   - `trunk_capacity` matches the formula at all 8 sizes.
   - A seeded 10k-op model test against a bounded array.
   - Spill to a new trunk when full, then drain back through `next_trunk`.
   - Pop on empty → `null`.
   - `count = capacity + 1`, a non-zero dead slot, and self-linked `next_trunk` → each
     `Corrupted`.
3. **`page/manager.zig`**:
   - create → close → open round trip.
   - Size mismatch with `Options` → `Corrupted`.
   - A byte flipped on disk → `ChecksumMismatch`.
   - A zero-length file, or a zeroed page 0 → `Corrupted`.
   - A page copied on disk to another offset → `ChecksumMismatch`.
   - Allocate/free model with reopen: no id handed out twice, page 0 never allocated, and
     `page_count_max` enforced.
4. **2C matrix**:
   - All suites above at the 8 sizes.
   - The real decoder plugged into `src/testing/truncation_matrix_test.zig`: every truncated image
     → `TornWrite`, and every torn image → `ChecksumMismatch` or `Corrupted`. None is accepted, and
     none is `Unwritten` unless all bytes are zero.
5. **Docs**: `grep -n "0002-page-format" docs/PRD.md` finds the §4.3 link.
