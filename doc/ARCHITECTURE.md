# Architecture

Ludax is one crate organised in layers. A module imports from its own layer or below, never above.

| Layer | Directory | Responsibility |
|---|---|---|
| 1 | `src/core` | maths, memory, containers, ids, random numbers, time, log, jobs, profiler, test harness |
| 2 | `src/data` | virtual file system, asset database, importers (glTF, `.bbmodel`, images, audio), serialisation |
| 3 | `src/world` | sparse-set ECS, scenes, transform hierarchy, spatial indices |
| 4 | `src/sim` | `kinetic` physics, animation, audio, navigation, gameplay |
| 5 | `src/render` | scene extraction, render graph, command stream, backends, lighting |
| 6 | `src/runtime` | main loop, game modules, settings |
| 7 | `src/voxel`, `src/openworld` | content modules; independent of each other |

The platform (windowing, GPU) is [smalt](https://github.com/Axle-lang/smalt); the editor, Ludax Studio, is built
on [zaffre](https://github.com/Axle-lang/zaffre) and lives outside the runtime.

## Design rules

1. **No fixed-size array as a value** (`T[N]`): the compiler we pin miscompiles it. Scalars, `malloc` buffers or
   our own containers instead.
2. **Data first.** Components are plain structs; systems are free functions over them.
3. **Generated code replaces reflection.** Axle has none: serialisation, the inspector and component
   registration are produced by a tool from the declarations.
4. **Determinism.** No wall clock in the simulation, no iteration order that depends on a hash or a thread,
   random numbers from an explicit `Pcg32`.
5. **Large worlds.** Positions are `f64`; rendering works camera-relative in `f32`.
6. **Rendering is data.** The scene is extracted into a command stream; a backend consumes it. The CPU reference
   backend is deterministic and is the oracle the GPU backend is tested against.
7. **One lighting library**, written once in GLSL and mirrored on the CPU, with numeric parity tests.
8. **Observable.** Per-pass CPU/GPU cost, the resources a pass used, and `LightExplain(pixel)`: which lights reach
   a pixel, with what contribution, and why a light was excluded.

## Lighting contract

Linear HDR throughout, tone-mapped once at the end. A white-furnace scene must return exactly its albedo.
Energy is conserved; light falloff, shadow mode (none / map / ray / baked) and include/exclude masks are explicit
per light. A CPU path tracer provides the reference every shortcut is compared with.

## Build and checks

```sh
axle fmt --check
cd tests && axle build -O 3 && ./target/tests
```

Use `-O 3` (the default is several times slower) and pin the compiler version: Axle breaks between weekly
releases.
