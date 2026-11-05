# frontier

An open-world drive on the engine's runtime layer and the `openworld` module, with no window and no dependency but
ludax.

A scripted driver takes a car across a generated landscape that is streamed in cells around it, completes a
three-stage mission and the debrief that follows, and does it all under `GameLoop` with a fake clock. The program
plays the same drive three times and prints each check:

1. at a steady 60 frames a second, recording the input of every simulation step to an `InputTape`;
2. with irregular frames (2 to 45 ms, with the odd 60 to 110 ms hitch), which must end in exactly the same state;
3. replaying the tape, saved to bytes and loaded back, under a third pacing: the same state again.

It writes `frontier.png`, a top-down map of the end of the first run.

```sh
cd examples/frontier
axle build -O 3
./target/frontier.exe
```

The exit status is the number of checks that failed (0 when all pass). The whole program, three runs of about
13 500 steps (226 simulated seconds) each, takes about a quarter of a second at `-O 3`.

## What it shows

| Idea | Where |
|---|---|
| A main loop with no clock inside: frame lengths in, whole fixed steps out | `src/sim/run.axle`, `src/sim/pacing.axle`: `GameLoop<FrontierGame>` and three pacings |
| A game as a `GameModule` | `src/sim/game.axle` |
| Systems with declared order and cost accounting | `src/sim/game.axle`: `Scheduler` constraints; `src/sim/systems.axle`: `SystemRunner` |
| Input as exact snapshots, named actions, record and replay | `src/sim/systems.axle`: `InputState`, `ActionMap`, `InputTape` |
| A world cut into cells that exist only near the car | `WorldPartition` and `CellStreamer`, tuned in `src/sim/systems.axle` |
| An arcade car on supplied ground | `VehicleModel` over `FrontierTerrain` (`src/world/terrain.axle`) |
| Missions from text, with a state machine, events and a save | `src/world/route.axle` writes the mission text; `MissionText`, `MissionBoard` |
| A sun and weather as plain data | `SkyClock`, `Weather` (advanced each step, folded into the state hash) |
| A map drawn with `Image` | `src/gfx/map.axle` |

## The map

Relief shading from the terrain height. Pale blue: every cell that was ever active along the way. Outlined in
yellow: the cells active at the end of the run, with the props the streamer holds in them (dark green trees, light
grey rocks, brown huts). The route is coloured by the stage of the mission the car was in (orange: collect three
crates at the depots, magenta: deliver to the outpost, cyan: come home); squares are waypoints (yellow depots, red
outpost, green home, white corners), the white-and-black square is where the car stopped. The three coloured
squares in the corner are the legend.

## What is and is not claimed

- The three runs end in one hash that covers the car, the driver, the mission board, the active cells, every
  streamed entity (its template and position to the millimetre), the sky and the weather. It is compared on this
  machine, under three pacings; agreement across machines is argued from the design (integer time, an explicit
  `Pcg32`, the engine's own `sinD`/`cosD`) and not measured here.
- The input of a step is quantised to 1/4096 on the axes, on the live run too, so the replay sees exactly what the
  live run saw. The driver itself is not part of a replay: the replay never calls it.
- The streamed "world" here is about 2 km across, so the car stays within 100 cells of activity. The 100 km walk
  that proves the active set stays bounded is in the tests (`tests/src/openworld_stream.axle`), not in this
  program.
- Streamed entities are scenery: they carry a transform and a template, nothing collides with them and nothing
  draws them. The depots' crates are picked up by distance, not by a physics query. There is no navigation and no
  coupling to `kinetic`: the car's physics is the openworld module's own arcade model.
- The scheduler's costs are work units counted by the systems (cells touched, events handled), not time, so they
  repeat exactly; nothing here measures real time, and the profiler is off.
- The weather and sky run and are hashed, but nothing in the drive reads them. `SkyClock` is built to feed
  `LightSky::atDayTime`; that hand-over is checked in the tests, not drawn here.
