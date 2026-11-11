# 3.9 Baked shadows

[Handbook](../README.md) · previous: [3.8 Display](08-display.md) · next: [3.10 Water](10-water.md)

## 1. Contract

`McBake` (`games/blockland/src/render/render_bake.axle`) holds, for every air or water cell beside a solid block
(the *shell*), what the shading reads instead of tracing rays: the share of the sky the cell sees, the colour its sky
rays met, the share of the sun's and the moon's disc it sees, the colour of the block light.

- **In**: the view (sections around the player), the sun's and the moon's directions each frame (`setBodies`).
- **Out**: `sample(p)`: the eight cells around a world point blended trilinearly.
- **Guarantees**
  1. A shadow moves because the sun moves, and for no other reason: not with the camera, not with the frame, not
     with the order in which sections are baked.
  2. Between two bakes of a cell the share it shows is a continuous function of the sun's direction.
  3. Light under foliage is a smooth function of the sun's direction (no pattern drawn again at each bake).

## 2. What is stored

One 32-bit word a cell:

| Bits | Field | Unit |
|---|---|---|
| 0..7 | access: share of the upper hemisphere open to the sky | 1/255 |
| 8..15 | sun: share of the sun's disc seen, as last baked | 1/255 |
| 16..23 | moon: the same for the moon | 1/255 |
| 24..29 | the sun share the cell *showed* just before its last bake | 1/63 |
| 30 | shell flag | |

plus a 16-bit tint and a 16-bit glow. For each pool entry (a section): the direction the sun had when the entry was
baked (`entryDir`, 3 floats) and `fade` (1 float).

## 3. Mathematics

### 3.1 A cell's share of the sun

Eight rays from the cell's centre toward points of the disc, spread by the golden angle:

```
r_k = sqrt((k + 0.5) / 8),   a_k = 2.39996 k              k = 0..7
toward_k = normalize(dir + spread (r_k cos a_k) A + spread (r_k sin a_k) B)      A, B perpendicular to dir
share = (1/8) sum_k T_k                                    T_k the transmittance of ray k (0 if blocked)
```

So a share is a multiple of an eighth, times what glass and foliage let through.

### 3.2 Generations

The sun's direction is compared with the one of the last bake; a new *generation* starts when

```
dot(sun, sunDir_gen) < 0.99997          an angle of 0.44 degrees: a little under one disc
```

and every section is baked again, nearest first, a batch each frame. With a 20-minute day the sun turns 0.3 degrees
a second: a generation every 1.5 s.

### 3.3 The glide

Read as it is, a cell's share hops by eighths at each generation, section after section: the picture, drawn every
frame while the camera moves, showed every hop ("the shadows blink and are drawn again at random"). So the share
that is read is

```
shown = was + (now - was) * fade
fade  = min(1, sqrt((1 - dot(sun_live, entryDir)) / (1 - 0.99997)))
```

- `1 - cos(angle)` is `angle^2 / 2`, so the square root makes `fade` the angle the sun has travelled since the entry
  was baked, over one step.
- When a cell is baked again: `was <- shown` (at that instant), `now <- the new share`, and the entry's `entryDir <-
  sun_live`, so `fade` restarts at 0. `shown` is continuous across the bake by construction.
- There is no clock in it: the sun stopped, the shadow stops; the same sun, the same shadow.
- The shadow shown lags the sun by at most one step (0.44 degrees).

**A jump is not a step.** When the sun moved by more than four steps since the last generation
(`dot < 0.99952`: the time of day was set, the sun rose), cells take their new share at once.

### 3.4 Foliage

A shadow ray through a leaf block used to test the leaf texture's alpha texel by texel: each of the eight rays
passed or not through a hole one sixteenth of a block wide. A sun 0.44 degrees further sends the rays through other
holes, so every generation drew the light under a tree again, at random.

A shadow ray now reads the texture at its coarsest level, whose alpha is the block's mean cover `c`:

```
T <- T * (1 - c)            for each leaf block crossed
```

The share is then a smooth function of the direction (it changes when a ray enters or leaves a whole block), and the
light under a tree is an even, stable shade. What is lost is the dapple at texel scale, which eight rays a cell could
not represent in the first place.

## 4. Complexity

| | Work | Cost |
|---|---|---|
| Bake of a cell | 12 sky rays (structure, once) + 8 + 8 body rays (each generation) | off the frame: a batch of sections a frame on the pool |
| `setBodies` | one dot product and a square root for each pool entry | about 2000 entries: microseconds |
| `sample` | 8 cells, one extra multiply-add each for the glide | unchanged to the precision of the measurement |
| Memory | 6 bits taken from the word's free bits; 16 bytes an entry | +32 KB |

## 5. Observations

- The symptom ("shadows change when I move") pointed at the camera. The measurement did not: two consecutive frames
  of a camera that is flagged as moving but turns by 0.00002 rad a second differed on 0.06 to 0.08 % of their bytes
  under a sun 20 times faster than the game's, and on none after the glide. What moved was the sun; a still picture
  hid it by being redrawn only every 0.75 s through a 12-frame history.
- An attempt to give every pixel its own share of the sun, read at its own place (one trilinear lookup a pixel),
  cost 40 ms a frame on one thread and changed 0.5 % of the bytes: the light shared across a block of pixels was
  already the world's, because the bake is smooth at the scale of a block. Withdrawn (log, X10).

## 6. History

| Date | Change | Effect |
|---|---|---|
| 2026-11-11 | the glide (§3.3) | consecutive moving frames under a fast sun: 0.06-0.08 % of bytes over 8 levels apart, to 0.00-0.01 % |
| 2026-11-11 | shadow rays read foliage at its coarsest level (§3.4) | a frame at 15:00 against 15:02: 8.7 % of bytes over 8 levels apart, to 3.9 %; 15:02 against 15:04: 10.0 % to 2.2 % |
| 2026-11-11 | a jump of the sun snaps | the bake's tests (`stv_bake`) read a shadow right after moving the sun |

## 7. Source

`games/blockland/src/render/render_bake.axle` (`setBodies`, `section`, `bakeCell`, `sunOf`, `shadow`, `sample`),
`render_bake_run.axle` (the batches), tests in `games/blockland/tests/src/stv_bake.axle`.
