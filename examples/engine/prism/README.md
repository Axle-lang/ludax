# prism

The render abstraction of Ludax, end to end and headless: a world, extraction, a render graph, a command stream and the
deterministic CPU backend. It draws one 640 x 360 picture and writes it to `prism.png`.

```sh
cd examples/engine/prism
axle build -O 3
./target/prism          # prints the graph report and every check; exit status = number of failed checks
```

## What it shows

A small stage lives in a world `Scene` as entities with components: a tiled floor, ten spheres (red plastic in front,
gold behind, each row from glossy to rough), a brick cube with a procedural albedo and a normal map, a steel column, a
blue glass ball (alpha blend), a glowing bulb, a sky dome with an emissive gradient, a warm lamp (a point light, 260 000
cd) and the sun (taken from `LightSky`: its tint and strength, 0.53 degree disc). Both lights cast ray-traced shadows.

Then, as a game would call the library:

1. `RenderExtract::run` turns the world into a camera-relative `RenderScene`: positions are made relative to the camera
   in f64 and narrowed, three decoy entities (behind the camera, far to the side, far above) are frustum-culled, and the
   instances are sorted by (material, mesh) with the blended glass last, far to near.
2. A `RenderGraph` declares the passes `bvh`, `forward`, `resolve` and a `luminance-meter` that nothing needs. The graph
   compiler validates it, culls the meter, orders the rest, and finds that `scene.bvh`, `hdr` and `depth` need three
   blocks of memory.
3. `FrameRecorder` records the plan and the scene into a `CmdStream` (flat arrays; it survives a round trip through
   bytes, which the example checks).
4. `CpuRenderer` executes the stream: tile rasteriser with exact top-left coverage, PBR shading by the lighting library
   per pixel, textures through `Texture` with an anisotropic footprint, shadow rays against a BVH, tone map and sRGB.
5. The graph report prints the pass order, what each pass read and wrote, its counters and its measured time (from the
   `Profiler`), the culled pass and the memory plan.

## What it checks (each line is printed with ok or FAIL)

- the graph is valid; the three passes run in dependency order; the unused pass is culled;
- extraction culled exactly the three decoys; the scene holds both lights; the command stream round-trips;
- every pixel is finite and non-negative, and the mean radiance is sane;
- the 640 x 360 picture is **bit-identical** on one thread and on many (every float of the HDR buffer, then the bytes);
- the same stage moved by (4 000 000, 0, -3 000 000) metres renders the same picture (camera-relative f32);
- `LightExplain` on a floor pixel in a sphere's shadow says the sun is blocked, and on a pixel in the open says it
  reaches; the parts add up to the renderer's colour with difference exactly 0;
- `prism.png` reads back as the picture that was written.

On the machine it was written on, 640 x 360 takes about 190 ms on 23 worker threads and about 330 ms on one (both
include building the albedo table of the lighting library). That is a measurement of one machine, not a promise.

## What it does not do

- **There is no GPU backend.** The CPU backend is the reference the GPU backend will be tested against; the command
  stream and the graph are the contract (see `doc/RENDERING.md`). Nothing here talks to a window or a GPU.
- Shadows are hard: one ray per light towards its centre, whatever the light's radius. Soft penumbrae from sized
  lights, shadow maps and baked shadows are not implemented.
- Reflections are an environment lookup (sky above, one ground colour below, blended by roughness), not reflections of
  the other objects; there is no ambient occlusion, bounce light, fog, bloom or anti-aliasing (the edges are exact but
  unfiltered).
- Texture filtering is trilinear with up to 8 anisotropic taps; there is no texture compression.
- `LightExplain` explains the opaque surface visible at a pixel; the blended glass over it is not part of the account.
