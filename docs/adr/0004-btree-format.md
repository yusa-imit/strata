# ADR-0004: B+Tree page format v1

- **Status**: Proposed (accepted on merge)
- **Date**: 2026-10-20
- **Milestone**: plan `docs/plans/005-phase-4a-btree.md`, item "ADR-0004 — B+Tree page format v1"
- **Applies to**: `docs/PRD.md` §4.6 (`btree`), §4.4 (pins, `fetchNew`, `discard`), §4.5 (one new
  frame type and its redo), §4.3 (three page types, trunk `lsn`)
- **Supersedes**: PRD §4.6's `parseLeaf(bytes, page_size)`: the slice length is the page size
  (ADR-0002 §4). **Depends on**: ADR-0001 (`node.zig` pure; tree methods take `io`), ADR-0002
  (24-byte header, types 16–31 reserved for this ADR, seeded CRC, id 0 = null, §8), ADR-0003
  (`frame_bytes_max`, strata frame types 16–127, one frame = atomic unit, §10 redo, OQ1).

## Context

The B+Tree is strata's third on-disk format and ships in v0.6.0. These forces shape it:

1. **64 KiB pages.** A page-relative offset can reach 65536, which is past the `u16` range
   (ADR-0002 Costs).
2. **A good checksum does not make a page well-formed.** A CRC proves the writer wrote the
   bytes, not that the writer was right. A malformed page must give `Corrupted`. It must never
   cause a panic or an out-of-bounds read.
3. **Atomicity versus frame size.** A split cascading to the root touches 2·height + 1 pages.
   The WAL's atomic unit is one frame of at most 1 MiB, and 15 images of 64 KiB fit in that.
4. **The freelist is unlogged.** `allocate` and `free` write trunks and page 0 straight to the
   file, and trunks carry `lsn = wal_lsn`. A crash must never leave a page both live and free.
   Four paths lead there:
   - (a) a free persists before the op that unlinked the page;
   - (b) a pop is lost while the frame that images the popped page is durable;
   - (c) redo from an older checkpoint replays a pre-free image over a page that became a trunk;
   - (d) the pool writes a stale dirty frame of a freed page over its trunk.
5. **The hot path is about 200 ns.** A point get must reach 5M ops/s (PRD §5), so parsing a
   node cannot be O(cells).
6. **The tools already exist.** `codec.varint` (canonical LEB128, rejects overlong input),
   `codec.fixed`, the pool's pins and its write-back gate (`page.lsn ≤ durable_lsn`), and
   `PageRedo`.

## Decision

Integers are little-endian and go through `codec.fixed`. Lengths go through `codec.varint`;
its `Truncated` and `Overlong` errors become `Corrupted`. A *payload offset* is a page offset
minus 24. Format v1 is everything in this document.

### 1. Page types (ADR-0002 §1 range 16–31)

| Value | Name | Layout |
|---:|---|---|
| 16 | `btree_leaf` | §3, §4 |
| 17 | `btree_internal` | §3, §5 |
| 18 | `btree_overflow` | §6 |
| 19–31 | reserved | successor layouts (§12) |

All three are legal at any id ≥ 1. `header.type_valid` learns them in the node item.
**Why:** a value inside the reserved range needs no page version bump (ADR-0002 §8), and
v0.5.0 readers fail closed with `Corrupted`.

### 2. Limits, derived per page size

```
usable(ps)               = ps - 32                     slot table + cells
cell_bytes_max(ps)       = usable/4 - 2                one cell; with its slot <= usable/4
key_len_max(ps)          = min(cell_bytes_max - 10, 1024)   10 = varint 3 + varint 3 + head 4
value_len_max            = 1 << 20                     format constant; varint <= 3 bytes
inline(ps, k, v)         = vs(k) + vs(v) + k + v <= cell_bytes_max   vs = varint size
overflow_capacity(ps)    = ps - 32
underflow_bytes(ps)      = usable/4
cell_count_max(ps)       = usable/4                    smallest cell 2 B + slot 2 B
images_per_frame_max(ps) = (payload_bytes_max - 8) / (ps + 4)      §9 frame layout
height_limit             = 16
height_max(ps)           = min(height_limit, (images_per_frame_max - 1) / 2)
```

| ps | cell max | `key_len_max` | inline v (16 B key) | overflow cap | pages/1 MiB | images/frame | `height_max` |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 512 | 118 | 108 | 100 | 480 | 2185 | 2032 | 16 |
| 1 KiB | 246 | 236 | 227 | 992 | 1058 | 1019 | 16 |
| 2 KiB | 502 | 492 | 483 | 2016 | 521 | 510 | 16 |
| 4 KiB | 1014 | 1004 | 995 | 4064 | 259 | 255 | 16 |
| 8 KiB | 2038 | 1024 | 2019 | 8160 | 129 | 127 | 16 |
| 16 KiB | 4086 | 1024 | 4067 | 16352 | 65 | 63 | 16 |
| 32 KiB | 8182 | 1024 | 8163 | 32736 | 33 | 31 | 15 |
| 64 KiB | 16374 | 1024 | 16355 | 65504 | 17 | 15 | 7 |

```zig
comptime {
    for (0..8) |shift| {
        const ps: u32 = header.page_size_min << shift;
        const ops: u32 = 2 * @as(u32, height_max(ps)) + 1;
        assert(images_header_size + ops * (4 + ps) <= frame.payload_bytes_max);
        assert(4 * (cell_bytes_max(ps) + slot_size) <= usable(ps)); // >= 4 cells, at 512 too
        assert(ps - header.header_size <= std.math.maxInt(u16)); // payload end fits a slot
        assert(height_max(ps) >= 7);
    }
}
```

- **Height** counts levels, including the leaves; a root leaf has height 1.
- **Why a cell is at most a quarter of `usable`.** At 512 B, four cells always fit
  (4 · (118 + 2) = 480). One split always makes room for the new cell, and each half ends
  above 3/8 of `usable`.
- **Why a byte-based underflow at 1/4.** A fresh split never underflows at once, and a merge
  needs the combined node to fit. So nodes do not thrash between split and merge.
- **Why the 1024 key cap.** Without the cap, 16 KiB separators at 64 KiB pages give fanout 3,
  and height 7 holds 729 leaves. With it, an internal node at 1/4 fill keeps at least 15
  cells, so a 64 KiB tree holds ≥ 2²⁴ leaves even when every separator is maximal. The cap
  also matches kv's default (PRD §4.8) at 8 KiB and above.
- **Why `height_limit` = 16.** It sizes the descent stack and the pool floor (§9). At the worst
  realistic fanout (3: maximal keys at 512 B), height 16 holds 3¹⁵ ≈ 1.4·10⁷ leaves.
- **Past the limit.** A tree that would exceed `height_max` returns `error.HeightLimit`. The
  error is raised in the prepare phase, before any byte changes (§9).

### 3. Node layout (leaf and internal)

| Offset | Width | Field | v1 rule |
|---:|---:|---|---|
| 0 | 24 | page header | ADR-0002; `page_type` 16 or 17 |
| 24 | 2 | `cell_count` | `u16`, ≤ `cell_count_max` |
| 26 | 1 | `level` | `0` = leaf (type 16); `1 … height_limit − 1` = internal (type 17) |
| 27 | 1 | `reserved` | must be `0` |
| 28 | 4 | `link` | leaf: `next` (0 = none); internal: `right_child` (≠ 0); never own id |
| 32 | 2·n | slots | `u16` payload offset of cell `i`; slot `i` is the `i`-th smallest key |
| | | free gap | `[8 + 2n, o[n−1])` in payload offsets, all zero |
| 24 + o[n−1] | | cells | dense and ordered: `o[i] + size(i) == o[i−1]`, `o[−1] = ps − 24` |

The slot table grows toward the end of the page. Cells grow toward the start, so cell 0 ends
at the page end.

- Inserting at slot `k` moves cells `k … n−1` down by the new cell's size. That is at most
  `usable` bytes. A sequential append moves nothing.
- A remove closes the gap the same way. There is no freeblock list and no separate compaction
  state.

**Why payload offsets.** The last byte (65511) and the end sentinel (65512) of a 64 KiB page
both fit a `u16`. Slots start at payload offset 8, so 0 is never a valid cell offset.

**Why dense and ordered.**
- One key set has exactly one byte image, so golden and differential tests work (as in
  ADR-0002 §5).
- Each cell can be checked against its neighbour alone in O(1) (§10).
- A split's halves are contiguous byte ranges.
- The cost is a memmove on a mid-node insert or remove.

**Why a `level` byte.** Descent requires `child.level == parent.level − 1`. Descent therefore
ends within `height_limit` steps, and a cycle or a leaf/internal mix-up is `Corrupted`. No
visited set is needed.

### 4. Leaf cells

```
inline:    key_len varint | value_len varint | key | value
overflow:  key_len varint | value_len varint | key | head u32   (first overflow page, ≠ 0)
```

- There is no flag byte. The form is a pure function of `inline(ps, key_len, value_len)`
  (§2), and the other form is `Corrupted`. Encoding stays canonical.
- Keys are strictly ascending.
- Only the root leaf may be empty.
- `next` is the right neighbour leaf in key order. It is 0 in the rightmost leaf and the root.
- **Why varint.** Typical keys and values are under 128 B, so a cell carries 2 B of length
  overhead instead of 6 B for a fixed `u16 + u32`. That is 10% of a 40 B cell.
- **Why only `next`.** The left node always survives a split or merge, so no third leaf is
  rewritten and the image bound holds (§9). `prev` uses the cursor's descent stack.

### 5. Internal cells

```
key_len varint | key | child u32   (+ right_child in the node header)
```

- `cell_count ≥ 1`, so every internal node has at least 2 children.
- Separators are strictly ascending.
- `child[i]` holds the keys `k` with `sep[i−1] ≤ k < sep[i]`. `right_child` holds the keys
  `k ≥ sep[n−1]`.
- Any `s` with `max(left) < s ≤ min(right)` is a valid separator. The v1 writer uses
  `min(right)`, and suffix truncation can come later without a format change.
- A child is never 0 and never the node's own id. The tree checks `child < page_count`.

### 6. Overflow pages (type 18)

| Offset | Width | Field | v1 rule |
|---:|---:|---|---|
| 24 | 4 | `next` | `0` = last page; never own id |
| 28 | 4 | `len` | data bytes in this page, `1 … overflow_capacity` |
| 32 | `len` | data | the rest of the page is zero |

A value of `v` bytes uses `n = ⌈v / overflow_capacity⌉` pages:
- every page but the last has `len == capacity` and `next ≠ 0`;
- the last page has `next == 0`;
- the `len` fields sum to `v`.

The reader walks exactly `n` pages, at most 2185. Any other shape is `Corrupted`: a short or
long chain, a wrong `len`, or a cycle (a cycle can never end in 0). The leaf cell keeps no
local prefix. **Why `len`:** each page can be validated alone, and a chain spliced from another
value fails.

### 7. Key order

Keys compare bytewise and lexicographically, as unsigned bytes, with a proper prefix first
(`std.mem.order(u8, a, b)`). The empty key is valid, and keys are unique. There is no
collation hook: consumers encode their order into the bytes.

### 8. Fixed root id, split and merge

The root id is allocated at `create` and never changes. The caller persists it (PRD
`root: page.Id`), so there is no meta page.

- **Root split.** The root's cells move to two new pages, L and R, at the root's level. The
  root becomes internal at `level + 1` with one cell `(sep, L)` and `right_child = R`. For a
  leaf root, `L.next = R` and `R.next = 0`. Images: the root, L and R.
- **Non-root split.** The left node keeps its id and the right node is new.
  - Leaf: `right.next = left.next` and `left.next = right`.
  - Internal: the middle cell's key moves up, and its child becomes `left.right_child`.
  - The split point is chosen by bytes, minimizing `|left − right|`.
- **Underflow.** A non-root node underflows when `2n + Σ cells < underflow_bytes`. It then:
  - merges with an adjacent sibling under the same parent if the result fits (internal nodes
    also take the pulled-down separator); the left node survives and the right is freed;
  - otherwise, redistributes by bytes.

  If the new separator would not fit in the parent, rebalancing is skipped and the node stays
  underfull, which is valid. Only `used ≤ usable` and `n ≥ 1` are hard rules. So a delete
  never splits.
- **Root collapse.** When the root would have one child, the child's bytes are copied into the
  root (`level − 1`) and the child is freed.
- **Why no meta page.** It saves one page and one image per height change, and avoids a
  pointer page that would need its own image path (ADR-0003 OQ2).

### 9. Logging and atomicity

These rules apply when a `wal.Writer` is attached. An unlogged tree appends no frames, keeps
page `lsn`s as they are, and `release_frees` frees everything.

**Frame type 16 `page_images`** (ADR-0003 §6, strata range):

| Offset | Width | Field | Rule |
|---:|---:|---|---|
| 17 | 4 | `count` | `u32`, ≥ 1 |
| 21 | 4 | `page_size` | `u32`, `page_size_valid` |
| 25 | count·(4 + ps) | entries | `page_id u32` (≥ 1, strictly ascending), then the page bytes |

Any of the following is `Corrupted`:
- `len ≠ 8 + count·(4 + ps)`;
- ids that are 0, unsorted or repeated (an O(n) check);
- an image without `STRA`, or with a type that is illegal at its id (as for `page_image`).

v0.5.0 readers reject this type as `Corrupted`.

**One op is one frame.**
1. **Prepare (may fail; changes no byte).**
   - Descend with pins.
   - Plan the splits and rebalancing.
   - Check `KeyTooLarge`, `ValueTooLarge`, `HeightLimit` and room in `frees_pending`.
   - Take new ids from the reserve (rule A) and `fetchNew` them.
   - Write the overflow chain (rule C).
2. **Apply (cannot fail).** Edit the pinned frames. Every page the op dirties stays pinned
   until step 4, so the pool cannot evict it while its `lsn` is still ≤ `durable_lsn`.
3. **Append** one `page_images` frame with every live page the op dirtied. That is at most
   2·height + 1 pages, which fits `images_per_frame_max` by §2. The frame gets LSN `L`.
4. **Stamp and release.** `set_lsn(L)` on each page, then unpin. Ids the op unlinked enter
   `frees_pending` tagged with `L`.
5. **Return.** Making the frame durable is the caller's `commit`.

Recovery yields the tree from before the op or after it, never half a split. If the append
fails, the writer latches. The tree then calls `pool.discardAll()`, because unlogged edits
must never reach disk while logged pages come back on replay, and the tree latches `Failed`.

**Rule A: an allocation is durable before it is referenced.**
- An id popped from the freelist goes into a frame only after `PageManager.sync` has made the
  pop durable. This closes path (b).
- The tree keeps a reserve of up to 2·`height_max` + 1 ids, refilled by `allocate` × k and
  then one sync.
- Growth needs no sync, because redo grows the file (ADR-0003 §10).
- After a crash, reserved ids leak, which ADR-0002 calls safe.

**Rule B: frees are deferred, and trunks outrank old images.**
- Unlinked ids wait in `frees_pending`, bounded by `frees_pending_max`. When it is full, the
  prepare phase returns `error.FreesPendingLimit`.
- `release_frees(io)` handles each entry whose `lsn ≤ durable_lsn`:
  1. `pool.discard(id)`, which closes path (d);
  2. `PageManager.free_at(io, id, durable_lsn)`, which stamps every trunk it writes with
     `lsn ≥ durable_lsn`.
- Deferral closes path (a), and the stamp closes path (c): redo skips any older image of a
  trunk page.

**Rule C: an overflow chain goes first.**
- A chain is logged before the op that references it, in `page_images` frames of at most
  2·`height_max` + 1 pages each. That is the pin budget, and each chunk stays pinned until its
  `set_lsn`.
- The chain is unreachable until the op frame. A crash in between leaks it. A failed op
  pushes the chain to `frees_pending`.
- A 1 MiB value is 1.06–1.13 MiB of images at every page size, so it cannot ride in the op
  frame.
- An overwrite or delete frees the old chain under rule B.

**Redo.** `PageRedo` validates the whole `page_images` frame before writing anything. It then
applies each image if the page fails to decode or if its `lsn` < `frame.lsn`, and re-stamps it
with `frame.lsn` (ADR-0003 §10, per image). Replaying twice equals replaying once.

**Pool floor.** `pool frames ≥ 2·height_max(ps) + 2` (an op's pins plus one cursor leaf). This
is asserted at tree init.

### 10. Untrusted bytes

Only caller contracts are asserted: a valid page size, `page.len == ps`, and an index below a
parsed node's count. Every byte read from a page is data. It is never asserted, and a failed
check is `Corrupted`.

- **`parse` (O(1), on every fetch) checks:**
  - the type is the expected one;
  - the level matches the type, and on descent equals the parent's level − 1;
  - `reserved == 0`;
  - `cell_count ≤ cell_count_max`, and the slot table ends at or before the lowest cell;
  - the `link` rules.
- **`cell(i)` (O(1), on access) checks:**
  - `8 + 2n ≤ o[i]`;
  - both varints decode inside the cell;
  - `key_len ≤ key_len_max` and `value_len ≤ value_len_max`;
  - the form matches §4;
  - `o[i] + size(i) == o[i−1]`.

  A binary search therefore verifies only the log₂ n cells it touches.
- **`validate(io, gpa)` (O(pages)) checks:**
  - every cell;
  - strict key order and the zero gap;
  - separator bounds and levels;
  - that the `next` chain equals the in-order leaves;
  - overflow chains, and ids `< page_count`.

  The walk is bounded by `page_count`.

### 11. Golden bytes (512 B, `lsn` 0; bytes not shown are zero)

Leaf at id 1 with `("apple","red")` and `("kiwi","green")`. The cells are 10 B at payload
offset 478 and 11 B at payload offset 467.

```
off  bytes                                     field
  0  53 54 52 41 | 10 | 00 | 01 00             magic | btree_leaf | flags | version 1
  8  3e 6f e1 ff                               checksum 0xFFE16F3E (seed u64le 1)
 12  00 x12                                    reserved | lsn 0
 24  02 00 | 00 | 00 | 00 00 00 00             cell_count 2 | level 0 | reserved | next none
 32  de 01 d3 01                               slots 478, 467
 36  00 x455                                   free gap
491  04 05 6b 69 77 69 67 72 65 65 6e          cell 1: 4, 5, "kiwi", "green"
502  05 03 61 70 70 6c 65 72 65 64             cell 0: 5, 3, "apple", "red"
```

Internal node at id 2, level 1. Page 3 holds the keys `< "kiwi"`; page 4 holds the keys
`≥ "kiwi"`.

```
  0  53 54 52 41 | 11 | 00 | 01 00             magic | btree_internal | flags | version 1
  8  ac 51 2e 33                               checksum 0x332E51AC (seed u64le 2)
 12  00 x12                                    reserved | lsn 0
 24  01 00 | 01 | 00 | 04 00 00 00             cell_count 1 | level 1 | reserved | right_child 4
 32  df 01                                     slot 479
 34  00 x469                                   free gap
503  04 6b 69 77 69 03 00 00 00                cell 0: 4, "kiwi", child 3
```

Negative pins:
- The leaf read under id 2 has checksum `0xED82B6EB`, which gives `ChecksumMismatch`.
- The leaf with slot 0 set to 479 (re-checksummed to `0x77133504`) decodes as a page, but
  `cell(0)` is `Corrupted`, because 479 + 10 ≠ 488.

The node item re-derives these bytes from the encoder; a mismatch there is an ADR erratum to
fix in the same PR, not a reason to change the layout silently.

### 12. Versioning

- The node layout rides on page `format_version` 1, the `STRA` magic and the page CRC.
- A layout change takes a new type id in 19–31 instead of bumping the page version. Old
  readers fail closed, and both layouts can coexist during a rewrite.
- A successor to frame type 16 takes a new strata frame type.
- A change to any §2 formula is a layout change.
- No migration tooling exists, because there is no earlier format.

### 13. API shape

```zig
// page/header.zig: Type gains btree_leaf = 16, btree_internal = 17, btree_overflow = 18.
// btree/node.zig: pure; no io, no allocation (ADR-0001). Lengths are u32 at the API.
pub const height_limit: u8 = 16;
pub const value_len_max: u32 = 1 << 20;
pub fn key_len_max(page_size: u32) u32;
pub fn value_inline(page_size: u32, key_len: u32, value_len: u32) bool;
pub fn height_max(page_size: u32) u8; // also usable, cell_bytes_max, overflow_capacity, ...
pub const ParseError = error{Corrupted};
pub const Value = union(enum) { bytes: []const u8, overflow: struct { head: Id, len: u32 } };
pub const Entry = struct { key: []const u8, value: Value }; // borrows the page
pub const Slot = struct { index: u16, found: bool };
pub fn parse_leaf(page: []const u8) ParseError!Leaf; // Leaf.entry(i), Leaf.search(key)
// btree/internal.zig: internal cells, same slot layout and untrusted-bytes rules as the leaf.
pub fn parse_internal(page: []const u8, level: u8) ParseError!Internal;
// btree/split.zig: Corrupted when the page bytes cannot be split; call it on a parsed node.
pub fn split_point(page: []const u8, incoming_bytes: u32, at: u16) ParseError!u16;

// btree/tree.zig
pub const Options = struct { value_len_max: u32, frees_pending_max: u32 };
pub const InsertError = cache.FetchError || page.AllocateError ||
    error{ KeyTooLarge, ValueTooLarge, HeightLimit, FreesPendingLimit, Corrupted, Failed };
// BPlusTree: create/open(target, ..., root), attach(writer), get/insert/delete(io, ...),
// release_frees(io) FreeError!u32, validate(io, gpa), check_invariants().

// Additive elsewhere (no signature or error-set change):
// BufferPool.fetchNew(io, id) FetchNewError!PageGuard zeroed frame, no read
// BufferPool.discard(id) void                        drop an unpinned frame, never write back
// PageManager.free_at(io, id, lsn) FreeError!void    trunks stamped max(wal_lsn, lsn)
// wal.frame.Type.page_images = 16                    payload_valid and PageRedo learn it
// wal.Writer.append_parts(io, type, parts) AppendError!Lsn   gather; no 1 MiB copy (OQ7)
```

### Rejected alternatives

| Alternative | Why not |
|---|---|
| Page-relative `u16` offsets | The 64 KiB end sentinel (65536) does not fit. |
| `u32` slot offsets | 2 B more per slot, with nothing gained. |
| Unordered cells + freeblock list | Fragmentation state, compaction, O(n log n) overlap check. |
| Fixed `u16`/`u32` lengths | 6 B per leaf cell instead of 2 B typical. |
| Doubly linked leaves | A split or merge rewrites a third leaf: one more image. |
| Meta page holding the root id | An extra page and image per height change; no image path. |
| One `page_image` frame per page | A cut between frames leaves half a split (ADR-0003 OQ1). |
| `commit` frame type (4–15) | The reader must buffer or undo groups; one frame is atomic. |
| Logical key-level redo | Replay must re-derive splits and allocations; later, as a new type. |
| Frees released at checkpoint | Needs no `free_at`, but freed space waits for a checkpoint. |
| `key_len_max` = cell bound | 16 KiB keys at 64 KiB: fanout 3, so height 7 holds 729 leaves. |

## Consequences

**Binding.** PRD §4.6 is edited in the same PR: its slotted-page bullet links this ADR, as
§4.3 and §4.5 do, and `parseLeaf` drops `page_size`. Node bytes are written only through
`btree/node.zig`, and frame type 16 only through the tree. A table change without a new type
id is rejected on review.

**Good.**
- Each malformed page or chain gives `Corrupted`, and no path panics.
- Every op is atomic in one frame, and crash safety covers all four freelist paths.
- The image is canonical, and the hot path does O(log n) checked reads.

**Costs.**
- A logged op writes whole pages: high write amplification (plan Risks; gated unlogged).
- Under logging, refilling the reserve costs one page-file sync. A crash leaks the reserved
  ids, pending frees and orphan chains until a sweep exists.
- A mid-node insert costs a memmove.
- Keys are capped at 1024 B; values at 1 MiB.
- 64 KiB trees stop at height 7, failing closed with `HeightLimit`.
- The pool must hold 2·`height_max` + 2 frames.

**Plan 005 impact.** The WAL-integration item also owns `PageManager.free_at`,
`BufferPool.discard`, frame type 16 in `wal/frame.zig` and `PageRedo`, and the id reserve
(rules A–C); the tree item owns `fetchNew`.

**Verification per item.**
- **Leaf:** the §11 golden and pins; round trip at 512 B, 4 KiB and 64 KiB; a seeded
  random-bytes sweep gives only `Corrupted`; a negative test for every §10 check; four
  maximal cells fit at 512 B.
- **Internal:** golden; `split_point` at all 8 sizes; child 0, a level mismatch and own-id
  links give `Corrupted`.
- **Tree:** the root id is unchanged across splits and collapses; `HeightLimit` and
  `FreesPendingLimit` leave the file byte-identical.
- **Overflow:** a 1 MiB value at 512 B and 64 KiB; a cycle, a short or long chain, or a wrong
  `len` gives `Corrupted`.
- **WAL:** a golden `page_images` frame; unsorted ids, a size mismatch or page 0 give
  `Corrupted` with no page written; crash points recover pre- or post-op; replaying twice
  equals once. These mutants must fail the model: pop without sync, `free` without `lsn`,
  free without `discard`.
- **Docs:** `grep -n "0004-btree-format" docs/PRD.md` finds the §4.6 link.

## Open questions (recommendations)

1. **The refill sync (rule A).** Its cost shows up in the logged bench figure. A logged
   freelist would need a page-0 image path (ADR-0003 OQ2). Recommendation: keep rule A for v1.
2. **Leaked pages.** v1 has no reclamation. Recommendation: a later `reclaim` that marks pages
   reachable from `validate` in a gpa-sized bitmap and frees the rest.
3. **Fill under sequential insert.** Even splits leave sequential inserts at 50% fill.
   Recommendation: an "append split" on the rightmost leaf, decided in the bench item. It is a
   writer policy and needs no format change.
4. **kv defaults (plan 006).** `key_len_max = 1 KiB` exceeds 1004 at 4 KiB. Recommendation:
   clamp to `node.key_len_max(page_size)`.
5. **Values over 1 MiB.** Recommendation: the consumer chunks them. Raising the limit is a
   layout change and needs a new type id.
6. **Small edits.** Recommendation: delta records under a new strata frame type, with no WAL
   version bump.
7. **`append_parts`.** If the WAL item declines a gather append, the tree allocates a
   `payload_bytes_max` staging buffer at init instead.
