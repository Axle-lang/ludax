# `src/voxel`

Layer 7. Content modules; independent of each other.

29 files in 2 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: data and voxel](../handbook/problems/data-voxel.md).

## `src/voxel/light`

The voxel light engine: the grid, the block table, the falloff curve, flood fills, sky light, rays, bakes, the surface shell and samples.

Read more: [visibility](../handbook/render/02-visibility.md); [baked shadows](../handbook/render/09-baked-shadows.md).

| File | What it does |
|---|---|
| `bake.axle` | the ray bakes: sun visibility, sky access and bounce tint, as jobs. |
| `block.axle` | what the light engine needs to know about a block, and nothing else. |
| `curve.axle` | how block light fades with distance: the calibrated inverse-square table. |
| `dda.axle` | walking a ray through the voxel cells it crosses, in order (Amanatides & Woo). |
| `flood.axle` | block light (red, green, blue at 8 bits and beyond) and sky light, edited incrementally. |
| `grid.axle` | a minimal chunked voxel grid: 16x16x16 chunks of block ids, found by chunk coordinate. |
| `pattern.axle` | the fixed fans of rays the bakes cast: a disc for the sun, a hemisphere for the sky. |
| `plane.axle` | one 32-bit value per voxel cell, laid out like the grid (slot * 4096 + local). |
| `queue.axle` | the work list of a flood: a FIFO of 64-bit entries that grows when it fills. |
| `sample.axle` | what a reader of the light gets back: one record, and the ambient-occlusion neighbour rule. |
| `surface.axle` | where the ray bakes keep their answers: only in the shell of cells next to blocks that stop light. |
| `trace.axle` | one ray through the grid: how much light survives it, and what colour it picked up. |
| `world.axle` | the light engine of one voxel grid, and the read seam over it. |

## `src/voxel/world`

The voxel world: palette-compressed chunks, the store, edits and their journal, region persistence, the generator, the streamer, the mesher and the light bridge.

| File | What it does |
|---|---|
| `blocks.axle` | the block ids of the streaming voxel world and what each one means to a mesher and to light. |
| `bridge.axle` | the loaded window of the world, lit by the voxel light library. |
| `chunk.axle` | 16 x 16 x 16 blocks stored as a palette and packed indices. |
| `codec.axle` | one chunk as bytes, and back. |
| `interact.axle` | pointing at a block, breaking it, placing one against it. |
| `journal.axle` | the log of block changes that the mesher and the light bridge consume. |
| `loader.axle` | generating a batch of chunks, on the job pool or on the calling thread. |
| `mesh.axle` | the triangles of one chunk as plain arrays. |
| `mesher.axle` | turns the blocks of one chunk into a `VoxMesh`, looking across the borders into its neighbours. |
| `noise.axle` | integer hashes and smooth value noise for the terrain generator. |
| `persist.axle` | saving a world's edits to a file and reading them back. |
| `region.axle` | many chunks in one file: a table of contents and one deflated payload per chunk. |
| `store.axle` | the chunks that are in memory, found by integer chunk coordinate. |
| `streamer.axle` | which chunks to hold, given where the player is. |
| `terrain.axle` | the world generator: a seeded terrain that is a pure function of the cell. |
| `world.axle` | an infinite voxel world: the generator, a sparse layer of edits, and the chunks in memory. |
