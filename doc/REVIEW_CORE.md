# Review of the engine core changes (may be deleted later)

Status: the findings of `src/core` and `src/data` are applied; see "Resolved" at the end for each one, with the test that
failed before the fix. The text between is the review as written (by reading, with the compiler blocked), kept for the
reasons.

Scope: `git diff HEAD` and `git status` under `src/core`, `src/data`, `src/world`, `src/sim`, `src/render`, `src/runtime`,
`src/voxel`, `src/openworld`, `src/lib.axle`, plus the modules extracted from `src/minecraft`.

Method and limits. The compiler is blocked: `axle build` (also with `--emit`) answers "this axle was built from an older
standard library", so nothing below was compiled, run or measured, and no code was edited. The review is by reading, and
by diffing every extracted module against its old version in the `stv` branch (`git show stv:src/minecraft/...`). The moves
are mechanical renames (identifiers, `MC_*` to `NBT_*`/`REGION_*`/`PALETTED_*`/`NAME_TABLE_*`); the only logic differences
are the new `ByteBuf.reserve`/`setLen` and a `PalettedScratch` parameter type. `tools/fmt.sh --check` runs and passes for
`src/`; it lists `tests/src/main.axle`, `tests/src/voxworld_save.axle` and four files of `examples/water/fluidview`.
Top-level name uniqueness (E0003) was checked by script over `src/`: no duplicates. Doc comments: every `pub` item of the
new modules has one (the only gaps are grouped struct fields in `hydro_world.axle:106-112`, `hydro_params.axle:123`).

## Findings, by severity

### High

1. **Layering: core imports data.** `src/core/collections/name_table.axle:11-12` imports `crate::data::bytes::ByteBuf` and
   `crate::data::text::DataText`. It is the only layer violation in the tree (checked: `core` to `data` is 2 imports, all
   here; `data/world/sim/render/runtime` import nothing above their layer; `voxel`, `openworld`, `minecraft` import none
   of each other; nothing imports `examples`; `minecraft` imports `render` once, which is allowed; `openworld` imports
   `runtime`, allowed).
   Fix (cleanest): move the file to `src/data/serial/name_table.axle` (layer 2, next to the NBT reader that is its main
   client; it is a byte-range lookup, not a generic collection), rename the prefix nothing (constants are already
   `NAME_TABLE_*`), update `src/lib.axle:190` and the `use` lines in `src/minecraft` (grep `name_table`), `ARCHITECTURE.md`
   row 1, `CORE_EXTRACTION.md` ("Layer" column says 1). Moving `ByteBuf` and `DataText` into core instead is a far larger
   churn and ByteBuf is used by every data module.
2. **`FastInflater.gzip` aborts on a bad header.** `inflate_fast.axle:153-155`: `begin(data, start, ...)` runs before the
   `start < 0` test, so for a corrupt gzip header (`start == -1`) the copy loop reads `raw[from + i]` with `from = -1`
   (out-of-range index, abort or out-of-bounds read). `level.dat` and gzip chunks are user files. Fix: test `start < 0`
   (set `bad`, `finish`) before `begin`. Add a test: gzip with wrong magic, truncated gzip, gzip of 17 bytes.
3. **`RegionFile.writePayload` is not crash-safe as documented, and leaves the sector map wrong on failure.**
   `region_file.axle:376-390` frees the old sectors, then allocates; the new run may overlap the old record, which is then
   overwritten before the table is flushed, so the doc ("a crash between the two leaves the previous chunk intact") is
   false for a moved chunk. When `writeExternal` or `file.write` fails (`:401`, `:416`) the function returns false with
   the old sectors already marked free and the new ones marked used while `locs[slot]` still names the old record: the next
   write can overwrite a chunk the table still points to. Fix: allocate first with the old run still marked used, write,
   then free the old run and update `locs`; on failure unmark the new run only.

### Medium

4. **`FastInflater` output limit is bypassed below 64 KiB.** `room()` (`inflate_fast.axle:282`) returns true while
   `outLen + extra <= outCap`, and `outCap` starts at `FI_INITIAL_OUT = 65536`, so a decoder built with `maxOutput < 65536`
   can produce up to 65536 bytes. Check `limit` first. Same function: growth loop `cap = cap * 2` can overflow `i32` only
   if `limit` is above 2^30; clamp `limit` in the constructor.
5. **Stale and false header in `inflate_fast.axle:12`:** "the Adler sum is checked only when `verify` is set": there is
   no `verify`. Say "never checked".
6. **`Lz4.decode` accepts what it should refuse** (`lz4.axle:55-85`): (a) a RAW block (method 16) with `plain > compressed`
   reads past the block (`data.get` beyond `to`, abort or reads the next block): require `plain <= compressed`; (b) a stream
   with fewer than 21 bytes left or no terminating empty block returns `true` with partial output: return false unless
   the end block was seen (or document "the framing bounds it" and test it); (c) `plain` is not bounded by `LZ4_BLOCK`
   before `out.reserve(written + plain + 1)`: a 21-byte header can request `limit` bytes (64 MB) of memory.
7. **`ZipReader` entry numbering breaks on duplicate names** (`zip_reader.axle:135-140`): the entry index is taken to be
   the `StringId` returned by `intern`, which de-duplicates. A zip with two entries of the same name (legal) shifts every
   later name onto the wrong entry. Fix: when `intern` returns an id different from `i`, refuse the archive
   (`isOpen` false) or keep an `ids: i32[]` map. Also: `methods[i] = (method) as u8` truncates the 16-bit method (264
   passes as 8, `:131`); store `255` when `method > 255`. `dirOffset + dirSize > total` can overflow `i32` for hostile
   values (compute in `i64`). `DataText::fromBytes(dir, pos+46, pos+46+nameLen)` is not bounds-checked against `dir.len()`
   when the name length exceeds the directory (abort on a corrupt zip): check `pos + 46 + nameLen + extraLen +
   commentLen <= dir.len()` per entry.
8. **`NbtReader` size arithmetic overflows `i32`** (`nbt_reader.axle:198-205`): `self.i32v() * NBT_SIZE_LONG` wraps for
   counts above 2^28, so a hostile count can wrap to a small positive number that `need` accepts and the reader resumes at
   the wrong place; `need` itself computes `cursor + n` (overflow near 2^31). It cannot read out of bounds, but it breaks
   the "failed on damage" promise. Fix: `if (n > (end - cursor) / size) fail`. Also `skipList` loops per element for
   fixed-size types: skip `n * size` at once after the same check (large byte/int lists in a chunk, see Performance).
9. **Name of the RegionFile/ZipReader/NameTable families is not generic.** `RegionFile` hard-codes the Anvil layout (32
   per side, 4096-byte sectors, `r.X.Z.mca`, `c.X.Z.mcc`, compression ids, the 255-sector external rule) in both constants
   and behaviour. That is a format reader, not a parameterised container; a "hyper-modular" version would take a
   `RegionFormat` struct (`sideBits`, `sectorBits`, name scheme). It is not a safe edit without the compiler (the slot
   arithmetic uses shifts, `locs` size, the header size). Recommended: keep the name and the constants, say so in the
   header ("the Anvil format, not a configurable container"), and move the `.mca`/`.mcc` file naming (`pathOf`,
   `readExternal`, `writeExternal`) behind one `static fn` so a second naming scheme is one function. The same holds for
   the `PalettedPool` widest palette (8 hard-coded at `paletted_pool.axle:341, 427, 484`): make `maxPaletteBits` a constructor
   argument (default 8 stays for the Minecraft instances); `palLen : u16[]` and `single : u16[]` also fix the state
   width to 16 bits: document it as a limit of the pool.

### Low

10. `RegionScratch` constructor assigns `self.lz4 = new i32[4096]` twice (`region_file.axle:100-101`, the first is garbage).
    `4096` should be a public `LZ4_TABLE_SIZE` (or `Lz4::newTable()`): `lz4.axle:25` has it private, `compress`'s doc repeats the
    literal, and an undersized table is not checked.
11. `RegionFile.erase` indexes `sectors[s]` without the `s < sectors.length` guard that `buildSectorMap` and `writePayload`
    use (`:446`): a corrupt location entry aborts. `erase` also leaves the `.mcc` file of an external chunk behind.
12. `RandomFile.write` seeks before validating its arguments (`random_file.axle:93`); harmless. `fseek`/`ftell` take an
    `i64` here; on Windows the C `long` is 32 bit, so files above 2 GiB depend on how `std::ffi::libc::fs` binds them: check
    the binding, or document the limit. The class is named `length()` for a byte count where NAMES.md says `count`;
    a length in bytes is the one case where `length` reads better: add it to NAMES.md as an exception or use `bytes()`.
13. **Stale headers still say `mc_*` and talk about Minecraft:** `name_table.axle:1-9` ("mc_name_table", block names),
    `paletted_pool.axle:1-8` ("mc_store", "A chunk has 24 sections"), `nbt_reader.axle:1` ("mc_nbt_reader", "of Minecraft
    saves", `readRoot` doc "every Minecraft file"), `nbt_writer.axle:1` ("mc_nbt_writer", and line 6 is 137 columns),
    `lz4.axle:1`, `region_file.axle:1` ("mc_region", and `:344` is 122 columns), `inflate_fast.axle` (a Minecraft
    paragraph), `zip_reader.axle` ("The Minecraft client jar is 38 MB"), `packed_cells.axle:6` ("the Minecraft chunk codec").
    The first line must be `// <file name> — one line` (CLAUDE.md); the examples of use can stay as "for instance".
14. **Names.** NAMES.md says `count`, `len` only on the std-like containers: `NameTable.len()` (`name_table.axle:41`)
    should be `count()` (the field `count` is not a problem: `ZipReader` already has field and method `count`);
    `NameTable.name(i)` aborts on a bad index and has no `has`/`getOr`: add `has(index)`. Abbreviated names inside the
    new modules against "a field never repeats its owner and is never an abbreviation": `NbtReader.buf/elem/u8v/u16v/i32v`,
    `PalettedPool.pal/palOff/palLen/dataOff`, `RegionFile.locs/rx/rz`, `FastInflater.src/out/bad/litFast/...`; prefixes `FI_`,
    `RF_`, `PACKED_LONG_BITS` against "carry the owner's name in full" (`FAST_INFLATER_*`, `RANDOM_FILE_*`,
    `PACKED_CELLS_*`). Rename together with the call sites when the compiler works.
15. `PalettedPool.pack` has a dead branch: `scratch.list` holds `cells` entries, and distinct states never exceed `cells`, so
    `listLen < list.length` (`:417`) and the later `reset > list.length` loop (`:441`) are always true/false.
16. `lib.axle`: `ZipReader` is exported under the "Layer 7 minecraft" comment (`:293`) although it is layer 2 (move it to
    the layer-2 block); `FastInflater`, `RandomFile`, `Lz4` are exported but `ZipReader`'s sibling `RegionScratch` fields are
    all `pub` (the whole scratch is a public bag of buffers: acceptable since it is a per-thread scratch, say so in the doc).
    The layer-7 comment lists `minecraft/*` blocks of 100 lines in the library export: a game does not need
    `McBlock`-level names; that is for the Minecraft owner.
17. Docs. `ARCHITECTURE.md:43` said `axle fmt --check` (a bare format that CLAUDE.md forbids because it rewrites
    `vendor/smalt`): **fixed** to `tools/fmt.sh --check`. Still to do: `ARCHITECTURE.md` layer 1 row should list
    "packed and paletted containers" (name table is layer 2 after fix 1); `CLAUDE.md` layer 7 row lists only voxel and
    openworld although `ARCHITECTURE.md` adds `minecraft`; `CORE_EXTRACTION.md` "Done" table gives `NameTable` layer 1 (wrong,
    fix 1) and says tests "still live in `tests/src/minecraft_*`": no test names `NameTable` or `RandomFile` at all.
18. `src/lib.axle` order: the two new blocks (`Layer 1`, `Layer 2`) are appended after layer 4 audio and before layer 7, out
    of layer order; fine for the compiler, confusing for readers.
19. Fluid. Two engines coexist on purpose (`doc/FLUID.md` says `FluidWorld` is legacy until the three examples migrate);
    both are in the export list. Keep, but do not let new code use `FluidWorld`. `hydro_runner.axle:105-112` builds a `JobPool`
    and shuts it down at once when `threads <= 1` (starts workers just to stop them): create the pool only when threaded.
    `hydro_world.axle` is 1065 lines (limit about 700): the header names the jobs, split along them: (a) construction and
    bed/sources/vents/sinks setup, (b) `step` and the substep driver, (c) readers and the `ledger`. `physics_world.axle` (724)
    and `cpu_tris.axle` (720) are marginally over; split only if they grow. Over the limit in `src/minecraft`:
    `mc_block_lookup` 1180 and `mc_block_enum` 1177 (generated tables, exempt), `feat_tree` 1057, `gen_eval` 883, `render_trace`
    855, `mc_registry` 733, `mc_world` 726, `render_view` 719, `feat_compile` 715; `openworld/mission_book` 700.
20. `Shared<T>` copied into locals: `minecraft/render/render_bake.axle:276,284,312,347,385,533`, `render_bake_run.axle:85`,
    `render_table.axle:205,229,254` do `let v : Shared<McView> = self.view;`. If any runs on a worker thread this is the
    known Axle hazard (a copy touches the count). Not in the scope of this review (Minecraft), flagged for its owner.
21. Determinism: `HydroWorld` uses `core::math::trig::{sin,cos}` (the deterministic ones), no clock, no hash order found in
    `src/sim/fluid` (grep for `Map`, clock, atomics: none); the runner's grain is fixed by item index, so thread count does
    not change results as the header claims.

## Duplication: decisions

- `inflate_fast` vs `inflate`: not a duplicate of purpose (table-driven, reusable buffers, zlib/gzip/raw) but of function:
  `png.axle` is the only user of the puff-style `Inflater`. Decision: migrate the PNG importer to `FastInflater.zlib` (checking
  Adler there, since PNG has no outer framing, add the `verify` flag the header already advertises) and delete `Inflater`
  after the PNG tests pass; the shared `deflate_tables` already serves both. Until then the header of `inflate_fast` says why both
  exist (it does, in one paragraph).
- `zip_reader` vs `vfs_archive`: `vfs_archive.axle` (a virtual-file-system archive mount) is whole-file; `ZipReader` is
  positional. Decide with the VFS owner; at least `vfs_archive` should be able to mount a `ZipReader`.
- `random_file` vs `data/files`: `DataFiles` reads whole files, `RandomFile` is positional; different jobs, keep. Both should
  share the `fopen` mode strings and the failed-open-is-a-value rule (they do in spirit).
- `name_table` vs `StringInterner`/`StringMap`: not a duplicate: it is thread-safe for reads (no counts), keyed by byte range
  without making strings, and the reason is in its header. Keep, but say in `string_id.axle` that concurrent readers should
  use `NameTable`.
- `packed_cells`/`paletted_pool` vs existing bit-packed containers: none in `core` (`grep` found no other packed array);
  keep. `voxel/world` has its own chunk storage; unify only when the streamer is unified (see CORE_EXTRACTION later table).
- `Arena` (`src/core/mem/arena.axle`): see the last section.

## Generality leftovers

Constants or behaviour of the game still in the generic modules: `REGION_SIDE`/`REGION_SECTOR_BYTES`/`.mca`/`.mcc` and the
compression ids (format, finding 9); palette width 8 in `PalettedPool` (finding 9); `NBT_*` Modified-UTF-8 note (fine);
`Lz4` framing is lz4-java's (format); `PackedCells` has none; `NameTable` has none (apart from prose); `ZipReader`
refuses zip64 and 65535 entries (documented). The headers (finding 13) are where the Minecraft wording is.

## Tests

Registered suites are all called (`tools/suites.sh`: "all run"). The generic modules are only tested through
`tests/src/minecraft_chunks.axle`, `minecraft_pipeline.axle`, `minecraft_world.axle`; `NameTable` and `RandomFile` have no test.
Tests to add when the compiler works, under generic names (`core_containers`, `data_formats` suites, registered in
`tests/src/main.axle`, which also needs `axle fmt`):
- `NameTable`: empty table, find/add of the same name, 10 000 names across several rehashes, byte-range lookup equal to string
  lookup, name with embedded high bytes, `name(i)` round trip, determinism (two builds give the same indices).
- `RandomFile`: create/write/read back, read past end false, write extends `length`, open of a missing file closed value,
  double close, update mode keeps the content.
- `PackedCells`: `set`/`get` for every width 1..16 against a plain array, `packRun` equal to repeated `set`, `longsFor`.
- `PalettedPool`: growth from single to every width to direct, `pack` then `expandAt` identity for random content, `load` with a
  corrupt index and with wrong data length, `bytesUsed` after compaction.
- `NbtReader`/`NbtWriter`: write-then-read round trip of every tag type, empty compound, depth 512 and 513, truncated input at
  every length (must set `failed`, never abort), list of 0 and of huge count (finding 8).
- `Lz4`: encode/decode round trip for 0, 1, 12, 13, 65535, 65536, 65537 bytes, incompressible and highly repetitive
  data; corrupt streams (finding 6).
- `FastInflater`: stored, fixed and dynamic blocks (compare with `Deflater` output and with a known zlib sample), truncated and
  bad gzip (finding 2), limit below 64 KiB (finding 4).
- `RegionFile`: write/read of all 1024 slots, rewrite with smaller and larger size, external chunk (over 255 sectors),
  erase then reuse of sectors, failure path (finding 3), reopen and compare.
- `ZipReader`: stored and deflated entries, duplicate names (finding 7), comment after the end record, corrupt directory.
No `measured:` line exists for any generic module (only fluid, gen and anim suites print them): add one each for
`PackedCells.get/set` per million cells, `PalettedPool.expand`/`pack`, `NbtReader` over a 100 KB document, `Lz4` encode and
decode MB/s, `FastInflater` MB/s, `RegionFile.read` per chunk and `NameTable.findBytes` per million lookups.

## Performance (by reading only: no IR or timing was possible)

The IR comparison the user asked for (`--emit llvm-raw -O 0` vs `--emit llvm -O 3`) could not run: the stdlib guard stops
`axle build` even with `--emit`. After the relink these are the loops to read first, with what the source predicts:

1. `PackedCells.get/set` (`packed_cells.axle:196-210`): three integer divisions by a non-constant per call (`64 / bits`,
   `i / per`, `i % per`); a 32-bit `idiv` is 20-26 cycles, so about 60 cycles per cell against about 3 for the shift-and-mask
   it replaces. `PalettedPool.get/set` call it per cell, and `set` also does a linear `indexOf` over up to 256 palette entries.
   Fix (exact): store `per` and a precomputed magic reciprocal per container (or a `u8[17]` table of `per` and compute
   `i / per` by `(i * recip) >> 32`, exact for `i < 4096`); `expandAt` and `packRun` already hoist `per` and are fine. For `set`,
   cache the last `(value, index)` pair of the container: worldgen writes runs of one block. Expected 2-4x on `get`, more on
   `set`. Estimate only.
2. `PalettedPool.grow` (`:335-364`): allocates `new u16[cells]` per growth and, for each of the 4096 cells, walks the palette
   linearly (O(cells x palette), up to 1M steps at the 256-entry step). Use the scratch `map` of `PalettedScratch` as `pack` does.
3. `FastInflater`: (a) input is copied byte by byte into `src` in `begin` and output byte by byte into `into` in `finish` (two extra
   passes over the data; the comment says storing a `ByteBuf` array in a field double frees: pass the `i8[]` as a parameter of the
   hot function instead of a field, or copy with a memcpy call); (b) `dynamic` allocates `lens` (320 x i32) and `construct` allocates
   `next` per block, and `construct` zeroes a 1024-entry table per call even for the fixed code; keep them as members; (c) the match
   copy is byte by byte with a bounds check per byte even when `dist >= len`, where a block copy is exact; (d) stored blocks
   read `take(8)` per byte. Estimated 15-25% on chunk decode, from (a) and (c).
4. `Lz4.decode`: literal and match copies go through `ByteBuf.get` (bounds check and mask) one byte at a time; read the raw
   `i8[]` of both buffers once and copy ranges (a forward byte loop only for overlapping matches). `Lz4.encode` allocates a 64 KB
   `body` per call; take it from the scratch. `compressBlock` zeroes (to -1) the 4096-entry table once per 64 KB block: fine.
5. `NameTable.findBytes`/`hashBytes`/`same`: `ByteBuf.get` per byte (bounds check and mask) twice (hash then compare); a lookup of a
   10-byte name is about 40 checked loads. Take the raw array once. `find(text)` allocates a `ByteBuf` per call (documented as
   main-thread only). A 32-bit FNV over `i32` is fine for tables below 2^16; check `mask` use if names exceed that.
6. `RegionFile.writePayload` allocates `new ByteBuf(count * 4096)` per chunk and pads with a `push(0)` loop of up to 4095
   iterations: use `resize` (zero-fills) once, or reuse a scratch buffer. `chunkCount` is a 1024 loop: cache it if called per frame.
7. `NbtReader.skipList` for lists of fixed-size elements loops per element with a recursive call; a chunk's `Heightmaps`/`BlockLight`
   arrays are `LongArray`/`ByteArray` (already O(1)), but lists of ints or doubles (entities) are not: skip `n * size` at once.
8. `HydroRunner` dispatches one channel round trip per stage per substep (six per substep); for grids of a few tiles the dispatch
   costs more than the work: run serially when `count < threads * grain`. `HYDRO_TILE_GRAIN = 4` tiles (1000 cells) is reasonable
   for large grids. `hydro_passes.axle` has `/` by a tile count in the per-tile preamble only (`t / g.tilesX`), not per cell;
   the per-cell divisions (`:216, :225, :348`) are guarded float divides by a value that changes per cell and cannot be hoisted:
   `1.0 / depth` is already computed once (`:338`).
9. i64/f64 where smaller fits: not audited without the IR; `RandomFile.bytes` and file offsets are `i64` on purpose; `PalettedPool`
   per-container arrays are already `u8`/`u16`/`i32`. `FastInflater` tables are `i32[]` where `u16` halves the cache footprint
   (`litFast`, `distFast`, `clFast` are 1024 entries, `litSym`/`distSym`): 4 KB each, so they sit in L1 anyway: gain small.
10. False sharing: none found: the pool partitions by item index, passes write only their own tiles or particles.

### Compiler-level observations to check after the relink (for AXLE_COMPILER_FINDINGS.md)

Unverified here, to be answered by the IR: are `i32` divisions by loop-invariant values hoisted or strength-reduced; does `-O 3` run
the loop vectoriser and mark array bases `noalias`; are `for (i of a..b)` indexings bounds-checked inside the loop and does the
pass hoist the check (the `T[]` header reload); is `memcpy` recognised from the byte copy loops; are `nounwind`/`readonly` inferred
on small free functions and `static fn`s; are `Shared<T>` accesses atomic RMWs (`lock xadd`) on read.

### What the compiler does for allocation, and `Arena`

Not verifiable from IR now. From the source: every `new T[n]` is a heap allocation that is freed when its owner goes out of scope
(`drop`); nothing pools them and nothing hoists an allocation out of a loop or a call. The per-call allocations found above
(`PalettedPool.grow`, `FastInflater.dynamic/construct`, `Lz4.encode`, `RegionFile.writePayload`, `NameTable.find`) therefore cost
one malloc/free each, small against the work in the decode paths but real for `grow` and `construct` (8 KB and 70 B per call, up to
thousands of times per region).

`Arena` (`src/core/mem/arena.axle`) is used by nothing but `tests/src/mem.axle` and the export in `src/lib.axle`. It hands out byte
offsets and number accessors that are bounds-checked per access, because Axle cannot turn raw memory into a typed array:
every read is a call with a check, and the result cannot be passed to the code that takes `u16[]`, `u64[]` or `ByteBuf`.
Recommendation: **(b)**, then **(c)**. The repository already has the better pattern (`PalettedScratch`, `RegionScratch`, per-thread
`ByteBuf`s): typed reusable `T[]` members in a scratch struct per worker. Apply it to the sites above (`grow` through the
scratch map, `FastInflater` members for `lens`/`next`, a body buffer in `RegionScratch`/`Lz4` table). Then `Arena` has no site where it
fits (nothing needs untyped lifetimes), so delete it with its test and export, but only on the user's decision: it was not touched.

## Fix list (all unapplied: they need the compiler)

In order: 2, 3, 6, 4, 7, 8 (correctness, each with the tests listed above); 1 (move `name_table`, update imports, `lib.axle`, docs);
13, 14, 10, 11, 16, 5 (headers, names, `lib.axle`); 15 (dead code); 19 (split `hydro_world.axle`, pool only when threaded);
then the performance items 1-8 with a `measured:` line each; then the missing tests; then format `tests/src/main.axle`.
Applied now: `doc/ARCHITECTURE.md` (bare `axle fmt --check` replaced by `tools/fmt.sh --check`), and this file.

## Resolved (compiler `axle 0.19.0-dev (93b6b5e)`, tests `tests/src/{core_packed*,data_*}.axle`)

Method: each correctness test was run against the code as reviewed (a copy of the library with the old file) and failed
or aborted, then passed after the fix. Rates are `measured:` lines, best of several runs, `-O 3`, on a loaded machine
(variation about 5-10%). "Before" is the same test file against the reviewed code.

| # | Finding | Status | Evidence |
|---|---|---|---|
| 1 | core imports data | **Resolved**: `NameTable` is `src/data/serial/name_table.axle`; `lib.axle`, `mc_registry`, `mc_biomes` import the new path; docs say layer 2 | build; layer check by grep |
| 2 | `FastInflater.gzip` aborts on a bad header | **Resolved**: the header is tested before `begin`; `FEXTRA` reads use `getOr`; `begin` clears the output on a bad range | before: `index -1 out of bounds`; after: 19 cut/garbage gzip cases refused |
| 3 | `RegionFile.writePayload` not crash-safe | **Resolved**: new run allocated while the old is reserved, record written, then the old run freed; on failure only the new run is unmarked; doc rewritten (a chunk rewritten in place keeps the game's risk) | before: a failed external write let later chunks overwrite slot 5 (`got 1, want 0`); after: intact through reopen |
| 4 | output limit below 64 KiB | **Resolved**: `room` tests the limit first, the usable room never passes the limit, the constructor clamps to 0..2^30 | before: limit 1000 gave 5000 bytes; after refused, output <= limit |
| 5 | false `verify` header | **Resolved**: header says checksums are never verified; `zlibVerified` is the explicit form (Adler checked), used by the PNG importer | `fastVerifiedChecks` |
| 6 | `Lz4.decode` accepts damage | **Resolved**: raw block needs `plain <= compressed`; LZ4 block needs `plain <= 255 * compressed`; `plain <= LZ4_MAX_BLOCK_BYTES` (32 MiB) and `<= limit - written` before any reserve; a stream without its end block is refused; literal and match lengths cannot overflow | before: 3 fails then `ByteBuf.get: index out of range`; after all pass, a 60 MB claim from 5 bytes reserves nothing |
| 7 | `ZipReader` numbering and bounds | **Resolved**: per-entry `nameIds` and `firstOf` (find answers the first of a repeated name), method > 255 stored as unsupported, `i64` sum for offset + size, per-record bounds check, `entries == 0xFFFF` refused | before: `StringInterner.name: unknown id`; after: duplicate, wide-method, overflow, long-name, count-mismatch, cut-everywhere cases pass |
| 8 | `NbtReader` overflow | **Resolved**: `need` compares against the bytes left, `needItems(count, size)` divides, lists of fixed-size elements skip at once (`skipItems`) | before: 8 hostile-count checks failed; after pass |
| 9 | not generic | **Resolved**: `RegionFormat` (side/sector bits, max in-file sectors, external flag, four compression numbers, two extensions) with `RegionFile::anvil()`, `openReadAs`, `openWriteAs`, `pathOfAs`, `slotOfAs`, `decompressAs`; `PalettedPool::withPaletteBits`, `PALETTED_STATE_BITS` documents the 16-bit state | all tests identical for the presets |
| 10 | `lz4` twice, 4096 literal | **Resolved**: `LZ4_TABLE_SIZE` exported, an undersized table aborts with a message | |
| 11 | `erase` bounds | **Resolved** (`mark` skips sectors past the map); **Left**: the `.mcc` file of an erased external chunk stays (documented) | `regionDamageChecks` aborted before (`index 65535 out of bounds`) |
| 12 | `RandomFile` | **Resolved**: arguments validated before the seek; files above `RANDOM_FILE_MAX_BYTES` (2 GiB - 1) are refused because the C binding takes a 32-bit `long` on Windows; `length()` is a named exception in NAMES.md | `random file` checks |
| 13 | headers | **Resolved**: first lines `// name — one line`, no `mc_` and no Minecraft prose in the generic modules, lines <= 110 columns in everything touched except pre-existing comments of `bytes.axle` and `png.axle` | line scan |
| 14 | names | **Resolved**: `NameTable.count()`, `has(index)`, `nameOr`; fields `input/output/damaged/literalFast/...`, `paletteStart/paletteSize/dataStart/palettes`, `regionX/regionZ/locations`, `source/elementType/damaged`; constants `FAST_INFLATER_*`, `RANDOM_FILE_*`, `PACKED_CELLS_*`. **Left**: `PalettedScratch.map/list/longs/listLen/outBits/outLongs/flat` are public API used by the game and keep their names | |
| 15 | dead branch in `pack` | **Resolved** | `pack` suite |
| 16 | `lib.axle` | **Resolved** (ZipReader sits in the layer-2 block; `RegionScratch` doc says it is a per-thread bag); new exports `RegionFormat`, `PackedLayout`, `PACKED_FAST_LIMIT`, `PALETTED_*`, `LZ4_TABLE_SIZE`, `LZ4_MAX_BLOCK_BYTES`, `RANDOM_FILE_MAX_BYTES`, `bytesCopy` | |
| 17 | docs | **Resolved** for ARCHITECTURE (layer rows), CORE_EXTRACTION (layer, knobs, tests), NAMES | |
| 18 | `lib.axle` order | Left (cosmetic) | |
| 19 | fluid, hydro_world split | Not in the scope of this pass (`src/sim`) | |
| 20 | `Shared<T>` copies | Not in scope (game code) | |
| 21 | determinism of hydro | Not in scope | |

Duplication: the PNG importer now decodes with `FastInflater::zlibVerified` (the limit is the raw size from the header, now
honoured below 64 KiB); the PNG round-trip checks (`data.axle`) and `examples/engine/texlab` are unchanged. `Inflater`
is **not** deleted: `games/blockland/src/block/mc_registry.axle`, `src/voxel/world/region.axle` and the `inflate:` checks
of `tests/src/data.axle` still use it. When those two are migrated (`FastInflater::zlibVerified` is the drop-in) the file
and its test go.

Performance (`-O 3`; before / after on the same test file):

| Item | Before | After |
|---|---|---|
| `FastInflater` text-like 4 MiB (1.4 MB compressed) | 440 MB/s | 515-530 MB/s (hot loop on locals, a fast path with 8 input bytes and 258 output bytes certain, block copies, bulk input and output copies, fixed tables kept, scratch members) |
| `FastInflater` long matches (4 MiB from 60 KB) | 11 GB/s | 11 GB/s (the compiler already vectorised the byte loop) |
| `Lz4` text encode / decode | 470 / 675 MB/s | 440-520 / 650-720 MB/s (noise level: the loop is branch-bound) |
| `Lz4` long matches decode | 17 GB/s | 22-24 GB/s |
| `PalettedPool.get` (5-bit palette) | 1020 Mcells/s | 1390 Mcells/s (`PackedLayout`: multiply instead of divide, exact below 2^26 cells, divide above) |
| `PalettedPool.set` incl. growth from single | 112 Mcells/s | 143-160 Mcells/s (layout, last-hit cache, `grow` packs a word at a time with a run cache) |
| `PalettedPool.pack` | 1380 Mcells/s | 1790 Mcells/s (`packValues`, no `set` per cell) |
| `PalettedPool.expand` | 2020 Mcells/s | 1800 Mcells/s (slower and not understood: the palette loop did not change; the direct form now uses `unpackRun`) |
| `PackedCells.get/set` with a constant width | 2490 / 1035 Mcells/s | unchanged (LLVM folds the division when the width is a constant) |
| `NameTable.findBytes`, 10 000 names | 41 Mlookups/s | 40 (raw-array loops did not change it: `ByteBuf.get` was inlined) |
| `RegionFile` 100 KB chunk read / write | 225-240 / 2300-2500 us | 160 / 2150 us (reused body buffer, zero fill in one pass, `pushRange` is one `memcpy`) |
| `ZipReader` 2000 deflated entries | 89 000 entries/s, 208 MB/s | 133 000 entries/s, 312 MB/s (the inflater) |
| `NbtReader` walk of 66 KB | no figure: the old reader does not build at `-O 3` (see the compiler finding) | 3-4 us at `-O 3`; the fixed arrays skip in one step |

Not done: a per-call 8 KB allocation in `PalettedPool.grow` remains (a scratch would change the `set` signature);
`FastInflater` still copies its input and output once each (an `i8[]` stored in a field cannot be shared with a `ByteBuf`
without a double free) but now as one `memcpy` each.

### Arena

`src/core/mem/arena.axle` is used only by `tests/src/mem.axle` and the export in `lib.axle`: no engine site allocates
through it. The compiler frees every `new T[n]` at its owner's scope exit and pools nothing, so an arena would only help
untyped memory, and Axle cannot turn raw memory into a typed array: every access is a call with a bounds check and the
result cannot go to code taking `u16[]`, `u64[]` or `ByteBuf`. The engine's own pattern is better and already used:
typed reusable members in a scratch struct (`PalettedScratch`, `RegionScratch`, the `FastInflater` tables, the region
file's body buffer). Recommendation: delete `Arena`, its export and `tests/src/mem.axle` when the owner agrees; it was not
touched.

### Compiler finding

`axle build -O 3` of a test project containing the reviewed (old) `NbtReader` with `NbtSuite.measure` stops with
`LLVM ERROR: Instruction Combining on NbtSuite.measure did not reach a fixpoint after 1 iterations` (the same code with
the fixed reader builds). Reproduce with the old `nbt_reader.axle` from git history and `tests/src/data_nbt.axle`.
