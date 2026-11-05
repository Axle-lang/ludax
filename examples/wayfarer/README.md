# wayfarer

Path finding and animation on the Ludax engine, headless. It generates a dungeon of eight rooms and
corridors, plans routes with A*, a flow field and a navigation mesh, walks eight agents along them (in four pairs
that meet head on), animates one of them as a skeleton, checks everything against independent answers and writes
`wayfarer.png`, a top-down picture.

```sh
cd examples/wayfarer
axle build -O 3
./target/wayfarer.exe        # prints what it checked, writes wayfarer.png, exits with the number of failures
```

It does not need smalt: no window, no audio, no GPU.

## What it does

| Part | Where | What is shown |
|---|---|---|
| Map | `src/world/dungeon.axle` | Rooms placed by a seeded `Pcg32`, joined by corridors two cells wide, some mud (cost 4). A seed is a map. |
| Routes | `src/app/scenario.axle` | `GridPathfinder` (A*, 8 directions, no corner cutting) per agent, then `GridPath::smoothed`; the same trips on a `NavMesh` built from the grid by `NavMeshGrid`; one `FlowField` to the walker's goal. |
| Crowd | `src/sim/crowd.axle` | `Steering::followPath` + `arrive`, plus `separation` from neighbours found by a `NeighborGrid`. Fixed step of 1/30 s. Walls are handled by sliding, outside the steering functions. |
| Walker | `src/anim/walker.axle`, `src/sim/walker_agent.axle` | An 8-bone skeleton, a procedural one-second walk clip with footstep markers, an idle clip, an `Animator` that fades between them. The agent's position advances by the **root motion** of the hips, and the animator's speed follows the wanted speed. |
| Picture | `src/gfx/` | A small canvas, saved with the library's PNG encoder. |

## What it checks

35 checks, printed as `FAIL ...` when one misses, and a summary line:

- the generator placed 8 rooms with mud, and every room can be reached from the first;
- A* costs equal breadth-first search on all 28 room pairs (on a unit-cost, 4-connected copy of the map);
- every smoothed path is shorter or equal, has no more corners than the raw one, and each of its segments is in
  clear sight; the navigation mesh finds a route for every agent, never longer than the polyline through the
  doorway midpoints and never shorter than the straight line;
- the flow field's cost at the walker's start equals the A* cost, and following its arrows pays exactly that;
- a 2 x 2 crate on the route makes the flow field stale and the new route avoids it and costs at least as much;
  removing it brings the original route back;
- all agents arrive (1467 steps), no two came closer than 0.25 cells (the smallest was 0.82, bodies are 0.6
  across), all end on open cells, and a **second run from the same seed** takes the same number of steps and
  ends with the same position checksum;
- the walker's footstep markers match two per cycle of the clip (within 4), left and right alternate, it covered
  about the length of its path, and every footstep mark lies on an open cell;
- the bind pose skins to itself, and two-bone IK puts a foot on a reachable point and stretches the leg to 0.9
  towards an unreachable one.

## Limits

- The walk is generated, not tuned: nothing makes the planted foot stand still on the ground (no foot-lock IK),
  so feet slide a little. The root motion and the footstep markers agree with each other, not with a physical
  foot.
- Steering has no knowledge of walls; it works because the paths are inside rooms and corridors and a slide
  fixes the rest. Agents can hug corners. Two agents meeting in a corridor get past by separation, not by a
  planned passing manoeuvre; with narrower corridors they could block each other.
- The mesh is made from the grid (rectangles), so it has no more freedom than the grid has; mud costs are
  ignored by the mesh. The mesh and the grid disagree on route length by design: the grid path runs through cell
  centres, the mesh path runs along the true shortest line inside its corridor.
- The picture is cluttered where routes overlap: the rooms form a chain, so many routes share corridors.
- Agents use the example's own `NeighborGrid`; the engine's world `SpatialGrid` is not in this branch.
