# orrery

Entities, components, a scene tree and a fixed step, with no window and no dependency but ludax.

A star, five planets, three moons and a station, and a comet move through ten simulated seconds. The program plays
them twice, once at a steady 60 frames a second and once with frames of random length, and checks that both end in
exactly the same state. It draws every body's path, seen from above, into `orrery.png`.

```sh
cd examples/orrery
axle build -O 3
./target/orrery.exe
```

## What it shows

| Idea | Where |
|---|---|
| An entity is an id; what it has lives in stores | `src/sim/bodies.axle`: `Orbit` and `Body` in `ComponentStore`s |
| A scene tree: moons orbit planets, the station orbits a moon, transforms compose | `Scene::addChild`, `worldTransform` |
| Systems are free functions over the stores | `src/sim/systems.axle` |
| A broad phase that finds touching pairs | `SpatialGrid`, rebuilt each tick |
| A fixed step makes the frame rate irrelevant | `src/sim/run.axle`: `FixedStep` and two pacings, one checksum |
| Destroying a parent destroys its subtree, and stores are swept | tick 300: the planet with moons takes 4 entities with it |

The exit status is 0 when the two runs agree and 1 when they do not.
