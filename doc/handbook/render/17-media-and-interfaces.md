# 3.17 Media, interfaces, immersion and thin surfaces

## 1. Contract

What light does in and at the boundary of a medium is the engine's, once, for every renderer
(`src/render/lux/medium`, `src/render/lux/look/lux_thin.axle`). A program traces the rays the library asks for through
its own world; the library plans and combines. dusk's water, its view from under the surface and its portal run on it.

| Module | Holds |
|---|---|
| `lux_medium` | `LuxMedium` (absorption, scattering, index); `luxMediumTransmit` (Beer-Lambert), `luxMediumGlow` / `luxMediumGlowKept` (single scattering), `luxMediumSource` (the calibrated source), `luxMediumSegment`; `luxSchlick`, `luxRefract` / `luxRefractF0` (Snell, total internal reflection) |
| `lux_interface` | a rough boundary seen from the lighter side: `LuxFluidQuality` (every cost/quality number), `LuxMicrosurface` (resolved normal, unresolved variance), `luxPlaneFootprint`, `luxReflectAbove`, `luxViewFresnel`, `luxMicroRoughness`, `luxSkyBlur`, `luxFresnelMix` |
| `lux_immersion` | the eye inside a medium: `luxBoundaryDistance`, `luxExit` (Snell's window, the underside's mirror), `luxAcrossBoundary`, `luxDepthSource`; light reaching inside: `luxSunInside` (once a frame), `luxSunPath` |
| `lux_thin` | a thin perforated surface: `luxFaceAxes`, `luxThinOnward` (the bent continuing ray), `luxThinSeen` (tint and emission) |

The ocean's surface (FFT, cascades, footprint filtering) lives in `src/render/lux/fluid` (formerly `lux/water`).

## 2. Why

The water's mathematics had grown inside dusk's worker (650 lines: footprint, microsurface, the reflection's floor,
the sky's blur, Snell's window, Beer-Lambert, the calibrated glow, the portal's thin surface). Another program (blockland, a
lava lake, ice, a fog bank with a top) would have had to copy it. Each piece is now a function of values, with its
budget in `LuxFluidQuality`, and the worker went from 653 to 511 lines of tracing (on 2026-11-25).

## 3. Mathematics

As before, unchanged to the bit (the dusk selftest's three pinned fingerprints, the picture, the view under the water
and the upscaled picture, and the engine's 78 `regress_*` checks held through every step):

```
footprint    a = t θ_px (1 + depth),  along = a / max(facing, graze)            facing = -d_y above, d_y below
micro        n = normalize(-s_x, 1, -s_z),  u = sat(lost / max(σ²_total, floor)),  r = lost^(1/4) (0 without slopes)
reflect      r = reflect(d, n), held at r_y ≥ max(riseShare · (-d_y), riseMin)
fresnel      F = f0 + (1 - f0)(1 - max(-n·d, 0.001))^5
sky          lerp(traced, sky_prefiltered(r), u)      only for a reflection that reached the sky
mix          F · reflection + (1 - F) · transmitted
medium       T(d) L + (σ_s / σ_t)(1 - T(d)) J,  J = deep σ_t / σ_s,  J(depth) = J T(depth)
exit         t = refract(d, -n, n_medium, 1); total → underside; else lerp(beyond, underside, F)
thin         d' = normalize(d + b_u û + b_v v̂),  L = tint · L(d') + emit
```

## 4. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| 2026-11-25 | water optics → `LuxMedium` (any medium), interface, immersion, thin surfaces in the engine; `lux/water` → `lux/fluid`; `Sheet` → `Thin`; dusk's worker reduced to tracing | pinned fingerprints unchanged; worker 653 → 511 lines | yes |
| 2026-11-25 | the upscaler's policy (`LuxUpscalePolicy`) and motion writer (`luxMotionWrite`), sprites (`luxDrawSprites`), the particles' fixed-tick clock (`PtcClock`), the window's sizes (`luxShownSize`, `luxComputedSize`, `luxStartScale`) moved into the engine | pinned fingerprints unchanged | yes |
