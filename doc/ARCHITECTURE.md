# Architecture

Ludax is one crate organised in layers. A module imports from its own layer or below, never above.

| Layer | Directory | Responsibility |
|---|---|---|
| 1 | `src/core` | maths, memory, containers (packed and paletted ones included), ids, random numbers, time, log, jobs, profiler, test harness |
| 2 | `src/data` | virtual file system, asset database, importers (glTF, `.bbmodel`, images, audio), serialisation (NBT, name tables), codecs (LZ4, inflate/deflate), sector region files, zip archives, random-access files |
| 3 | `src/world` | sparse-set ECS, scenes, transform hierarchy, spatial indices |
| 4 | `src/sim` | `kinetic` physics, `fluid` water, animation, audio, navigation, gameplay |
| 5 | `src/render` | scene extraction, render graph, command stream, backends, lighting |
| 6 | `src/runtime` | main loop, game modules, settings |
| 7 | `src/voxel`, `src/openworld` | content modules; independent of each other |

Above the library sit programs, each a package depending on `ludax` by path: `examples/engine/*` (one example per
engine area), `examples/water/*` (the fluid demos and their shared `fluidview` library), `examples/rendering/lumen`
(the lit valley), and `games/*`. `games/blockland` is the Minecraft-format game: a library (`src/lib.axle`: block
registry, chunk and world formats, worldgen, the renderer's view of a streamed world, the player) plus the program
(`src/main.axle`, `src/app`) and its own tests, tools and docs (`games/blockland/{tests,tools,doc}`). The engine
imports none of them. What the picture is made of when it is path-lit (sky, SH9 dome, bloom, tone curve, the shading
core `lumenShadeCore`, the frame filter) is `src/render/pathlight`, layer 5, used by lumen and blockland alike.

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
tools/fmt.sh --check
cd tests && axle build -O 3 && ./target/tests
cd games/blockland/tests && axle build -O 3 && ./target/blockland_tests
```

Use `-O 3` (the default is several times slower) and pin the compiler version: Axle breaks between weekly
releases.
