# Roadmap

Status in brackets: done, partial, or not started. "Done" means built, tested with numbers and used by an example;
the limits of each part are written next to it, and in the part's own README or header.

0. **Foundations**: skeleton, lint, test harness. [done]
1. **Core** (layer 1): maths in f32 and f64, memory, containers, ids, random numbers, time, log, jobs, profiler. [done]
2. **Data** (layer 2): [done, with limits]
   - bytes, checksums, inflate/deflate, PNG read and write, images, an image cache, WAV (`AudioClip`, `WavCodec`);
   - JSON (parser, writer, document model);
   - a virtual file system (disk, memory and archive mounts, layered lookup);
   - an asset database (stable ids, typed kinds, dependencies, version bump on reload);
   - glTF 2.0 and `.bbmodel` importers into `Mesh` and plain skin/clip data.
   Limits: a disk mount cannot list directories (the standard library has no call for it); glTF has no sparse
   accessors, morph targets or JPEG; `.bbmodel` handles cubes only.
3. **World** (layer 3): [done, with limits] entities, component stores, typed joins over two and three stores, a scene
   tree with lazy f64 transforms and names, a spatial grid, scenes saved to and loaded from JSON (the game stores its
   own component fields beside the transform), a text inspector. Limits: no BVH or octree (the grid and the
   renderer's own BVH serve today); no prefab or scene-merge layer.
4. **Render abstraction** (layer 5): [done, with limits] scene data and extraction, a byte-serialisable command stream,
   a render graph (validation, culling, ordering, lifetimes, aliasing, report), a deterministic tile-rasterising CPU
   backend with PBR through the lighting library, ray shadows, mip-mapped textures in linear light and
   `LightExplain`; see `doc/RENDERING.md`. Limits: hard shadows only, no anti-aliasing, reflections are a sky lookup;
   a path-tracing reference for shortcuts is not written.
5. **GPU**: Vulkan backend on smalt, lighting v2, shadow maps. [not started: blocked on offscreen render targets in
   smalt, which are an upstream change. The command stream and the render graph are the interface it will implement.]
6. **Simulation** (layer 4): [done, with limits]
   - `kinetic` physics: sphere, box, capsule, plane; contact manifolds; sequential-impulse solver; ball-socket,
     distance and hinge joints; sleeping; ray and overlap queries; a state hash. Limits: no triangle meshes or
     continuous collision;
   - animation: keyframe tracks, skeletons, clips, blending, a crossfading animator, root motion, events, IK, skinning.
     Limit: no adapter yet from the glTF `Model*` data to the animation types;
   - audio: a deterministic software mixer with buses, 3D spatialisation, Doppler, music crossfades and a synth.
     Limit: offline only, nothing drives an audio device;
   - navigation: grid A*, flow fields, a navmesh with funnel smoothing, steering.
7. **Runtime** (layer 6): [done, with limits] a game loop over a fixed step, typed settings with a text format and command
   line overrides, input snapshots with a replayable tape, an action map, a system scheduler. Limit: nothing is
   wired to a window; that is smalt's job.
8. **Content** (layer 7):
   - `voxel`: [partial] the lighting library and `voxel/world` (palette-compressed chunks, a seeded generator, a streamer
     with bounded memory, an edit layer saved as region files, a greedy mesher, a light bridge, ray casts). Not yet: a
     game on top (block registry, textures, player physics, inventory), water flow, structures other than trees;
   - `openworld`: [partial] cell streaming, an arcade vehicle model, missions, day/night and weather. Not yet: coupling
     of vehicles to `kinetic`, streamed entities that are more than scenery, an actual game.
9. **Ludax Studio**: scene editor, inspector, lighting debugger. [not started: it lives outside the runtime, on zaffre.
   The scene file format, the inspector text and `LightExplain` are the data it will show.]

Examples (each builds, runs headless, checks itself and exits 0): `lumen` (the lit valley, in `examples/rendering`; needs smalt for its window),
`orrery` (world, scene, JSON, fixed step), `texlab` (images, PNG, textures), `assetdb` (JSON, VFS, assets, glTF),
`kinetic` (physics), `wayfarer` (animation, navigation), `chimes` (audio), `prism` (render graph and CPU backend),
`voxelwalk` (streaming voxel world), `frontier` (runtime and open world), and the small games `bastion` and
`stardrift`.
