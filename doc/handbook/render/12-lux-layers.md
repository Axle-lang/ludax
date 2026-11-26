# 3.12 Lux: layers of light, keys and caches

[Handbook](../README.md) · previous: [3.11 The face cache](11-face-cache.md) · next: [3.13 Dusk](13-dusk.md)

## 1. Contract

`src/render/lux/graph` is the frame of the layered light. Each computation of light (sky tables, shadow pages, fog,
shading, grade) is a **layer**; the buffers between layers are **transient** (one frame) or **caches** (kept across
frames). The library decides what runs, when a cache becomes visible, and how the screen layers group; the program
runs the layers on its job pool.

- **In**: a graph (`LuxGraph`: layers, buffers, reads, writes, outputs), and once a frame the frame's inputs
  (`LuxView`).
- **Out**: the frame's run list (`LuxScheduler`: layer and slice, in order), the fused groups of screen layers, the
  moment each cache is swapped, the measured cost of each layer and the scale that keeps the frame inside its time
  (`LuxBudget`).
- **Guarantees**
  1. No layer reads live state: everything comes from one `LuxView` copied at the start of the frame.
  2. A reader never sees a cache half written: readers see the front copy, the refresh writes the back one, and the
     swap happens after `endFrame`, with no worker running (`LuxCache`, `swapIfDue`).
  3. A refresh spread over N frames always finishes, whatever changes in the meantime; the next refresh starts after
     it, from the newest key. No cache can be starved by an input that moves every frame.
  4. The decisions are integer comparisons: the same frames give the same runs, slice for slice, on any machine and
     with any number of threads.
  5. A layer that nothing visible needs does not run (liveness), and a cache no live layer reads does not keep its
     writer alive.

## 2. Why

The path-lit pictures before lux (`pathlight`, chapters 3.1 to 3.11) sequence their stages by hand in one kernel,
with a barrier on the pool between every stage, and decide invalidation case by case: an epoch here, a phase there,
a full redraw every 24 relights. Each new effect (fog, shadow, water, grade) added another hand-written rule, and
most visual faults reported (a shadow made for one sun beside a sky made for the next, a stepping picture under a
running clock) were two of those rules disagreeing. Lux states the rules once:

- every cache is keyed on integers (`LuxKey`): the world's epoch, the **step** of the sun, the camera's **cell**,
  the epochs of the art table and of the settings, the frame. Continuous inputs enter through steps, so a cache
  made at one step stays valid until the next, and its readers blend two generations instead of popping;
- every layer says which of those inputs it reads (`LUX_IN_*`), how many frames a refresh may take, and how often it
  must be redone anyway;
- every read says whether it wants this frame's result (`reads`, an ordering) or the previous frame's
  (`readsPrevious`, no ordering: history).

The model is Unreal's render dependency graph and Frostbite's frame graph (declare, compile, execute; persistent
state as external resources), with the budgeted refreshes of Lumen's surface cache (a fixed share of the cache per
frame).

## 3. Mathematics

### 3.1 Staleness

For a layer `l` with input mask `m`, period `p`, slices `s`, last key `K_l`, and feeds `F(l)`:

```
stamp(l)  = sum over q in F(l) of version(q)                 versions only grow, so the sum changes
                                                             exactly when one of them does
stale(l)  = never ran
          or (K differs from K_l on the bits of m)
          or stamp(l) != stamp seen at l's last refresh
          or (p > 0 and frames idle + 1 >= p)
```

A stale layer starts a refresh at this frame's key. With `s = 1` its version rises when it is scheduled, so the
layers after it in the same frame see it as new. With `s > 1` it runs slice 0, 1, ..., s-1 on successive frames and
its version rises at `endFrame` after the last slice.

### 3.2 The sun's step and blend

```
sunStep  = floor(dayTime * 1440)            one step per 0.25 degrees of the sun's turn (one minute of the day)
sunBlend = dayTime * 1440 - sunStep         in [0, 1): the weight of the next generation
```

### 3.3 The camera's cell

`floor(eye / 16 m)` on each axis, each masked to 21 bits and packed: x in bits 0-20, y in 21-41, z in 42-62. A
world-space cache centred on the camera is re-centred exactly when the camera crosses a 16 m cell.

### 3.4 The governor

With target `T` (16.67 ms for 60 frames a second; `retarget` changes it while playing) and frame time `t`:

- **Fall.** Three frames in a row with `t > 0.95 T` lower the scale by 1/16. Falling is quick so a heavy view does not
  drop frames for long.
- **Rise.** The scale rises by 1/16 only after `patience` frames in a row whose *predicted* cost at the next step stays
  under 85 % of `T` (`LUXB_RISE_FIT`). Rising only where the next step fits keeps the scale from hunting: with the
  first rule tried, "under 75 %", 560 x 320 cost 72 % and 640 x 368 cost 97 %, and the picture restarted every second.
- **Patience.** It starts at 30 frames. A fall right after a rise is the sign of hunting and doubles it, up to 480.
- **Prediction.** `endFrameSplit(nanos, scaled)` takes the part of the frame that grows with the picture's pixels
  (`scaled`) and predicts `(nanos - scaled) + scaled * (next / now)^2`. The rest (a display at a fixed output size) does
  not shrink with the picture; taking all of it as growing kept an upscaled 1080p picture at its floor, where 9 of its
  13 ms were the output's own. `endFrame(nanos)` is the case `scaled = nanos`.

The scale stays in `[floor, 1]`. A held scale (reference pictures, checks) is never moved: the governor reads wall-clock
time, so only a held scale gives the same picture twice. Three helpers turn a scale into sizes: `luxShownSize(w, h)`
(the window rounded down to 16, at least 16), `luxComputedSize(shown, scale)` (each side the nearest multiple of 16) and
`luxStartScale(shown, pixels)` (the scale at which a picture holds about `pixels`, never above 1).

## 4. Algorithm

Once, at start-up:

1. Declare buffers (`addTransient`, `addCache`), layers (`addLayer` with a `LuxLayerDesc`), reads and writes, and
   outputs.
2. `compile`: the render graph (`GraphCompiler`) validates and orders (Kahn, lowest id first); then liveness is
   found by a fixed point from the outputs, feeds are listed, and live screen layers are cut into fused groups: a
   group continues while the layers keep one scale and read nothing of the group around their pixel
   (`readsAround`).

Every frame:

1. Fill a `LuxView`; `plan(view)`.
2. For each run `(layer, slice)` in order, dispatch to the kernel; a fused group runs each tile (`LuxTiles`, 64 x 16
   pixels) through all its layers.
3. `endFrame()`; then `swapIfDue(layer, cache)` for each cache; `budget.endFrameSplit(nanos, scaled)`
   (or `endFrame(nanos)` when all of it grows with the picture).

## 5. Complexity

| Step | Cost |
|---|---|
| `compile` | `O(L^2 E)` for `L` layers and `E` edges; tens of layers, once |
| `plan` | `O(L + sum of feeds)` integer operations a frame |
| `endFrame`, `swapIfDue` | `O(runs)`; a swap is two integer stores |
| `LuxCache.carry` | `O(size)`, only for partial refreshes |

The SIMD lanes (`src/render/lux/simd/lux_simd.axle`), measured on 2026-11-23, one thread, 921 600 pixels:

| Loop | Scalar | `f32x8` |
|---|---|---|
| exposure, 3x3 matrix, `x / (1 + x)`, planar buffers | 0.29 ns/px (vectorised by the compiler) | 0.29 ns/px |
| the same, writing interleaved RGB | 1.31 ns/px (left scalar) | — |
| Beer-Lambert fog, `light * e^(-k d)` | 13.2 to 14.0 ns/px with `lightExp` | 0.53 ns/px with `luxExpNeg8` |
| `f32x8` with `.fma()` (F11) | — | 3.77 ns/px, 9 times slower than `*` and `+` |

## 6. Observations

- Planar layout is most of the SIMD gain: the compiler vectorises a plain loop over planar `f32[]` by itself. Lanes
  by hand pay where it stops: a call (`exp`), a selection, a long body.
- `.fma()` on a dispatched vector shape is a call through the start-up trampoline (AXLE_COMPILER_FINDINGS F11);
  `a * b + c` is contracted to `vfmadd` anyway.
- A vector `store` through a parameter does not count as a write for the `mut` rule (F12): such a parameter must be
  declared without `mut`.
- A container of ours cannot hold a class (`Vec<LuxCache>` fails E0513 in `Vec.getOr`), so the program owns its
  caches and hands them to `swapIfDue`.
- `e^x` in lanes is within 2e-7 of the f64 reference in `2^y` form; through `x / ln 2` rounded to f32 the error grows
  as `|x| * 6e-8`: 2e-6 at -20, 4e-6 at -79.

## 7. History

| Date | Change |
|---|---|
| 2026-11-23 | First version: keys, view, layers, graph (liveness, feeds, fusion, `readsPrevious`), two-copy caches, scheduler, budget, tiles, SIMD lanes; suites `LuxGraphSuite`, `LuxScheduleSuite`, `LuxSimdSuite` |

## 8. Source

- `src/render/lux/graph/lux_key.axle`: `LuxKey`, `LUX_IN_*`.
- `src/render/lux/graph/lux_view.axle`: `LuxView`, `sunStep`, `sunBlend`, `cameraCell`.
- `src/render/lux/graph/lux_layer.axle`: `LuxDomain`, `LuxLayerDesc`, `luxLayer`.
- `src/render/lux/graph/lux_graph.axle`: `LuxGraph`.
- `src/render/lux/graph/lux_cache.axle`: `LuxCache`.
- `src/render/lux/graph/lux_scheduler.axle`: `LuxScheduler`.
- `src/render/lux/graph/lux_budget.axle`: `LuxBudget`, `LUX_FRAME_60`.
- `src/render/lux/graph/lux_tiles.axle`: `LuxTiles`, `LuxTile`.
- `src/render/lux/simd/lux_simd.axle`: `luxExpNeg8`, `luxExp2Neg8`, `luxClamp8`, `luxMix8`, `luxMin8`, `luxMax8`.
- Tests: `tests/src/lux_graph.axle`, `tests/src/lux_schedule.axle`, `tests/src/lux_simd.axle`.
