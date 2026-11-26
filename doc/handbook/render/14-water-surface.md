# 3.14 The water surface: a wind-driven sea without a pattern

[Handbook](../README.md) · previous: [3.13 Dusk](13-dusk.md) · next: [4.1 The job pool](../engine/01-job-pool.md)

## 1. Contract

`LuxOcean` (`src/render/lux/fluid/lux_ocean.axle`) gives the slope of a water surface raised by a wind, at any world
point and time, as a pixel of a given footprint can see it.

- **In**: a `LuxWind` (speed m/s, direction, spreading, energy kept against the wind, shelter, fetch m) and a seed;
  each frame the animation time.
- **Out**: `sample(x, z, footprint)`: the slopes `dh/dx`, `dh/dz`, and `lost`, the slope variance of the waves too
  small for the footprint.
- **Guarantees**
  1. The same wind, seed and time give the same bits on every machine and with any number of threads (deterministic
     `sin`, `cos`, `log2`, a seeded `Pcg32`, a fixed-order FFT).
  2. The summed slope variance of the surface is Cox and Munk's for the wind, times `shelter`.
  3. No visible period: the three cascades have incommensurate sizes and angles, the finest is modulated by a
     non-repeating-at-world-scale gust field.
  4. A wave shorter than the footprint is faded, never aliased; what it would have added is reported in `lost`.
  5. Memory 0.4 MB; an update 0.26 ms a frame on one thread; a sample 46 ns.

## 2. Why

The water inherited from lumen was three fixed cosine swells plus one octave of value noise: visible stripes, the same
on every patch, and a fine ripple that sparkled into noise in the distance ("reflections from hell" was a visitor's
word for it). The owner asked for water that is noisy, answers the wind, and shows no repeating pattern.

## 3. Mathematics

### 3.1 The surface as a sum of waves (Tessendorf 2001)

On a grid of `N x N` points over a square of side `L`, with wave vectors `k = (2π n / L, 2π m / L)`,
`n, m ∈ [-N/2, N/2)`:

```
h(x, t) = Σ_k ĥ(k, t) e^{i k·x}
ĥ(k, t) = ĥ0(k) e^{iω(k)t} + conj(ĥ0(-k)) e^{-iω(k)t}         ω(k) = sqrt(g |k|)  (deep water)
ĥ0(k)   = (ξ_r + i ξ_i) sqrt(P(k) / 2)                          ξ ~ N(0, 1), Box-Muller from a seeded Pcg32
```

The second term makes `ĥ(-k, t) = conj(ĥ(k, t))`, so `h` is real. The slopes are `∂h/∂x = Σ i k_x ĥ e^{ik·x}` and
`∂h/∂z = Σ i k_z ĥ e^{ik·x}`; both are real, so they are packed into one complex field
`S = i k_x ĥ + i (i k_z ĥ)` whose inverse transform has `∂h/∂x` as real part and `∂h/∂z` as imaginary part: one
transform for both slopes. With `ĥ = h_r + i h_i`:

```
S_r = -k_x h_i - k_z h_r          S_i = k_x h_r - k_z h_i
```

### 3.2 The spectrum: fetch-limited JONSWAP

Phillips's spectrum `P(k) ∝ exp(-1/(kL)²)/k⁴` (the usual choice) models a fully developed sea; with `L = V²/g` a strong
wind moves its energy to long swells. Over a bay the wind blows across a few hundred metres (the fetch `F`) and raises
short waves. JONSWAP (Hasselmann et al. 1973), measured on fetch-limited seas:

```
S(ω)  = ω^-5 exp(-5/4 (ω_p/ω)^4) γ^r            r = exp(-(ω - ω_p)² / (2 σ² ω_p²)),  γ = 3.3,  σ = 0.07 | 0.09
ω_p   = 22 (g² / (U F))^(1/3)                   the peak: 7.5 rad/s, a wave of about 1.1 m, for U = 12 m/s, F = 300 m
P(k)  = S(ω) (dω/dk) / k · |k̂·ŵ|^p · exp(-(k l)²)    dω/dk = g / (2ω); p = 2; l = 0.08 m
```

and `P` is multiplied by `against = 0.07` for waves running against the wind. The constant in front of `S` does not
matter: §3.3 sets the scale.

### 3.3 The amplitude from Cox and Munk

Cox and Munk (1954) measured, from photographs of the sun's glitter, the mean square slope of the sea against wind
speed: `σ² = 0.003 + 0.00512 U` (U in m/s at 12.5 m). With `P` unscaled, the expected slope variance of the surface is

```
σ²_raw = Σ_k k² (P(k) + P(-k))          (E|ĥ0|² = P/2 per part; ĥ(k, t) draws on k and -k)
```

so every `ĥ0` is multiplied by `sqrt(shelter σ²_CM / σ²_raw)`. `shelter` (0.6 by default) stands for the shorter fetch
of a bay against the open sea Cox and Munk measured.

### 3.4 Cascades and why the sum does not repeat

Three grids of 64², `L = 97.3, 23.9, 6.1 m`, keep the wave numbers `[0, 1)`, `[1, 4)` and `[4, ∞)` rad/m: each band
belongs to exactly one grid, so no energy is counted twice. One grid repeats every `L`; a sum of grids repeats only
at a common multiple of their periods (Dupuy and Bruneton 2012), and these sizes have no small common multiple. Each
grid is also turned (0°, 31°, 67°): its spectrum is built in the turned frame, with the wind at `angle - turn`, and its
slopes turned back: `(s_x, s_z) = (s_u cos θ - s_v sin θ, s_u sin θ + s_v cos θ)`. The repeat lattices then share no
direction either.

### 3.5 The gust field

The finest band is multiplied by `g(x, z, t) = 1 + 1.1 (fbm(x', z') - 0.5)`, `fbm` three octaves of value noise at
0.018 cycles a metre, `(x', z') = (x, z) - ŵ · 0.35 U t`: patches of rougher and calmer water that drift downwind. It is
baked once into a 128 x 128 table of 8 m texels (period 1 024 m), seamless by the classic blend of the noise with its
copies one period away:

```
T(x, z) = f(x, z)(1-a)(1-b) + f(x-P, z) a(1-b) + f(x, z-P)(1-a) b + f(x-P, z-P) a b,     a = x/P, b = z/P
```

whose values on opposite edges agree. One bilinear read replaces a three-octave noise evaluation (59 → 46 ns a sample).

### 3.6 The footprint, the fade, and what the unresolved waves do to the reflection

**The footprint.** A pixel at distance `t` covers `a = t · θ_px` metres across the view (`θ_px` the angle of a pixel;
a mirror ray of depth `d` multiplies it by `1 + d`) and `a / cos v` along it, where `cos v = -d_y` (floored at 0.08)
is the cosine of the view against the vertical: at a grazing angle the pixel's patch of water is a long ellipse. The
fade uses the side of the square of the same area, the geometric mean:

```
f = sqrt(a · a / cos v) = a / sqrt(cos v)
```

**The fade.** A cascade of grid spacing `Δ = L / N` cannot show its shortest waves once `f > Δ`. It is kept with
weight

```
w = 1 - smoothstep(1, 4, f / Δ)              whole up to Δ, gone at 4Δ: two octaves
```

and `(1 - w²) σ²_c` is added to `lost`. The cascades' sizes step by about four (97.3, 23.9, 6.1 m): each starts to fade
where the next coarser one is still whole, so together they fall off as one continuous slope.

**The unresolved waves.** They are not gone: a far pixel sees thousands of them, which blur and stretch the
reflection. By the central limit theorem their slopes are Gaussian with variance `lost` (Bruneton, Neyret and
Holzschuch 2010): a Beckmann roughness `α² = lost`, a perceptual roughness `r = lost^(1/4)`. The reflection is traced
along `reflect(d, n_resolved)`; where it reaches the sky, the sky it reads is blurred by those waves:

```
u        = lost / σ²_total                                   the unresolved share, 0 near, toward 1 far away
mirror   = traced                                            the ray struck the world
mirror   = lerp(traced, sky_prefiltered(r), u)               the ray reached the sky
```

The blurred reflection of a building stays a building: only the sky is replaced by its blurred self. The reflected
direction is held above the water at no less than half the rise of the flat reflection, `r_y ≥ max(0.5 (-d_y), 0.002)`.

### 3.6.1 Four mistakes of the first version, found from the owner's pictures (2026-11-24)

| Seen | Cause | Why it happened | Fix |
|---|---|---|---|
| Three distinguishable bands of water with the distance | each cascade faded over one octave (`f` from `Δ` to `2Δ`) while their sizes step by four: three separate fade zones, three changes of look | the fade width was chosen for one grid, not for the set | fade over two octaves (`Δ` to `4Δ`): the zones abut and the sum falls off continuously |
| Distant water a flat mirror | the footprint was the long side of the ellipse, `a / cos v`, about 8 m at 200 m for a grazing view, where the short side is 0.4 m: every cascade was faded out | the footprint along the view was taken as the footprint | the geometric mean `a / sqrt(cos v)`: the coarse waves stay at a distance, stretching the reflections |
| The shore floats above its reflection, a band of sky between them | every reflection was blended toward the blurred sky by the unresolved share, which is highest on the farthest water, the water at the foot of the shore: the reflection of the shore's base was replaced by sky | "the unresolved waves blur the reflection" was implemented as "they replace it by the sky" | only a reflection that reached the sky is blurred toward the prefiltered sky; one that struck the world is kept |
| The waterline missing from distant reflections (inherited from lumen) | a wavy reflection tilted toward the water was lifted to a fixed rise `r_y = 0.02`; at grazing views the flat reflection rises less than that, so the lifted rays passed over the foot of what they mirror | a floor meant to stop rays from striking the water was fixed in absolute terms | the floor is half the rise of the flat reflection (and at least 0.002) |

Measured after the fixes: the trace costs about 7 % more on viewpoint 1 (one thread), because distant water traces its
mirror again instead of reading the sky; the pictures compared before and after are in the session notes of
2026-11-24 (shore attached to its reflection, lit windows stretched into vertical streaks, no bands).

*Withdrawn earlier the same day:* drawing the unresolved slopes at random per pixel and frame, to be averaged by the
frame's history. With the water moving every frame the history of a water pixel is short and the draws never
converged: visible grain over all distant water. And blending every reflection toward the sky by distance (the third
row above).

### 3.6.2 Anisotropic filtering of the waves

A pixel's patch of water is an ellipse `a` wide and `a / cos v` long, its long axis the view's direction on the water.
Two single-sample choices both failed: fading the cascades by the long axis flattened distant water into a mirror
(§3.6.1), and fading them by the geometric mean kept waves the long axis could not resolve, which aliased into a moiré
that slid across the water as the camera turned (reported 2026-11-24: "the wave pattern moves beyond the water"). The
ocean now filters as a texture unit filters a surface seen edge on:

```
span    = max(along - across, 0)                 what the short axis does not already cover
fade by max(across, span / 4)                    each tap resolves what its share of the span can
slope   = mean of four taps at offsets ((k + 1/2)/4 - 1/2) · span along (dirX, dirZ)
lost    = mean of the taps' lost + (mean of their squared slopes - squared mean slope)
```

Four taps always, so nothing in the filter is a whole number that can step with the view's angle: a count that went from
one tap to two moved the sampling points at once, a ring of changing ripples round the camera. The averaging flattens the
slope; the variance it removes stays in `lost`, so the pixel's total slope variance is the taps' own.

The axis is the direction from the eye to the point, projected on the water: it depends on where the eye is, not on
where it looks, so turning the camera does not move the filter. Cost: four samples (about 47 ns each), the cascades the fade removes not read.

### 3.8 Light through the water

What the eye sees through the surface (`belowSurface` in `examples/rendering/dusk/src/render/worker.axle`), with the
functions of `src/render/lux/medium/lux_medium.axle`:

```
t        = refract(d, n, 1, 1.333)                                Snell; Fresnel F with the incident cosine
bed      = the first solid along t (water passed as air), at distance s
L_below  = L_bed · T(s)  +  (σ_s/σ_t)(1 - e^{-σ_t s}) J            Beer-Lambert to the eye, plus single scattering
T(x)     = exp(-(σ_a + σ_s) x)                                    σ_a = (0.40, 0.07, 0.05), σ_s = (0.05, 0.06, 0.07) /m
J        = deep · σ_t / σ_s                                       water of no bottom shows the sky's `deep` colour
colour   = F · mirror + (1 - F) · L_below
```

The medium: pure water's absorption (Pope and Fry 1997, red first) with a little dissolved matter, and the scattering of
a clear bay; σ_t is 0.13 /m in green and 0.12 /m in blue, about eight metres to 1/e. A first choice of three times the
scattering (σ_t 0.22 /m) left an eye under water seeing a flat wall of colour past four metres.

**The bed's light** (`lumenImmersedSurface` in `examples/rendering/dusk/src/light/shade.axle`). The baked volumes
carry the sun in a straight line and dim it by the water's per-cell opacities. At dusk the sun is a few degrees up: its
straight path to a bed six metres down crosses dozens of cells and arrives black. Measured on the bay at 17:38: the bed
received 0.001, against 0.0032 for the deep colour and about 0.2 for sand in full sun. The real sun refracts at the
surface to within 48.6° of the vertical. So a point under the surface is lit by

```
s_sun   = depth / cos θ_t                                         θ_t: the sun refracted into the water, ≤ 48.6°
E_sun   = E_⊙ · V(q) · (1 - F(θ_⊙)) · T(s_sun) · max(n·ŝ_t, 0) / π · caustic(x, z, t)
q       = the point where the refracted sun ray crosses the surface: V(q), the baked sun visibility read there, is the
          shade of the pier, the bridge, the city on the water (one volume lookup, no ray)
E_sky   = E_dome(up) · V_sky(above p) · (1 - 0.066) · T(depth) · (1/2 + n_y/2)      0.066: water's hemispherical Fresnel
E_lamps = the volume's flooded block light at p
```

The walk used to multiply a fixed transmittance per water cell crossed (0.45, 0.8, 0.92): the depth graded in steps,
one per block, and the shallows ended in a hard pale band. Now both terms are continuous in the distance; the shallows
grade from sand to turquoise to the deep colour.

### 3.9 The view from under the water

When the eye is in a water cell (`LumenEnv.inWater`), every camera ray goes to `immersedPrimary` (and `immersedView` for the bounces) instead of the walk:

```
hit      = the first solid along d (water passed as air), at t_hit
t_s      = (sea top - o_y) / d_y           for d_y > 0, the surface
J_eye    = J · T(depth of the eye)          the water scatters the light that reached it
if t_hit < t_s:   L = L_bed · T(t_hit) + glow(t_hit)
else:             n = the ocean's normal at the surface point (footprint-filtered as from above), facing down
                  out = refract(d, -n, 1.333, 1)
                  under = the view reflected back into the water (one bounce, then the depths' glow)
                  at_surface = out.total ? under : lerp(view through the surface, under, F)
                  L = at_surface · T(t_s) + glow(t_s)
```

Snell's window follows: within asin(1/1.333) = 48.6° of the vertical the world above shows through, compressed and
rippled; outside it the surface is a mirror of the water below (total internal reflection), and the window's rim, where
F rises to 1, is bright. The camera's pixels under water are all water to the temporal stages (their light moves with
the waves above). Cost: a short walk under water (64 m at most) plus, for rays that reach the surface, one ray above
it and one reflected below.

### 3.7 The transform

`LuxFft` is radix-2 Cooley-Tukey in place: a bit-reversal permutation, then `log2 N` passes of `N/2` butterflies,
by rows then by columns. Work `O(N² log N)`: for `N = 64`, `2 · 64 · 6 · 32 = 24 576` butterflies a grid.

## 4. Algorithm

At construction: three cascades draw `ĥ0` and precompute `ω`, `k_x`, `k_z`; the common scale is found (§3.3); the gust
table is baked. Each frame whose time changed (`LumenEnv.setTime`): each cascade writes `S(k, t)` and transforms it
in place into its slope arrays. Each water pixel (`examples/rendering/dusk/src/render/worker.axle`, `fluidSurface`):
`sampleFootprint(x, z, footprint)`, normal `normalize(-s_x, 1, -s_z)`.

## 5. Complexity

| Part | Time | Memory |
|---|---|---|
| construction | `O(3 N²)` draws + 16 384 noise evaluations | — |
| update a frame | `3 (N² trig + N² log N butterflies)`: 0.25 ms measured | 3 cascades × 7 × 64² floats = 344 KB |
| sample | 3 turned bilinear reads + 1 gust read: 46 ns measured | gust table 64 KB |

## 6. Observations

- Phillips's spectrum with Cox-Munk scaling made a 12 m/s wind look calmer than 2 m/s over the bay: the energy went to
  long, slow swells. JONSWAP with a 300 m fetch gives the right order: rougher, shorter, choppier as the wind rises.
- The baked gust table took 13 ns off a sample (59 → 46 ns).
- The inherited water traced its mirror ray from a sparkling normal; with the footprint fade, distant reflections are
  smooth instead of speckled.

## 6.1 Seeing what the water computes

`dusk --debug-water MODE` paints the water with one number of its rendering as a flat colour (`lux_water_debug`), with
the exposure fixed and no bloom or fog: `normal` (the resolved normal), `unresolved` (the share of the waves the pixel
cannot resolve, blue to red), `fresnel`, `blocked` (the share of the reflection that strikes the next wave), `span` (how far the
taps spread along the footprint, in short axes), `cascades` (how much of each cascade is kept: coarse red, middle green,
fine blue) and `checker` (a world-anchored checker bent by the slope, so the waves show as a lens). A ring where the
water changes look with the distance is a ring of a colour in `taps` or `cascades`.

`dusk --features LIST` keeps only the named parts of the picture (`waves,reflection`), or drops some (`-reflection,-fog`):
`lamps`, `bounce`, `shafts`, `bloom`, `fog`, `waves`, `reflection`, `transmission`, `sun`, `sky`, `flood` (the lamps' baked
light) and `emission`. With the reflection and the transmission both off, the water shows its body alone (its deep colour
shaded by the slope towards the sun), and only to the eye: nothing reflects it.

## 7. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| (lumen) | three cosine swells + one octave of value noise | stripes, sparkle at distance | replaced |
| 2026-11-24 | Tessendorf FFT, Phillips, 3 cascades, Cox-Munk scale, gust fbm, footprint fade | update 0.26 ms, sample 59 ns; strong wind looked calm | spectrum replaced |
| 2026-11-24 | JONSWAP with fetch | wind order right (2, 6, 12 m/s) | yes |
| 2026-11-24 | cascades turned 0/31/67°, gust baked into a seamless table, faded cascades skipped | sample 46 ns | yes |
| 2026-11-24 | unresolved waves drawn at random, averaged over frames | grain over far water while it moves | **withdrawn** |
| 2026-11-24 | unresolved waves as roughness: every reflection blended toward the prefiltered sky by the unresolved share | clean in a single pass, but three bands, a mirror-flat distance and floating shores | **replaced** |
| 2026-11-24 | footprint as the geometric mean, two-octave fade, sky-only blur, reflection floor relative to the flat reflection (§3.6.1) | shores attached to their reflections, no bands, coarse waves kept at a distance; trace +7 % | yes |
| 2026-11-24 | anisotropic filtering along the view (§3.6.2) | no moiré sliding as the camera turns (to be confirmed in the window) | yes |
| 2026-11-24 | light through the water: continuous Beer-Lambert both ways, single scattering, Snell and Fresnel from `lux_medium` (§3.8) | shallows grade to the deep colour, no pale band | yes |
| 2026-11-24 | the bed lit by the baked light *and* dimmed along the refracted sun path | the water's absorption counted twice; beds black under 3 m | **replaced** |
| 2026-11-24 | the bed lit by the refracted sun, Fresnel transmission, Beer-Lambert along its path, caustics; shade read where the sun crosses the surface (§3.8) | bed at 6 m: 0.001 → about 0.02, visible from under the water | yes |
| 2026-11-24 | the view from under the water: Snell's window, total internal reflection, glow scaled by the eye's depth (§3.9); a clearer medium (σ_t 0.22 → 0.13 /m in green) | the bed seen at 10 to 20 m | yes |
| 2026-11-24 | the clock runs whether the camera moves or not; water keeps 3 to 16 frames of history by its unresolved share, the rest of the picture accumulates as still | waves move with the mouse at rest | yes |
| 2026-11-26 | the reflectance is the exact unpolarised Fresnel, not Schlick (`luxViewFresnel`) | 0.722 against 0.769 at 3° above the surface; the pins of the picture, the underwater view and the upscaled picture moved | yes |
| 2026-11-26 | a reflection a wave tilts to skim the water takes the water's colour for the share that would strike the next crest (`luxReflectOpen`, quadratic in its rise over the floor), where the lifted ray alone gave it the sky's | water-level view (shot 2 at 9.4 m, 640 × 360): lower half's mean luminance 58.41 → 55.17; no bright patch left fixed under the moving waves; the view from under the water differs on 2 341 of 57 600 pixels of a fresh session, 51 by more than 8 levels, all on the rim of Snell's window | yes |
| 2026-11-26 | four taps always, spread over what the short axis does not cover (`luxTapPlan`), the slope variance their average removes added to the unresolved share; before, a whole number of taps (1 to 4) that jumped where the ratio of the footprint's axes crossed an integer | sweep of the ratio 1 to 5: the largest step of the spread 0.0005 m, of the slope 0.00013; the old fade jumped by 0.297 m; not yet confirmed by eye in the window | yes |

## 8. Source

- `src/render/lux/fluid/lux_fft.axle`: `LuxFft`.
- `src/render/lux/fluid/lux_ocean.axle`: `LuxWind`, `LuxWaterSample`, `LuxOcean`, the cascades, JONSWAP, the gust table.
- `examples/rendering/dusk/src/render/env.axle` (`ocean`, `setWind`, `setTime`),
  `examples/rendering/dusk/src/render/worker.axle` (`fluidSurface`, the footprint), `--wind` and `--wind-dir` in
  `examples/rendering/dusk/src/app/options.axle`.
- Tests: `tests/src/lux_ocean.axle` (the transform against the plain sum, the inverse, the Cox-Munk scale, the wind's
  direction, no period at 97.3 m, the footprint fade, determinism, the time; a `measured:` line).
