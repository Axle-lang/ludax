# 3.6 The sky

[Handbook](../README.md) · previous: [3.5 Shading](05-shading.md) · next: [3.7 Accumulation](07-accumulation.md)

## 1. Contract

`LumenSky` (`src/render/pathlight/pathlight_sky.axle`) is the sky of one moment of the day.

| Call | Returns | Cost | Smooth? |
|---|---|---|---|
| `view(d, eye)` | everything the eye sees along `d` | 114 ns | no |
| `veil(d, eye)` | the radiance map and the clouds over it, and `clear`, the share of the bodies the clouds let through | about 95 ns | **yes** |
| `bodies(d)` | the sun's and moon's discs and the stars | 2 to 15 ns | no |
| `base(d)` | the radiance map alone | 20 ns | yes |
| `prefiltered(d, r)` | the map as a surface of roughness `r` reflects it | 20 to 58 ns | yes |
| `haze(d)` | the colour distant things dissolve into | 47 ns | yes |
| `dome.irradiance(n)` | the cosine-weighted sky on a surface facing `n` | 0.4 ns | yes |

Identity: `view(d) = veil(d).colour + bodies(d) * veil(d).clear` ([1.1](../concepts/01-smooth-and-sharp.md) §4.2).

## 2. The radiance grid

### 2.1 What it holds

A latitude-longitude picture of the sky's radiance without sun disc, moon, stars or clouds: 128 cells round the
azimuth (it wraps), 64 from nadir to zenith (it is clamped), three `f32` a cell. Each cell is a single-scattering
integral through the atmosphere (`src/render/light/light_sky.axle`), 0.16 ms a direction, 1.3 s for the grid on one
thread: it is **baked**, not evaluated per pixel. Two blurred copies (32 x 16, 8 x 4) serve rough reflections.

### 2.2 Where a direction falls

```
u = atan2Quick(d_x, d_z) / (2 pi)        wrapped into 0..1
v = asinQuick(d_y) / pi + 0.5
```

### 2.3 Reading it (`SkyGrid.look`)

Linear round the azimuth, Catmull-Rom up the elevation:

```
f_x = u W - 0.5,  x0 = floor(f_x),  t_x = f_x - x0          columns x0 and x0 + 1, wrapped by comparison
f_y = clamp(v H - 0.5, 0, H - 1),  y0 = floor(f_y),  t = f_y - y0      rows y0 - 1 .. y0 + 2, clamped

w_0 = (-t^3 + 2 t^2 - t) / 2
w_1 = (3 t^3 - 5 t^2 + 2) / 2
w_2 = (-3 t^3 + 4 t^2 + t) / 2
w_3 = (t^3 - t^2) / 2

value = max(0, sum_{j=0..3} w_j [ (1 - t_x) cell(x0, y_j) + t_x cell(x0 + 1, y_j) ])
```

**Why cubic.** The sky's gradient is steep near the horizon. A linear blend between rows has a kink at every row:
one every 2.8°, about 25 pixels. On a smooth gradient the eye sees those kinks as bands. Catmull-Rom has a continuous
first derivative through every row. The `max(0, ...)` removes the small undershoot a cubic can make.

Eight cells, 24 loads, each channel one sum of eight products.

## 3. The cloud deck

A plane at height 150, seen from a fixed eye height of 24 so that flying up does not bring it closer.

```
reach  = (150 - 24) / d_y                      no cloud when d_y < 0.02
(p_x, p_z) = eye_xz + d_xz * reach
cover  = smoothstep(0.5, 0.78, fbm5(0.011 p_x + 0.012 t, 0.011 p_z + 0.004 t))
thick  = saturate(cover(p + 14 sunDir_xz) - cover + 0.55)
lit    = [ sunIrr / pi * saturate(3 sunY) * (0.25 + 0.9 (1 - thick))
         + moonIrr / pi * saturate(3 moonY) * 0.5
         + zenith ] * (0.97, 0.97, 1)
alpha  = cover * saturate(6 d_y) * 0.92
```

`fbm5` is five octaves of value noise, each twice as fine (x 2.03) and half as strong. The second lookup, 14 blocks
toward the sun, makes a cloud dark where it is thick on the sun's side and bright at the edge that faces it.

**Bandwidth.** The finest octave has a period of `1 / (0.011 * 2.03^4) = 5.4` blocks. Overhead the deck is 126
blocks away and a pixel is `126 * 0.0017 = 0.21` block, so that period is 25 pixels. Lower in the sky the deck is
farther and its detail finer on screen, but `alpha` fades it out (`saturate(6 d_y)`). This is why the veil can be
sampled every 4 pixels.

### 3.1 The deck averaged over a sample (2026-11-11)

One sample of the sky covers `across = reach * 0.0068 / dir.y` blocks of the deck (`reach = (150 - 24) / dir.y`): its
angle times the distance, stretched by the slant. Near the horizon that is more than a cloud, and the plain cover was
one sample white and the next blue: a horizon that sizzled with every move. `lnFbm2Soft` replaces by its mean every
layer of the noise whose wavelength is under `2 across`, and in part those under `4 across`:

```
keep_o = saturate(wavelength_o / (2 across) - 1)          wavelength_o = 91 / 2.03^o blocks
n = sum_o a_o (keep_o v_o + (1 - keep_o) / 2) / sum_o a_o
```

Overhead (`across` under a block) all five layers are kept; at 17 degrees of elevation two; at 11.5 one; under 7.9
none. This is the cover of the averaged noise, not the average of the cover: the mean of the noise, 0.5, is exactly
the threshold of a cloud, so where no layer is kept there is no cloud at all. Far clouds thin out and vanish
instead of flickering; a deck that kept its mean cover there would need that mean measured and blended in.

The sample's angle is `CloudLight.sample` (default 0.0068 rad: four pixels of a 720-line picture, the spacing of a
picture that samples its sky sparsely). A renderer that reads the sky for every pixel should give one pixel's angle,
or its clouds are averaged four times more than it needs. Measured on two consecutive frames
of a slow turn, sky near the horizon: mean difference 0.65 levels to 0.19.

In a rippled mirror (`LumenSky.mirrored`, [3.10](10-water.md)) the deck fades out altogether under 17 degrees.

## 4. Quick trigonometry

`atan2Quick` and `asinQuick` (`src/core/math/trig.axle`).

```
atan(q) ≈ q (a1 + a3 q^2 + a5 q^4 + a7 q^6 + a9 q^8)        for 0 <= q <= 1
a1 = 0.9998660, a3 = -0.3302995, a5 = 0.1801410, a7 = -0.0851330, a9 = 0.0208351
```

(Abramowitz and Stegun 4.4.47; error below `1e-5` radian.) The rest is folding:

```
q = min(|x|, |y|) / max(|x|, |y|)
a = atan(q);   if |y| > |x|: a = pi/2 - a;   if x < 0: a = pi - a;   if y < 0: a = -a
asinQuick(s) = atan2Quick(s, sqrt(1 - s^2))
```

| | Exact (`atan2`) | Quick |
|---|---|---|
| Arithmetic | `f64`, minimax with argument reduction | `f32`, one division, five multiplications |
| Error | 1.3e-7 | 2e-5 (checked by `tests/src/math_trig.axle`) |
| Use | anything that integrates or accumulates | a table lookup by direction |

`1e-5` radian is 1/5000 of a grid cell. Both are deterministic: only IEEE additions, multiplications and divisions.

## 5. The bodies

```
sun:   if d . sunDir > cos(0.012):  sunIrr * scale * smoothstep(limit, limit + 0.00002, d . sunDir)
moon:  if d . moonDir > cos(0.017): moonIrr * (1 - seas - craters) / (pi sin^2(0.017))       two value-noise lookups
stars: cell = floor(260 d);  h = hash(cell);  a star when h > 0.9975
       brightness k^2 (0.75 + 0.25 sin(3 t + 40 warm)),  k = (h - 0.9975) / 0.0025
```

A star is one direction cell, so it is one or two pixels: it must be evaluated per pixel and must not be averaged
with a reprojected history ([3.7](07-accumulation.md) §4).

## 6. Following the clock

| Quantity | Updated | By |
|---|---|---|
| Sun and moon directions, irradiances, `night` | every game tick | `glide`, on the calling thread: closed-form |
| Radiance grid, its two blurs, the dome's SH9 | when a background bake finishes | `SkyBaker`: a thread, a gate, two channels |

`glide(t)` asks the baker for the grid of time `t` if it is idle, and swaps in a finished one. The frame never waits.
Before, the grid was recomputed on the tick: 365 ms, every 0.85 s.

## 7. Complexity

| | Time | Memory |
|---|---|---|
| Bake of the grid | `128 * 64` integrals: 1.3 s on one thread, in the background | 98 KB + 6 KB + 0.4 KB |
| `look` | `O(1)`: 24 loads | — |
| `veil` | one `look`, two `fbm5` | — |
| A sky pixel, filled | ray or skyline test, a bilinear blend of 4 samples, `bodies` | 4 floats a sample |

## 8. Observations

- Replacing the exact trigonometry by the quick one saved 10 ns of 68: the lookup itself, not the angle, is the
  cost. Rewriting `look` in scalars changed nothing either: it is 24 bounds-checked loads and that is its price.
  The gain came from **calling it less** (sparse veil), not from making it faster.
- A sky pixel cost as much as a terrain pixel (140 ns) before the veil was shared.
- The Axle benchmark `bicubic_sample` (`axle/tests/bench/game_numerics`) measures this very shape: 942 ms in Axle
  against 313 ms in C. A compiler that removes the provable bounds checks would speed `look` up without touching it.

## 9. History

| Date | Change |
|---|---|
| 2026-11-09 | `SkyBaker` and `glide`: the grid is baked in the background |
| 2026-11-10 | `atan2Quick`, `asinQuick`; `look` in scalars, wrap without a remainder |
| 2026-11-10 | `veil` / `bodies` split; `CloudLayer` returned apart from the blend |

## 10. Source

`src/render/pathlight/pathlight_sky.axle`, `pathlight_skygrid.axle`, `pathlight_cloud.axle`,
`pathlight_celestial.axle`, `pathlight_noise.axle`; `src/core/math/trig.axle`; `src/render/light/light_sky.axle`.
