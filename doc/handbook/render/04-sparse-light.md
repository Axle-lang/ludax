# 3.4 Sparse light

[Handbook](../README.md) · previous: [3.3 The skyline](03-skyline.md) · next: [3.5 Shading](05-shading.md)

## 1. Contract

`McFrame.trace` shades one pixel in `s x s`; `McFrame.fill` gives every other pixel a radiance.

- **In**: the samples' radiance, albedo, position, `sid`; the three sample grids ([2.2](../standards/02-shared-buffers.md) §4.2).
- **Out**: `cur`, `alb`, `pos`, `sid` for every pixel.
- **Guarantees**: texture, edges and cut-outs are each pixel's own; light never crosses from one plane to another;
  a pixel no sample can speak for shades itself.

### 1.0 Where it lives (2026-11-11)

The mechanism is the engine's, in `src/render/pathlight/pathlight_sparse.axle`; a renderer supplies only what it
alone knows.

| Piece | Owner | What it does |
|---|---|---|
| `LumenSparse` | engine | the samples of a picture at a stride: `put` / `putAt(g, light, fog, key, place)`, `corners(x, y)`, `blend(corners, key)`, `blendNear(corners, key, place, reach)`, `mix(corners)` |
| `SparseCorners` | engine | the four samples around a pixel: pixel offsets, sample offsets, weights that add to 1 |
| `SparseLight` | engine | `ok`, `light` (over the albedo), `fog` (what the air adds); `shade(albedo) = albedo * light + fog` |
| `LumenLightMemo` | engine | the light of a thing no sample fell on, kept by key for one frame |
| the **key** | caller | an `i64` that says who may share a sample: a plane, a face, an object, a material; `SPARSE_NO_KEY` for a sample nobody may share |
| the **reach** | caller | how far from a pixel, in the caller's units, a sample of its key may lie: the distance over which the caller's light is smooth |
| the fallback | caller | what to do when `blend` is not `ok` (blockland: shade the face's centre once, `faceLight`) |
| extra channels | caller | anything else stored a sample (blockland: the sky's `clear`, the water's `below` and `above`), indexed by the same sample offsets |

The stride is a power of two (`setStride` takes the largest one under what it is asked): a pixel's block and its
place in it are a shift and a mask. As divisions by a stride reloaded for every pixel they were four `idiv` a pixel.

Guarantees, each a check of `tests/src/render_sparse.axle` (32 checks):

1. The four weights of every pixel add to 1 and the four samples are inside the grid.
2. A pixel that is a sample reads its own sample with weight 1.
3. A light that is linear in the pixel is given back exactly, and its fog with it; past the last sample of a row a
   pixel holds that sample (nothing is extrapolated).
4. A sample with another key never enters a blend; a pixel no sample speaks for is told so (`ok` false).
5. A sample stored with `SPARSE_NO_KEY` is shared with nobody.
6. A constant light is constant at any stride.
7. Within the reach the samples of the key blend as they would without it; one beyond the reach is left out, along
   any axis; another key within reach is still another key.
8. The memo gives back what it was given, for that key and that frame only; when crowded it forgets, it never
   answers with another key's light.

blockland's picture is bit-identical before and after the move (two views compared byte by byte).

### 1.1 Whose light a pixel may take (2026-11-11)

A pixel takes the light of the samples **in its plane and within one block of it** along every axis
(`LumenSparse.blendNear(corners, key, place, reach)` with the plane as the key and `reach = 1`). When none is that
near it takes the light of its face, shaded once where the face was first seen in the chunk and remembered for the
frame (`McPixelWorker.faceLight`).

Three rules were tried, in this order:

| Rule | What went wrong |
|---|---|
| Same plane (then "facing the same way at about the same distance") | every leaf of a forest at one height is one plane: a leaf took the light of another, and which one changed with the camera |
| Same face of the same block; else the face's centre | a floor is made of faces: at every border between two blocks the light was held over `stride` pixels instead of blended, so the edge of a shadow was a staircase; and the centre of a face of which only a sliver shows may be in the sun when the sliver is not (bright dots along edges) |
| Same plane **and** within a block; else the face where it is seen | — |

The reach is the grain of what is being shared: the baked light is blended between the centres of neighbouring
cells, so within a block of a point it is smooth and a neighbour's sample is a fair estimate. Near the eye the four
samples are centimetres apart and all count, across block borders too; far away they are blocks apart, none counts,
and the face is lit once.

Measured from the sky above a forest, two consecutive frames of a slow turn, bytes more than 8 levels apart: 8.8 %
(plane), 8.4 % (face), 7.8 % (plane and reach), at the same cost within the noise.

## 2. Mathematics

### 2.1 Why light can be shared

For a matte surface, radiance toward the eye is

```
L = a E + S            a albedo,  E light gathered over the hemisphere,  S specular
```

`E` at a point depends on the baked terms of the cells round it, read with a trilinear blend ([3.5](05-shading.md)).
A trilinear function restricted to a plane is bilinear in the plane's two coordinates, and a plane seen in
perspective maps to the screen by a projective map that is close to affine over a few pixels. So across a face `E`
is, to first order, **linear in screen coordinates between samples**, and bilinear interpolation reproduces it.

### 2.2 The blend

A pixel at `(x, y)` lies between the four samples at `(g_x s, g_y s)`, `((g_x + 1) s, g_y s)`,
`(g_x s, (g_y + 1) s)`, `((g_x + 1) s, (g_y + 1) s)`, with

```
t_x = (x - g_x s) / s        t_y = (y - g_y s) / s
w_a = (1 - t_x)(1 - t_y)     w_b = t_x (1 - t_y)     w_c = (1 - t_x) t_y     w_d = t_x t_y
```

Let `M` be the set of those samples whose `sid` equals the pixel's. Then

```
E(pixel) = sum_{i in M} w_i E_i  /  sum_{i in M} w_i            if M is not empty
L(pixel) = clamp(E(pixel) * a(pixel))
```

Renormalising by the weights present is what keeps an edge sharp: a sample on the other side of an edge is not in
`M` and contributes nothing.

### 2.3 Kinship, when `M` is empty

The pixel may lie on a plane none of its four samples hit (a single leaf, a stair's riser). Then it takes the light
of the sample with the largest weight among those that

```
are plain surfaces,   face the same way (sid & 7 equal),   and   |r_i - r| <= 0.15 max(r_i, r) + 0.5
```

with `r` the distance from the eye. Same normal means the same cosine to the sun and the same dome; nearly the same
depth means nearly the same cells of baked light.

### 2.4 Error

| Source | Size | Where it shows |
|---|---|---|
| `E` is not linear across a shadow's edge | the edge is `s` pixels soft at most | nowhere new: the baked shadow is already a cell soft |
| `S` treated as proportional to `a` | under 4 % of `L` for a rough dielectric | not visible |
| Kinship across leaves at different depths | bounded by the 15 % rule | foliage is lit a little more evenly than it should be |
| Perspective (the map is projective, not affine) | second order in `s / distance in pixels` | nil at `s <= 4` |

## 3. Algorithm

### 3.1 Trace (one pixel in `s^2`)

```
for y in rows, y mod s = 0:  for x mod s = 0:
    d = camera ray through (x + j_x, y + j_y)            j = 0.5 moving, jittered still
    L = radiance(eye, d)                                 full shading (3.5), sets alb, pos, sid
    write cur, alb, pos, sid at (x, y)
    g = (y / s) ceil(W / s) + x / s
    below[g] = light under the water surface, if any
    if open sky:  lightGrid[g] = veil(d).colour;  veilGrid[g] = veil(d).clear
    else:         lightGrid[g] = clamp(L) / alb;  veilGrid[g] = -1
```

### 3.2 Fill (the other pixels)

```
q = camera ray through the pixel
plain = worker.plain(eye, q)                             the primary ray only: alb, pos, sid, the hit
if open sky and the four samples are open sky:           (3.6 §3)
    L = bilinear(lightGrid) + bodies(q) * bilinear(veilGrid)
elif plain:
    E = sharedLight(four samples, sid, pos)              §2.2, then §2.3
    if E exists:  L = E * alb
    else:         L = full shade from the hit already found
else:                                                    water, a glowing block, a mirror, the sky beside something
    L = settle(...)                                      water beside a water sample: its own ripple, the sample's bed
write cur, alb, pos, sid
```

`plain` answers false for anything whose light is the view's own: a fluid, an emitter, a hit seen through tinted
glass, the block the player aims at (its outline is drawn in the albedo).

## 4. Complexity

| | Time a pixel | Count a frame |
|---|---|---|
| Sample | ray + shade: 350 ns | `P / s^2` |
| Filled, light shared | ray + blend: 73 + about 15 ns | most of `P (1 - 1/s^2)` |
| Filled, shades itself | ray + shade without a second ray | the rest: edges of foliage, water, emitters |
| Memory | 7 floats a sample | `7 P / 4` at most |

```
T(trace + fill) ≈ P [ 350 / s^2 + (1 - 1/s^2)(88 + f * 280) ]        f = share of pixels that shade themselves
s = 4, f = 0.02:   P * (22 + 88) = 101 ms          measured 103 ms on the ground
s = 4, f = 0.25:   P * (22 + 148) = 157 ms         measured 166 ms at the horizon (foliage)
```

## 5. Observations

- `f`, the share of pixels no sample speaks for, is what separates a cheap view from a dear one. Foliage is the
  worst: every leaf is its own plane.
- Interpolating instead of copying removed the visible squares at no cost: the blend is four loads and a few
  multiplications.
- A still picture uses the same path at `s = 2`. Its jittered rays change which texel and which side of an edge a
  pixel sees from frame to frame; the mean of 8 frames is the anti-aliased picture.

## 6. History

| Date | State | Problem |
|---|---|---|
| before 2026-11-09 | one sample copied to its `s x s` block: texture, light, everything | "360p" while moving |
| 2026-11-09 | texture per pixel (`plain`); light **copied** from the block's sample when on its plane | squares of light; the sea in squares |
| 2026-11-10 | a pixel on another surface shaded in full | median 80 ms: too slow in foliage |
| 2026-11-10 | light copied also from a sample at a similar depth | fast again, still squares |
| 2026-11-10 | **bilinear blend over same-plane samples**, kinship as the fallback; samples and fill as two stages | current |

## 7. Source

`games/blockland/src/app/mc_frame.axle` (`trace`, `fill`, `sharedLight`, `kin`, `mcfSimilar`),
`mc_worker.axle` (`plain`, `finish`, `settle`, `wet`, `skyFrom`).
