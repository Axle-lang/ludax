# 2.3 Types and memory

[Handbook](../README.md) · previous: [2.2 Shared buffers](02-shared-buffers.md) · next: [3.1 The frame](../render/01-frame.md)

## 1. Which type for which datum

| Datum | Type | Why |
|---|---|---|
| A world position | `f64`, or `i32` cell + `f32` fraction | `f32` has 24 bits: at 16 million blocks it cannot tell two cells apart |
| A position inside the frame | `f32`, relative to the base cell | the base is within 1024 blocks, so `f32` keeps 1/8192 of a block |
| Radiance, light, albedo while they are summed | `f32` | linear, unbounded above |
| A block state | `u16` | 29 873 states fit in 15 bits |
| A count of cells a ray may skip | `u8` | at most 4 |
| A baked share (access, sun, moon) | 8 bits | a shadow needs no more than 256 steps |
| A baked tint | 4 bits a channel | it multiplies a dome that is itself a blur |
| A finished pixel | `i32`, `0x00RRGGBB` | what the window takes |
| An index into a picture | `i64` | `3 P` passes `2^31` at 16 K pictures, and Axle indexes with `i64` anyway |
| A time of day | `f64` in 0..1 | a tick is 1 / 24000 and must add up over days |

Rules that follow:

1. **Store narrow, compute wide.** A buffer holds the narrowest type that keeps the datum; the loop widens it once.
2. **Never store a world coordinate in `f32`.**
3. **A share in 0..1 that is read through a blur is a byte.**

## 2. What the frame weighs (1280 x 720)

`P = 921 600`. One `f32` plane is 3.7 MB.

| Buffer group | Planes | Size |
|---|---|---|
| History, two sets (`light 3, albedo 3, moments 2, counts 1, surfaces 1`) | 20 | 73.7 MB |
| G-buffer (`cur 3, alb 3, pos 3, sid 1`) | 10 | 36.9 MB |
| `hdr` | 3 | 11.1 MB |
| Sample grids (`lightGrid 3, below 3, veilGrid 1, ray 1` at a quarter) | 2 | 7.4 MB |
| Display (`lv1..lv4`, `tmp`, `disp 3`, `out 1`) | about 5.7 | 21 MB |
| **The picture** | | **about 150 MB** |

## 3. What the world weighs (view distance 12, measured by `axle profile`, 2026-11-10)

| Structure | Size | Note |
|---|---|---|
| Baked light (`McBake`: words `i32`, tints `u16`, glows `u16` a cell) | 45.5 MB | 8 bytes a cell of a baked section |
| Light flood scratch (`McLightScratch`) | 1.8 MB a worker | 41 MB at 23 workers, 22 MB at 12 |
| Section cache (`u16` a cell, 1452 sections) | 11.9 MB | |
| Gap field (`u8` a cell, same sections) | 5.9 MB | replaced a 64-bit mask a section |
| Blocks (palettes) | 10 MB | |

Halving the workers ([4.1](../engine/01-job-pool.md)) halved the light scratch: 19 MB for nothing lost.

## 4. Where memory could still come down

None of these is done; each is listed with what it would save and what it risks.

| # | Change | Saves | Risk |
|---|---|---|---|
| M1 | `disp` is not needed at scale 1 except for the raw debug view: allocate it on first use | 11.1 MB | none |
| M2 | Albedo as a packed `i32` (8 bits a channel) in `alb` and in both history sets | 22 MB | an accumulated albedo loses the sub-code precision that anti-aliases texture; needs a look |
| M3 | `pos` as one depth along the pixel's ray; the position is rebuilt as `eye + ray * depth` | 7.4 MB | a camera ray recomputed where the position is read (3 ns) |
| M4 | `counts` as `u8`, `moments` as two `f16`-like fixed-point values | 7 MB | none for counts (at most 32); moments need care |
| M5 | The second history set exists only for the still camera's blend; a moving frame could write in place | 36.9 MB while moving | the swap is what makes temporal row-independent |
| M6 | Baked `words` as three bytes and a flag bit instead of an `i32` | 0 (it is already packed) | — |

M1 and M3 are the safe ones.

## 5. Observations

- The picture's memory is dominated by history that a moving frame does not use.
- Memory is also time: the history's 74 MB do not fit any cache, so temporal's cost is its memory traffic. Since
  moving frames stopped reprojecting, temporal went from 44 ms to 3 ms a frame, mostly because it stopped reading the
  set it does not need.
- A narrower type in a hot buffer helps twice: fewer bytes moved, more of them in cache.

## 6. History

| Date | Change | Effect |
|---|---|---|
| 2026-11-10 | brick mask (8 bytes a section) replaced by the gap field (4096 bytes a section) | +5.9 MB, for the walk's jumps |
| 2026-11-10 | shaft buffer at a quarter of the picture | −2.8 MB |
| 2026-11-10 | workers: one a core | −19 MB of light scratch |

## 7. Source

`games/blockland/src/app/mc_frame.axle` (constructor of `McFrame`), `src/render/pathlight/pathlight_post.axle`
(constructor of `LumenPost`), `games/blockland/src/render/render_view.axle`, `render_bake.axle`.
