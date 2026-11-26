# Names

The vocabulary of Ludax: one word per concept, in every file. Each area appends its own section.

## Vocabulary

| Concept | Word | Not |
|---|---|---|
| number of things | `count` (`len` only on the std-like containers `Vec`, `Map`, `Heap`, `Ring`, `ByteBuf`) | `length`, `size`, `n` |
| append / remove / empty | `add`, `remove`, `clear` | `pushX` on a domain class, `clearAll` |
| may fail / must exist / fallback | `find` / `get` / `getOr` | |
| comparison of two values | `same(other)` | `sameAs`, `equals` |
| failure text | `error()` | `lastError()` |
| duration of something | `duration()` | `seconds()` on a clip |

## src/core, src/data, src/world, src/runtime

- A field never repeats its owner and is never an abbreviation: `Mesh.positions/normals/uvs/tangents/indices/joints/weights`,
  `ModelAsset.materials/nodes/skins/clips/textures`, `ModelClip.channels`.
- A parameter that names an index of a kind is named for the kind (`action`, `slot`, `dense`, `index`), never `a`, `s`, `d`.
- A JSON field reader with a fallback ends in `Or` (`intOr`, `numberOr`, `stringOr`), on `JsonDoc` and `GltfFile` alike.
- The number of children of a JSON value is `childCount`, not `len`.
- A glTF accessor answers `componentCount`, `floatAt(element, component)`, `intAt(element, component)`.
- Free hash functions carry the `hash` prefix: `hashFnv1a64`, `hashFnv1a64Bytes`, `hashMix`, `hashCombine`.
- Private types carry their owner's name in full (`SchedulerEdge`, `SettingsLine`), not an abbreviation.
- A byte count of a file or a buffer is `length()` (`RandomFile.length`, `ByteBuf.len`), the one place `length` reads
  better than `count`; a number of items is `count()` (`NameTable.count`, `ZipReader.count`). `has(index)` asks before
  `name(index)` or `get(index)` aborts.

## src/sim (kinetic, fluid, animation, audio, navigation)

- A file is named for the type it holds, snake_case, one job per file: `physics_world`, `physics_settings`,
  `physics_query`, `physics_measure`, `broad_phase`, `kinetic_geometry`, `kinetic_sort`; `audio_engine`,
  `audio_voice`, `audio_spatial`, `audio_math`, `music_track`; `vec3_track`, `track_math`, `pose`, `bone_mask`,
  `pose_blend`, `event_buffer`, `animation_clip`; `grid_path`, `grid_line`, `grid_pathfinder`, `nav_path`,
  `funnel`. No abbreviation in a file or type name (`KGeom` became `KineticGeometry`, `AMATH_*` `AUDIO_MATH_*`).
- Constructors of a plain-data description are `static fn`s of its struct, not prefixed free functions:
  `BodyDesc::dynamic / fixed / kinematic` (`static` is a keyword), `FluidSource::finite / infinite`, `FluidSink::at`.
- Per-body arrays of `BodyStore` are named for what they hold, without an abbreviation: `position`, `rotation`,
  `linearVelocity`, `angularVelocity`, `prevLinearVelocity`, `linearDamping`, `userData` (`inv*` stays: it is the
  physics symbol for an inverse).
- Fluid state: a grid is `width` x `depth` columns; a frontier lies between a `firstColumn` and a `secondColumn`;
  per-frontier arrays are `velocity`, `viscousDelta`; per-column ones `outflow`, `inflow`, `outScale`, `inScale`.
  Lists of ids say what they list: `awakeColumns`, `touchedColumns`, `liveFrontiers`.
- Interpolation of keys is `TrackInterpolation` (animation) and `AudioInterpolation` (resampling), never `Interp`.
- A parameter named for its type's role, not a letter: `bodies : BodyStore`, `settings`, `desc`, `joint`, `point`,
  `listener`, `emitter`, `request : AudioPlay`, `ground`, `source`, `sink`, `transition`; goal arrays of a flow
  field are `goalXs / goalYs / goalCount`.
- Identifiers use the American spelling the public API already has (`center`: `Aabb::fromCenterHalfSize`,
  `NavMesh::centerX`); prose in comments may be either.

## examples/water/fluidview/src/terrain (the water demos' landscape)

- The landscape is a `HydroTerrain` made from `TerrainParams` (`HydroParams` is the fluid engine's own type) by
  `HydroTerrain::generate(seed, params, workers)`; its files are `hydro_*` for what it holds and answers (`hydro_terrain`,
  `hydro_parts`, `hydro_check`) and `terrain_*` for what makes it (`terrain_plan` the layout, `terrain_noise`,
  `terrain_relief`, `terrain_erosion`, `terrain_meander`, `terrain_valley`, `terrain_lake`, `terrain_hydrology`,
  `terrain_materials`, `terrain_generate` the pass runner). One unit is a metre, x is east, z is south, the river flows to +z.
- Heights are `bed` (`f32`, one per cell centre, `bed[j * width + i]`); per-cell codes are `material` (`HYDRO_ROCK`,
  `HYDRO_SCREE`, `HYDRO_GRASS`, `HYDRO_FOREST`, `HYDRO_GRAVEL`, `HYDRO_MUD`), `wetness` and `lakeMask`.
- The water's records are `river` (`RiverPoint`: `width`, `depth` below the bank, `bankHeight`, `bedHeight`, `curvature`),
  `lake` (`level` is the spill level, `spill` the lip), `escarpment` (`fall`, `lip`, `faceRun`), `pool`, `inflows`,
  `outflow`, `puddles`. A list is a `T[]` and its `…Count`; `fall` is the cliff's height because `drop` is a keyword.
- A pass is a `static fn` of a class named for it (`TerrainRelief::rows`, `TerrainErosion::incise`); a row pass takes
  `begin` and `end` rows and writes only those, so any number of workers gives the same bytes.

## Containers and formats extracted from the Minecraft module (now `games/blockland`)

- `PackedCells` (entries of `bits` width in `u64` words, none spanning two), `PalettedPool` (many paletted containers over
  two pools; `PalettedScratch` is the per-thread buffer set), `NameTable` (immutable-after-build, thread-safe name to
  index), `NbtReader` / `NbtWriter` with `NBT_TAG_*`, `Lz4` (the lz4-java block-stream framing), `RegionFile` /
  `RegionScratch` with `REGION_*` (sector-addressed slot files, `RegionFormat::anvil()` is the `.mca` layout). A
  container's width knobs are constructor arguments (`cells`, `minBits`, `directBits`, `maxPaletteBits`), never constants
  of a game. `NameTable` lives in `data/serial` (it takes `ByteBuf` ranges), `FastInflater` fields are spelled out
  (`input`, `output`, `damaged`, `literalFast` ...) and every constant carries its owner's name (`FAST_INFLATER_*`,
  `RANDOM_FILE_*`, `PACKED_CELLS_*`, `PALETTED_*`, `LZ4_*`, `NAME_TABLE_*`, `ZIP_*`).
