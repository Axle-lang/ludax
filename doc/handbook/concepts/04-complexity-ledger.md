# 1.4 The complexity ledger

[Handbook](../README.md) · previous: [1.3 The cost model](03-cost-model.md) · next: [2.1 Hot-loop rules](../standards/01-hot-loop-rules.md)

Every mechanism of the path-lit picture, with each way it has been done: what the way costs as a function of its
inputs, what it cost when measured, and why it was kept or dropped. The chapter of the mechanism has the
derivation; this is the record to read before trying a way again.

Symbols: `P` pixels of the picture (921 600 at 1280 x 720), `s` the stride between samples, `S = P / s^2` samples,
`n` cells a ray crosses, `F` faces of blocks in view, `E` how often the light of the world changes, `T` threads.
Times are nanoseconds for one item on one thread unless a frame time is given.

## 1. Light of a pixel

| # | Way | Work a frame | Measured | Kept? Why |
|---|---|---|---|---|
| 1 | Shade every pixel, one random sample, average over frames | `P` shadings | 350 ns a pixel; grain, ghosts | no: noise and a history that follows the camera |
| 2 | Shade every `s`-th pixel, copy to its block | `S` shadings + `P` copies | "360p" look | no: texture and edges are block-sized |
| 3 | Shade every `s`-th pixel; every pixel traces its own ray and blends the light of the samples on its **plane** | `S` shadings + `P` rays + `P` blends of 4 | fill 134 ms a frame, one thread | no: every leaf at one height is one plane, light flipped between leaves |
| 4 | The same, samples on its **face** only, else the face's centre | `S + P + F'` (faces no sample fell on) | equal to 3 | no: light held at every block border (stairs in shadows), hidden centres lit |
| 5 | The same, samples on its plane **within one block**, else the face where seen | `S + P + F'` | equal to 3 | superseded by 6 for the light, kept for the air |
| 6 | Light of a **face kept in the world** (9 points), read by every pixel; lit again only when the world's light changes ([3.11](../render/11-face-cache.md)) | `P` reads + `9 F E` shadings, spread over 16 frames | ground 32 to 24 ms on 12 threads; nothing shaded while only the camera moves | yes |
| 7 | A picture at rest: read the light again for every pixel, trace nothing | `P` reads | 1.7 ms a frame on average against a full frame 8 times a second | yes |

The step from 5 to 6 changes the order: the cost of light no longer grows with the frames drawn but with the changes
of the world, `O(F E)` instead of `O(S)` a frame.

## 2. Visibility: what a pixel sees

| # | Way | Work a ray | Measured | Kept? Why |
|---|---|---|---|---|
| 1 | Cell by cell (Amanatides and Woo) | `O(n)`, 2 to 3 ns a cell | 350 ns toward the sky | base case |
| 2 | Empty sections left in one move | `O(n / 16)` in open air | 95 ns toward the sky | yes |
| 3 | Above a column's last section: no lid | `O(1)` for a rising ray | — | yes |
| 4 | Brick mask: 4^3 groups of empty cells | `O(n / 4)` at best | 98 to 94 ns | replaced by 5 |
| 5 | Gap field: the largest empty cube centred on the cell, radius up to 4 | `O(n / (2g+1))`; needs `g >= 2` to pay | 94 ns; **0 to 3 moves a ray**: within two blocks of a surface there is no such cube | yes, but it is not what limits a ray |
| 6 | Branch-free choice of the axis | the same `O(n)`, longer dependency chain | 94 to 118 ns | no |
| 7 | Skyline: a ray above the horizon of the loaded world is not traced | `O(1)` | sky pixels free | yes |
| 8 | The section a ray starts in remembered | saves one `resolve` a ray | not measurable | kept, free |
| 9 | Water: full cells skipped, cubes of one fluid, uniform sections | `O(n)` with a small constant; cubes stop at section faces | 464 to 97 ms under water | yes; 115 iterations a ray remain |

Counted on 921 600 rays: a ray crosses 24 (ground), 33 (forest) or 42 (horizon) cells, takes 0, 1 or 3 box moves,
reads 2.5 to 2.9 texels and tests 0.5 to 1.3 models. At 2 to 3 ns a cell the walk is linear in `n` and that is the
frame: fill is 21 of 28 ms.

Not tried: starting the rays of a block where its samples know the air to be clear (a beam; exact with the gap
field, expected to save a fifth to a third of `n`).

## 3. The sky

| # | Way | Work a lookup | Measured | Kept? Why |
|---|---|---|---|---|
| 1 | Physical sky evaluated a pixel | scattering integrals | far too slow | no |
| 2 | Radiance grid over direction, baked when the sun moves | `O(1)`: 24 loads, bilinear x Catmull-Rom | 55 ns | yes |
| 3 | Bake on the frame's thread | 365 ms every 0.85 s | a freeze a second | no |
| 4 | Bake on a background thread, swapped in | `O(1)` a frame | p99 392 to 35 ms | yes |
| 5 | Exact `atan2`, `asin` for the grid's coordinates | libm | 68 ns | replaced by 6 |
| 6 | Polynomials (Abramowitz and Stegun 4.4.47), 1e-5 rad | 5 multiply-adds | 58 ns | yes |
| 7 | Clouds: 5 octaves of noise a lookup | `O(octaves)` | aliasing at the horizon | replaced by 8 |
| 8 | Clouds averaged over a sample's footprint: octaves under it replaced by their mean | `O(octaves kept)`, fewer far away | consecutive frames 0.65 to 0.19 levels apart | yes |
| 9 | Sky sampled every `s` pixels and blended; sun, moon, stars a pixel | `S` lookups + `P` blends | — | yes |

## 4. Shafts

| # | Way | Work a frame | Measured | Kept? Why |
|---|---|---|---|---|
| 1 | A march a pixel, 24 steps | `24 P` | — | no |
| 2 | A march a 2 x 2 block, jittered, averaged over frames | `24 P / 4` + a history | 9.3 then 2.5 ms; not deterministic | no |
| 3 | A march an 8 x 8 block over the sky averaged by the same blocks | `P` (averaging) + `24 P / 64` | 27 to 5 ms; no random number, no history | yes |

## 5. Display

| # | Way | Work a pixel | Measured | Kept? Why |
|---|---|---|---|---|
| 1 | Compose to floats, then pack; 4 bloom levels read bilinearly | 16 + 16 loads, 3 `pow` | 67 to 70 ms | no |
| 2 | Bloom folded to 2 levels; dither from a tile; meter on 1 pixel in 16 | 8 + 15 loads, 3 `sqrt` | 53 ms | superseded |
| 3 | One loop writes the words; locals; nearest sRGB entry over `sqrt` | the same, fewer reloads | 44 ms | superseded |
| 4 | One bloom level walked along the row (3 loads a pixel); integer code table over the linear value; integer dither | 15 + 3 loads, no `sqrt`, no float-to-int for the code | 21 ms (compose 17) | yes |

## 6. Baked shadows

| # | Way | Behaviour in time | Kept? Why |
|---|---|---|---|
| 1 | Re-bake a section, show the new share at once | a hop of an eighth, section by section, every 1.5 s | no: seen as blinking while moving |
| 2 | Glide from the share shown to the new one as the sun travels one step | continuous in the sun's direction; `O(entries)` a frame for the fades | yes |
| 3 | Shadow rays test foliage texel by texel | a new random pattern each generation | no |
| 4 | Shadow rays read foliage at its mean cover | smooth in the sun's direction | yes; the dapple is lost |

## 7. Threads

| # | Way | Scaling | Kept? Why |
|---|---|---|---|
| 1 | One worker a hardware thread (23) | 6.4 x the frame of one thread | no: 12 % more than 12 for twice the processor time |
| 2 | One worker a core (12) | 5.7 x | yes |
| 3 | A cache written by every thread as it goes | data race | no |
| 4 | A cache read by all, written between stages from one batch a chunk | deterministic; `O(new faces)` serial a stage | yes |

## 8. Rules drawn from the ledger

1. A cost that grows with the frames drawn is the first suspect: ask what would make it grow with the changes of
   the world instead (1.6, 1.7, 3.4, 6.2).
2. A shortcut must be exact or it will be seen: three of the dropped ways (1.3, 1.4, the ray skipped between four
   sky samples) were approximations of "which pixels may share".
3. Skipping empty space pays where space is empty. Near a surface the walk is linear and only doing fewer walks, or
   shorter ones, can help (2.5).
4. What cannot be resolved must be averaged before it is read, not after: clouds (3.8), foliage texels, the sun in a
   mirror, far ripples, the sky under a shaft (4.3).
5. Count before changing: three wrong guesses in a row on the walk through water, one run of counters to settle it.
