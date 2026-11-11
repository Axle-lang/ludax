# 3.3 The skyline

[Handbook](../README.md) · previous: [3.2 Visibility](02-visibility.md) · next: [3.4 Sparse light](04-sparse-light.md)

## 1. Contract

`McSkyline.rebuild(world, eye)` once a frame; `McSkyline.clear(dx, dy, dz) : bool` for every primary ray.

- `clear` answers **true only when** a ray from the eye along the unit direction `d` meets nothing in the loaded
  world. It may answer false for a ray that in fact meets nothing (it is conservative); it never answers true for a
  ray that hits.
- `ceiling` is the world `y` above which no loaded chunk holds anything.

A cleared ray is the open sky and is not traced.

## 2. Mathematics

### 2.1 One chunk

A chunk is a square column `[x0, x0 + 16) x [z0, z0 + 16)` whose content ends at the top `c` of its highest
non-empty section. Seen from the eye at height `e`, with `near` and `far` the smallest and largest horizontal
distances from the eye to the square:

```
rise  = c + 1 - e                        one block of slack: the eye may have moved since the rebuild
slope = rise / max(near - 1, 0.25)       if rise > 0   (the chunk rises above the eye: its near edge is steepest)
slope = rise / far                       if rise <= 0  (it lies below: its far edge is the highest line of sight)
```

A ray whose slope `d_y / sqrt(d_x^2 + d_z^2)` exceeds this cannot enter the chunk's content: at every horizontal
distance inside the square it is above `c`.

### 2.2 Bearings

The circle round the eye is cut into `B = 720` bins of half a degree. The chunk covers the bearings between the
smallest and largest angle of its four corners (measured round the bearing of its centre, so the wrap at ±180° does
not matter), and each of those bins keeps the largest slope it is given:

```
horizon[b] = max over chunks covering b of slope(chunk)
```

If the eye is over the chunk (`near = 0`), every bin gets its slope.

### 2.3 From slopes to sines

A unit direction has `d_y = sin(elevation)` and `slope = tan(elevation)`, so

```
sine[b] = horizon[b] / sqrt(1 + horizon[b]^2)
```

and since both are increasing functions of the elevation, `slope(d) > horizon[b]` is the same test as
`d_y > sine[b]`. The table is converted once a frame; a ray is then tested without a square root or a division:

```
clear(d):
    if d_y <= low:  return false          low = min_b sine[b]: under every horizon
    if d_y >  top:  return true           top = max_b sine[b]: over every horizon
    b = floor(atan2Quick(d_x, d_z) / 2 pi * 720)
    return d_y > sine[b]
```

## 3. Complexity

| | Time | Memory |
|---|---|---|
| Rebuild | `O(C (S + 4 + w))`: `C` chunks (625), `S` sections scanned from the top, `w` bins covered | 720 floats |
| | about 0.1 ms a frame | |
| `clear`, ray below `low` or above `top` | two comparisons | — |
| `clear`, ray in the horizon band | one `atan2Quick` (a division and a five-term polynomial), one load | — |

## 4. Observations

- On the ground almost every ray is under `low`: the test is one comparison and saves nothing. In the open, a third
  of the picture is over `top` and those pixels cost no ray at all.
- Under trees the chunk the eye stands in rises above it, `near = 0`, and its slope `rise / 0.25` is so steep that
  nothing is cleared. Those rays are traced, and end at the column's top ([3.2](02-visibility.md) §3, class 2).
- The first version of `clear` computed `sqrt(d_x^2 + d_z^2)`, a division and an exact `atan2` for **every** ray:
  18 ns, a fifth of the ray it was there to save. A test in front of a hot function must be cheaper than the
  function's fixed cost, or it is a loss on every ray it does not save.

## 5. What it does not do

It knows a chunk only by the top of its highest section, a multiple of 16. A hill of 70 blocks counts as 80. A finer
table (the chunk's heightmap) would clear more rays over low ground; it is not needed while those rays end quickly at
the column's top.

## 6. History

| Date | Change | Cost a ray |
|---|---|---|
| 2026-11-10 | first version: slopes, exact `atan2` | 18 ns |
| 2026-11-10 | `atan2Quick` for the bearing | about 14 ns |
| 2026-11-10 | sines, `low` and `top` | under 1 ns outside the horizon band |

## 7. Source

`games/blockland/src/render/render_skyline.axle`; used by `McPixelWorker.plain` and `radiance`
(`games/blockland/src/app/mc_worker.axle`); rebuilt in `McSession.pass`.
