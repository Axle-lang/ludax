# 2.2 Shared buffers: the bus between the stages

[Handbook](../README.md) · previous: [2.1 Hot-loop rules](01-hot-loop-rules.md) · next: [2.3 Types and memory](03-types-and-memory.md)

## 1. The idea

The stages of a frame do not call each other. Each reads buffers the stage before it wrote and writes its own. The
buffers are the interface: a stage can be replaced, measured alone or run on any number of threads as long as it
honours the layout. This chapter is that layout. It is the only "bus" the renderer has, and the only one it needs: a
message queue between stages would add copies and latency to pass what is already an array.

## 2. Conventions

| # | Convention | Reason |
|---|---|---|
| C1 | A picture buffer is row-major: pixel `(x, y)` is at `i = y W + x`. | one multiplication, rows are contiguous for a chunk of rows |
| C2 | A colour is three consecutive `f32`: `buf[3 i], buf[3 i + 1], buf[3 i + 2]` (`pixelAt`, `pixelPut`). | one stream a buffer, no padding |
| C3 | Radiance and light are linear, in the scene's units; only the display's output is encoded. | sums and means are only right in linear |
| C4 | Positions in a buffer are **local**: relative to the base cell (`McEnv.baseX/Y/Z`, multiples of 512). | `f32` cannot hold a world coordinate in the millions to a fraction of a block |
| C5 | A stage writes only the rows it was handed and reads only what no chunk of the same stage writes. | determinism ([1.2](../concepts/02-determinism.md) §2.3) |
| C6 | A sparse grid has one entry a sample: sample `(gx, gy)` is the pixel `(gx s, gy s)`, at `g = gy ceil(W / s) + gx`. | the grid's size depends on the stride only |
| C7 | Identifiers that say "what kind of thing" are negative; a plane is positive. | one comparison tells a plain surface from the rest |

## 3. The surface identifier (`sid`)

One `i32` a pixel says what the pixel saw, and it is the key of every decision about sharing.

| Value | Name | Meaning | Shares light? | Keeps history? |
|---|---|---|---|---|
| `>= 0` | plane | `(c + 2^25) * 8 + face`, `c` the cell coordinate along the face's normal | with samples of the same value | yes, on the same value |
| `-1` | `MCW_SKY` | nothing was hit | the sky's veil, when all four samples are open sky | never |
| `-2` | `MCW_WATER` | a water surface | the bed light of its sample | yes, pinned to the pixel |
| `-3` | `MCW_UNFILTERED` | a glowing block, a mirror, a metal | no: shades itself | yes, pinned |
| `-4` | `MCF_EDGE` | (temporal stage only) a pixel beside another surface | no | as radiance, not light |
| `-9` | `MCF_NO_SURFACE` | a history slot never written | — | — |

Two pixels with the same non-negative `sid` lie in the same infinite plane, facing the same way: `sid & 7` is the
face (0 down, 1 up, 2 north, 3 south, 4 west, 5 east), `sid >> 3` the plane's coordinate.

## 4. The buffers of a frame

`P = W H` pixels; `G = ceil(W / 2) ceil(H / 2)` is the room of a sparse grid (sized for the smallest stride, 2).

### 4.1 Written by trace and fill (the G-buffer)

| Buffer | Type | Size | Holds | Read by |
|---|---|---|---|---|
| `cur` | `f32 x 3` | `P` | the pixel's radiance sample | temporal |
| `alb` | `f32 x 3` | `P` | its albedo, floored at `MCW_ALBEDO_MIN`; white for sky and water | temporal, resolve |
| `pos` | `f32 x 3` | `P` | where the primary ray ended, local | fill (kinship), shafts (air), filter |
| `sid` | `i32` | `P` | the surface identifier | fill, temporal, shafts |

### 4.2 Written by trace, read by fill (the sample grids)

| Buffer | Type | Size | Holds |
|---|---|---|---|
| `lightGrid` | `f32 x 3` | `G` | for a plain surface, radiance / albedo; for open sky, the veil's colour |
| `veilGrid` | `f32` | `G` | for open sky, the share of the bodies the clouds let through; `-1` for anything else |
| `below` | `f32 x 3` | `G` | for water, the light refracted from under the surface |

### 4.3 History (two sets, swapped each frame)

| Buffer | Type | Size | Holds |
|---|---|---|---|
| `light` | `f32 x 3` | `P` | the mean light so far (radiance for an edge pixel) |
| `albedo` | `f32 x 3` | `P` | the mean albedo so far |
| `moments` | `f32 x 2` | `P` | mean and mean square of the light's luminance |
| `counts` | `f32` | `P` | how many samples the mean holds |
| `surfaces` | `i32` | `P` | the `sid` the history belongs to |

### 4.4 Output

| Buffer | Type | Size | Holds |
|---|---|---|---|
| `hdr` | `f32 x 3` | `P` | the frame's radiance: light times albedo, plus shafts |
| `ray` | `f32` | `G` | the shaft march, averaged over frames |
| `post.lv1..lv4` | `f32 x 3` | `P/4, P/16, P/64, P/256` | the bloom levels |
| `post.out` | `i32` | `P scale^2` | the finished words, `0x00RRGGBB` |

## 5. Who writes what, in order

```
skyline ─► trace ─► fill ─► temporal ─► (filter) ─► resolve ─► shaft march ─► shafts ─► display
   │         │        │         │                       │            │            │         │
 slopes   cur alb   cur alb   history set            hdr          ray          hdr       out
          pos sid   pos sid
          grids
```

A stage to the right may read anything to its left. Nothing reads to its right.

## 6. The frame's constants (the other half of the bus)

`Shared<McEnv>` is read by every worker and written by nobody during a frame: the view of the world, the baked
light, the block table, the atlas, the sky, the settings, the base cell, the skyline. It is set between frames by
`McSession`. This is what makes rule C5 enough for determinism.

## 7. Observations

- The G-buffer is what lets fill be a separate stage from trace: fill needs the four samples around a pixel, which
  belong to other rows and other workers, and it finds them in buffers that are complete before it starts.
- A sample's three grids are indexed alike and written together, so adding a shared quantity is one more grid, not a
  new protocol.
- `pos` is the heaviest buffer for what it is used for. A depth along the pixel's ray would be one float instead of
  three; see [2.3](03-types-and-memory.md) §4.

## 8. Source

`games/blockland/src/app/mc_frame.axle` (the fields of `McFrame`, `McFrameSet`, `McCorners`),
`mc_worker.axle` (`MCW_*`, `plane`), `src/render/pathlight/pathlight_pixels.axle` (`pixelAt`, `pixelPut`).
