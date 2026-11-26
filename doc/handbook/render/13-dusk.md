# 3.13 Dusk: the walk over the bay, the picture that settles, and how a change is proved harmless

[Handbook](../README.md) · previous: [3.12 Lux](12-lux-layers.md) · next: [3.14 The water surface](14-water-surface.md)

`examples/rendering/dusk` is the showcase of the layered light: a harbour at sunset (towers with mirror and glass
curtain walls, a suspension bridge, a pier with lanterns, 320 x 96 x 320 cells). It began as a fork of lumen (its
session, frame and shading) so that every change could be measured against a known baseline. This chapter records
what was changed in that inherited frame, the mathematics that says why each change is safe, what each cost and
saved, and what was tried and withdrawn.

## 1. Contract

- **Gate of every optimisation.** `dusk --golden` renders the four viewpoints (480 x 270, 6 passes each) and a
  10-frame turn, and prints FNV-1a fingerprints of every bit of the HDR picture and of the displayed picture; it
  writes the displayed pictures as BMP. `scratchpad/golden/compare.py` compares two folders pixel by pixel.
  - A change that keeps the arithmetic must print the **same fingerprints** ("bit-identical").
  - A change that reaches the same cells by another rounding path (decided with the owner on 2026-11-23: "visually
    identical") must show **the same cells hit**, and its displayed-pixel differences are published: count, how many
    by more than one level, worst.
- **Determinism.** The fingerprints are the same on 1, 3, 5 and 23 threads (checked at each step).
- **Temporal behaviour.** A moving picture is bit-identical to the inherited one (checked with `--drift` against the
  build before the temporal changes); a picture that stops settles monotonically (`--settle`).

## 2. Why

The inherited frame cost 722 ns a pixel to trace on one thread (640 x 360 internal, 23 threads: 17.3 ms moving, 49 fps
in the window at 87 % of the processor), and the owner reported that a picture which stopped moving shimmered for a
second, windows vibrating, before resting at 32 samples.

## 3. Mathematics

### 3.1 The cell walk and its two ways of computing a time

The walker is Amanatides and Woo's: for a ray `o + t d`, the time to cross one cell along axis `a` is
`δ_a = 1 / |d_a|`, and the time of the next boundary along `a` is kept in `T_a`. Each step takes the axis with the
smallest `T_a`, enters the next cell along it and adds `δ_a` to `T_a`. The time of the boundary just crossed is the
hit time `t` when the entered cell is solid.

Two ways give that time:

- **accumulated**: `T_a ← T_a + δ_a`, `k` times. In floating point (unit roundoff `u = 2^-24` for f32), the error of a
  running sum of `k` positive terms is bounded by `(k - 1) u Σ|terms| ≈ k u T` (Higham, *Accuracy and Stability of
  Numerical Algorithms*, §4.2). For a ray of 100 cells reaching `T = 300`, about `100 · 6·10^-8 · 300 ≈ 1.8·10^-3`
  cell;
- **recomputed**: `T_a = (c_a + 1 - o_a) δ_a` (or `(o_a - c_a) δ_a` going down), one subtraction and one product:
  error at most about `2 u T`, `3.6·10^-5` cell at `T = 300`.

The walk used the second form after every empty brick it crossed and the first everywhere else. **Any change of
where the walk jumps changes which form gives the hit time**, by at most the bound above. The cell found is the same
whenever the boundary is not within that bound of a cell face; the hit *point* `o + t d` moves by at most that much.

What such a shift can change on the picture: the texel under the point, when the point lies within `1.8·10^-3` cell
of a texel edge (a texel is `1/16 = 0.0625` cell, so about `2 · 1.8·10^-3 / 0.0625 ≈ 6 %` of hits that land on a
texel-decided surface, glass frames and leaf holes, for the longest rays), and anything that depends continuously on
the point (fog, the level of detail, lighting), by a relative `10^-5` or less. The first is a decision and can change a
pixel's sample fully; the second is invisible.

### 3.2 Column tops: a sufficient test for air

`top(x, z)` is one more than the height of the highest non-air cell of column `(x, z)` (0 for an empty column). By
definition every non-air cell `(x, y, z)` has `y < top(x, z)`. Contrapositive: **`y ≥ top(x, z)` implies air.** The
walk tests it before reading the 9.8 MB flat world; when it holds, it skips a load that would have answered air. The
cells visited and every time computed are unchanged: bit-identical.

### 3.3 The column ceiling: crossing a column of bricks in one move

Let `B` be the column of bricks holding the ray's cell: the 8 x 8 columns `x ∈ [8i, 8i + 8)`, `z ∈ [8j, 8j + 8)`, the
whole height. Its **ceiling** is `C = max top(x, z)` over its 64 columns, so every non-air cell of `B` has `y < C`.

**Theorem.** Let the ray be in cell `(cx, cy, cz)` of `B` at time `t₀` with `cy ≥ C`, and let `t_e > t₀` be the time
it leaves `B` sideways (the smaller of its exit times along x and z). If `d_y ≥ 0`, or `o_y + d_y t_e ≥ C`, the ray
meets no non-air cell of `B` on `[t₀, t_e]`.

*Proof.* `y(t) = o_y + d_y t` is affine, so its minimum over `[t₀, t_e]` is at an end. At `t₀`, `y(t₀) ≥ cy ≥ C`
(the ray is inside cell `cy`). At `t_e`, `y(t_e) ≥ C` by hypothesis, or `y(t_e) ≥ y(t₀)` when `d_y ≥ 0`. Hence
`y(t) ≥ C` throughout, so every cell the ray occupies has `floor(y) ≥ C`, and is air by the definition of `C`. ∎

The theorem holds for a column of any width `w = 2^k`: only `C` and `t_e` depend on it. The walk keeps two levels,
`w = 8` (a column of bricks, ceiling `ceil`) and `w = 32` (ceiling `ceilWide`). Since a wide column contains its narrow
ones, `ceilWide ≥ ceil` there, so a cell below the narrow ceiling is below the wide one too: the narrow test, inline
and the most often false, comes first; above it, `jumpShift` tries the wide jump, then the narrow one.

The walk then sets `t = t_e`, enters the cell beyond the face it left by (the next column along that axis, the floor
of the position on the other two), rebuilds its boundary times from the origin (the recomputed form of §3.1), and
**tests the block of that cell like any cell entered**. Two edge cases match the cell walk exactly: a ray that leaves
the world through the top lands on a cell `inside` rejects, and so misses as before; `t_e > tmax` stops it in air, as
the cell walk would have.

### 3.4 Exact shortcuts in the light shafts

- `window(x)` is `smoothstep(0, m, d)` with `d` the distance to the nearest border. For `d ≥ m`, `d / m ≥ 1` (division
  is correctly rounded and monotone, and `m / m = 1`), `saturate` gives 1, and `1·1·(3 - 2·1) = 1` exactly. Returning
  `1.0` there gives the same bits without the division, in 24 steps of every pixel's march.
- `air(i)` is `smoothstep(3, 40, |p - eye|)`. For `|p - eye|² ≥ 1600`, the correctly rounded square root is `≥ 40`, so
  the ease is 1. Below 1600 the old path runs unchanged (the root may round up to exactly 40.0 just below, and then also
  gives 1: both paths agree).

### 3.5 Why the picture shimmered after a stop

A still pixel accumulates its samples in a running mean capped at `L = 32`: `μ_n = μ_{n-1} + (x_n - μ_{n-1}) / n`. Its
change from one frame to the next is `(x_n - μ_{n-1}) / n`, of order `σ / n` for samples of deviation `σ`.

1. **History refused when the surface changes.** History was accepted only when the pixel's surface id was the same as
   last frame's. A lit window one or two pixels wide on a mirror facade is hit by the jittered sample with some
   probability `p`, the facade otherwise: the id changes between two frames with probability `2p(1 - p)`, and each
   change restarted the mean. The expected run of accepted frames is `1 / (2p(1 - p))`, **2 frames at `p = 1/2`**: the
   mean never grows, the pixel keeps the full deviation `σ` of window against glass (up to 198 levels between two
   consecutive frames was measured). Fix: with a still camera the history of this very pixel is the right estimator
   whatever surface it came from, so it is kept as radiance (light × albedo, albedo 1), as an edge's is.
2. **An edge's history pulled down to its sample.** `frameTameEdge` capped an edge's history at `2·lum(sample) + 0.1`
   every frame. For a pixel alternating between `a` (window) and `b` (glass) with `a > 2b + 0.1`, every `b` sample cut
   the history to `2b + 0.1`: it never converged. It is a ghost guard for a *borrowed* history; with a still camera the
   history is the pixel's own, so it now applies only when the camera moved.
3. **A jitter that opened up on the stop** (a quarter pixel while moving, the whole pixel over 8 frames after): new
   samples are drawn from a wider distribution than the history's, a step in the mean. Kept as inherited (see 3.6).

### 3.6 Why the first fix was withdrawn: blur and lost reflections in motion

The first attempt (2026-11-23) kept the history while moving: 12 frames instead of 3, the full-pixel jitter always,
the history clipped to the neighbourhood's YCoCg box (`LuxMoments`), the radiance fallback while moving too, and
samples weighted by inverse luminance (Karis 2014). The owner reported a blurred picture and reflections gone. Why:

- **Repeated bilinear reprojection is a repeated low-pass filter.** Each frame resamples the history with a tent of
  random sub-pixel offset; the blur kernels compose, their variances add, so after `k` frames the kernel's deviation
  grows as `√k` (about `√(k/6)` pixel for uniform offsets). With 12 frames, more than a pixel of blur.
- **Borrowing across surfaces while moving** spread a window's light over its neighbours.
- **Inverse-luminance weights are biased toward dark**: the weighted mean `E[w x] / E[w]` with `w = 1 / (1 + x)` is
  below `E[x]` for any spread of `x` (the weight falls where `x` rises), most for sparse bright samples: the sun's
  glints on the water, which are what reflections are made of.

The second version restores the moving behaviour exactly (checked: `--drift` pictures byte-identical to the build
before the temporal changes) and keeps only items 1 and 2 of §3.5, both restricted to a still camera.

### 3.7 Where the memory went, and what is needed after the bake

The memory of a session is fixed by the world's cell count `N = 320 · 96 · 320 = 9 830 400`:

| Owner | What | Bytes |
|---|---|---|
| `VoxLightFlood` | 8 planes of one `i32` a cell: red, green, blue, sky seeds, path, stamp, emitters, pass masks | `32 N` = 315 MB |
| `LumenLight` | 3 volumes of one `i32` a cell: lamp light and flags, cover (access and tint), sun, moon and sky | `12 N` = 118 MB |
| `VoxLightSurface` | the shell's index, one `i32` a cell | `4 N` = 39 MB |
| `VoxelGrid` | one byte a cell, capacity doubled to 4 096 chunks for 2 400 | 16.8 MB |
| `LumenScene` | the flat copy, one byte a cell | `N` = 9.8 MB |

The flood is needed to compute the lamp and sky light; `LumenLight` copies that light into its own volumes at
start-up, and the bay is never edited. After the copy nothing reads the flood: the bakes (`bakeSunSlice` and
`bakeAll`) read the grid, the block table and the shell only (`src/voxel/light/bake.axle`, `surface.axle`).
`VoxLightWorld.releaseFlood` therefore gives the eight planes back. Proof that the picture cannot change: the render
reads `LumenLight`, never the flood; the golden fingerprints and the pixel comparison are unchanged.

### 3.8 Bricked light volumes: one triplet for a brick that does not vary

`LumenLight` stores three words a cell (lamp light and flags, cover, sun and sky). They are now stored by bricks of
`8³ = 512` cells. A brick whose 512 cells have the same three words, and none of which is a shell cell, keeps that
triplet and no cells; every other brick owns a block of 512 cells in a pool. With `B` bricks of which `B_o` own a
block, the memory is

```
M = 12 · 512 · B_o  +  16 · B          (three words a cell in the pool; a slot and a triplet a brick)
```

against `12 · 512 · B` dense. On the bay `B = 19 200`, `B_o = 4 565` (24 %): `M = 28 MB` against 118 MB.

*Why a triplet is never written.* The only writes after start-up are the sun's and the moon's re-bakes (`setBody`),
and they write shell cells only. A brick that holds a shell cell always owns a block (`LvBlock.fill` marks it
varied), so every write lands in the pool. `setBody` also refuses a triplet address, so the invariant cannot be
broken silently by a future caller.

*Why the picture cannot change.* A read asks `cellAt` for the pool index or the brick's triplet and decodes the same
three words in the same order as before; the trilinear arithmetic is untouched. Fingerprints identical to the step
before.

### 3.9 The resolution governor, a resizable window and the whole screen

The frame's stages want a picture whose sides are multiples of 16. A change of size (`LumenSession.resize`) keeps the
frame and its pool: `LumenFrame.fit` and `LumenPost.fit` reinterpret buffers that only ever grow to the largest size
asked, and the history starts again. The finished picture is the window's own size, whatever the size the picture is
computed at (the post's last pass resamples to any size). The first version built a new frame and pool per resize and
leaked each old frame (history below).

The window (`src/app/window.axle`) asks for it in two cases:

```
base      = window size / display scale (2)
share     = LuxBudget.scaleNow()          from 0.4 to 1, steps of 1/16
picture   = round16(base · share)          both sides
```

- **The window changed size** (it is resizable; F11 or `--fullscreen` opens a borderless pop-up the size of the primary
  screen, which Windows places at the corner). smalt's `present` stretches the picture to the window in between.
- **The governor moved the share.** It reads only frames that drew (pass and display, without the pacer's wait); a
  converged still picture draws nothing and would otherwise pull the share up. It steps down after 3 frames in a row
  above 95 % of 16.7 ms and up after 30 frames below 75 %. Falling fast and rising slowly is what keeps resizes rare. It
  starts at the share where the picture has about 640 × 360 pixels, the size known to hold 60 a second here, so a
  1080p screen does not begin at four times the work.

Observed on the first run (1280 × 720 window, 23 threads, the user's own dusk running alongside): 640 × 368, then one
step down to 608 × 336, where it stayed. A size named with `--size` is kept: no governor and no resize.

## 4. Algorithm

The walk of `trace` and of `visibility` (`examples/rendering/dusk/src/world/scene.axle`), per iteration:

1. If `cy ≥ ceilingOf(cx, cz, 3)`, `jumpShift` picks the widest column the theorem of §3.3 allows (32, then 8 cells)
   and `columnJump` gives the exit time and the cell beyond; the walk rebuilds its boundary times from the origin.
2. Else, if the brick is empty: leave it in one move (inherited).
3. Else one cell along the axis of the nearest boundary (inherited, accumulated times).
4. Then, for the cell entered: if `cy ≥ top(cx, cz)` it is air (§3.2); else the block is read and decided.

The ray's constants are a `SceneRay` built once per walk; a jump is a `SceneJump`. The cheap ceiling test is inline,
and the jump struct is built only when the jump happens (see §6 for why that matters).

## 5. Complexity

Symbols: `n` cells a ray crosses, `n_a` of them above the ceiling of their column of bricks, `n_b` in empty bricks.

| Walk | Work a ray |
|---|---|
| inherited | `O(n - n_b + n_b / 8)` |
| with ceilings | `O(n - n_a - n_b + (n_a + n_b) / 8)` in the worst alignment, a jump per column of bricks crossed |

Memory: tops `sx · sz` bytes (100 KB), ceilings `sx · sz / 64` bytes (1.6 KB) and `sx · sz / 1024` (100 bytes): all
stay in the second-level cache.

Measured (Ryzen 9 9900X, one thread, 640 x 360 moving frames of viewpoint 1, best of 3 alternated runs):

| | Inherited | Now |
|---|---|---|
| steps a primary ray | 40.4 | 20.5 |
| steps a water mirror ray (0.28 a pixel) | 93.7 | 29.0 |
| steps a smooth-surface mirror ray (0.08 a pixel) | 73.8 | 32.4 |
| primary walk alone, ns a pixel | 241 | 188 |
| ns a step | 4.9 | 7.4 (fewer, dearer steps) |
| trace of a frame | 160-172 ms | 143-145 ms |
| shafts + resolve | 27.3 ms | 21.6 ms |
| frame, 23 threads | 62 fps (bench) | 66 fps |

With the wide columns (2026-11-24), one thread, best of 3 alternated runs:

| | Inherited | Narrow columns | Narrow and wide |
|---|---|---|---|
| steps a primary ray | 40.4 | 20.5 | 11.7 |
| steps a water mirror ray | 93.7 | 29.0 | 12.5 |
| primary walk alone, ns a pixel | 241 | 188 | 96 |
| trace of a frame, viewpoint 1 | 163 ms | 143 ms | 112 ms |
| viewpoint 2 (open water) | 188 ms | — | 122 ms |
| viewpoint 3 (the bridge) | 179 ms | — | 134 ms |
| viewpoint 4 (a street) | 80 ms | — | 85 ms (within noise: ceilings rarely help between towers) |
| frame, 23 threads (bench) | 63 fps | 66 fps | 75 fps |

Inside a water pixel after these steps (scratch-copy profile, one thread, 640 x 360, ns averaged over every pixel of
the picture, water is 28 % of it): the whole water branch 207, its mirror call 95 (12.5 steps, then the shading of
what it hits, which may trace a second mirror off a facade), the ray to the bed 28, the bed's shading about 67, the
wave normal 17. What is left there is shading, not walking.

Displayed-pixel differences against the inherited picture (14 golden pictures, 1 814 400 pixels): 3 526 differ
(0.19 %) with the narrow columns, 3 422 (0.189 %) with both levels; in the still viewpoints 61, 67, 94 and 0 pixels differ, of which 17, 10, 22 and 0 by more than one level
(isolated water glints and window texels, §3.1); in the 10 moving frames 0.03 % to 0.37 %, the larger counts because
a frame with 3 frames of history shows a flipped sample fully. Fingerprints identical on 1 and 5 threads.

`--settle` (24 frames of turning, then 40 still; sum over the 40 still frames):

| | Mean difference | Bytes moved > 8 levels |
|---|---|---|
| inherited | 20.3 | 29.5 % |
| second version | 13.2 | 15.5 % |

Memory (headless 1280 x 720, Windows working set):

| | Inherited | After `releaseFlood` |
|---|---|---|
| while rendering | 741 MB | 307 MB, then 222 MB with bricked volumes (§3.8) |
| peak (start-up, flood and volumes together) | 754 MB | 620 MB, then 561 MB |

## 6. Observations

- The cost of a step is its arithmetic, not its memory: the column-tops test (which removes the 9.8 MB load from
  steps in the air) saved 5 % within the noise; removing every bounds guard of the step with `getUnchecked` saved
  nothing (4.90 against 4.88 ns).
- A branch-free axis choice (selects instead of branches) made the step slower: 5.68 against 4.88 ns. Along a ray the
  axis sequence is regular enough for the predictor; the select form lengthens the dependency chain. Blockland found
  the same (ledger §2 row 6).
- Readability has a price the compiler sets: returning a struct from a function called every step, or building an
  empty struct every step to hold "no jump", cost 17 % (walk 188 → 220 ns). Asking a boolean first (`canJump`) and
  building the struct only when the jump happens kept both the shape and the speed.
- A struct literal of a struct declared later in the same file fails (E0016, AXLE_COMPILER_FINDINGS F13).
- Under the "bit-identical" rule the walk could not be shortened at all: every way to cross air in fewer steps changes
  which formula of §3.1 gives the hit time.

## 7. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| 2026-11-23 | fork of lumen, the bay world, `--settle`, `--golden` | baseline: trace 722 ns/px, 17.3 ms / frame on 23 threads | yes |
| 2026-11-23 | temporal v1: history 12 moving, clip, full jitter, radiance fallback, inverse-luma weights | settle 20.3 → 10.4; motion blurred, reflections lost | **withdrawn** (§3.6) |
| 2026-11-23 | temporal v2: moving behaviour restored bit for bit; radiance fallback and no edge taming, still camera only | settle 20.3 → 13.2 | yes |
| 2026-11-23 | column tops (§3.2) | step 5.19 → 4.91 ns (within noise); bit-identical | yes |
| 2026-11-23 | shaft eases (§3.4) | shafts + resolve 27.3 → 21.9 ms; bit-identical | yes |
| 2026-11-23 | branch-free axis choice | step 4.88 → 5.68 ns | no |
| 2026-11-23 | unchecked loads in the walk | 4.88 → 4.90 ns | no (unsafe for nothing) |
| 2026-11-24 | column ceiling jumps (§3.3), first version: skipped the test of the entered cell | 30 % of pixels wrong, worst 203 | bug, fixed |
| 2026-11-24 | column ceiling jumps, fixed | walk 241 → 186 ns, trace −14 %, 0.19 % pixels differ | yes |
| 2026-11-24 | the ceiling kept in a local, re-read at brick changes | no change | no |
| 2026-11-24 | `SceneRay` / `SceneJump` for readability | 186 → 220 ns, then 188 ns with `canJump` | yes, with `canJump` |
| 2026-11-24 | `releaseFlood` after the copy into the volumes (§3.7) | 741 → 307 MB while rendering; bit-identical to the step before | yes |
| 2026-11-24 | bricked light volumes, one triplet for a uniform brick (§3.8) | volumes 118 → 28 MB, 307 → 222 MB while rendering; trace unchanged; bit-identical | yes |
| 2026-11-24 | light shafts as blockland draws them: a march a block of 8 x 8 pixels over the averaged sky, no random number, no screen-space history | the glow that trailed across the screen while walking is gone; shafts 2.6 → 0.7 ms a frame on 23 threads | yes |
| 2026-11-24 | wide columns of 32 x 32 over the narrow ones (§3.3) | walk 188 → 96 ns, water mirror 29 → 12.5 steps, trace 143 → 112 ms; 75 fps on 23 threads | yes |
| 2026-11-24 | `--bench` prints a paced line (frames timed whole as the window draws them: median, p95, worst, frames over 16.7 ms) | window closed, 640 × 360, 23 threads: shot 1 median 13.6 ms, p95 14.5, worst 15.8, 0 of 120 over; shot 2 median 14.7, p95 15.5, worst 17.1, 1 over. The stutters were frames at the edge of the budget: the governor (§3.9) makes the margin | yes |
| 2026-11-24 | the resolution governor, a resizable window, the whole screen (§3.9) | 640 × 368 → 608 × 336 on the first run | yes |
| 2026-11-25 | the lamps' fullest block read y and z the wrong way round (`LumenLamps.fullestBlock`): on the bay (17 x 5 x 17 buckets) the scratch every worker sizes by it could be too small, and lamps near the pier were dropped silently | fixed, a selftest compares it with a walk over the three axes; the picture's pins moved (the light that was missing is back) | yes |
| 2026-11-24 | each resize built a new frame and its pool | the old frame was never freed (its `Shared` count passed through the pool's trait-typed kernel, F10): memory grew with every window drag and every step of the governor | **replaced** |
| 2026-11-24 | `LumenFrame.fit` / `LumenPost.fit`: buffers that only grow and are reused below their size, the pool kept; the picture finished at the window's own size, any size (no system stretch) | 7 governor resizes in 40 s: 162 MB flat; 50 resizes in the selftest reuse the same buffers | yes |
| 2026-11-24 | the governor rose on "under 75 %": 560 × 320 cost 72 %, 640 × 368 cost 97 %: it hunted, the picture restarting every second | | **replaced** |
| 2026-11-24 | rise only when the next step's predicted cost (∝ scale²) fits under 85 %; a drop after a rise doubles the patience (30 to 480 frames); floor 0.2 of the window; `--fps N` | checks in `lux_schedule` | yes |

## 8. Source

- `examples/rendering/dusk/src/world/scene.axle`: `tops`, `ceil`, `ceilingOf`, `canJump`, `columnJump`, `SceneRay`,
  `SceneJump`, `sceneLeave`, `sceneNext`; the walks `trace` and `visibility`.
- `src/render/pathlight/pathlight_shaft.axle`: `LumenShaft.window`, `LumenShaft.air`.
- `examples/rendering/dusk/src/render/frame.axle`: `blendPixel`, `historyAsRadiance`, `frameAsRadiance`,
  `frameTameEdge` (moving camera only).
- `examples/rendering/dusk/src/app/measure.axle`: `golden`, `settle`, `benchWalk`, the ray counts of `bench`.
- `examples/rendering/dusk/src/render/worker.axle`: the ray counts per kind.
- `src/voxel/light/world.axle`: `VoxLightWorld.releaseFlood`; `examples/rendering/dusk/src/app/session.axle` calls it.
- `examples/rendering/dusk/src/light/lightvol.axle`: `LumenLight` (bricks, pool, triplets, `cellAt`), `LvBlock`,
  `lvLightWord`, `lvCoverWord`, `lvSkyWord`.
- `examples/rendering/dusk/src/world/scene.axle`: `ceilWide`, `jumpShift`, the `shift` of `ceilingOf`, `canJump`,
  `columnJump`.
