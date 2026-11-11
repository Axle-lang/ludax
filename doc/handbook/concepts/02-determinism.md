# 1.2 Determinism

[Handbook](../README.md) · previous: [1.1 Smooth and sharp](01-smooth-and-sharp.md) · next: [1.3 The cost model](03-cost-model.md)

## 1. Contract

> The same world, the same camera and the same time of day give the same picture, bit for bit, on any number of
> threads and on any run.

This is a feature of the engine (`CLAUDE.md`, "Determinism is a feature"), and for a picture it means three things.

| # | Level | Promise | Mechanism |
|---|---|---|---|
| 1 | Arithmetic | an operation gives the same bits on every machine | IEEE-754 `+ - * / sqrt` only; polynomials for trigonometry ([3.6](../render/06-sky.md) §4) |
| 2 | Threads | which thread runs which rows cannot change a bit | a stage is a pure function of the buffers of the stage before it, written row by row ([4.1](../engine/01-job-pool.md)) |
| 3 | Time | a moving picture does not depend on how the camera got there | no history and no random number while moving ([3.7](../render/07-accumulation.md)) |

## 2. The three sources of non-determinism, and what was done

### 2.1 Random sampling

A path tracer draws random numbers: a point on the sun's disc, a jitter inside the pixel, a bounce. The picture then
converges over frames, and until it has it is noise. While the camera moves there is never time to converge.

| Random quantity | Was | Is |
|---|---|---|
| Point on the sun's disc (outside the baked radius) | uniform on the disc, new each frame | the disc's centre |
| Jitter inside the pixel | ±0.125 px while moving, ±0.5 px still | 0 while moving, ramped to ±0.5 px over 8 still frames |
| Key of a pixel's random stream | `(x, y, frame)` | `(x, y, 0)` while moving, `(x, y, frame)` still |

The soft edge of a shadow is still there: it is in the **baked** share of the sun's disc a cell sees, computed with a
fixed fan of 8 rays (golden angle), not drawn by chance.

### 2.2 History

A frame that blends in the frame before depends on every frame before it. Reprojection (finding where a surface
point was in the previous picture) made the picture a function of the camera's whole path: a turn left a different
picture from a turn right ending at the same pose.

- **Moving**: the frame's sample is the history. Nothing is reprojected.
- **Still**: frame `n` is blended with weight `1 / n` (a running mean), which depends only on the count.
- **Sky**: never keeps a history at all; it is a function of direction and time.

### 2.3 Threads

A worker claims chunks of rows from an atomic cursor, so which worker draws which rows changes from run to run. It
does not matter, because:

1. a chunk writes only its own rows of the output buffers;
2. a chunk reads only buffers no chunk of the same stage writes (the stage before, or constants of the frame);
3. per-worker scratch (the tracer's section context, its biome cache) is rebuilt from the inputs and never changes a
   result, only how fast it is found.

Rule 3 has one consequence worth stating: **a cache may not change an answer**. The tracer's last-biome cache returns
exactly what the lookup would; it is reset at each frame so a block change cannot leave a stale value.

## 3. How it is checked

```sh
target/blockland --walk 3 --speed 8 --turn 0.6 --day-speed 0 --frame a.bmp
target/blockland --walk 3 --speed 8 --turn 0.6 --day-speed 0 --frame b.bmp
cmp a.bmp b.bmp            # must be silent
```

A change that is meant to be invisible is checked the same way against the build before it. Two results are accepted:
identical, or a difference of one code in a handful of bytes when a ray's `t` is computed along a different but
equivalent sequence (the gap field moved one byte in 691 200 by 1).

## 4. What is not deterministic, on purpose

| Thing | Why it is allowed |
|---|---|
| The time a frame takes | it is wall-clock; it selects nothing in the picture |
| When a background sky bake is swapped in | the clock's tick decides the sun's place; the radiance grid follows a moment later, and a recorded run must fix the swap tick if it needs the grid's bits |
| The order chunks finish loading | the picture is restarted (`dirty`) when a chunk arrives |

## 5. History

| Date | Change | Effect |
|---|---|---|
| 2026-11-09 | sun sampled at its centre; moving jitter 0; moving random key fixed | two walks give `cmp`-identical frames |
| 2026-11-10 | no reprojection while moving; sky without history | a pose gives one picture; stars are points on a turn |

## 6. Source

`games/blockland/src/app/mc_session.axle` (`accumulate`, `MCS_JITTER_MOVING`), `mc_frame.axle` (`drawKey`,
`blendPixel`), `mc_worker.axle` (`shadow`), `src/core/jobs/kernel.axle` (the ordering contract).
