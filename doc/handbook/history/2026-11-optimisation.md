# 5.1 The November 2026 optimisation log

[Handbook](../README.md) · previous: [4.1 The job pool](../engine/01-job-pool.md)

What was changed in the path-lit renderer of `games/blockland` on 9 and 10 November 2026, in order, with the
measurement before and after each step and the experiments that were withdrawn. All times are one thread at
1280 x 720 on a Ryzen 9 9900X unless a worker count is given.

## 1. Where it started

The complaints, in the player's words: a freeze every second; grain; "360p" while moving; leaves that change their
holes; a grey sky; stars drawn as streaks; the processor at 80 %; a different picture each time the mouse moves.

| Symptom | Cause, found by measurement |
|---|---|
| Freeze every second | the day clock recomputed the sky on the frame's thread: 365 ms every 0.85 s |
| Grain | each batch of re-baked shadows marked the picture dirty and threw the history away |
| Not deterministic | a random point on the sun's disc and a random jitter while moving |
| "360p" | one sample copied to a block of 2 x 2 to 4 x 4 pixels |
| Leaves change | the mip level of the alpha test followed the block size |
| Grey sky | the light shafts added a uniform veil over the whole sky |
| Streaked stars | sky pixels were reprojected through the history |
| 80 % processor | 23 workers for the speed of 12; 16 to 32 full-resolution passes after every stop; every stage 2 to 4 times dearer than it need be |

## 2. The steps

### Day 1 (2026-11-09): correctness

| # | Change | Before | After |
|---|---|---|---|
| 1 | `--walk`: a scripted walk that times every stage of every frame | no measurement | p99 392 ms seen |
| 2 | Sky baked on a background thread (`SkyBaker`, `glide`) | p99 392 ms | p99 35 ms |
| 3 | A bake batch no longer restarts the picture | history lost each frame | kept |
| 4 | Sun shadow to the disc's centre; no jitter and a fixed random key while moving | frames differ | `cmp` identical |
| 5 | A settled picture under a running clock redrawn every 15 ticks | a 125 ms frame every 4 | every 0.75 s |

### Day 2 (2026-11-10): work a frame

Frame = trace + fill + temporal + display, ground view, head turning. A dash means the frame was not measured at
that step; the note carries what was.

| # | Change | Frame, ms | Note |
|---|---|---|---|
| 0 | start of the day | 345 | trace 199, temporal 44, display about 100 |
| 6 | Texture per pixel (`plain`), light shared by the block | — | sharp texels, light in squares |
| 7 | Mip footprint fixed at one pixel | — | leaves stop changing |
| 8 | Shafts gathered round the sun, faded under a high sun | — | blue sky |
| 9 | Shafts marched at half resolution | −7 | 9.3 to 2.5 ms |
| 10 | Sky keeps no history | — | stars are points |
| 11 | Samples and fill as two stages; light **interpolated** among same-plane samples; no reprojection while moving | 210 | trace 134, temporal 4 |
| 12 | Sky veil shared, bodies per pixel; every sky pixel traced or cleared | — | twigs kept |
| 13 | `MCT_ABOVE` and the window ceiling | — | sky ray 350 to 95 ns |
| 14 | Still frames at stride 2; 8 samples | — | a still pass 83 to 39 ms on 12 workers |
| 15 | One worker a core | — | same wall time, half the processor time |
| 16 | Display: meter 1 in 16, dither tile, bloom folded, words written by compose | 196 | display 67 to 53 |
| 17 | Gap field replaces the brick mask | — | ray 98 to 94 ns |
| 18 | `slotOf` without division; fixed tints by table; last-biome cache | — | ray 94 to 86 ns |
| 19 | Skyline test as sines | — | ray 86 to 73 ns |
| 20 | `composeWords` | **147** | display 53 to 44 |

Other views at the end: horizon 236 ms (370 at the start), sky under trees 169 ms (195).
On 12 workers: 26, 46 and 31 ms.

### Day 3 (2026-11-11): display, shafts, water, shadows

One thread, 1280 x 720, head turning, the three views (ground / horizon / sky under trees), measured in alternation
with the build of the day before on a machine that was also running the game (20 % of noise).

| # | Change | Frame, ms | Note |
|---|---|---|---|
| 0 | start of the day | 147 / 208 / 166 | compose 37, shafts 27 to 30 where the sun shows |
| 21 | Composition: one bloom level walked along the row, integer code table and dither ([3.8](../render/08-display.md) §3.6, §3.7) | 124 / 187 / 144 | compose 39 to 17 |
| 22 | Shafts marched once for 64 pixels over the averaged sky, no jitter, no history ([3.1](../render/01-frame.md) §5) | — | 27 to 5.5 ms; at most 2 levels of difference on 3.4 % of the bytes |
| 23 | A moving frame is direct: no temporal, no resolve ([3.7](../render/07-accumulation.md)) | — | 4 ms |
| 24 | Under water: plain surfaces share light, the surface from below is shaded from the pixel's ripple ([3.10](../render/10-water.md)) | — | 464 to 272 ms (640 x 360, level) |
| 25 | The ray knows it is still in the water after a water plant | — | a bug: the sea bed behind sea grass was a wall of water |
| 26 | Fluid cells, cubes and sections skipped; the ray followed 64 blocks | — | 272 to 120 ms |
| 27 | Fog stored apart from the light | — | the grain on the sea bed gone; 120 to 97 ms |
| 28 | Baked shadows glide with the sun; shadow rays read foliage at its mean cover ([3.9](../render/09-baked-shadows.md)) | — | consecutive frames identical under a moving sun |
| 29 | The sky in a rippled mirror: the sun as a lobe, far clouds faded | — | the dotted edges of reflections gone; the sea from above 50 to 36 ms on 12 workers |
| 30 | The sky baker's thread is waited for on exit | — | a crash at the end of every run with a moving clock |
| | end of the day | **128 / 165 / 118** | trace and fill unchanged: 105 / 139 / 92 |
| 31 | A picture at rest redoes its water alone, 30 times a second (`Ripple`); water keeps no history | — | the sea stood still when the player did; 8.8 ms a redo on 12 workers for a picture that is all sea |
| 32 | A settled picture follows the sun every 5 drift events, not 15 | — | steps of a quarter of a second, not three quarters |
| 33 | Light with no sample on its plane is blended over the kin samples, not taken from the heaviest | — | the choice flipped with every move of the camera: the sizzle of foliage in motion |
| 34 | The cloud deck is averaged over the footprint of a sample (`lnFbm2Soft`) | — | the horizon sizzled: consecutive frames of a slow turn 0.65 levels apart on average, to 0.19 |
| 35 | Foliage is read at a level where a texel covers two pixels, counting the slant of the face ([3.2](../render/02-visibility.md)) | — | a forest from the sky twinkled leaf by leaf: consecutive frames of a slow turn differed by more than 8 levels on 26.4 % of the bytes, 8.4 % after; far foliage is flatter |
| 36 | Light is shared between the samples of one face of one block, not of one plane; a face no sample fell on is lit once at its centre ([3.4](../render/04-sparse-light.md)) | — | 8.8 % to 8.4 % at the same cost: every leaf at one height was one plane, so a leaf took the light of another |
| 37 | The shadow ray of a point the bake does not reach reads foliage at its mean cover, as the bake does | — | not measured |
| 39 | A pixel shares with the samples of its plane within a block (`blendNear`); a face no sample is near is lit where it is seen | — | the face rule held the light at every border of a floor (shadow edges in steps) and lit hidden faces at their centre (bright dots on edges) |
| 40 | The face cache: diffuse light kept in the world, nine points a face, read by every pixel ([3.11](../render/11-face-cache.md)) | — | ground 32 to 24 ms on 12 workers, trees 38 to 24; nothing is lit again while the camera alone moves |
| 41 | The faces take turns to follow a drifting light (`faceStagger`) | — | p99 of a walk under a running clock 55-83 ms to 35-46 |
| 42 | Water read at its coarsest level; a fluid under a block fills its cell; the water's own colour dims at night; stars twinkle between 0.8 and 1 | — | the game's water texels at night, a slit of air under blocks seen from below, a glow far away under water at night, stars that went out |
| 43 | The aimed block is lit like its neighbours, its outline drawn on its texture; a resting picture that is redrawn lights every face again | — | the aimed block was shaded apart and looked like a wrong light that followed the crosshair |
| 44 | A water sample shows what its neighbours show (the sky in the mirror, its own bed); ripples go flat once a pixel runs over 0.6 block of water; the mirror reads the clouds through a blur of 2 and without their second noise | — | black dots on the sample lattice wherever a traced mirror met a tree; a grain on far water; the sea from above 50 to 37 ms on 12 workers |
| 45 | A loading screen: the window opens first and the start-up runs in steps between its pictures (`mc_loading.axle`) | — | several seconds without a window |
| 46 | The loading screen's steps are timed in the walk harness (`load:` lines); the search for dry land, 7 s in one call, is stepped | — | the "freeze at the light" was the land search that follows it |
| 47 | Every loop of a frame is timed (`McSession.loops`, `loop:` lines of `--walk`) and a ray's work counted | — | fill 21.2 of 28 ms; a ray crosses 24 to 42 cells, takes 0 to 3 box moves, reads 2.5 to 2.9 texels and tests 0.5 to 1.3 models |
| 48 | A picture at rest is relit, not redrawn: `Relight` reads each plain pixel's light again from the face cache; the whole picture is drawn again once in 24 relights | — | at rest under a running clock: a full frame 8 times a second (80 % of the pool) to 1.7 ms a frame on average |
| 49 | The far ground under the horizon is the horizon's colour dimmed, with a slow fade | — | a second, olive horizon seen from high above the sea |
| 50 | Review of the core's changes by a second reader: `LumenSparse` sized and clamped to a power-of-two stride, the mirror's lobe scaled by 17/16, an empty cache slot that no epoch can match, a lattice not undone by a flat light, a dead branch out of `compose`, the bloom pyramid in its own file, comments brought to what the code does (trig within 1.2e-5, the code table's error, the far ground) | — | 9 checks added (4 864); the picture is bit-identical |
| 38 | The sparse light moves into the engine: `LumenSparse`, `SparseCorners`, `SparseLight`, `LumenLightMemo` (`src/render/pathlight/pathlight_sparse.axle`), with the sharing key left to the caller and 26 checks ([3.4](../render/04-sparse-light.md) §1.0) | — | the picture is bit-identical |

On 12 workers the three views are 26, 36 to 45 and 21 ms, against 26 to 31, 30 to 47 and 22 to 28 the day before: the
gain of the day is inside the noise there, because what was removed (compose, shafts) already ran on all the workers
and the walk of the rays, which did not change, is what is left. Under water: 335 to 568 ms down to 53 to 86.

### Along the way

| # | Found | Fixed |
|---|---|---|
| A | Crash scrolling the inventory: `index -66981886 out of bounds` | a packed colour was read as a texture index in `McIcons.draw`; a test now makes all 1160 icons |
| B | Segfault with few threads: `shared refcount: strong count underflow` | an Axle bug (F10, §533): non-atomic counts through a trait-typed launch argument; worked round in `mc_env.axle` |
| C | The newer compiler's E0283 (`mut` on a parameter that is written through) | 39 signatures |

## 3. Experiments withdrawn

| # | Tried | Result | Lesson |
|---|---|---|---|
| X1 | Thinning the clouds overhead to cure the grey sky | no change | the grey was the shafts; measure with the suspect switched off (`--fog 0`) before changing it |
| X2 | Every pixel off its sample's plane shades itself | median 80 ms | foliage makes that most pixels; share by kinship |
| X3 | Skipping the ray between four sky samples | fast, but thin things against the sky vanished | a shortcut must be exact |
| X4 | Exact `atan2` replaced by a polynomial in the sky lookup | 68 to 58 ns | the lookup was the cost, not the angle |
| X5 | `SkyGrid.look` rewritten in scalars | no change | 24 bounds-checked loads are its price |
| X6 | 128 bytes of padding in the per-chunk workers | no change | no false sharing there |
| X7 | Branch-free axis choice in the ray walk | 94 to 118 ns | a predicted branch beats a longer dependency chain |
| X8 | `--target-cpu native` | under 2 % | not the lever here |
| X9 | `axle profile` (instrumented) | unusable | every small function is a call; sampling needs an Administrator shell |

| X10 | Each pixel reads its own share of the sun from the bake (one trilinear lookup a pixel) | +40 ms a frame, 0.5 % of the bytes changed | the shared light was already right at the bake's scale; the flicker was the bake hopping in time (step 28) |
| X11 | The section a ray starts in is remembered from the ray before | not measurable | `resolve` was not the fixed cost of a ray; the entry stays (it is correct and free) but item 1 of §5 is still open |
| X12 | Three guesses at the cost of a ray under water (surface height, ray length, uniform sections) | none moved it | counters in the loop found it in one run: 115 iterations a ray |

## 4. What each kind of change was worth

| Kind | Steps | Gain |
|---|---|---|
| Doing less (sparse light, sparse sky, no reprojection) | 11, 12 | 135 ms (345 to 210) |
| Skipping empty space | 13, 17 | 250 ns a sky ray; 4 ns a ground ray |
| Removing hidden costs (division, strings, trigonometry, field reloads) | 16, 18, 19, 20 | about 49 ms (196 to 147) |
| Not running what does not help (extra threads, extra passes) | 14, 15 | half the processor time at equal speed |

## 5. What is left

| # | Item | Size | Chapter |
|---|---|---|---|
| 1 | The ray's fixed overhead: an 18-field hit returned by value, the first `resolve`, the caller's copy | 26 ns of 73 | [3.2](../render/02-visibility.md) |
| 2 | The composition loop: sharpen and bloom reads, three square roots | 39 ms | [3.8](../render/08-display.md) |
| 3 | Pixels no sample speaks for, in foliage | horizon 236 ms against ground 147 | [3.4](../render/04-sparse-light.md) |
| 4 | The sky reflection lookup of a rough surface: harmonics instead of the grid | 55 ns a sample | [3.5](../render/05-shading.md) |
| 5 | Memory: `disp` at scale 1, `pos` as a depth | 18 MB | [2.3](../standards/03-types-and-memory.md) |
| 6 | Compiler: bounds checks in bilinear and bicubic reads, no vectorisation across `sqrt` | 2 to 9 times on those loops | `AXLE_COMPILER_FINDINGS.md` |

A moving frame is 21 to 45 ms on 12 workers: 22 to 47 frames a second, not 60. Of the six items only the second
was done (compose 39 to 17 ms). Items 1 and 3, the walk of the rays, are the whole of what is left: 105, 139 and
92 ms of the 128, 165 and 118.

Opened on day 3:

| # | Item | Chapter |
|---|---|---|
| 7 | Grey bands on sand seen from under water: reported, not reproduced | [3.10](../render/10-water.md) |
| 8 | The walk through water: 115 iterations a ray, cubes that stop at section faces | [3.10](../render/10-water.md) |
| 9 | No test for the fluid tracking through water plants, the glide, the mirrored sky | [3.9](../render/09-baked-shadows.md), [3.10](../render/10-water.md) |
| 10 | A sampling profiler that needs no elevation (Axle ledger §550) | — |

## 6. How to reproduce a row

```sh
cd games/blockland
axle build -O 3 --codegen-units 1 -o /tmp/blockland.exe
/tmp/blockland.exe --bench --size 1280x720 --new Land1 --day-speed 0 --time 12:00 --down 0.6 --yaw 1.0
/tmp/blockland.exe --threads 1 --walk 2 --speed 0 --turn 1.2 --size 1280x720 --new Land1 --day-speed 0 --time 12:00 --down 0.6 --yaw 1.0
```

`--down 0.6` is the ground view, `-0.2` the horizon, `-1.3` the sky from under trees.
