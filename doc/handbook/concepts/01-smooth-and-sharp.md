# 1.1 Smooth and sharp signals

[Handbook](../README.md) · next: [1.2 Determinism](02-determinism.md)

## 1. The idea

A picture is the product and the sum of several signals. Each has a **bandwidth**: the finest detail it can hold,
measured in pixels. Sampling theory says a signal whose finest period is `T` pixels is fully described by one sample
every `T / 2` pixels. So a signal that cannot change faster than a few pixels does not need to be computed at every
pixel: it can be sampled on a coarse grid and interpolated, and nothing is lost.

The rule the renderer is built on:

> **A smooth signal is sampled sparsely and interpolated; a sharp signal is computed for every pixel.**

The whole gain of a frame comes from sorting each signal into the right column, and the whole risk from sorting one
wrongly.

## 2. How to decide

For a signal `f`, ask three questions.

1. **What is its finest period on screen?** Find the smallest feature of its source and project it.
   A block is `514 / d` pixels wide at distance `d` blocks (720 rows, 70 degrees of view: `H / (2 tan 35°) = 514`).
2. **Does it have discontinuities?** An edge is infinitely sharp whatever its period elsewhere. A signal with edges
   can still be sampled sparsely **if the edges are known from a per-pixel signal** and interpolation never crosses
   them. This is what the plane identifier does for light (chapter [3.4](../render/04-sparse-light.md)).
3. **Is it linear in what varies?** Interpolation is exact for the linear part of a signal. A product `a(x) b(x)` of
   a smooth `a` and a sharp `b` is handled by interpolating `a` alone and multiplying by the exact `b`.

## 3. The table

| # | Signal | Finest period | Edges | Verdict | Where |
|---|---|---|---|---|---|
| 1 | Geometry (which surface a pixel sees) | 1 px | everywhere | every pixel | [3.2](../render/02-visibility.md) |
| 2 | Texture (albedo) | 1 texel = `32 / d` px | texel borders | every pixel | [3.2](../render/02-visibility.md) |
| 3 | Light on a plain surface | 1 cell = `514 / d` px | at plane changes only | every `s` px, bilinear inside a plane | [3.4](../render/04-sparse-light.md) |
| 4 | Sky gradient | a grid cell = 2.8° = 25 px | none | every `s` px | [3.6](../render/06-sky.md) |
| 5 | Cloud deck | finest octave 5.7 blocks = 27 px overhead | none (smoothstep) | every `s` px | [3.6](../render/06-sky.md) |
| 6 | Sun and moon discs | the edge | yes | every pixel | [3.6](../render/06-sky.md) |
| 7 | Stars | a point | yes | every pixel | [3.6](../render/06-sky.md) |
| 8 | Water ripple, Fresnel | a few px far away | none, but fast | every pixel | [3.5](../render/05-shading.md) |
| 9 | What lies under water | blurred by absorption | soft | once a sample | [3.5](../render/05-shading.md) |
| 10 | Light shafts | a glow | none | every 2 px | [3.1](../render/01-frame.md) |
| 11 | Bloom | a blur | none | half resolution and below | [3.8](../render/08-display.md) |

## 4. Decompositions used

Three signals were split so that their smooth part could be shared.

### 4.1 Radiance = light x albedo

For a matte surface the shaded radiance is `L = E a + S`, with `E` the incoming light, `a` the albedo and `S` a small
specular term. `E` is smooth (row 3), `a` is sharp (row 2). The frame stores `E ≈ L / a` at the samples, interpolates
it, and multiplies by the pixel's own `a`. The error is the specular term being treated as if it scaled with the
albedo, which for a rough dielectric is under 4 % of the light.

### 4.2 Sky = veil + bodies x clear

```
view(d) = lerp(backdrop(d) + bodies(d), cloud(d), c(d))
        = lerp(backdrop(d), cloud(d), c(d))  +  bodies(d) (1 - c(d))
        =            veil(d)                 +  bodies(d)  clear(d)
```

`veil` and `clear` are smooth (rows 4 and 5); `bodies` is sharp (rows 6 and 7). The identity is exact, so the only
error is the bilinear interpolation of `veil` and `clear`.

### 4.3 Water = ripple(pixel) x Fresnel(pixel) x mirror + below(sample)

The ripple normal and the Fresnel factor are evaluated for the pixel; the light refracted from the bed, which is
blurred by the water itself, is taken from the nearest sample.

## 5. What goes wrong when a signal is misfiled

| Mistake | Symptom seen | Fix |
|---|---|---|
| Texture copied from the sample to its block | "360p" look while moving | texture per pixel (2026-11-09) |
| Light **copied** to the block instead of interpolated | visible 3 x 3 squares in shadows | bilinear blend (2026-11-10) |
| The mip level of a cut-out texture tied to the stride | leaves change their holes when the camera moves | footprint fixed at one pixel |
| Water ripple taken from the sample | the sea in squares | ripple per pixel |
| Sky assumed between four sky samples, untraced | twigs against the sky vanish | every pixel traced or cleared by the skyline |
| Stars reprojected through the frame's history | stars drawn as streaks on a turn | the sky keeps no history |

## 6. Observations

- The stride is a quality knob only for the smooth signals. Going from `s = 2` to `s = 4` costs nothing visible on a
  face and saves `3/4` of the shading of the remaining samples.
- A signal can change column with distance: a leaf texel is 1 px at 32 blocks, so beyond that the albedo of foliage
  is undersampled even per pixel. That is aliasing, and only a still picture's jitter removes it.
- The plane identifier is what makes sparse light safe: it turns "interpolate light" into "interpolate light among
  samples of the same plane", so an edge can never be blurred.

## 7. Source

`games/blockland/src/app/mc_frame.axle` (`trace`, `fill`, `sharedLight`),
`src/render/pathlight/pathlight_sky.axle` (`veil`, `bodies`, `view`).
