# Core extraction: generic mechanisms that lived inside the Minecraft module

Rule: a mechanism that is a general algorithm, format or data structure belongs in the engine's lower layers, with a
Minecraft-agnostic name and its knobs as parameters. The game package `games/blockland` keeps what only makes sense for the game:
the block registry and state tables of 26.1, vanilla data (biomes, features, tags), and behaviours that exist to
reproduce Java bit for bit. Every move preserves behaviour exactly; the worldgen suites guard it.

Status: **done** = moved in phase 2 (uncommitted in the working tree), **phase 3** = depends on files the worldgen
agents (branch `stv`, worktree `ludax-stv`) are still editing (`gen/gen_*`, `gen/feat_*`, `gen/noise_*`, `render/**`,
`assets/**`, now `games/blockland/src/app/**`), **later** = needs a design change first.

## Where the code lives now

`src/minecraft` is gone from the engine; `ludax` imports nothing of it and exports nothing Minecraft-specific.

| Was | Now |
|---|---|
| `src/minecraft/{assets,block,chunk,gen,play,render,world}` | `games/blockland/src/...` (library, `src/lib.axle` names what tests and tools may import) |
| `examples/lumen/src/mc/*` (the game program) | `games/blockland/src/app/*` + `src/main.axle`; the pixel worker `McWorker` became `McPixelWorker` (the library has an `McWorker` of its own) |
| `tests/src/{minecraft_*,gen_*,stv_*}` (13 suites, 1576 checks) | `games/blockland/tests/src` (package `blockland_tests`); the engine's 4306 checks stay in `tests/src` |
| `doc/{MINECRAFT,WORLDGEN}.md`, `tools/{mc_world,mc_gen}` | `games/blockland/doc`, `games/blockland/tools` (the scripts run from `games/blockland`, where `mccache/` lives) |
| `examples/lumen/src/light/{sky,skygrid,celestial,cloud}`, `render/{settings,camera,filter,pixels,post}`, `world/noise` | `src/render/pathlight/pathlight_*` (layer 5): sky, SH9 dome, clouds, camera, frame filter, bloom/tone/post, settings, hash noise |
| `lightvol::{LumenBody, LumenLightSample}`, `point::LumenPoint`, `shade::{LumenLit, LumenMirror, lumenShadeCore, lumenBody, lumenCaustic, lumenCloudShade}` | `pathlight_sample`, `pathlight_point`, `pathlight_shade`: the shading core reads a point, a baked-light sample and a sky, nothing of a world. The valley keeps its volumes, lamps and `lumenShade`; the game builds its samples from the streamed world. |

Still open in this move (the valley is pixel-identical, so these are cleanups, not fixes): the game's `McFrame`
(`app/mc_frame.axle`) is a near copy of the valley's `LumenFrame` (`render/frame.axle`); one generic accumulator over a
"worker" trait would replace both. The `Lumen*` names of `pathlight` are the valley's history and should become general
(`PathSky`, `PathPoint`, ...).

## Done

| Was | Now | Layer | Knobs |
|---|---|---|---|
| `nbt/mc_nbt_reader` `McNbtReader`, `MC_TAG_*` | `data/serial/nbt_reader` `NbtReader`, `NBT_TAG_*` | 2 | none needed: pull parser over a `ByteBuf` (no tree), `skipValue`, `nameIs`, typed reads. NBT is a generic tagged tree. |
| `nbt/mc_nbt_writer` | `data/serial/nbt_writer` `NbtWriter` | 2 | initial capacity; copy-raw for splicing |
| `anvil/mc_lz4` `McLz4` | `data/codec/lz4` `Lz4` | 2 | `encode(src,from,to,out,table)`: table is caller scratch (per thread); `decode` takes an output limit. Block-stream framing of lz4-java. |
| `anvil/mc_region` `McRegion`, `McIoScratch`, `MC_*` | `data/archive/region_file` `RegionFile`, `RegionScratch`, `REGION_*` | 2 | codec per write (`REGION_COMPRESSION_*`), scratch holds inflater/deflater/lz4 table. A `RegionFormat` (side and sector bits, largest in-file record, external flag, compression numbers, the two extensions) is the knob; `RegionFile::anvil()` is the Minecraft preset and `openRead`/`openWrite` use it, `openReadAs`/`openWriteAs`/`pathOfAs`/`slotOfAs`/`decompressAs` take another. |
| `block/mc_name_table` `McNameTable` | `data/serial/name_table` `NameTable` | 2 | name bytes straight from a buffer range (no string made), lock-free reads once built. Layer 2, not 1: it takes `ByteBuf` ranges, and core imports nothing of data. `count()`, `has(index)`, `nameOr`. |
| `chunk/mc_cells` `McCells` (arithmetic) | `core/collections/packed_cells` `PackedCells` | 1 | `bits` is an argument of every call; entries never span words |
| `chunk/mc_store` `McSectionStore`, `McPackScratch` | `core/collections/paletted_pool` `PalettedPool`, `PalettedScratch` | 1 | constructor `(count, cells, minBits, directBits)`: 4096-cell blocks and 64-cell biomes are two instances; `PalettedPool::withPaletteBits(.., maxPaletteBits)` for a palette wider or narrower than the default 8 bits. States are `u16`. Uniform containers take no pool space; two growable pools with compaction. |
| `block/mc_base64` | deleted; `data/model/base64` `Base64::decode` | 2 | merged (the generated state table decodes through the existing strict decoder) |

What stayed in `chunk/mc_cells.axle`: only the game's numbers (`MC_BLOCK_CELLS` 4096, `MC_BIOME_CELLS` 64, direct and
minimum bits). The widest palette form is the `maxPaletteBits` knob of the pool (default `PALETTED_PALETTE_BITS`, 8). The
generic modules have their own suites in `tests/src` (`core_packed*`, `data_name_table`, `data_random_file`, `data_nbt`,
`data_lz4`, `data_inflate_fast`, `data_zip`, `data_region`), each with a `measured:` line.

## Target layout (user's order, final)

All algorithmic mechanics go into the engine with general names and knobs; nothing Minecraft-specific in an API.
`src/minecraft` keeps only data, format and rule specifics: the 26.1 registry and tables, vanilla JSON feature data and
rules, Java-exact behaviours that exist to reproduce the game. The game itself moves to `games/blockland/`;
`examples/lumen` returns to the valley only, and the lumen light, sky and post passes move from the example into the
library (shared by the valley and blockland). The phase 3 table below is therefore not optional: it runs once the stv
state is copied into this tree, including `play/*`, `render/*`, `gen/*` and `feat_*` (generic geometry helpers of
tree, ore and disk features go to `core/procgen` next to the placement VM).

## Phase 3, after the agents finish (design)

| Candidate | Files | General name, layer | API sketch | Stays in Minecraft |
|---|---|---|---|---|
| Random sources | `gen/gen_random` (`GenXoro`, `GenXoroFactory`, `GenLegacy`, `GenSeed`), `feat_random` | `core/rng`: `Xoroshiro128pp`, `JavaLcg`, `SplitMix64`, positional factory | each has `nextI64/nextI32(bound)/nextF64`, `fork`/`forkAt(x,y,z)` as a factory struct; seed by `u64` or by hash | `WorldgenRandom` quirks (`feat_random`: LCG over a Xoroshiro source, the game's draw order) |
| Hashes | `gen/gen_hash` (MD5, SHA-256) | `data/hash` `Md5`, `Sha256` | `update(bytes)`, `digest()` | the choice of "seed from hash of identifier" |
| Gradient noise | `noise_perlin` (improved noise, octave sum, paired normal noise), `noise_blended` | `core/math/noise` (or `core/procgen`): `GradientNoise3`, `OctaveNoise(amplitudes, firstOctave)`, `PairedNoise` | permutation built from any rng; octave list as data | `BlendedNoise` (vanilla terrain shape); exact seeding order |
| Simplex | `feat_simplex` (new, agents) | same module | | |
| Density-function graph | `gen_graph`, `gen_compile`, `gen_eval` | `core/procgen` `FieldGraph` (flat typed nodes), `FieldEval` (per-thread caches: per-cell, per-column, interpolation grid) | node set is an enum of generic ops (add, mul, clamp, spline, blend, noise ref, cache markers); compiler input is a neutral node list, the JSON compile stays a Minecraft front end | JSON format of noise settings, router roles (continents, erosion, ...) |
| Surface rule VM | `gen_surface`, `gen_surface_run` | `core/procgen` `RuleProgram` (rule tree to flat program, conditions over column quantities) | quantities (stone depth, water height) supplied by a generic struct | the overworld rules, biome and block names |
| Climate lookup | `climate_tree`, `biome_source` | `core/collections` `NearestBoxTree` (R-tree of N-d boxes, nearest by squared distance plus offset penalty) | dimension count and parameter scaling are constructor arguments | the 6 climate parameters, biome table |
| Aquifers / carvers | `gen_aquifer`, `gen_carve` | only the jittered-grid cell hashing is generic (`procgen/cell_grid`); the rest is vanilla behaviour | | aquifer and carver logic |
| Decoration framework | `feat_window`, `feat_cache`, `feat_nodes`, `feat_run`, `feat_sample`, `feat_book` | `core/procgen` `PlacementProgram` (node tables: providers, predicates, modifiers), `RegionWindow` (3x3 chunk window with ring cache) | window radius and element type are parameters; node opcodes generic | the feature implementations (`feat_tree`, `feat_ore`, ...) and the vanilla JSON compiler |
| JSON with exact doubles | `gen/gen_json` | merge into `data/json/json_parse` as an option `exactDoubles` | `JsonDoc` already exists; the exact reader must parse the same `double` as Java | none |
| Number lists | `gen_lists` (`GenInts`, `GenFloats`) | `core/collections` as `Vec<i32>`/`Vec<f64>` if `Vec` fits; otherwise `IntList`/`FloatList` | | |
| File loading | `gen_files` | `data/files` (already has file readers) | | |
| Ray walker over bricks | `render/render_trace` (section, brick, cell Amanatides-Woo), `render_view` summaries | `voxel/light/dda` `VoxelDda` already exists: extend it with a hierarchical walker over a generic occupancy | brick sizes as constructor knobs | block-model element hit, atlas reads |
| Light flood | `render/render_light` | reuse `voxel/light/flood` with a block-light table; add a sky channel | | the opacity/emission tables |
| Block model element ray | `render_model`, `assets/mc_model_files` | `render` `BoxElement` (rotated box with six faces) | | model JSON resolution |
| Atlas with mips | `render_atlas`, `assets/mc_assets` | `data/image` `TextureAtlas` (tiles, mip chain, animated strips) | | the import |
| Binary blob container | `assets/mc_blob` | `data/serial` `ArrayBlob` (magic + typed arrays) | | the Minecraft cache schema |

## Needs a design change first (later)

| Candidate | Files | Why it is not a move | Target and API |
|---|---|---|---|
| Streaming chunk ring | `world/mc_world` | owns `McChunk`, `McRegistry` and the pipeline | `world/` ring: slot = coord modulo side, loaded/unloaded events, `viewDistance`, RAM budget, per-frame batch; generic over a chunk type. `voxel/world/streamer` has a similar ring: unify there first. |
| Async slot pipeline | `world/mc_pipeline` | decode/encode/gen are Minecraft calls | `core/jobs` `SlotPipeline`: slot state machine (empty/loading/ready/saving), two `BoundedChannel`s of `slot*4+op`, N workers, per-worker scratch; the four steps become a stage object |
| Hot cache | `world/mc_hot_cache` | keyed by (cx,sy,cz,version) on `u16[]`; `render_view` (agents) uses it | `core/collections` `LruSlots`: bounded pool of fixed-size arrays, pin/release, 4-int key; small and generic |
| Player controller | `play/play_player`, `play_target`, `play_edit`, `play_shapes`, `play_hotbar` | constants are the game's, shapes come from the registry and `render_table` (agents) | `sim/gameplay` `BoxController` (AABB swept against a box provider, tick-based; params: size, eye, gravity, drag, step height, fluid factors), `VoxelRay` (Amanatides-Woo f64), `Hotbar` (slots, selected, scroll, pick). The vanilla values become a preset in `minecraft/play`. |
| Day clock | in the lumen example | | `sim/gameplay` `DayClock` |
| Chunk-column codec | `chunk/mc_chunk_nbt`, `mc_chunk` | schema of the game | stays; now a thin client of `NbtReader`, `PalettedPool`, `RegionFile` |

## Risks

- Axle quirks: top-level names are package-global (hence the `NBT_`, `REGION_`, `PALETTED_`, `NAME_TABLE_` prefixes), no
  `T[N]`, no `string` elements in our generic containers, a trait needs one implementor in the library.
- Exactness: noise, random and the compilers must keep draw order and f64 operation order; a move must not change a
  single expression. Run the full suite after each move.
- Hot paths use `f32`, positions `f64`; keep determinism (no hash-ordered iteration).
- The agents' branch edits the phase-3 files: move after they merge, `git mv` first and import edits after.
