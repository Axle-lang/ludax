# 3.1 The frame

[Handbook](../README.md) · previous: [2.3 Types and memory](../standards/03-types-and-memory.md) · next: [3.2 Visibility](02-visibility.md)

## 1. Contract

`McSession.pass()` draws one picture of the world from the session's camera into `frame.hdr` (linear radiance) and
answers whether anything changed. `McSession.show()` turns `hdr` into display words.

- **In**: the camera, the world's view, the baked light, the sky of the moment, the settings.
- **Out**: `hdr`, and the history for the next frame.
- **Guarantees**: deterministic ([1.2](../concepts/02-determinism.md)); a settled picture under a stopped clock
  costs nothing; no stage waits on a background thread.

## 2. The stages

| # | Stage | Runs on | Rows | Reads | Writes | Chapter |
|---|---|---|---|---|---|---|
| 0 | Decide | main | — | camera, `dirty`, `soft`, `still` | stride, jitter, history limit | §3 |
| 1 | Skyline | main | — | loaded chunks | 720 sines, the ceiling | [3.3](03-skyline.md) |
| 2 | Trace | pool, grain 2 | `H` | env | `cur alb pos sid` at the samples, the three grids | [3.2](02-visibility.md), [3.5](05-shading.md) |
| 3 | Fill | pool, grain 2 | `H` | the samples, the grids | `cur alb pos sid` everywhere else | [3.4](04-sparse-light.md) |
| 4 | Temporal | pool, grain 2 | `H` | `cur alb sid`, last history | this frame's history | [3.7](07-accumulation.md) |
| 5 | Filter (off by default) | pool | `H` x 3 rounds | history | `cur` / `alb` as scratch | — |
| 6 | Resolve | pool | `H` | history light and albedo | `hdr` | §4 |
| 7 | Shaft march | pool | `H / 2` | `sid` | `ray` | §5 |
| 8 | Shafts | pool | `H` | `ray`, `pos`, `sid` | `hdr` | §5 |
| 9 | Display | pool, grain 4 | several | `hdr` | `post.out` | [3.8](08-display.md) |

## 3. Stage 0: what kind of frame

```
moved    = camera differs from the camera of the last frame drawn
changing = moved or dirty or soft
```

| Case | Stride `s` | Jitter | History limit | Drawn? |
|---|---|---|---|---|
| `moved` | 4 | 0 | 3 (unused: nothing is reprojected) | yes |
| `dirty` (a chunk loaded, a block changed) | 2 | 0 | restart | yes |
| still, `still < samples` | 2 | ramps 0 to 1 over 8 frames | `samples` (8), or 12 if the light drifts | yes |
| still, settled, clock stopped | — | — | — | **no** |
| still, settled, light drifting | 2 | 1 | 12 | once every 15 drift events (about 0.75 s) |

A drift event is a game tick of a running clock or a batch of re-baked shadows. Shadows that move do not restart the
picture; a loaded chunk does.

## 4. Resolve

```
hdr = light * albedo        for a surface pixel
hdr = light                 for an edge pixel (its history is radiance already)
```

Light and albedo are accumulated apart so that a filter, when one runs, never touches texture detail.

## 5. Light shafts

A screen-space estimate of the sun's light scattered by the air between the eye and what a pixel sees
(`src/render/pathlight/pathlight_shaft.axle`).

### 5.1 The march

The sky is first averaged over blocks of `S = 8` pixels each way (`LumenShaft::skyShare`): `share[g]` is how much of
block `g` is open sky, 0 to 1. Then, for each block, from its middle `p` toward the sun's place `q` in the picture,
`N = 24` steps over the fraction `sigma = min(0.92, 0.55 max(W, H) / |q - p|)` of the way:

```
x_k = p + (q - p) sigma (k + 1/2) / N
w_k = 0.93^k                                 the weight decays along the march
win_k = smoothstep(0, 0.12 min(W, H), distance of x_k to the border)
sky  = sum(w_k win_k bilinear(share, x_k))
seen = sum(w_k win_k)
total = sum(w_k)
march(p) = sky / max(seen, 0.35 total)  /  (1 + (|q - p| / (0.5 max(W, H)))^2)
```

The steps are some thirty pixels apart. Over single pixels they aliased, which a jitter drawn each frame and an
average over frames used to hide; over the averaged sky they do not, so the march draws no random number and keeps
nothing from the frame before: the same camera gives the same shafts.

The last divisor gathers the glow round the sun. Without it an open sky gave `march = 1` everywhere and the shafts
added a grey veil to the whole sky.

### 5.2 The gain

```
gain = sunIrradiance * 0.1 * saturate(8 sunY) * (1 - 0.94 smoothstep(0.15, 0.5, sunY)) * open
```

`sunY` is the sine of the sun's elevation and `open` how much sky the eye itself sees by. The third factor fades
the shafts in at sunrise; the fourth takes them down to 6 % under a high sun, when the air is lit everywhere and a
shaft is no longer a shape.

### 5.3 Per pixel

```
hdr += gain * bilinear(march, pixel) * smoothstep(3, 40, distance to the surface)
```

One march for 64 pixels, read back bilinearly; the air term is the pixel's own. The three stages (`RaySky`,
`RayMarch`, `Rays`) are skipped when the sun is behind the camera or the gain is zero.

| | Cost | Memory |
|---|---|---|
| March | `O(P / 4 * 24)`: 2.5 ms a frame on one thread when the sun is in view | `P / 4` floats |
| Add | `O(P)`: under 1 ms | — |

## 6. Complexity of a frame

```
T1(moving) = P [ 1/16 shade + 15/16 (ray + blend) + temporal + display ]
           = P [ 22 + 82 + 3 + 43 ] ns        on the ground
```

See [1.3](../concepts/03-cost-model.md) §2 for the measured table.

## 7. Observations

- The cost of a frame barely depends on the stride once `s >= 2`: the samples are a fifth of the frame at `s = 4`.
  Per-pixel visibility is the floor.
- A horizon view is the worst case: long rays through foliage, and many pixels with no sample on their plane.
- Restarting on a baked-shadow batch (which happens continuously under a moving sun) was the cause of the grain of
  2026-11-09: the history was thrown away every frame.

## 8. History

| Date | Change | Before | After |
|---|---|---|---|
| 2026-11-09 | sky recomputed on a background thread, not on the clock's tick | a 365 ms stall every 0.85 s | none |
| 2026-11-09 | a bake batch no longer restarts the picture | history lost every frame | kept |
| 2026-11-10 | shafts marched at half resolution | 9.3 ms | 2.5 ms |
| 2026-11-10 | shafts gathered round the sun and faded under a high sun | grey sky at 9:00 and noon | blue |
| 2026-11-10 | trace + fill replace the copied blocks | 199 ms, blocky | 103 ms, per-pixel texture |
| 2026-11-10 | still frames at stride 2, 8 samples | 425 ms a pass, 16 passes | about 200 ms a pass, 8 passes |

## 9. Source

`games/blockland/src/app/mc_session.axle` (`pass`, `accumulate`, `stream`, `show`),
`mc_frame.axle` (`runRange` and every stage), `src/render/pathlight/pathlight_shaft.axle`.
