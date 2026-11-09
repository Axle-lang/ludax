# kinetic

A headless demo of the `kinetic` physics engine (`src/sim/kinetic`). It builds a small world, simulates six seconds
of it (720 steps of 1/120 s), checks the result, and draws it from the side into `kinetic.png`:

* a tilted plank with a box that slides down it (friction 0.3 is below tan 20 degrees) and two balls that roll,
* a pyramid of 15 boxes,
* six balls dropped and thrown toward it, bouncing with restitution 0.55,
* a chain of four capsule links and a heavy bob on ball-and-socket joints, released 60 degrees from the vertical,
* a floor and four walls (planes) that keep the side view honest.

```sh
cd examples/engine/kinetic
axle build -O 3
./target/kinetic-demo.exe              # prints the checks, writes kinetic.png
./target/kinetic-demo.exe --out my.png
```

The exit status is the number of failed checks, so it can run in a script.

## What it checks

Ten checks, printed with `ok` or `FAIL`:

| Check | How |
|---|---|
| The pyramid still stands | every box within 12 cm of where it was placed (it sinks by the 5 mm contact slop per row) |
| The pyramid is calm | its fastest box is below 0.05 m/s (it has gone to sleep: 0) |
| Nothing left the world | all dynamic bodies finite, above the floor, inside the walls |
| The box slid down the ramp | its x moved right of -5 |
| The chain's joints held | the two anchors of every joint never more than 8 cm apart (about 7 mm in the run) |
| The bob stays within the chain's length | distance to the pivot below 4.4 m |
| Energy never rose | peak total energy (kinetic plus potential) at most 1 % above the start |
| Energy was dissipated | the end energy is lower than the start |
| Determinism | a second run of the same scene ends in the identical state hash; a different seed does not |

## The picture

`kinetic.png` is a side view (x to the right, y up, depth ignored): boxes are filled with their front face, balls
are discs with a line that shows how far they have turned, capsules are rods, yellow dots are joint anchors, red dots
are the last step's contact points, and the faint white dots are the paths of the balls, the slider and the bob
sampled every 8th step. The file is a PNG written by the library's encoder through `draw/png.axle`:

## Layout

```
src/main.axle           run, check, draw
src/scene/scene.axle    the world and the handles into it
src/scene/verdict.axle  counts and prints the checks
src/draw/side_view.axle the picture
src/draw/canvas.axle    pixels, lines, discs, polygons
src/draw/png.axle       the PNG file
```

## Limits (of the demo and of the engine it shows)

* The picture is 2-D: depth is ignored, and a body that moves in z shows only its x and y.
* Shapes are spheres, boxes, capsules and planes only. There are no meshes, heightfields, compound shapes or
  cylinders.
* There is no continuous collision detection: something that moves further than its own thickness in one 1/120 s
  step can pass through a thin wall. The demo's fastest body is far below that.
* Resting bodies sit about 5 mm inside each other (the penetration slop), and a tall stack creeps sideways by less
  than a millimetre per second until it falls asleep.
* The chain's joint gap is not zero: a whipping free end of a six-link chain reaches about 5 cm (see
  `tests/src/kinetic_joints.axle`); here it stays under 1 cm.
* There is no gyroscopic term, so a freely spinning body with unequal moments of inertia does not precess exactly.
* The demo's determinism is checked on one machine and one compiler. The engine uses only IEEE `+ - * /`, `sqrt`
  and its own `sinD`/`cosD`, but a bit-identical result on another platform has not been verified.
