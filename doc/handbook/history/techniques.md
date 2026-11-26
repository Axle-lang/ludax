# 5.1 What was tried, by technique

[Handbook](../README.md) · previous: [4.1 The job pool](../engine/01-job-pool.md)

Every procedure the renderer has used or tried, grouped by the problem it was meant to solve: what the procedure is, the
Axle toolchain it was built with, what it cost when measured, and whether it stayed. Read the group of your problem
before trying a procedure again; the verdict column says why a dropped one was dropped. Chapters 3.x derive the
procedures that stayed. [1.4 The complexity ledger](../concepts/04-complexity-ledger.md) lists the same procedures of the
path-lit voxel picture by their order of growth.

**Conventions.** Times are nanoseconds for one item on one thread, or milliseconds for a frame, at 1280 x 720 on a
Ryzen 9 9900X (12 cores, 24 threads) unless a size or a worker count is given. "Bit-identical" means the golden
fingerprints did not move. A dash means the measurement was not taken.

**Toolchain.** Rows carry the Axle that was current on the day of the work, taken from the repository's commit history
and the compiler findings, not from a per-row record:

| Axle | Days of work |
|---|---|
| 0.19.0-dev | 9 November 2026 |
| 0.20 | 10 and 11 November |
| 0.21-dev | 12 November |
| 0.22 | 23 November |
| 0.23.0 | 24 November on |

`n/r` means the version was not recorded (the procedure predates the log). A procedure measured on 0.20 may cost differently today. The compiler behaviours that changed a result are in
`AXLE_COMPILER_FINDINGS.md` (F-numbers below).

## 1. Finding what a ray hits

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Walk cell by cell (Amanatides and Woo) | n/r | 350 ns toward the sky, 2 to 3 ns a cell | base case | exact, simple |
| Leave empty sections in one move | n/r | 95 ns toward the sky | kept | most air is whole sections |
| No lid above a column's last section | n/r | O(1) for a rising ray | kept | |
| Brick mask: groups of 4 x 4 x 4 empty cells | n/r | 98 to 94 ns | replaced | the gap field beats it |
| Gap field: the largest empty cube centred on a cell, radius up to 4 | 0.20 | 94 ns; moves a ray 0 to 3 times | kept | within two blocks of a surface no such cube exists, so it only pays in open air |
| Branch-free choice of the axis | 0.20, again 0.22 | 94 to 118 ns; 4.88 to 5.68 ns a step | dropped, twice | a predicted branch beats a longer dependency chain |
| `slotOf` without division, tints from a table, last-biome cache | 0.20 | 94 to 86 ns | kept | hidden costs, not the algorithm |
| Skyline: a ray above the loaded world's horizon is not traced | 0.20 | O(1); sky pixels free | kept | |
| Skyline test written as sines | 0.20 | 86 to 73 ns | kept | |
| Remember the section a ray starts in | 0.20 | not measurable | kept, free | `resolve` was not the fixed cost of a ray |
| Skip the ray between four sky samples | 0.20 | fast | dropped | thin things against the sky vanished: a shortcut must be exact |
| Column tops (the highest solid cell of a column) | 0.22 | 5.19 to 4.91 ns a step | kept | bit-identical, inside the noise |
| Column ceiling jumps, first version: the entered cell's test skipped | 0.23.0 | 30 % of pixels wrong, worst error 203 | bug, fixed | |
| Column ceiling jumps, fixed | 0.23.0 | walk 241 to 186 ns, trace -14 %; 0.19 % of pixels differ | kept | the differing pixels are the rounding of the hit time |
| The ceiling kept in a local, re-read at brick changes | 0.23.0 | no change | dropped | |
| `SceneRay` / `SceneJump` for readability | 0.23.0 | 186 to 220 ns; 188 ns with `canJump` | kept with `canJump` | readability had a price until the branch was hoisted |
| Unchecked loads in the walk | 0.22 | 4.88 to 4.90 ns | dropped | unsafe for nothing |
| Wide columns of 32 x 32 over the narrow ones | 0.23.0 | walk 188 to 96 ns; water mirror 29 to 12.5 steps; trace 143 to 112 ms; 75 fps on 23 threads | kept | 0.189 % of pixels differ from the inherited picture |
| `--target-cpu native` | 0.19.0-dev | under 2 % (F1 measured up to 18 % elsewhere) | not the lever here | |

Where it stands: a ray crosses 24 to 42 cells, takes 0 to 3 box moves, reads 2.5 to 2.9 texels and tests 0.5 to 1.3
models. Its fixed overhead (an 18-field hit returned by value, the first `resolve`, the caller's copy) is 26 ns of 73.
Derivation: [3.2](../render/02-visibility.md), [3.13](../render/13-dusk.md) §3.2 and §3.3.

## 2. Light of a pixel

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Shade every pixel with one random sample, average over frames | n/r | 350 ns a pixel | dropped | grain, and a history that follows the camera |
| Shade every `s`-th pixel, copy it to its block | n/r | -- | dropped | the "360p" look: texture and edges become block-sized |
| Texture per pixel, light shared by the block | 0.20 | -- | kept as a step | sharp texels, light in squares |
| Samples and fill as two stages; light interpolated among same-plane samples; no reprojection while moving | 0.20 | frame 345 to 210 ms (trace 134, temporal 4) | kept | the largest single gain: doing less |
| Every pixel off its sample's plane shades itself | 0.20 | median 80 ms | dropped | foliage makes that most pixels |
| Share light by kinship, blended over the kin samples, not taken from the heaviest | 0.20 | -- | kept | the choice of the heaviest flipped with every camera move: the sizzle of foliage |
| Share among the samples of one face of one block | 0.20 | 8.8 % to 8.4 % of bytes flickering at the same cost | replaced | every leaf at one height was one plane, so it took another leaf's light |
| Share among the samples of the plane within a block, else light the face where seen | 0.20 | -- | kept | the face rule held the light at every border of a floor and lit hidden faces at their centre |
| Each pixel reads its own sun share from the bake (one trilinear read a pixel) | 0.20 | +40 ms a frame, 0.5 % of bytes changed | dropped | the shared light was already right; the flicker was the bake hopping in time |
| Diffuse light kept on the face in the world, nine points a face, read by every pixel | 0.20 | ground 32 to 24 ms, trees 38 to 24 ms on 12 workers; nothing relit while the camera alone moves | kept | cost follows the changes of the world, O(F E), not the frames drawn |
| Faces take turns to follow a drifting light (`faceStagger`) | 0.20 | p99 of a walk under a running clock 55-83 ms to 35-46 | kept | |
| A picture at rest redrawn every few ticks | 0.19.0-dev | a 125 ms frame every 4 frames | replaced | |
| A picture at rest relit from the face cache, redrawn once in 24 relights | 0.20 | a full frame 8 times a second (80 % of the pool) to 1.7 ms a frame on average | kept | |
| Sparse light moved into the engine (`LumenSparse`) | 0.20 | bit-identical; 26 checks | kept | |
| Lamp bucket scratch indexed y and z the wrong way round | 0.23.0 | lamps near the pier dropped silently | bug, fixed | a selftest compares it with a walk over the three axes |

Derivation: [3.4](../render/04-sparse-light.md), [3.11](../render/11-face-cache.md), [3.12](../render/12-lux-layers.md).

## 3. Sky, clouds and light shafts

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Recompute the sky on the frame's thread when the clock moves | 0.19.0-dev | 365 ms every 0.85 s: a freeze | replaced | |
| Sky baked on a background thread (`SkyBaker`, `glide`) | 0.19.0-dev | p99 392 to 35 ms | kept | |
| Thread of the sky baker waited for on exit | 0.20 | -- | bug, fixed | a crash at the end of every run with a moving clock |
| Sky keeps no history | 0.20 | -- | kept | stars stay points; reprojected sky pixels streaked |
| Sky veil shared, bodies per pixel; every sky pixel traced or cleared | 0.20 | -- | kept | twigs kept |
| Exact `atan2` replaced by a polynomial in the lookup | 0.20 | 68 to 58 ns | dropped | the lookup was the cost, not the angle |
| `SkyGrid.look` rewritten in scalars | 0.20 | no change | dropped | 24 bounds-checked loads are its price |
| Cloud deck sampled at a point | 0.20 | consecutive frames of a slow turn 0.65 levels apart | replaced | the horizon sizzled |
| Cloud deck averaged over the sample's footprint (`lnFbm2Soft`) | 0.20 | 0.65 to 0.19 levels | kept | |
| Thin the clouds overhead to cure a grey sky | 0.20 | no change | dropped | the grey was the shafts: switch the suspect off (`--fog 0`) before changing it |
| Shafts: a uniform veil over the sky | n/r | -- | replaced | grey sky |
| Shafts gathered round the sun, faded under a high sun | 0.20 | -- | kept | blue sky |
| Shafts marched at half resolution | 0.20 | 9.3 to 2.5 ms | replaced | |
| Shafts marched once per 64 pixels over the averaged sky, no jitter, no history | 0.20 | 27 to 5.5 ms; at most 2 levels of difference on 3.4 % of bytes | kept | |
| Shafts as a march per 8 x 8 block, no random number, no screen history | 0.23.0 | 2.6 to 0.7 ms on 23 threads | kept | the glow that trailed across the screen while walking is gone |
| Shaft "eases" answered 1 | 0.22 | shafts + resolve 27.3 to 21.9 ms | kept | bit-identical |
| Sky in a rippled mirror: the sun as a lobe, far clouds faded | 0.20 | the sea from above 50 to 36 ms on 12 workers | kept | the dotted edges of reflections are gone |

Derivation: [3.3](../render/03-skyline.md), [3.6](../render/06-sky.md), [3.1](../render/01-frame.md) §5.

## 4. Display: exposure, bloom, tone

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| The display as first written | 0.20 | about 100 ms | replaced | |
| Meter 1 in 16, dither tile, bloom folded, words written by compose | 0.20 | display 67 to 53 ms | kept | |
| `composeWords` | 0.20 | 53 to 44 ms | kept | |
| One bloom level walked along the row, integer code table, dither | 0.20 | compose 39 to 17 ms; frame 147 to 124 ms | kept | |
| Bloom and meter from the computed picture while upscaled | 0.23.0 | 24 to 20 ms a frame at 1080p | kept while moving | |
| Bloom of a still view from the shown picture | 0.23.0 | still silhouettes stop blinking (steady 0.48 to 0.06) | kept | |

Derivation: [3.8](../render/08-display.md).

## 5. Water

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Unresolved waves drawn at random, averaged over frames | 0.23.0 | -- | withdrawn | grain over far water while it moves |
| Unresolved waves as roughness: reflection blended toward the prefiltered sky | 0.23.0 | clean in one pass | replaced | three bands, a mirror-flat distance, floating shores |
| Footprint as the geometric mean, two-octave fade, reflection floor relative to the flat reflection | 0.23.0 | trace +7 % | kept | shores attached to their reflections, no bands |
| Cascade fade by the long axis of the footprint, one sample | 0.23.0 | -- | dropped | flattened distant water into a mirror |
| Cascade fade by the geometric mean, one sample | 0.23.0 | -- | dropped | long waves along the view aliased into a moire that slid |
| Anisotropic filter, a whole number of taps (1 to 4) | 0.23.0 | about 47 ns a tap | replaced | the count stepped where the footprint's axis ratio crossed an integer: a ring of changing ripples round the camera (fade step 0.297 m) |
| Anisotropic filter, four taps spread over what the short axis does not cover, the variance the average removes kept as unresolved | 0.23.0 | step of the spread 0.0005 m, of the slope 0.00013 over a sweep of the ratio 1 to 5 | kept | nothing in the filter is a whole number; not yet confirmed by eye in the window |
| Schlick's Fresnel | 0.23.0 | 0.769 at 3 degrees above the surface | replaced | 6 to 10 % too high at grazing angles |
| Exact unpolarised Fresnel for the index that gives F0 | 0.23.0 | 0.722 at 3 degrees; equations checked by a suite | kept | |
| A reflection lifted above the plane keeps the sky's colour | 0.23.0 | -- | replaced | a fixed bright patch under moving waves |
| The share of the reflection that would strike the next crest shows the water (`luxReflectOpen`, quadratic) | 0.23.0 | water-level view's lower half mean 58.41 to 55.17 | kept | |
| A clearer medium for the view from above (absorption 0.36 / 0.06 / 0.02, scattering about 4 times lower) | 0.23.0 | differences barely visible on five views | dropped | it moved the pinned underwater view for no visible gain |
| Water body: bed lit by the baked light and dimmed along the refracted sun path | 0.23.0 | beds black under 3 m | replaced | the absorption was counted twice |
| Bed lit by the refracted sun, Fresnel transmission, Beer-Lambert path, caustics | 0.23.0 | bed at 6 m 0.001 to about 0.02 | kept | |
| Under water: plain surfaces share light, the surface from below shaded from the pixel's ripple | 0.20 | 464 to 272 ms (640 x 360, level) | kept | |
| Fluid cells, cubes and sections skipped; the ray follows 64 blocks | 0.20 | 272 to 120 ms | kept | 115 iterations a ray remain |
| Three guesses at the cost under water (surface height, ray length, uniform sections) | 0.20 | none moved it | dropped | counters in the loop found it in one run |
| Fog stored apart from the light | 0.20 | grain on the sea bed gone; 120 to 97 ms | kept | |
| A picture at rest redoes its water alone, 30 times a second (`Ripple`) | 0.20 | 8.8 ms a redo on 12 workers for an all-sea picture | kept | the sea stood still when the player did |
| Clock runs whether the camera moves or not; water keeps 3 to 16 frames of history by its unresolved share | 0.23.0 | waves move with the mouse at rest | kept | |

Derivation: [3.10](../render/10-water.md), [3.14](../render/14-water-surface.md), [3.17](../render/17-media-and-interfaces.md).

## 6. Keeping a picture still: temporal accumulation and upscaling

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Reproject while moving | 0.20 | -- | dropped | history followed the camera: ghosts and streaked stars |
| Temporal v1: history 12 moving, colour clip, full jitter, radiance fallback | 0.22 | settle 20.3 to 10.4 | withdrawn | blur and lost reflections in motion |
| Temporal v2: moving behaviour restored bit for bit; still camera only | 0.22 | settle 20.3 to 13.2; bytes over 8 levels 29.5 % to 15.5 % | kept | |
| Upscale: the picture finished at the window's size by stretching the computed one | 0.23.0 | 480 x 256 shown at 1920: "480p" | replaced | |
| `LuxUpscale`, 3 x 3 gather | 0.23.0 | 24 ms a frame at 1080p | improved | |
| 2 x 2 gather, reciprocals, no copy, boxes once | 0.23.0 | 20 ms | kept | |
| Full output size computed when still | 0.23.0 | 8 frames a second at 1080p | withdrawn | frozen |
| Computed picture with no history of its own while upscaled; caps 16 moving, 12 water | 0.23.0 | sharper, but a still view shimmered (steady 0.79 against 0.52) | withdrawn | |
| Still sample keeps its history whatever its distance | 0.23.0 | steady 0.48 to 0.06 | kept | a depth test on still samples threw the history away every frame |
| Offset cycle 16, one memory for all pixels | 0.23.0 | still shimmer 0.65 | replaced | an exponential mean of a T-periodic signal ripples by about 1/(2 sin(pi/T)) / cap |
| Cycle 8, three memories by what the pixel's rays met, a history on the edge read not refused | 0.23.0 | still shimmer 0.65 to 0.20, settle 24 to 5, edge ripple 0.130 to 0.001 | kept | |
| Restless memory 32 while moving | 0.23.0 | -- | replaced | water reflections slid when moving |
| Restless memory 4 while moving, 32 when still | 0.23.0 | `--flicker` with a still camera 0.20 to 0.45 | kept, a trade | a short memory moving costs a noisier still start |
| Governor floor 0.2 of the window | 0.23.0 | 256 x 144 | replaced | a blur |
| Governor floor 0.5 | 0.23.0 | no 256 x 144 blur at 60 a second | kept | |

Derivation: [3.7](../render/07-accumulation.md), [3.16](../render/16-upscale.md).

## 7. Resolution governor

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Rise after 30 frames under 75 % of the budget | 0.23.0 | 560 x 320 cost 72 %, 640 x 368 cost 97 % | replaced | it hunted, restarting the picture every second |
| Rise only when the next step's predicted cost (proportional to scale squared) fits under 85 %; a drop after a rise doubles the patience (30 to 480 frames) | 0.23.0 | checks in `lux_schedule` | kept | |

Derivation: [3.12](../render/12-lux-layers.md) §3.4, [3.13](../render/13-dusk.md) §3.9.

## 8. Memory

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| A new frame and pool for every resize | 0.23.0 | memory grew with every window drag (the old frame never freed, F10) | replaced | |
| Buffers that only grow and are reused below their size, the pool kept | 0.23.0 | 7 governor resizes in 40 s: 162 MB flat | kept | |
| `releaseFlood` after the copy into the volumes | 0.23.0 | 741 to 307 MB while rendering | kept | the flood's 8 planes are not read after the copy; bit-identical |
| Bricked light volumes, one triplet for a uniform brick | 0.23.0 | volumes 118 to 28 MB; 307 to 222 MB | kept | bit-identical |
| Growing buffers held directly in a field | 0.23.0 | 900 MB, then 150 MB more at every corner | replaced | a field store frees the displaced array only if the value never leaves the object (compiler ledger section 862): hold them in owner objects replaced whole |
| Owner objects and a `--memory` report | 0.23.0 | 359 to 215 MB counted | kept | |

## 9. Threads and scheduling

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| 23 workers for the speed of 12 | 0.20 | processor 80 % | replaced | |
| One worker a core | 0.20 | same wall time, half the processor time | kept | |
| Still frames at stride 2, 8 samples | 0.20 | a still pass 83 to 39 ms on 12 workers | kept | |
| 128 bytes of padding in the per-chunk workers | 0.20 | no change | dropped | no false sharing there |
| A `Shared` value through a trait-typed launch argument | 0.20 | segfault with few threads: non-atomic count (F10) | replaced | workaround in `mc_env.axle`; dusk's IR has no plain refcount in thread paths |
| Loading screen: the window opens first, start-up in steps | 0.20 | several seconds without a window | kept | the land search, 7 s in one call, is stepped |

Derivation: [4.1](../engine/01-job-pool.md).

## 10. Compiler and instruction-level experiments

| Procedure | Axle | Cost | Verdict | Why |
|---|---|---|---|---|
| Beer-Lambert fog with `lightExp` | 0.22.0-dev | 14.0 ns a pixel | replaced | |
| `luxExpNeg8` over 8 lanes | 0.22.0-dev | 0.53 ns a pixel | kept | planar scalar loops vectorise by themselves (0.29 ns either way); written to interleaved RGB the same loop stays scalar (1.31 against 0.32) |
| `f32x8.fma` | 0.22.0-dev, 0.23.0 | 9 times slower than `a * b + c` | dropped | goes through a dispatch trampoline (F11) |
| `axle profile` (instrumented) | 0.20 | unusable | dropped | every small function is a call; sampling needs an Administrator shell |
| Build at `-O 1` | n/r | 3 to 4 times slower than `-O 3` | dropped | |

## 11. Measuring: what each method found

| Method | What it found |
|---|---|
| A scripted walk timing every stage (`--walk`) | the 392 ms p99 freeze (the sky on the frame's thread) |
| Counters in the loop (`McSession.loops`) | a ray's real work; the 115 iterations a ray under water |
| Switching the suspect off (`--fog 0`) | that the grey sky was the shafts |
| Golden fingerprints, 14 of them, equal on 1, 3 and 5 threads (`--golden`) | every exact optimisation |
| A series of still frames with the clock running (`--flicker --steady --dump`), then per-pixel variance and autocorrelation | the period-16 shimmer, the refused history on the edge, the depth test on still samples |
| A sweep of one input with a continuity bound (the filter's axis ratio 1 to 5) | the ring of fine ripples round the camera |
| Alternating the new and the old binary in one command | the 20 % noise of a machine that is also running the game |

None of these was found by reading code or by an averaged metric alone.

## 12. What is left

| Item | Size | Chapter |
|---|---|---|
| The ray's fixed overhead | 26 ns of 73 | [3.2](../render/02-visibility.md) |
| The composition loop: sharpen and bloom reads, three square roots | 39 ms | [3.8](../render/08-display.md) |
| Pixels no sample speaks for, in foliage | horizon 236 ms against ground 147 | [3.4](../render/04-sparse-light.md) |
| Sky reflection of a rough surface: harmonics instead of the grid | 55 ns a sample | [3.5](../render/05-shading.md) |
| Memory: `disp` at scale 1, `pos` as a depth | 18 MB | [2.3](../standards/03-types-and-memory.md) |
| Compiler: bounds checks in bilinear and bicubic reads, no vectorisation across `sqrt` | 2 to 9 times on those loops | `AXLE_COMPILER_FINDINGS.md` |
| Grey bands on sand seen from under water | reported, not reproduced | [3.10](../render/10-water.md) |

A moving frame of the voxel renderer is 21 to 45 ms on 12 workers: 22 to 47 frames a second, not 60. The walk of the
rays is the whole of what is left of it.

## 13. Reproducing a row

```sh
cd games/blockland
axle build -O 3 --codegen-units 1 -o /tmp/blockland.exe
/tmp/blockland.exe --bench --size 1280x720 --new Land1 --day-speed 0 --time 12:00 --down 0.6 --yaw 1.0
/tmp/blockland.exe --threads 1 --walk 2 --speed 0 --turn 1.2 --size 1280x720 --new Land1 --day-speed 0 --time 12:00 --down 0.6 --yaw 1.0
```

`--down 0.6` is the ground view, `-0.2` the horizon, `-1.3` the sky from under trees. For the bay (`examples/rendering/dusk`):
`dusk --golden`, `dusk --bench --shot 1`, `dusk --flicker --steady --upscale --dump PREFIX`, and
`dusk --debug-water MODE` to see one number of the water at a time.
