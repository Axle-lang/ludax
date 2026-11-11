# The ludax handbook

How the engine's heavy mechanisms work: the mathematics, the algorithms, what each costs, and how each came to be
the way it is. `doc/ARCHITECTURE.md` says where code goes and `doc/STYLE.md` how it is written; this says **why a
mechanism computes what it computes**.

Every chapter follows the same plan, so a reader knows where to look:

1. **Contract** — what goes in, what comes out, what is guaranteed.
2. **Mathematics** — the formulas, derived step by step.
3. **Algorithm** — the steps, with the data they touch.
4. **Complexity** — time and memory, in symbols and in measured nanoseconds.
5. **Observations** — what was measured, what surprised, what failed.
6. **History** — what the mechanism was before, and why it changed.
7. **Source** — the files and functions.

## Map

| # | Folder | Chapter | What it answers |
|---|---|---|---|
| 1 | `concepts/` | [1.1 Smooth and sharp signals](concepts/01-smooth-and-sharp.md) | What may be computed sparsely, and what may not |
| 1 | `concepts/` | [1.2 Determinism](concepts/02-determinism.md) | Why the same input gives the same bits, and what breaks that |
| 1 | `concepts/` | [1.3 The cost model](concepts/03-cost-model.md) | Nanoseconds a pixel, budgets, how to measure and how not to |
| 1 | `concepts/` | [1.4 The complexity ledger](concepts/04-complexity-ledger.md) | Every way each mechanism has been done: its order, its measured cost, why it was kept or dropped |
| 2 | `standards/` | [2.1 Hot-loop rules](standards/01-hot-loop-rules.md) | Twelve rules for code that runs for every pixel, each with its measurement |
| 2 | `standards/` | [2.2 Shared buffers](standards/02-shared-buffers.md) | The frame's buffers and grids: the one bus the stages talk through |
| 2 | `standards/` | [2.3 Types and memory](standards/03-types-and-memory.md) | Which width for which datum, and what each buffer weighs |
| 3 | `render/` | [3.1 The frame](render/01-frame.md) | The stages of a picture, in order |
| 3 | `render/` | [3.2 Visibility](render/02-visibility.md) | The voxel ray walk: DDA, the four skips, the gap field |
| 3 | `render/` | [3.3 The skyline](render/03-skyline.md) | Which rays are sky without being traced |
| 3 | `render/` | [3.4 Sparse light](render/04-sparse-light.md) | Sampling light every few pixels and interpolating it |
| 3 | `render/` | [3.5 Shading](render/05-shading.md) | The BRDF, the dome, the baked terms |
| 3 | `render/` | [3.6 The sky](render/06-sky.md) | Radiance grid, clouds, the veil and the bodies, quick trigonometry |
| 3 | `render/` | [3.7 Accumulation](render/07-accumulation.md) | Jitter, the running mean, when history is refused |
| 3 | `render/` | [3.8 Display](render/08-display.md) | Exposure, bloom, tone, sRGB, dither |
| 3 | `render/` | [3.9 Baked shadows](render/09-baked-shadows.md) | The sun's share a cell at a time, generations, the glide, foliage |
| 3 | `render/` | [3.10 Water](render/10-water.md) | The surface from above and below, the rippled mirror, the walk through water, fog apart from light |
| 3 | `render/` | [3.11 The face cache](render/11-face-cache.md) | Diffuse light kept in the world: nine points a face, epochs, a light that drifts, publishing between stages |
| 4 | `engine/` | [4.1 The job pool](engine/01-job-pool.md) | Chunks, scaling, why one worker a core |
| 5 | `history/` | [5.1 The November 2026 optimisation log](history/2026-11-optimisation.md) | Every step, its measurement, the experiments that failed |

Chapters 3.x describe the path-lit voxel picture: the engine's `src/render/pathlight` (sky, shading, display) and the
frame of `games/blockland` that drives it. `examples/rendering/lumen` uses the same sky, shading and display.

## Notation

| Symbol | Meaning |
|---|---|
| `W`, `H`, `P = W H` | the picture's width, height and pixel count (1280, 720, 921 600 in every measurement here) |
| `s` | the stride of the light samples: 4 while the camera moves, 2 when it is still |
| `k` | cells a ray crosses before it hits |
| `ns/px` | nanoseconds a pixel on **one** thread of the reference machine (Ryzen 9 9900X, 12 cores, 24 threads) |
| `O(...)` | growth in the named quantity; constants are given in `ns` beside it |

## Related documents

- `games/blockland/doc/RENDERER.md` — the one-page summary of chapters 3.x, with the commands.
- `AXLE_COMPILER_FINDINGS.md` — what the compiler does to this code (F1 to F10), with repros.
- `doc/LIGHTING.md`, `doc/LIGHTING_MATH.md` — the lighting library (`src/render/light`) on which chapter 3.5 rests.
- `doc/RENDERING.md` — the rasterising and command-stream side of the engine, which this handbook does not cover.

## Keeping it true

A chapter is changed in the same change as the code it describes. A number is replaced by a new measurement, never
adjusted by hand; the old number moves to the chapter's History table with the date.
