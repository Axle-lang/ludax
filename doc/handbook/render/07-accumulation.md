# 3.7 Accumulation

[Handbook](../README.md) · previous: [3.6 The sky](06-sky.md) · next: [3.8 Display](08-display.md)

## 1. Contract

`McFrame.blendPixel` folds this frame's sample of a pixel into the pixel's history, or starts a new one.

- **In**: `cur`, `alb`, `sid` of the frame; the history set of the frame before.
- **Out**: the other history set (light or radiance, albedo, luminance moments, count, surface).
- **Guarantees**: a moving frame takes nothing from the past; a still frame's result depends only on how many frames
  it has seen; light never mixes across surfaces.

## 2. Why accumulate at all

One ray through the centre of a pixel answers "what is at this point", not "what does this pixel cover". An edge
that crosses the pixel is drawn as a stair. Moving the ray inside the pixel from frame to frame and averaging
integrates over the pixel's area: this is the only anti-aliasing the renderer has, and it needs the camera to hold
still.

## 3. Mathematics

### 3.1 The jitter

For frame `n` of a still camera, pixel `(x, y)`:

```
(j_x, j_y) = 0.5 + (rng(x, y, n) - 0.5) * amount            amount ramps from 0 to 1 over the first 8 still frames
ray through (x + j_x, y + j_y)
```

The ramp keeps the first still frame equal to the last moving one, so stopping does not make the picture jump.

### 3.2 The running mean

With `c` the count held and `limit` the longest history allowed:

```
c'     = min(c, limit) + 1
alpha  = 1 / c'
light' = light + (sample - light) alpha
```

For `c < limit` this is the exact mean of all samples. At the limit it becomes an exponential average with a window
of `limit` frames, which is what lets a settled picture follow a slowly moving sun (`limit = 12` while the light
drifts, 8 otherwise).

The albedo is averaged the same way, apart from the light, so texture is anti-aliased without being blurred by
anything that filters light.

### 3.3 Fireflies

A sample far brighter than the history has ever been is brought down before it is folded in:

```
if c >= 3 and luma(sample) > 6 (mean + 0.25):   sample *= 6 (mean + 0.25) / luma(sample)
```

With deterministic shading there is little left for this to catch; it stays for mirrors and water.

### 3.4 Edges

A pixel with a different `sid` beside it (left, right, up or down) is an **edge**. Its jittered rays see one surface
on some frames and the other on others, so "the light of its surface" has no meaning. It is stored as `MCF_EDGE`
with albedo 1: its history is the pixel's **radiance**, and the mean of that is the coverage-weighted blend of the two
surfaces, which is exactly an anti-aliased edge.

## 4. When history is refused

| Case | Why |
|---|---|
| The camera moved | a moving picture is complete and exact each frame; history could only blur or ghost it |
| The pixel is open sky | the sky is a function of direction and time: there is nothing to converge, and a star reprojected along a turn is a streak |
| The history's `sid` differs from the pixel's | another surface |
| A restart (`fresh`): a chunk loaded, a block changed, the base cell moved | the world is not the one the history saw |

## 5. Complexity

| | Time | Memory |
|---|---|---|
| Moving | one division by the albedo and a store: 3 ns/px | writes one set |
| Still | four neighbour tests, one fold: about 12 ns/px | reads one set, writes the other |
| Both | — | 2 x 10 floats a pixel = 74 MB at 720p ([2.3](../standards/03-types-and-memory.md)) |

## 6. Observations

- Reprojection was the most expensive stage after tracing (44 ms a frame on one thread) and the source of three
  visible defects: ghosts behind moving edges, smeared stars, and a picture that depended on the camera's path.
  Removing it from moving frames cost nothing visible, because nothing in a moving frame is noisy any more.
- Convergence is now short: 8 frames against 32, each about half the price, since only the anti-aliasing is left to
  converge.
- The second history set is used only so that temporal can be run row by row with no ordering between rows.

## 7. History

| Date | State |
|---|---|
| before 2026-11-09 | every frame: one stochastic sample, reprojected history, limit 3 moving and 32 still |
| 2026-11-09 | deterministic shading; the history kept across baked-shadow batches |
| 2026-11-10 | the open sky keeps no history |
| 2026-11-10 | a moving frame keeps no history; still frames at stride 2, 8 samples |
| 2026-11-11 | a moving frame is *direct*: the display reads the samples (`cur`) and the temporal and resolve stages do not run (they copied the picture twice: 4 ms a frame on one thread); the frame after it starts a history |

## 8. Source

`games/blockland/src/app/mc_frame.axle` (`temporal`, `blendPixel`, `isEdge`, `history`, `reproject`, `mcfFold`,
`mcfTameEdge`), `mc_session.axle` (`accumulate`), `src/render/pathlight/pathlight_settings.axle` (`LumenRng`).

`reproject` and the spatial filter remain in the source for the still camera's first frames and for the `denoise`
setting; neither runs in a default moving frame.
