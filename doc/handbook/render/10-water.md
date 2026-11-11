# 3.10 Water

[Handbook](../README.md) · previous: [3.9 Baked shadows](09-baked-shadows.md) · next: [3.11 The face cache](11-face-cache.md)

## 1. Contract

Water is the one surface whose light is the view's: a mirror and a window, rippled. The frame's rule
([1.1](../concepts/01-smooth-and-sharp.md)) still holds: what is sharp (the ripple, the Fresnel term, where the
surface is) is worked out for every pixel; what is smooth (what lies below the surface, what the mirror would show of
the land) is taken from the samples.

- **Seen from above** (`McPixelWorker.wet`): the pixel's own ripple and Fresnel, the sky in the mirror, and the
  light its block's water samples found below the surface.
- **Seen from below** (`wetUnder`): the pixel's own ripple decides whether it is inside Snell's window; the mirror
  and the window are its block's water samples'.
- **An eye under water** shares light between pixels exactly as in the air.
- **Guarantee**: no ray is traced for a water pixel that is not a sample.

## 2. Mathematics

### 2.1 The surface from above

```
n       = wave normal at the hit (three moving swells, calmed with distance)
cosI    = max(-n . d, 0.001)
F       = 0.02 + 0.98 (1 - cosI)^5                         Schlick, water against air
r       = reflect(d, n), held above the horizon (r.y >= 0.02)
colour  = F * mirror(r) + (1 - F) * below
```

`below` is the sample's: one refracted ray to the bed, its light, and the water's absorption along it.

### 2.2 The surface from below

```
cosI   = max(d . up, 0.001)                                up: the wave normal
k      = 1 - eta^2 (1 - cosI^2)                            eta = 1.3329
k <= 0:  total reflection: colour = mirror_below
else:    cosT = sqrt(k);  F = 0.02 + 0.98 (1 - cosT)^5
         colour = lerp(window, mirror_below, F)
```

Snell's window is the cone `k > 0`, about 49 degrees from the vertical. `mirror_below` (the bed reflected) and
`window` (the world above, refracted) are the samples'; when the sample was outside the window and the pixel is
inside, the window is the sky along the refracted direction.

### 2.3 The sky in a rippled mirror

`LumenSky.mirrored(dir, eye, spread)` replaces `view` for every ray that is not the camera's:

1. **The sun as a lobe.** Under one pixel the ripples tilt the mirror by more than the sun's disc is wide (0.27
   degrees), so the disc was met by one pixel in two. Its light is spread over a Gaussian lobe of width `spread`
   (0.07 rad) that carries the same irradiance `E`:

   ```
   L(theta) = E / (pi spread^2) * exp(-theta^2 / spread^2),     theta^2 ~ 2 (1 - dir . sunDir)
   integral of L over directions = E
   ```

   `exp(-x)` is `(1 - x/16)^16`, cut at `x = 7`. That polynomial, cut there, integrates to 0.9411 where the
   exponential gives 0.9991, so the lobe is multiplied by 17/16 to carry the whole irradiance (found in review: the
   reflected sun was 6 % dim). A width under 0.005 rad is taken as 0.005.

2. **Far clouds fade out.** Near the horizon the deck is a field of clouds smaller than a pixel of the mirror: one
   pixel white, the next blue (the "dotted" edge of every reflection). The deck's cover is scaled by
   `smoothstep(0.08, 0.3, dir.y)`: none of it under 4.6 degrees of elevation, all of it above 17.

### 2.4 Fog apart from the light

A sample's radiance is `C = keep * (albedo * E) + add`: `keep` is what the air or the water lets through, `add` what
it adds (the haze, the water's own colour), which owes nothing to the surface. Dividing all of `C` by the sample's
albedo and multiplying by the pixel's printed the texture of the bed on the water's colour (a grainy sea bed). So a
sample stores them apart:

```
lightGrid = (C - add) / albedo_sample
fogGrid   = add
pixel     = albedo_pixel * blend(lightGrid) + blend(fogGrid)
```

`add = fogUnder(0, z)`: `haze(d) * share` in the air, `deep * (1 - k)` under water.

### 2.5 Absorption and the reach of a ray

Under water a ray's light is scaled by `(k^2, k, exp(-0.03 z))` with `k = exp(-0.09 z)`. At 64 blocks that is
`(0.00001, 0.003, 0.15)`: nothing red or green is left and a seventh of the blue. A ray that starts in water is
followed for 64 blocks, not 400.

## 3. The walk through water

A ray in the air skips empty space ([3.2](02-visibility.md)); in water every cell is a fluid cell.

| Case | Before | Now |
|---|---|---|
| A cell of the fluid the ray is in, with the same fluid above it | the surface height was worked out (a lookup of the cell above through the view, a division) | nothing to meet: one comparison against the cached cell above |
| A cube of one fluid around the cell (the gap field, now also for fluids) | cell by cell | left in one move, all but its top layer, whose cells may have a surface |
| A section that is all one fluid | cell by cell | the same, 16 x 15 x 16 |
| A plant that grows in water, a waterlogged block | the ray forgot it was in water: the next water cell was a wall seen from the air, shaded as a surface with a reflection and a refraction | the cell is a cell of its fluid |

The last row was a bug as well as a cost: behind the first sea grass, the sea bed was a wall of water.

**The gap field for fluids.** A cell's cube is of "its own stuff": air with air, or one fluid with itself at any
level. In a cube of one fluid every cell but those of the top layer has the fluid above it, so it is full and has no
surface: the box a ray may leave in one move is the cube without its top layer (`2g+1` by `2g` by `2g+1`).

### 3.1 Water at rest

A picture at rest is not redrawn, so its water stood still with it. The stage `Ripple` redoes the water alone: for
every pixel whose history is water (an edge keeps the blend it settled to), the ripple of this moment at the point
the pixel's last sample met, over the light its block's sample found below the surface, and its share of the shafts
again. Nothing is traced. It runs at most 30 times a second, only with the eye in the air; water keeps no history
during the still frames either, since a mean of eight moments is no ripple.

Cost: 8.8 ms on 12 workers for a picture that is all sea, plus the display; nothing when no sample met water.

## 4. Complexity (1280 x 720 scaled from 640 x 360, one thread, eye under water in the open sea)

| View | Before | Now |
|---|---|---|
| Level | 464 ms | 97 ms |
| Up, at the surface | 553 ms | 64 ms |
| Down, at the bed | 370 ms | 84 ms |

On 12 workers at 1280 x 720, level: 335 ms to 86 ms. The sea from above, eye in the air: 43 to 36 ms.

What is left under water is the walk itself: 115 iterations a ray, 13 of them through the slow fluid path, because
the cubes stop at the faces of a section and most open water lies near one.

## 5. Observations

- Three guesses at "what costs 400 ns a ray under water" were wrong in a row (the surface height, the length of the
  ray, uniform sections). Counters in the loop settled it in one run: 115 iterations a ray. Count before changing.
- The dots along the reflections were not on the sample grid (their positions were evenly spread over the 16
  residues of `(x mod 4, y mod 4)`): they were content, far clouds, not an artefact of the stride.

## 6. Open

- Grey bands across sand seen from under water, one a block, reported and **not reproduced**.
- The surface seen from above still costs a sky lookup a pixel (the sea from above is 36 ms on 12 workers).
- No test yet for the fluid tracking through water plants, nor for the glide of [3.9](09-baked-shadows.md).

## 7. History

| Date | Change |
|---|---|
| 2026-11-10 | `wet`: a water pixel beside a water sample is shaded from its own ripple |
| 2026-11-11 | plain surfaces share light under water; `wetUnder`; the blocks' water samples blended, not the first corner's |
| 2026-11-11 | fluid cells skipped, fluid cubes in the gap field, uniform fluid sections, plants in water |
| 2026-11-11 | `mirrored`: the sun as a lobe, far clouds faded |
| 2026-11-11 | fog stored apart from the light |

## 8. Source

`games/blockland/src/app/mc_worker.axle` (`water`, `fromBelow`, `wet`, `wetUnder`, `settle`, `fogUnder`, `reach`),
`mc_frame.axle` (`fill`, `waterBlend`, `sharedLight`), `render/render_trace.axle` (the fluid branch of `trace`,
`hitFluid`), `render/render_view.axle` (`fillCache`, `cubeSide`), `src/render/pathlight/pathlight_sky.axle`
(`mirrored`).
