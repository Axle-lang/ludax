# 3.18 Small things: shapes inside a cell

## 1. Contract

`ShapeBank` (`src/world/shape/shape_bank.axle`, layer 3) gives a block a shape made of a few axis-aligned boxes in
sixteenths of its cell, as block models do: a torch, a flower, a button, a lever, a fence, a lantern on a chain. A
program marks such blocks with its own kind (dusk: `LumenKind::Shape`) and calls `intersect` when its walk enters one.

## 2. Light behaves as it should

| What | How | Exact? |
|---|---|---|
| a ray seen by the camera or a reflection | stops at the nearest box face (slab test), with its normal; goes on past the cell otherwise | yes |
| a lamp's shadow ray | blocked only where a box is: the shadow is the object's own outline | yes |
| the baked flood and sky (diffuse light) | the cell stops the share its boxes cover: `open = 1 - (a_x + a_y + a_z) / 3`, `a_k` the cover of the boxes' projection along axis `k`; light goes past a flower almost whole, a lever a little less | an average over directions, as a baked volume must be |
| an emitter (a torch) | its head glows (texels from row 10 up), the flood is lit by its block (`BlockLight::lamp`), and a small point lamp (`LumenLampSpec`, radius 0.15 m, flickering) lights the surroundings with shadow rays | yes |

The slab test: for each axis the interval of `t` where the ray is between the box's two planes, `[min(t0, t1),
max(t0, t1)]` with `t_i = (plane_i - o) / d`; the box is hit on `[max of the entries, min of the exits]` if not empty,
on the face of the axis entered last. A component of `d` under 1e-7 is parallel: inside the slab all along, or never
(no division by zero, which traps). A ray that starts inside a box stops at the cell's entry.

## 3. Checks

`tests/src/world_shape.axle`: the stick and the head met at their faces with their normals, a ray beside the stick
passing, a ray parallel to two axes meeting the top, a ray starting inside, volumes, and the diffuse openness of a full
cube (0) and of a torch (over 0.85). dusk's selftest: a ray meets a torch's head at its face and passes beside its
stick, a flower lets over 80 % of the flood through, a torch lights the deck beside it.

## 4. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| 2026-11-25 | `ShapeBank`; dusk's walks (`trace`, `visibility`) test shaped cells | with no shaped block placed, dusk's three pinned fingerprints unchanged | yes |
| 2026-11-25 | torches, a button and a lever by the portal, flowers on the beach | new content: the picture's and the upscaled picture's pins updated (the torches light the pier near viewpoint 1); the view under the water unchanged | yes |
