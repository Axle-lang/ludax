# 3.2 Visibility: the voxel ray walk

[Handbook](../README.md) · previous: [3.1 The frame](01-frame.md) · next: [3.3 The skyline](03-skyline.md)

## 1. Contract

`McTracer.trace(ray, tmax, shadow, inFluid) : McHit`

- **In**: a ray `o + t d` in local coordinates (`d` a unit vector), a reach `tmax`, whether it is a shadow ray, and
  the fluid it starts in.
- **Out**: the first surface the ray meets: the cell, the face, the distance `t`, the texel's colour (tint
  applied), the state and its kind, and the transmittance `tr` gathered through glass on the way. `hit = false`
  when it meets nothing within `tmax` or leaves the loaded world.
- **Guarantee**: every skip is exact. A ray that jumps hits what it would have hit stepping cell by cell.

## 2. Mathematics

### 2.1 The cell walk (Amanatides and Woo, 1987)

Space is a grid of unit cells. A ray in cell `c = floor(o)` leaves it through one of three planes. For each axis `a`:

```
step_a   = sign(d_a)
tDelta_a = 1 / |d_a|                                    ray length that crosses one cell along a
tMax_a   = (c_a + [d_a > 0] - o_a) / d_a                ray length to the first boundary along a
```

The next boundary is the smallest `tMax`. One step:

```
a* = argmin_a tMax_a
t        = tMax_{a*}
c_{a*}  += step_{a*}
tMax_{a*} += tDelta_{a*}
```

The face entered is the one of axis `a*` that faces back along the ray: its normal is `-step_{a*}` on that axis.
The point entered is `o + t d`, and its fraction inside the cell gives the texel.

Cost: one comparison tree, three updates. `O(k)` for a ray that crosses `k` cells; `k <= 3 tmax`.

### 2.2 Leaving a box in one move

If the cell lies in an axis-aligned box `[l, l + b)^3` known to be empty, the ray leaves the box at

```
e_a = (l_a + b [d_a > 0] - o_a) / d_a            for each axis with d_a != 0
t   = min_a e_a,   a* = argmin
c_{a*} = l_{a*} + b      if step_{a*} > 0,   else  l_{a*} - 1
c_a    = floor(o_a + t d_a)                       for the other two axes
```

and `tMax` is recomputed for the new cell. This costs about two single steps, so it pays when the box is three or
more cells across.

### 2.3 The gap field

For each cell `c` of a cached section, `gap(c)` is the largest `g` such that the cube of side `2 g + 1` centred on
`c` holds nothing and lies inside the section, capped at `G = 4`.

It is built in two passes over the 4096 cells.

**Pass 1.** `edge(c)` = the side of the largest empty cube whose far corner (largest x, y, z) is `c`:

```
edge(c) = 0                                           if c holds anything
edge(c) = 1                                           if c is empty and on a near face (x, y or z = 0)
edge(c) = min(2 G + 1, 1 + min over the 7 neighbours n in {c - (1,0,0), ..., c - (1,1,1)} of edge(n))
```

*Why it is right.* A cube of side `m` ending at `c` is empty exactly when `c` is empty and the seven cubes of side
`m - 1` ending at its seven neighbours toward the origin are empty: their union with `c` is the cube. This is the
three-dimensional form of the largest-square dynamic programme. Cells are visited in rising x, z, y, so the seven are
already known.

**Pass 2.** The cube of radius `g` centred on `c` is the cube of side `2 g + 1` ending at `c + (g, g, g)`:

```
gap(c) = max { g <= G : c + (g, g, g) inside the section and edge(c + (g, g, g)) >= 2 g + 1 }
```

`gap` is monotonic (a clear cube of radius `g` contains one of radius `g - 1`), so `g` is raised while the test
holds: at most `G` tests a cell.

| | Cost |
|---|---|
| Build | `4096 * (7 + G)` operations, about 50 microseconds a section, when the section is cached |
| Memory | 1 byte a cell: 4096 bytes a cached section |
| Read | one load a step |

## 3. Algorithm: four sizes of nothing

A ray resolves the section it is in (`resolve`: which column slot, which section, what it holds), then at each
iteration takes the largest exact move available.

| # | Class | Test | Move | Size |
|---|---|---|---|---|
| 1 | Above the window | cell `y >= ceiling` and `d_y >= 0` | the ray is done | unbounded |
| 2 | `MCT_ABOVE`: above the column's highest non-empty section | section index `>= colTop[slot]` | a box 16 x 16 with no lid: out by a side, or down to `colTop` if `d_y < 0` | a column of air |
| 3 | `MCT_EMPTY`: an empty section | the section's flag | a box of 16 | 16^3 |
| 4 | `MCT_CACHED` with `gap(c) >= 2` | one byte | a box of `2 gap + 1` | 5^3 to 9^3 |
| 5 | otherwise | — | one cell (§2.1) | 1 |

Other section classes: `MCT_UNIFORM` (one state throughout, stepped by cell), `MCT_PALETTE` (not cached: the state
is read through the chunk's palette), `MCT_OUT` (not loaded: the ray is done).

After a move, if the cell's section changed, `resolve` runs again. Then the cell's state is read and its kind
decides (`McRenderTable.kind`):

| Kind | Primary ray | Shadow ray |
|---|---|---|
| none | continue | continue |
| cube | hit; texel at the entry point | blocked |
| cut-out (leaves) | hit if the texel's alpha `>= 128`, else continue | `tr *= 1 - alpha / 255` |
| glass | `tr *= 1 - a + a c`; hit only if alpha `>= 250` | same, blocked when `tr < 0.02` |
| model | intersect its boxes; hit the nearest opaque texel | blocked unless it has no collision |
| fluid | its surface, unless the ray is already in that fluid | water dims, lava blocks |
| proxy | hit, flat map colour | blocked |

### 3.1 The texel

```
level = levelOf(t * footprint)              footprint = pixelAngle * 16 texels a block
(u, v) = the entry point's two fractions on the face, in 0..16
colour = atlas[tex][level][v][u]            an overlay texel replaces it where it is opaque (grass sides)
colour = colour * tint(biome)               when the face is tinted
```

`footprint` is **one pixel's**, whatever the stride of the light samples. When it followed the stride the leaves'
alpha was read at a coarser mip while the camera moved, and their holes changed.

The biome is stored a 4 x 4 x 4 block at a time behind a palette; the tracer keeps the last block's answer, since
neighbouring rays end in the same one.

### 3.1.1 Foliage (2026-11-11)

A texture is read with no filter, at the level `levelOf(q)` where `q` is the texels a pixel covers: level 0 up to one
texel a pixel. For most textures that is the crisp look wanted. Foliage is the exception: its texels differ as much
as a leaf and a hole, so at one texel a pixel every move of the camera shows another texel, and a forest twinkles.
For a cut-out cube

```
q = t * footprint * 2 / max(|d . n|, 0.3)
```

a texel covers two pixels at least, and a face seen at a slant counts the texels a pixel runs over along it. Far
foliage becomes flatter (down to one colour a face); near foliage is unchanged.

### 3.2 `resolve`: which section

```
slot  = slotOf(cx >> 4, cz >> 4)            a ring of side x side columns
live  = colLive[slot] and colCx[slot] == cx >> 4 and colCz[slot] == cz >> 4
sidx  = (cy >> 4) - minSec
```

`slotOf` is a floored remainder by `side` (25 for a view distance of 12, not a power of two). It is computed from
an anchor, a multiple of `side` just below the window, by subtraction and at most one correction: no division.

## 4. Complexity

| Quantity | Ground view | Horizon | Sky from under trees |
|---|---|---|---|
| Steps a ray (all kinds) | 9.3 | 14.0 | 10.0 |
| of which box moves | 0.19 | 2.7 | 4.2 |
| Section changes | 0.37 | 1.6 | 2.4 |
| Texels read | 1.2 | 1.1 | 0.04 |
| **ns a ray** | **73** | **106** | **76** |
| of which before the first step | 26 | 26 | 28 |

(Counts from an instrumented build of 2026-11-10, before the gap field replaced the brick mask; times after.)

A single step is about 5 ns; the fixed part (set-up, the first `resolve`, returning the hit, the caller's
book-keeping) is a third of a ground ray.

## 5. Observations

1. **Near the ground the walk is cell by cell.** With the eye 1.6 blocks up, rays graze cells whose neighbours are
   full, so `gap` is 0 or 1 and the box move is rare (0.19 a ray). The gap field's gain is on the horizon and under
   trees, not on the ground.
2. **The fixed overhead is as large as the walk** on a short ray. Most of it was not in the tracer: the skyline test
   in front of it cost 18 ns before it became a comparison ([3.3](03-skyline.md)).
3. **Rays that end in the sky were the slowest**, not the fastest: 16 empty sections to the top of the world, each a
   `resolve` and a box move. Classes 1 and 2 removed that.
4. **The hit is 18 fields returned by value.** It is copied once into the worker for the fill stage. Passing a
   smaller record for the primary ray is the next thing to try.

## 6. Experiments that failed

| Tried | Result | Why |
|---|---|---|
| Branch-free axis choice (three 0-or-1 factors) | 94 to 118 ns a ray | the products lengthen the chain that carries `t` between steps, and the branch was predicted well |
| Padding the workers and tracers by 128 bytes against false sharing | no change | the scaling limit is elsewhere ([4.1](../engine/01-job-pool.md)) |
| Skipping the trace between four sky samples | faster, but twigs against the sky vanished | a pixel is sky only if its own ray, or the skyline, says so |

## 7. History

| Date | Change | ns a ray (ground / horizon / sky) |
|---|---|---|
| 2026-11-10 morning | sections of 16, bricks of 4, cells | 98 / 143 / 101 |
| | `MCT_ABOVE` and the window ceiling | 90 / 135 / 95 |
| | gap field replaces the brick mask | 94 / 145 / 94 |
| | `slotOf` without division; fixed tint by table | 89 / 120 / 90 |
| | last-biome cache | 86 / 117 / 89 |
| | skyline test as a comparison of sines | 73 / 106 / 76 |

## 8. Source

`games/blockland/src/render/render_trace.axle` (`McTracer.trace`, `resolve`, `biomeAt`, `hitModel`, `hitFluid`),
`render_view.axle` (`McView.fillCache`, `slotOf`, `colTop`), `render_table.axle` (`kind`, `faceTex`, `tintColor`),
`render_atlas.axle` (`texel`, `levelOf`).

Reference: J. Amanatides, A. Woo, *A Fast Voxel Traversal Algorithm for Ray Tracing*, Eurographics 1987.
