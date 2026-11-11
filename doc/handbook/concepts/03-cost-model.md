# 1.3 The cost model

[Handbook](../README.md) · previous: [1.2 Determinism](02-determinism.md) · next: [1.4 The complexity ledger](04-complexity-ledger.md)

## 0. Where a frame goes (2026-11-12)

`McSession.loops` times every loop of a frame; `--walk` prints them (`loop:` lines) with the start-up's steps
(`load:` lines: steps, total, longest step, which is how long the loading screen stands still).

Walking in a forest under a running clock, 12 workers, 28 ms a frame:

| Loop | ms a frame |
|---|---|
| fill (a ray, a cache read and a blend for every pixel) | 21.2 |
| display | 5.6 |
| samples | 2.6 |
| bake step | 0.4 |
| publish faces, skyline, world stream, view sync | 0.3 |

Build level matters more than any of it: a plain `axle build` used to be `-O 1`, three to four times slower; the
packages now set `[profile.dev] opt-level = 3`.

## 1. The unit

Everything is counted in **nanoseconds a pixel on one thread** (`ns/px`). A picture has `P = 921 600` pixels, so

```
1 ns/px  =  0.92 ms a frame on one thread
frame time on one thread  T1 = P * sum(ns/px of every stage)
frame time on n workers   Tn = T1 / speedup(n)        (speedup(12) is about 5.5, see 4.1)
processor share           = T1 * fps / (cores * 1000 ms)
```

One thread is the honest unit: it measures **work**. Wall time on many threads hides waste, and the number of threads
that helps is itself a measurement ([4.1](../engine/01-job-pool.md)).

A processor at 5 GHz runs about 5 cycles a nanosecond, three to four simple instructions a cycle when nothing
stalls. Useful sizes:

| Operation | Cost |
|---|---|
| add, multiply, compare (f32 or i32) | 0.2 to 1 cycle, pipelined |
| a load that hits the first-level cache, with its bounds check | 1 to 2 cycles |
| `sqrt` f32 | 12 to 18 cycles of latency, one every 4 to 6 cycles in a row |
| division f32 | 11 to 13 cycles, with a guard branch (Axle traps on a zero divisor) |
| division or remainder i32 | 20 to 40 cycles |
| a mispredicted branch | 15 to 20 cycles |
| a call that is not inlined, returning a struct | 5 to 10 cycles |
| an exact `atan2` (f64 minimax) | about 60 cycles |

## 2. The budget of a frame

Measured on 2026-11-10 with the head turning at 1.2 rad/s (`--walk 2 --speed 0 --turn 1.2 --threads 1`).

| Stage | Ground view | Horizon | Sky under trees | Unit |
|---|---|---|---|---|
| Camera ray | 2.7 | 2.7 | 2.7 | ns/px |
| A ray stopped before its first step (fixed overhead) | 26 | 26 | 28 | ns/ray |
| Primary visibility (`plain`) | 73 | 106 | 76 | ns/ray |
| A full shaded sample | 353 | 338 | 180 | ns/sample |
| Trace + fill, whole frame | 103 | 166 | 94 | ms |
| Temporal | 2.7 | 2.8 | 2.8 | ms |
| Display | 40 | 41 | 42 | ms |
| **Frame on one thread** | **147** | **236** | **169** | ms |
| Frame on 12 workers | 26 | 46 | 31 | ms |

The first three rows come from `--bench`, the rest from `--walk`.

### 2.1 Where a moving frame's time is

For the ground view, with `s = 4`:

```
samples   P / 16  * 353 ns  =  20 ms
fill      P * 15/16 * (73 ns ray + ~15 ns blend)  =  76 ms
other pixels that shade themselves (no sample speaks for them)  ~  7 ms
display   P * 43 ns  =  40 ms
```

The primary ray is half the frame, the display a quarter.

## 3. Complexity, in symbols

| Mechanism | Time | Memory |
|---|---|---|
| Camera ray | `O(1)` a pixel | none |
| Primary ray | `O(k)` with `k` the box and cell steps (9 to 14 measured) | none |
| Sample shading | `O(1)`, plus one shadow ray `O(k)` outside the baked radius, plus one mirror ray for a smooth surface | none |
| Fill | `O(1)` a pixel after its ray | 7 floats a sample: `7 P / s^2` |
| Skyline rebuild | `O(C + B)` a frame, `C` chunks (625), `B` bearings (720) | `B` floats |
| Skyline test | `O(1)`: two comparisons, or one `atan2Quick` in the horizon band | none |
| Gap field of a section | `O(4096 * 7)` to build, `O(1)` to read | 1 byte a cell |
| Temporal | `O(1)` a pixel | 10 floats a pixel, twice |
| Bloom | `O(P / 4 * 5 * 2)` for the two blurs, `O(P / 16)` for the rest | `P` floats in all levels |
| Compose | `O(1)` a pixel | `P` words out |

## 4. How to measure

| Tool | Gives | Use it for |
|---|---|---|
| `--bench` | ns of the camera ray, a ray stopped at once, the primary ray, a shaded sample; two rounds | the cost of one building block, away from the frame |
| `--walk S --speed V --turn R --threads 1` | the work of a frame by stage, on one thread | the budget table above |
| `--walk ...` (default threads) | median, p95, p99 and worst frame, spikes with their stage | what the player feels |
| `--frame out.bmp` then `cmp` | whether a change moved a bit | every change that claims to be invisible |
| `axle build --emit llvm` | the IR after the passes | calls, divisions, panics in a hot function |
| `axle build --emit decisions` | what the compiler proved or refused at each site | refcount atomicity, bounds, inlining |

### 4.1 Rules of measurement

1. **One run is not a measurement.** Other processes move a number by 20 to 30 %. Run twice; `--bench` already does.
2. **Change one thing.** The skyline test was found to cost 18 ns a ray only by building once with it removed.
3. **Measure the fixed part apart from the part that grows.** "A ray stopped at once" (26 ns) against a whole ray
   (73 ns) says the walk is 47 ns for 9 steps, about 5 ns a step, and that the overhead is a third of the ray.
4. **Count before timing.** The tracer was instrumented once to count steps, box moves, section changes and texels a
   ray (9.3, 0.19, 0.37, 1.2 on the ground). The counts said the brick skip was almost never used; no timing would
   have.
5. **Keep the failed experiment.** It is in [5.1](../history/2026-11-optimisation.md) with its number, so nobody
   tries it again.

## 5. Observations

- Every stage costs about the same order: 40 to 100 ns a pixel. There was no single culprit, and no change gave more
  than a third. The frame went from 345 to 147 ms by nine changes.
- Arithmetic is rarely the cost. In four cases out of five the cost was something the source did not show: an integer
  division in a wrap-around, a string comparison in a colour lookup, an exact `atan2` in a table lookup, fields
  reloaded for each pixel.
- A branch that looks unpredictable may be predicted well: the axis choice of the ray walk was faster as branches
  than as arithmetic, because neighbouring rays take the same turns.

## 6. Source

`games/blockland/src/app/mc_walk.axle` (`walk`, `bench`, `report`), `mc_frame.axle` (`bench`).
