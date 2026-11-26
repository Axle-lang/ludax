# `src/render`

Layer 5. Scene extraction, render graph, command stream, CPU backend, the lighting library, the path-lit picture (`pathlight`) and the layered light (`lux`).

76 files in 14 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [the frame](../handbook/render/01-frame.md); [problems: classic rendering](../handbook/problems/render-classic.md); [problems: light and display](../handbook/problems/render-light.md).

## `src/render/cmd`

The render command stream: recording, its byte codec and per-pass costs.

Read more: [the rendering specification](../spec/rendering.md).

| File | What it does |
|---|---|
| `cmd_codec.axle` | a command stream as bytes, and back. |
| `cmd_costs.axle` | what each pass of a frame cost, filled in by the backend that ran it. |
| `cmd_stream.axle` | the render command stream: what to draw, as plain data in flat arrays. |

## `src/render/cpu`

The CPU backend: triangle setup, the tile rasteriser and shader, surface sampling, the BVH and shadow rays, and the pixel explainer. The reference a GPU backend is tested against.

Read more: [the rendering specification](../spec/rendering.md).

| File | What it does |
|---|---|
| `cpu_bvh.axle` | a bounding-volume hierarchy over triangles, for the shadow rays of the CPU backend. |
| `cpu_explain.axle` | why a pixel has its colour (design rule 8, doc/spec/lighting.md section 9), for the CPU backend. |
| `cpu_kernel.axle` | the tile rasteriser and shader: one tile of the picture per unit of parallel work. |
| `cpu_renderer.axle` | the CPU backend: executes a command stream and produces the picture. |
| `cpu_shadow.axle` | shadow rays against a triangle BVH, behind the lighting library's `LightShadowQuery`. |
| `cpu_surface.axle` | the surface at one pixel of a stored triangle: position, normals, material and texture reads. |
| `cpu_tris.axle` | triangle setup for the CPU rasteriser: transform, clip, snap to a sub-pixel grid, bin into tiles. |

## `src/render/graph`

The render graph: declaration, validation, culling, ordering, lifetimes and memory aliasing, recording into a command stream, and a report.

Read more: [the rendering specification](../spec/rendering.md).

| File | What it does |
|---|---|
| `graph_graph.axle` | the declaration side of the render graph: resources, passes, and who reads and writes what. |
| `graph_plan.axle` | compiling a render graph: validation, culling, ordering, lifetimes and memory aliasing. |
| `graph_record.axle` | a compiled graph and a scene become a command stream. |
| `graph_report.axle` | a graph and its plan as text a person can read (design rule 8: observable). |
| `graph_types.axle` | the vocabulary of the render graph: resource kinds, formats, pass kinds, and the issues found. |

## `src/render/light`

The lighting library: units, BRDF, irradiance closed forms, SH9, the analytic sky, tone and sRGB, the shading of a light, and the explain path. Written in a restricted subset of Axle that a tool can translate to GLSL.

Read more: [the lighting contract](../spec/lighting.md); [the lighting mathematics](../spec/lighting-math.md); [shading](../handbook/render/05-shading.md).

| File | What it does |
|---|---|
| `light_brdf.axle` | GGX, Smith, Schlick, multiple scattering and diffuse (doc/spec/lighting-math.md §3), f32 with f64 twins. |
| `light_color.axle` | exposure, the tone curve and the sRGB transfer function (doc/spec/lighting-math.md §8). |
| `light_dfg.axle` | the directional albedo of the specular lobe, tabulated by quadrature (not Monte Carlo). |
| `light_explain.axle` | why a pixel has its colour (doc/spec/lighting.md §9). |
| `light_irradiance.axle` | how much light a source puts on a surface point, exactly (doc/spec/lighting-math.md §2). |
| `light_material.axle` | a glTF metallic-roughness material and the surface point it is shaded at. |
| `light_math.axle` | deterministic exp2, log2 and pow, and the rules of the shading subset. |
| `light_quadrature.axle` | Gauss-Legendre nodes and weights, computed, never typed in. |
| `light_sh.axle` | second-order spherical harmonics (SH9) of an environment, and irradiance from them. |
| `light_shade.axle` | shading one surface point: one light's contribution, the ambient term, and their separable sum. |
| `light_sky.axle` | an analytic clear sky by single scattering with exact optical depth (doc/spec/lighting-math.md §5). |
| `light_source.axle` | the kinds of light and the data of one light. |
| `light_units.axle` | the one place the scale of the scene is defined, and the exposure that leaves it. |
| `light_vndf.axle` | sampling the distribution of VISIBLE GGX normals (Heitz 2018, doc/spec/lighting-math.md §3). |

## `src/render/lux/fluid`

The FFT ocean (JONSWAP spectrum, three cascades, an anisotropic filter) and the colours that show what its rendering computes.

Read more: [the water surface](../handbook/render/14-water-surface.md).

| File | What it does |
|---|---|
| `lux_fft.axle` | the fast Fourier transform of a square grid, for the ocean's waves. |
| `lux_ocean.axle` | a wind-driven water surface without a visible pattern: Tessendorf's spectral ocean in three cascades. |
| `lux_water_debug.axle` | colours that show what the water's rendering computes, instead of how it looks. |

## `src/render/lux/graph`

The framework of the layered light: layers, keys, the layer graph, two-copy caches, the scheduler, the resolution governor, tiles and the frame's view.

Read more: [the layers of light](../handbook/render/12-lux-layers.md).

| File | What it does |
|---|---|
| `lux_budget.axle` | what each layer of light costs, and the resolution that keeps a frame inside its time. |
| `lux_cache.axle` | a cache of light kept from frame to frame, read from one copy while the next is written into the other. |
| `lux_graph.axle` | the layers of light and the buffers between them: who depends on whom, what runs, what runs together. |
| `lux_key.axle` | what a cached light computation was made from, as plain integers a layer can compare. |
| `lux_layer.axle` | what a layer of light declares about itself: where it lives, how often it must be redone, at what cost. |
| `lux_scheduler.axle` | which layers of light run this frame, which slice of a long refresh each does, and when a cache becomes visible. |
| `lux_tiles.axle` | the picture cut into tiles, the unit a fused group of screen layers is run over. |
| `lux_view.axle` | the frozen inputs of one frame: what every light layer reads instead of live state. |

## `src/render/lux/look`

How a surface responds to fields (the look stack), and thin perforated surfaces.

Read more: [view layers](../handbook/render/15-view-layers.md); [media and interfaces](../handbook/render/17-media-and-interfaces.md).

| File | What it does |
|---|---|
| `lux_look.axle` | how a surface responds to fields: colour, glow, tilt, roughness, and how it bends what is seen through it. |
| `lux_thin.axle` | crossing a thin, perforated surface: a portal's sheet, a stained pane, a curtain of leaves, a grate. |

## `src/render/lux/medium`

Light in a medium and at its boundary: Beer-Lambert, Snell, exact Fresnel, rough interfaces and the view from inside.

Read more: [media and interfaces](../handbook/render/17-media-and-interfaces.md).

| File | What it does |
|---|---|
| `lux_immersion.axle` | the view from inside a medium bounded by a free surface: an eye under water, in a lava lake, in a fog bank with a top. |
| `lux_interface.axle` | a rough boundary between two media seen from the lighter one: a lake from the air, ice, wet ground. |
| `lux_medium.axle` | what light does in a participating medium and at its boundary: Beer-Lambert, single scattering, Snell, Fresnel. |

## `src/render/lux/simd`

Eight-lane helpers for the per-pixel layers.

Read more: [the layers of light](../handbook/render/12-lux-layers.md).

| File | What it does |
|---|---|
| `lux_simd.axle` | eight pixels at a time: the lane helpers the light layers are written with. |

## `src/render/lux/sprite`

Particles drawn into a finished picture as pixel-art sprites, with an undo for the history.

Read more: [view layers](../handbook/render/15-view-layers.md); [temporal super-resolution](../handbook/render/16-upscale.md).

| File | What it does |
|---|---|
| `lux_sprites.axle` | particles drawn into a finished picture as square pixel-art sprites, hidden behind nearer surfaces. |

## `src/render/lux/temporal`

The colour clip and the temporal upscaler that rebuilds a small jittered picture at the window's size.

Read more: [temporal super-resolution](../handbook/render/16-upscale.md).

| File | What it does |
|---|---|
| `lux_clip.axle` | how far a pixel's history may be trusted: the colour box of its neighbourhood this frame. |
| `lux_upscale.axle` | temporal super-resolution: a picture computed small, rebuilt at the window's size from frame to frame. |

## `src/render/pathlight`

The path-lit picture: camera, sky and clouds, sparse light, the face cache, shading, shafts, the edge-avoiding filter, bloom and display, and the settings and feature switches.

Read more: [sparse light](../handbook/render/04-sparse-light.md); [shading](../handbook/render/05-shading.md); [the sky](../handbook/render/06-sky.md); [accumulation](../handbook/render/07-accumulation.md); [display](../handbook/render/08-display.md); [the face cache](../handbook/render/11-face-cache.md).

| File | What it does |
|---|---|
| `pathlight_bloom.axle` | the bloom pyramid's arithmetic: halving a picture, blurring it, folding a level into the next. |
| `pathlight_camera.axle` | a pinhole camera: a position, two angles and a field of view, turned into one ray per pixel. |
| `pathlight_celestial.axle` | what hangs in the sky: the sun's and the moon's discs and the stars. |
| `pathlight_cloud.axle` | the cloud deck: where it is, how much of it covers a point, and how it is lit. |
| `pathlight_facecache.axle` | the light of a surface kept where the surface is, not where the camera looks. |
| `pathlight_features.axle` | the parts of the picture a program may switch off, chosen by name. |
| `pathlight_filter.axle` | the edge-avoiding spatial filter, one pixel at a time. |
| `pathlight_noise.axle` | integer hashes and smooth value noise: the only source of variety in the worlds and textures built on it. |
| `pathlight_pixels.axle` | reading and writing the interleaved float pictures the frame keeps. |
| `pathlight_point.axle` | the shading inputs of one surface point: position, normals, albedo, roughness, emission. |
| `pathlight_post.axle` | from radiance to pixels: exposure, bloom, vignette, tone curve, sRGB, upscale, dither. |
| `pathlight_sample.axle` | the baked light at a point, as the shader reads it. |
| `pathlight_settings.axle` | the knobs of the picture, and the random numbers a pixel draws. |
| `pathlight_shade.axle` | the light that arrives at a surface point and what the surface sends back. |
| `pathlight_shaft.axle` | the sun's light shafts as a screen-space scatter of the sky's silhouette. |
| `pathlight_sky.axle` | the sky of one moment: a radiance map, the sun and the moon as lights, the dome's SH9 and the stars. |
| `pathlight_skygrid.axle` | a latitude-longitude grid of sky radiance: the one picture the sky is looked up in. |
| `pathlight_sparse.axle` | light sampled every few pixels and given back to every pixel. |

## `src/render/scene`

From the world to something renderable: the scene snapshot, extraction and ordering, camera, meshes, materials, lights and procedural shapes.

Read more: [the rendering specification](../spec/rendering.md).

| File | What it does |
|---|---|
| `scene_assets.axle` | the meshes, materials and textures a frame refers to by number. |
| `scene_camera.axle` | the eye: perspective or orthographic, placed in f64, projected camera-relative in f32. |
| `scene_extract.axle` | from the world to a `RenderScene`: components in, culled and ordered instances out. |
| `scene_frame.axle` | the snapshot of a world that one frame is drawn from. |
| `scene_light.axle` | a light as a component: physical units, no position of its own. |
| `scene_material.axle` | a glTF metallic-roughness material as the renderer sees it. |
| `scene_mesh.axle` | triangles in the flat layout a GPU takes: parallel arrays of floats, an index list, and bounds. |
| `scene_shapes.axle` | procedural meshes: box, uv-sphere, plane, cylinder. |

## `src/render/texture`

Textures in linear light, with mip chains and filtered reads.

| File | What it does |
|---|---|
| `texture.axle` | an image prepared for sampling: linear light, a mip chain, filtered reads. |
