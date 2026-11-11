# 3.5 Shading

[Handbook](../README.md) · previous: [3.4 Sparse light](04-sparse-light.md) · next: [3.6 The sky](06-sky.md)

## 1. Contract

`McPixelWorker.radiance(env, o, d, depth, primary) : Vec3` — the radiance arriving at `o` from direction `d`.

- **In**: a ray, the bounce depth (0 for the camera's ray, at most 2), the frame's environment.
- **Out**: linear radiance; for a primary ray also `gAlb`, `gPos`, `gSid`, `gBelow`, `gOpenSky`.
- **Guarantee**: no random number. The result is a function of the ray, the world and the time.

The surface formula is the engine's `lumenShadeCore` (`src/render/pathlight/pathlight_shade.axle`), shared with
`examples/rendering/lumen`; the game supplies the point and its light sample.

## 2. The light sample of a point

For a hit at `p` with normal `n`, the world is asked at `p + 0.5 n` (inside the air cell in front of the face).

| Term | From | Meaning |
|---|---|---|
| `sky` | the game's own sky-light flood (`McLight`), 0..15 through `0.8^(15 - level)` | how open the place is |
| `block` | the block-light flood, same curve | lamps |
| `access` | baked: 12 rays over the upper hemisphere, 40 blocks | the share of the sky dome the cell sees |
| `tint` | baked: the mean colour of what those rays hit | the bounce's colour |
| `sun`, `moon` | baked: 8 rays over the body's disc, 160 blocks | the share of the disc the cell sees: a soft shadow |
| `glow` | baked: the colour of the emitters in reach | coloured lamp light |

The baked terms are stored a cell at a time and read with a **trilinear blend over the shell cells** (air cells
beside a solid) among the eight round the point, renormalised by the weights present. `ok = false` when none of the
eight is baked: then `sun` is one shadow ray toward the centre of the disc (220 blocks), and `access = sky`.

A body's shadows are re-baked when it has moved by `acos(0.99997) = 0.44°`, nearest sections first, six a frame.

## 3. Mathematics: the surface

Notation: `n` normal, `v` toward the eye, `l` toward a light, `h = normalize(l + v)`, `a` albedo, `r` roughness,
`m` metalness, `alpha = max(r^2, alpha_min)`.

### 3.1 Material at this view (`lightPrepare`)

```
F0   = lerp(0.04, a, m)
(A, B) = dfg(n.v, r)                      the split-sum table, 24 x 48
E    = max(A + B, E_min)
comp = 1 + F0 (1 / E - 1)                 multiple-scattering compensation
spec = (F0 A + B) comp                    the specular albedo
diff = a (1 - m) max(1 - spec, 0)         what is left for the diffuse lobe
```

### 3.2 One body (`lumenBody`, `lightBrdf`)

```
D   = alpha^2 / (pi ((n.h)^2 (alpha^2 - 1) + 1)^2)                               GGX
V   = 0.5 / (n.l sqrt((n.v)^2 (1 - alpha^2) + alpha^2) + n.v sqrt((n.l)^2 (1 - alpha^2) + alpha^2))
F   = F0 + (1 - F0)(1 - v.h)^5                                                   Schlick
f   = diff / pi  +  D V F comp
L_body = f * colour * irradiance(n.l) * shadow * cloud
cloud  = 1 - 0.78 cover(p + l * reach)          the deck's cover where the ray to the body crosses it
```

Skipped when the body is below `l_y = -0.04`, when its intensity is nil, or when `shadow = 0`. The moon is added
when `night > 0.05`.

### 3.3 The dome

```
L_dome = diff * SH9(n) * sky (0.35 + 0.65 access) * tint
```

`SH9(n)` is the sky's radiance projected on the nine order-2 spherical harmonics and convolved with the cosine lobe:
the irradiance on a surface facing `n` under an unoccluded sky. 0.4 ns.

### 3.4 The sky's reflection

```
dir    = normalize(2 (n.v) n - v)
L_spec = spec * prefiltered(dir, r) * sky * access
```

`prefiltered` reads the 128 x 64 grid for `r < 0.18`, blends it with the 32 x 16 one up to `r = 0.5`, then the
32 x 16 with the 8 x 4. A surface with `r < 0.3` traces the mirror ray instead (`radiance` at `depth + 1`).

### 3.5 Block light and emission

```
L_block = diff * glow * block * 3.4 * 0.3
L_emit  = a * 4 * level / 15
```

### 3.6 Total

```
L = L_sun + L_moon + L_dome + L_spec + L_block + L_emit
```

## 4. Mathematics: the air and the water

### 4.1 Fog

```
z     = t * max(d . forward, 0.2)                       depth along the camera's axis
x     = z * fog / 320
share = (1 - exp(-x^2)) * open
L     = lerp(L, haze(d), share)                         skipped when share <= 0.002
```

`haze(d)` is the sky near the horizon in that direction (the direction's `y` flattened to `0.25 y + 0.05`), replaced
by the dome's smooth colour round the sun so a mountain in front of the sun is hazed, not lit. The open sky is not
fogged.

### 4.2 Water seen from the air

```
calm = saturate(1 - 0.006 t)
n    = normalize(-s_x calm, 1, -s_z calm)               s the slope of three wave trains (cosines of x, z and time)
cos_i = max(-n . d, 0.001)
F    = 0.02 + 0.98 (1 - cos_i)^5                        Fresnel
k    = 1 - eta^2 (1 - cos_i^2),   eta = 0.7502          refraction (Snell); k <= 0 is total reflection
t_r  = normalize(eta d + (eta cos_i - sqrt(k)) n)
below = bed * T + deep * (1 - T),   T_c = exp(-len * 0.38 * (1 - 0.6 tint_c + b_c)),  b = (0.5, 0.3, 0.1)
L    = F * mirror + (1 - F) * below
```

`mirror` is a traced ray for a sample and `sky.view(r)` for a filled pixel (`wet`); `below` is traced at the sample
(up to 48 blocks) and shared with the pixels round it.

### 4.3 Under water

```
k = exp(-0.09 z)
L = L * (k^2, k, exp(-0.03 z)) + deep * (1 - k)         red dies first
```

Seen from below, the surface is a window inside Snell's cone (about 49° from the vertical) and a mirror outside it.

## 5. Complexity

| Part | ns | Note |
|---|---|---|
| Primary ray | 73 to 106 | [3.2](02-visibility.md) |
| Flood probe, baked sample | about 40 | 8 cells, 3 arrays |
| `lumenShadeCore` | about 160 | of which the reflection lookup 58, the cloud shade 33 a body |
| Fog | about 50 | one grid lookup, an exponential |
| Shadow ray, outside the baked radius | 70 to 100 | |
| **Shaded sample** | **180 to 350** | sky, ground |

All `O(1)` a sample except the rays.

## 6. Observations

- The reflection lookup is a third of the shading and contributes a few percent of the light on a rough block. For
  `r >= 0.5` the lobe is so wide that the answer is close to `SH9(dir) / pi`; replacing the grid lookup by the
  harmonics would save about 55 ns a sample. Not done: it changes the picture slightly and should be compared.
- The cloud shade is a five-octave noise for each body. It varies over tens of blocks; a coarse map of it round the
  eye, refreshed slowly, would do.
- Both are worth `1 / s^2` of their cost now that shading is sparse: at `s = 4` the whole of shading is 22 ns a pixel.

## 7. History

| Date | Change |
|---|---|
| 2026-11-09 | the sun's shadow outside the bake: one ray to the disc's centre, not a random point |
| 2026-11-10 | `gridPlace` with quick trigonometry; `SkyGrid.look` in scalars |
| 2026-11-10 | water of a filled pixel from its own ripple (`wet`), not from its sample |

## 8. Source

`games/blockland/src/app/mc_worker.axle` (`radiance`, `radianceOf`, `surface`, `water`, `fromBelow`, `fogUnder`),
`mc_shade.axle`, `games/blockland/src/render/render_bake.axle`, `render_light.axle`;
`src/render/pathlight/pathlight_shade.axle`, `src/render/light/light_brdf.axle`, `light_sh.axle`, `light_dfg.axle`.
See also `doc/LIGHTING.md` and `doc/LIGHTING_MATH.md`.
