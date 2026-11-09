# voxelwalk

A streaming voxel world, flown over with no window and no dependency but ludax.

A seeded generator makes terrain, rivers, seas, biomes, caves and trees on demand. A streamer keeps only the chunks
around the camera in memory. The camera flies about 5,000 blocks; the program prints the chunks loaded and the bytes
they take. Then it edits the world with ray casts, saves the edits, flies away until the edited chunks have left
memory, flies back, and loads the save into a second world to check the two are the same block for block.

```sh
cd examples/engine/voxelwalk
axle build -O 3
./target/voxelwalk.exe
```

It writes three pictures, drawn from the chunk store itself (so they show exactly what is in memory; black is "not
loaded"):

- `voxelwalk.png`: the start, seen from above. The loaded disc of 8 chunks around the camera, chunk borders marked.
- `voxelwalk_far.png`: the same view after the flight: a different world (sea, coast, a snowy island, forest).
- `voxelwalk_side.png`: a vertical section through the start, with a cavern under the forest.

The exit status is the number of checks that failed. On the reference machine a run takes under a second.

## What it shows

| Idea | Where |
|---|---|
| Chunks of 16 x 16 x 16 blocks stored as a palette and 0, 4, 8 or 16 bit indices; a uniform chunk (open sky) has no array | `src/voxel/world/chunk.axle` |
| Terrain is a pure function of the cell, so chunks come out the same in any order and on any thread | `terrain.axle`, `loader.axle` |
| Trees cross chunk borders by being re-evaluated in every chunk they touch | `terrain.axle` |
| The streamer loads nearest first, unloads past a hysteresis radius, and obeys per-update budgets | `streamer.axle` |
| A world is generator + edits; only edited chunks are saved, as deflated chunks behind a checksummed table of contents | `world.axle`, `region.axle`, `persist.axle` |
| Greedy meshing with ambient occlusion, correct across chunk borders | `mesher.axle` |
| The loaded window feeds the voxel light library; edits arrive through a journal | `bridge.axle`, `journal.axle` |
| Ray cast, place and break | `interact.axle` |

This example uses the streaming, edits, persistence and ray cast. The mesher and the light bridge are tested in
`tests/src/voxworld_mesh.axle` and `voxworld_light.axle`; the example draws maps rather than triangles.

## How this answers the dense-memory limit of lumen

`lumen` lights a world held in a `VoxelGrid`: one `i32` per cell for the blocks, and the light planes, surface shell
and bake tables on top, roughly 70 bytes per cell. That is why its world is a few hundred cells across: a box of
5,000 x 256 x 128 cells would need about 11 GiB (the program prints this arithmetic). lumen is unchanged.

The streaming world attacks the two parts of that cost separately:

1. **Storage.** A chunk keeps a palette instead of a number per cell. Open sky is one palette entry and no array; most
   terrain chunks have fewer than 16 kinds of block and take 2 KiB of indices. The test walk (10,000 blocks, radius 2)
   holds its 150 chunks in about 220 KB, a quarter or less of the dense cost of one `i32` per cell, and the flight above
   holds about 2,000 chunks in 2-3 MB (roughly 1.3 KB a chunk against 16 KB dense). Memory depends on the view radius,
   not on how far the camera has gone; the program checks the peak against a bound computed from the radius alone.
2. **Light.** The light grid is not kept for the whole world. `VoxLightBridge` builds a *window* of a few chunks around
   the camera and floods only that. Edits go to the window through the journal, one at a time, using the library's
   incremental update, which a test shows equal to a rebuild.

## Limits, honestly

- **The light window is rebuilt when it slides.** `VoxelGrid` never frees or moves a chunk, so moving the window
  copies and floods it again; the cost grows with the window's volume (not measured here), and it is not an incremental
  slide. `recentre` with a slack keeps it from happening on every step. Light is not carried across a window's edge: a
  lamp just outside lights nothing inside.
- **The window is partly dense.** Inside the window the light module still uses its dense grid at about 70 bytes per
  cell, so the window radius is limited the same way lumen's world is (the tests use a radius of 1 chunk, a 48 x 48 x 128 cell box).
- **The edit layer keeps whole chunks.** An edited chunk is stored whole (compact palette form, then deflated in a
  region file), not as a list of changed cells. A chunk edited back to what the generator makes stays in the layer.
  One saved region file holds any number of chunks; there is no splitting into several files by area.
- **The world is one chunk column tall** (128 blocks). The generator is deterministic only for a given version of its
  own constants: change a noise constant and old saves no longer match the terrain they were made on, because a save
  holds edits, not terrain.
- **Meshes are not cached or uploaded.** The mesher produces plain arrays per chunk; there is no renderer, texture
  atlas or material system here, and no frustum or distance culling.
- **No game on top.** There is no block registry, inventory, player physics or water flow. Block ids and their light
  table live in `blocks.axle` and are meant to be replaced by a game's own.
- **Generation is fast, but not free.** The run printed about 90,000 to 120,000 chunks a second on a 24-thread machine (many of them cheap sky
  or rock); the serial path was not timed. The wall-clock figure the program prints is for
  information only: nothing in the simulation reads a clock.
