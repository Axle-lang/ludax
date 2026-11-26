# 3.15 View layers: fields, looks and particles

## 1. Contract

Everything that wobbles, glows or drifts is written as data on three pieces of the engine, and a program never codes
an effect by hand:

| Piece | Where | What it is |
|---|---|---|
| **Field** `LuxFieldTape`, `LuxField` | `src/core/field` (layer 1) | a function of a point and the time, built from a closed set of ops, evaluated with its exact gradient and filtered by the pixel's footprint |
| **Look** `LuxLookBank`, `LuxFx` | `src/render/lux/look` (layer 5) | how a surface responds to fields: colour, glow, tilt, roughness, bend of what is seen through; bound to block ids |
| **Particles** `PtcEffect` | `src/sim/particles` (layer 4) | a pool of plain arrays moved by a stack of closed ops, spawned deterministically |

The fields sit in the core so that the simulation (particles, wind, later physics) reads the same functions as the
renderer. This chapter is what was built.

## 2. Why

The water, the portal, heat haze, waving leaves and lava are the same three questions asked at a hit: what varies
(a field), how does the surface respond (a look), which blocks respond so (a binding). Every engine that layers effects
cheaply flattens the stack before the hot loop (Unreal compiles materials into one shader, Niagara compiles a module
stack into one script, Blender's SVM interprets a flat byte code). Axle has no JIT and its trait rules (E0605, E0709)
forbid a tree of trait objects, so the stack is a closed `enum` evaluated by one `match` over flat arrays.

## 3. Mathematics

### 3.1 Two kinds of node, one order

A **point** node is a place to read at: coordinates `(x, y)`, the footprint `fp` in its own units, the Jacobian
`J = ∂(x, y)/∂(u, v)` against the hit's coordinates, and the hit's footprint. A **value** node is a number and its
gradient against `(u, v)`. Eight floats a node, in one `f32[]` per worker.

A node can only name nodes built before it: the graph is a DAG by construction, the build order is an evaluation
order, a node shared by two consumers is evaluated once. A look lists the nodes its ops need (`compile`, a depth-first
mark) and evaluates only those.

### 3.2 Exact gradients, forward

| Op | Point | Jacobian | Footprint |
|---|---|---|---|
| `here` | `(u, v)` | `I` | `fp` |
| `scale(p, k)` | `k p` | `k J` | `|k| fp` |
| `scroll(p, vx, vy)` | `p + o(t)` | `J` | `fp` |
| `warp(p, a, b, s)` | `p + s (a - ½, b - ½)` | `J + s [∇a; ∇b]` | `fp + s L fp₀`, `L = max(L_a, L_b)` |
| `pixelate(p, c)` | `(⌊c p⌋ + ½) / c` | `J` (kept: the motion stays in the slope) | `max(fp, 1/c)` |

A value read at a point turns its own gradient into the hit's through the transpose:
`∂f/∂u = g_x J₀₀ + g_y J₁₀`, `∂f/∂v = g_x J₀₁ + g_y J₁₁`. `add`, `mul` and `remap` follow the sum, product and
scale rules. Value noise has an exact gradient (`lux_noise`): with the fade `s(t) = t²(3 - 2t)`,

```
∂n/∂x = s'(fx) ((b - a) + ((d - c) - (b - a)) s(fy)),   ∂n/∂y = s'(fy) (bottom - top),   s'(t) = 6t(1 - t)
```

**The warp's footprint is safe.** For `p' = p + s g(p)` with `g` L-Lipschitz, `|p'(x) - p'(y)| ≤ (1 + sL)|x - y|`:
the footprint grows by at most `s L fp₀`. `L` is a number of the node, computed at build time (an octave of value noise
has slope at most 1.5 a cell: `L_fbm = L_p Σ aᵢ fᵢ 1.5 / Σ aᵢ`), so the bound costs nothing per hit. Checked: no slope
measured on 400 points exceeds the bound.

### 3.3 The footprint fade

Each octave of frequency `f` is kept with weight `w = 1 - smoothstep(1, 4, fp · f)` and replaced by its mean ½
otherwise (two octaves wide, the ocean's rule of 3.14 §3.6.1). On average over many points the value nears the mean
as the footprint grows; a single point may not (two octaves of opposite signs: removing one moves the value away), which
is why the check averages 500 points.

### 3.4 Time

A scroll's offset `o = v t` is computed once a frame in f64 and wrapped by 4096 units (one jump every 4096 / v seconds,
over two hours at 0.5 a second); per point the scroll is one f32 add. An f32 clock would lose a millisecond of
precision after an hour.

### 3.5 Looks

| Stage | Op | Combines by |
|---|---|---|
| 1 material | `Albedo`: colour × ramp(field) | product |
| 2 shape | `Normal`: slope += k ∇field | sum (∇ is linear: two normals are one normal of the sum, checked to 1e-5) |
| 3 response | `Rough`: + k field; `Emit`: + ramp(field) | sums |
| 4 interface | `Bend`: bend += k ∇field | sum |

Ops run in stage order whatever order they were added in; checked: albedo-then-emit equals emit-then-albedo bit for
bit. A look never traces a ray; the program reads the `LuxSurface`, traces what it asks (a `Thin` interface, `LuxInterface::Thin` in the look bank (`LuxLookBank.thin`, `lux_thin.axle`), continues the ray,
bent and tinted) and combines, so looks nest (a portal seen through water seen through a portal) with no rule beyond a
depth limit (3 thin surfaces).

### 3.6 Particles

Each op is one flat loop over the pool, in the order of the stack: `Gravity` (v += g dt), `Drag` (v ×= 1 - k dt),
`Wind` (v += (w - v) k dt), `Attract` (v += (c - p) k dt + (ŷ × (c - p)) s dt: pulled in and swirled round a vertical
axis), `Rise`, `Wobble` (a hashed push per particle and time slot, no state), `Colour` and `Size` over the life,
`Flicker`. Births per tick are `⌊(t+1) r dt⌋ - ⌊t r dt⌋`, a function of the tick alone; each emitter draws from a
`Pcg32` seeded by the effect, its key and the tick; the dead are swap-removed in index order. Two runs give the same
particles bit for bit (checked over 300 ticks).

**Drawing** (`LumenFrame.splat` in dusk): after the resolve and the shafts, into the picture the display reads. Without the upscaler that
picture is the frame's own and is rebuilt every frame, so sprites never smear. With it the picture is the upscaler's output,
which becomes the history at `swap` (handbook 3.16): the sprites reach the history, and the next frame's neighbourhood
clamp bounds the trail they leave. Bloom takes the bright ones. A
sprite is a 4 × 4 diamond of texels (whole in the middle, half on the rim), hidden where the pixel's surface is nearer.

## 4. Algorithm

Per hit on a bound block: `LuxFx.lookOf(block)` → `shade(look, u, v, fp, regs)`: evaluate the look's nodes in order
into the registers, then its ops in stage order into one `LuxSurface`. The face's two world axes are `(u, v)`, so a
wall of portal cells is one continuous field. Per frame: `LuxFx.prepare(t)` writes the scroll offsets and compiles the
looks if they changed. Per tick (60 a second): `emit`, then `step`. Per frame: `splat`.

## 5. Complexity

| What | Cost | Measured |
|---|---|---|
| a field node | O(1); a noise octave 4 hashes | — |
| a look at a hit | O(nodes + ops) | the portal (3 scrolls, 2 noises of 2 octaves warping a 3-octave noise, pixelated; emit and bend): **112 ns** a hit, one thread |
| a portal on 5 % of a 640 × 360 picture | 11 500 hits | about 1.3 ms of CPU, 0.06 ms on 23 threads |
| particles, step | O(n × ops) | 600 motes: microseconds |
| particles, splat | O(n + covered pixels) | serial, microseconds |
| memory | 8 floats a node a worker; 13 floats a ramp; 13 arrays × capacity for particles | the portal's tape: 14 nodes, 448 bytes a worker; 600 motes: 31 KB |

## 6. Observations

- The portal (dusk `--shot 5`): a violet swirl that drifts and folds, 16 texels a block, the sunset bent through it,
  the pier lit violet by its lamp, motes drawn in and swirled round it.
- The first portal saturated to white (strength 2.2): the ramp was narrowed and the strength lowered to 0.9, so the
  scene behind shows through.
- The first gradient check failed at 5 %: the error was the check's own, central differences in f32 far from the
  origin (a step of 0.0005 at |u| = 11 is a few hundred f32 units) and across lattice lines where the fade's second
  derivative jumps; the check now runs near the origin with a step of 0.001, and each op alone agrees to 1e-3.

## 7. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| 2026-11-24 | design by three agents: architecture, research with patents, particles and wind | — | yes |
| 2026-11-24 | fields in `core/field` with forward gradients and footprint fade; looks and bindings in `render/lux/look`; particles in `sim/particles`; 21 checks | portal look 112 ns a hit | yes |
| 2026-11-24 | dusk: obsidian, the portal on the pier, its look, its lamp, its motes; `--shot 5` | — | yes |

Not built yet (the design's later steps): baking a field into a table each frame (the design's 0.10 ms instead of
0.69 ms for the portal), the shared wind field in `src/sim/wind`, the leaves' texel shift in the walker, heat haze,
lava as a look, motion vectors from the fields for the history.

## 8. Source

`src/core/field/lux_noise.axle`, `src/core/field/lux_field.axle`, `src/render/lux/look/lux_look.axle`,
`src/sim/particles/particles.axle`, `examples/rendering/dusk/src/render/looks.axle`, the worker's `thin`, the frame's
`splat`, the session's `portalMotes`; checks in `tests/src/lux_field.axle`.
