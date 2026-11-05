# Rendering

Design rule 6: *rendering is data*. A frame is extracted from the world into a snapshot, planned as a graph of passes,
recorded as a command stream and executed by a backend. The CPU backend is deterministic and is the oracle a GPU backend
is tested against. This page is the contract between the layers; `doc/LIGHTING.md` is the contract of the shading.
Code: `src/render/{scene,cmd,graph,cpu}`; example: `examples/prism`.

## Data flow

```text
World (Scene + ComponentStore<MeshRef|MaterialRef|LightComp>)        f64 positions
   |  RenderExtract::run(camera)      frustum culling, sort, camera-relative f32
   v
RenderScene  = camera + instances (mesh id, material id, model Mat4) + lights (LightSource) + environment
   |                                                      RenderAssets: meshes, materials, textures by id
   |  RenderGraph (passes read/write named resources) --GraphCompiler--> GraphPlan (order, culled, lifetimes, aliasing)
   |  FrameRecorder::record(graph, plan, scene)
   v
CmdStream    flat arrays of (opcode, 3 ints, 4 floats); CmdCodec <-> bytes
   |  backend.execute(stream, scene)
   v
CpuRenderer  HDR colour + depth per resource  --Resolve--> 8-bit sRGB Image;  PassCosts, Profiler, LightExplain
```

**Camera-relative.** Positions in the world are f64. Extraction subtracts the camera's position in f64 and only then
narrows to f32, so a scene 5000 km from the origin renders the same picture (`prism` checks this). Everything after
extraction (instances, lights, BVH, shading) is in camera-relative world axes with the camera at the origin; the view
matrix is the camera's rotation alone. A hand-built `RenderScene` must follow the same convention.

**Order.** Extraction sorts opaque and masked instances by (material, mesh, entity slot) and blended ones after them,
far to near. The key depends on the data only; ties keep the world's insertion order (stable merge sort).

## Command stream

A command is `op, a, b, c, f0..f3`; unused slots are zero. Ids refer to the graph (resources, passes), `RenderAssets`
(mesh, material) and the scene's instance list.

| op | slots | meaning |
|---|---|---|
| BeginPass / EndPass | a = pass id | opens/closes the span timed under profiler scope = pass id and owns the counters |
| SetTarget | a = colour resource, b = depth resource or -1 | targets of the draws that follow |
| Clear | a = flags (1 colour, 2 depth), f0..f2 colour, f3 depth | |
| BindMaterial | a = material id | material of the draws that follow |
| DrawMesh | a = mesh, b = first instance, c = count | draws that mesh for instances `first..first+count` of the scene |
| BuildAccel | a = acceleration-structure resource | build what shadow rays traverse |
| Resolve | a = source colour, b = destination, f0 exposure, f1 knee | tone map + sRGB encode |

The wire form is little-endian 32-bit words: `"LXCS"`, version, count, 8 words per command, CRC-32. Decoding refuses a wrong
magic, version, length, opcode or checksum. Floats are written by exact bit pattern (finite normals and zero; -0 reads
back as 0).

## Render graph

Passes declare `reads(pass, name)` and `writes(pass, name)`; resources are colour/depth targets, textures and
acceleration structures, declared with a size and optionally `imported` (outside the graph: the window, an asset) or
marked `output`. Writers of one resource run in the order their passes were added; a pure reader runs after the last
writer; a pass that reads and writes one resource needs an earlier writer. The compiler reports, with the names involved:
unknown resources, reads nobody writes, read-before-write, cycles, duplicate names, no output, and a pass given resources
of the wrong kind. It culls passes nothing needs (a pass is live if it writes an output or an imported resource, or a
live pass depends on it), orders the rest with the lowest pass id first among the ready ones, gives each used resource
its first and last position in that order, and lets transient resources of the same size that are never alive together
share a block. `GraphReport::text` prints all of it plus, per pass, the counters the backend filled
(draw calls, triangles submitted/rasterised, pixels shaded) and, on request, the measured time.

## Backend contract (what a GPU backend must do)

1. Execute the commands in order with the meanings above. `DrawMesh` ranges index `RenderScene` instances; the bound
   material applies to the whole range. Draws between two non-draw commands form one batch: opaque and masked geometry
   resolves by depth before blended geometry is mixed over it, in instance order.
2. Conventions: right-handed, +Y up, camera looks down -Z; Vulkan clip space (depth 0 near .. 1 far, +Y down in NDC);
   counter-clockwise triangles seen from outside are front faces; row 0 of an image is the top; uv (0, 0) is the
   top-left of the texture; normal maps are tangent space with green up.
3. Shade with the lighting library only (`lightShade` on a `LightSurface`/`LightMaterial`, one function for every light,
   one ambient term, tone map and sRGB last). The CPU backend's per-pixel inputs come from `CpuSurface::sample`.
4. A light's `shadowMode` decides how it is shadowed; `Ray` is the reference. A backend that uses maps must agree with the
   rays within a stated band; the CPU rays are hard (one ray to the light's centre).
5. Report per-pass cost into `PassCosts` (the counters have the same meaning) and per-pass time through the profiler.
6. Be testable against the oracle: the CPU backend's picture for a scene is the expected value, compared with a
   tolerance for float differences; the CPU backend itself is exact and does not depend on thread count.

## CPU backend, in one paragraph

Triangles are transformed, clipped against the near plane and a guard band, snapped to a 1/256 pixel grid and binned into
32 x 32 tiles in submission order. Coverage uses integer edge functions with the top-left rule, so a pixel is covered
exactly once along shared edges. Per tile: visibility (depth + triangle id, alpha mask tested here), then one shading per
visible pixel, then blended triangles. A tile touches only its own pixels, so any worker count gives the same bits.
Shadow rays traverse a median-split BVH built from the shadow-casting instances. `CpuExplain` rebuilds the pixel's surface
with the renderer's own function and runs `lightExplain`, whose parts sum exactly to the pixel.

## Not done

A GPU backend (needs offscreen targets and depth sampling in smalt), soft shadows, shadow maps, baked shadows, a CPU path
tracer reference, post passes (bloom, auto exposure), reflections of scene objects, anti-aliasing, model import into
`MeshData`, culling of lights.
