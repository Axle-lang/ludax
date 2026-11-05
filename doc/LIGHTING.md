# Lighting

Lighting is Ludax's first priority and the part that must never be wrong. This document is the contract; each
section ends with how it is *proved*, because a rule that no test can fail is a wish.

## 0. What voxel-axle already does, and what it does not

voxel-axle (read in full for this document) is a good base. Kept as ideas:

| Idea in voxel-axle | Why it stays |
|---|---|
| **Direct and ambient light are two numbers, never summed early** (`FaceLight`) | A shadow removes the first and keeps the second; a cloud moves light from one to the other; the colour depends on which won |
| Sun light = Lambert × **soft visibility** baked by a fan of rays over the sun's disc | Soft shadows without a shadow map; refreshed round-robin so they glide |
| Sky access = hemisphere rays; the colour of what blocked them becomes the **bounce tint** | Cheap one-bounce GI, grass bleeds green into its shade |
| Block light per **RGB channel** flooded through voxels, sky light flooded down columns | Incremental, edit-friendly, exact on a grid |
| Linear-light shading, then tone curve, then sRGB (`encode`) | Correct order |
| Surface-only storage (a shell of air cells, ~1 in 80) | 47 MB → a few MB |
| Light computed once per mesh change, not per frame | Cheap |

What it cannot do (and Ludax must):

| Gap | Consequence |
|---|---|
| 4-bit levels with `FALLOFF^(15-level)` | 16 steps, banding, no physical falloff, no intensity above "15" |
| One body (sun *or* moon) | No second light with a shadow, no spot, no dynamic point light |
| Per-vertex lighting only | Wrong on large faces, no normal maps, no specular beyond a "sheen" |
| Entities sample the world through `boxpose` | Dynamic objects are lit by hand-rolled code, cast nothing onto the world |
| No PBR (albedo × light), no emissive surfaces, no reflections | Cannot do GTA-class materials or wet roads |
| CPU/GPU parity kept *by hand*, "line for line" (30 `user` vec4s addressed by macros) | One edit on one side silently breaks the other |
| Terrain is not part of `FrameDesc`; lighting under-tested | No way to ask *why* a pixel has its colour |

## 1. Principles

1. **Scene-referred linear HDR.** Radiometric units (see §2). Exposure and tone mapping happen once, last.
   sRGB encode is the final step and the only place gamma exists.
2. **Direct and indirect stay separate** until the final sum (voxel's best idea), and *each light's* contribution is
   kept separable so it can be explained (§9).
3. **One shading function.** BRDF, attenuation, tone map exist once. They are written in a restricted Axle subset
   (pure functions over `f32`/`Vec3`, no allocation) and compiled to GLSL by `tools/axle2glsl` — parity by
   construction, never "line for line". Fallback if the transpiler proves too costly: GLSL is the source and a CPU
   mirror is checked against golden vectors on real hardware.
4. **Every approximation has a reference.** A CPU path tracer (`render/ref`) renders the same `LightingScene`; fast
   paths are tested against it with stated error bounds.
5. **Lighting is data.** A `LightingScene` (lights, probes, volumes, environment, settings) is extracted from the
   world each frame; the renderer is a function of it. No light state hides in a renderer.
6. **Deterministic.** The same scene, seed and settings give the same pixels on the CPU backend, bit for bit.

## 2. Units and the light model

- Radiance in linear sRGB primaries, `1.0` = diffuse white lit by the reference sun (illuminance 100 000 lux →
  scene value π·k; the constant lives in `LightUnits` and is the *only* place the scale is defined).
- **Exposure** is explicit (EV100, manual or auto from a luminance histogram); tone map = filmic curve with a
  documented knee; debug view `NoTonemap` shows raw HDR.
- Light types (`LightKind`, an enum matched exhaustively):
  `Directional` (angular diameter ⇒ penumbra), `Point` (radius ⇒ no singularity, inverse-square with a smooth
  window to a finite range), `Spot` (inner/outer cone, smooth), `Area` (sphere/disc/rect, later via LTC),
  `Emissive` (a mesh/voxel face that emits), `Sky` (analytic atmosphere → SH9 irradiance + prefiltered specular).
- Per light: colour, intensity (lux / candela / lumens converted at the API edge), range, **shadow mode**, **layer
  mask**, **include/exclude lists**, `static`/`dynamic`.

*Proved by:* inverse-square law (distance ×2 ⇒ ¼), cosine law, window reaches exactly 0 at range, spot cone
monotone, unit-conversion round trips.

## 3. Materials

glTF metallic-roughness is the base (`baseColor`, `metallic`, `roughness`, `normal`, `occlusion`, `emissive`,
`alphaMode`), shaded with GGX + Smith-correlated visibility + Schlick Fresnel + energy-compensated multiscatter
diffuse/specular. Extensions added behind flags: clearcoat, transmission/glass tint, subsurface-lite (foliage).
**Voxel profile**: albedo × baked per-corner light (voxel's current model) *through the same exposure/tone path*,
so a voxel block next to a glTF prop is lit by the same sun with the same colour.

*Proved by:* **white-furnace** (albedo 1, any roughness, uniform environment ⇒ pixel = environment, within ε);
BRDF energy ≤ 1 by Monte Carlo integration; reciprocity; Fresnel → 1 at grazing.

## 4. Shadows

Per-light `ShadowMode`: `None`, `Baked` (voxel ray visibility / lightmap), `Map` (cascaded for sun, atlas tiles for
spot, cube for point), `Ray` (CPU reference, voxel DDA), plus optional `Contact` screen-space. Soft edges from the
light's physical size (PCSS-style on maps, disc sampling on rays). The bias policy is one function with a test,
not tuned constants scattered in shaders. Dynamic objects **cast** onto voxel terrain (the map path) and
**receive** the baked field (§6) — voxel's one-way entity sampling becomes two-way.

*Proved by:* shadow maps vs CPU ray shadows on test scenes (max disagreement band, no light leaking through a
contact edge, no acne on a flat plane at grazing angle), penumbra width = analytic.

## 5. Indirect light (layered, each layer optional)

1. **Sky/ambient**: atmosphere model → SH9; occlusion by sky access.
2. **Voxel/grid flood** (voxel's mechanism, upgraded): RGB at **8 bits** per channel with a configurable falloff
   *calibrated to inverse-square*, opacity-aware (glass tints, leaves attenuate), sunlight columns.
3. **Sky access + bounce tint** (voxel's hemisphere bake) generalised to *any* occupancy provider.
4. **Probe grid** (irradiance SH volume, updated incrementally) for dynamic objects and non-voxel worlds (open world).
5. **Baked lightmaps** for static glTF geometry (CPU path-traced, stored as assets — deterministic bake).
6. **Screen-space**: GTAO, optional SSR; always an *addition* to the above, never a substitute.
7. Reflections: prefiltered sky cubemap + local reflection probes (box-projected).

*Proved by:* each layer renders alone in a debug view; flood invariants (monotone decay, remove-then-add is the
identity, no light through opaque cells); probe irradiance at a point equals a brute-force hemisphere integral.

## 6. How voxel drives the lighting (the integration contract)

Voxel does not own a lighting engine; it **supplies fields** to Ludax's:

```text
trait OccluderWorld  { rayHit(origin, dir, maxDist) : RayHit;  isOpaque(cell) : bool;  transmittance(cell) : Vec3 }
trait LightField     { blockLight(cell) : Vec3;  skyAccess(cell) : f32;  sunVisibility(cell, sunDir) : f32;
                       bounceTint(cell) : Vec3 }       // sampled at face corners or at any world point (trilinear)
```

- The **voxel module implements them** over its chunk ring; Ludax's `render/light` calls them. Nothing in
  `src/render` imports `src/voxel` (the layer lint enforces it); the voxel module registers its providers.
- Lamps/torches are **ECS entities** with a `LightSource` component: the same component feeds the flood (static,
  voxel-aligned) *and* a dynamic point light with a shadow (when it moves or is held).
- Chunk meshes carry packed corner light as today; the shading goes through the shared function with the
  *voxel profile* (§3). A GTA-class world instead uses `Baked` lightmaps + probes + maps — same `LightingScene`.
- The light thread / crew (bakes off the main thread, tables published atomically) is kept; it becomes
  `LightJobs` on the engine's `JobPool`, deterministic (results indexed by job).

## 7. Atmosphere and post

Analytic sky (Rayleigh+Mie, day/night, sun & moon as real lights), height fog + volumetric fog (froxels, later),
god rays, clouds (voxel's cloud deck generalised), underwater volume. Post: bloom, auto exposure, tone map, colour
grading LUT, optional TAA. All through one `PostChain` that records its passes (§9).

## 8. Backends

- **Reference (CPU, deterministic)**: rasteriser + `PathTracer` sharing the lighting library. Source of truth for
  tests and golden images. Slow, and it is the oracle.
- **Software fast**: smalt's `SoftDevice` can't do this (one directional light, Blinn-Phong): Ludax brings its own
  tile rasteriser using the same library.
- **Vulkan** (via smalt 0.2): clustered forward, shadow atlas, post chain. Needs upstream: offscreen colour/depth
  targets, depth sampling, larger uniform/storage buffers, instancing. This is the critical path.

## 9. Observability (a requirement, not a debug extra)

- `LightExplain(pixel)`: position, normal, material, and for **every light**: reaches / excluded (why: range, mask,
  shadow, backface, spot cone), N·L, attenuation, shadow factor, final RGB contribution; plus indirect terms;
  the sum is checked to equal the shaded pixel.
- Select a light ⇒ highlight what it lights (influence mask), draw its frustum/cone/range/shadow cascades,
  list objects included/excluded.
- Debug views: normals, albedo, roughness/metal, direct only / indirect only / per light, AO, shadow cascade index,
  light count per tile, overdraw, flood levels, probe cells, NoTonemap.
- Rays: draw the shadow ray for a pixel and what it hit.
- Per pass: CPU time, GPU time, draw calls, triangles, lights, shadow-map texels; the textures, materials and
  shaders each pass used (render graph records them).

## 10. Test scenes (reproducible, deterministic render mode)

`cornell`, `furnace`, `plane-and-sphere (sun at angles)`, `point-light-ladder (distances)`, `spot-cone`,
`contact-shadow`, `voxel-cave (torches)`, `voxel-overhang (sun + sky)`, `glass-and-leaves`, `night-street`.
Each has a golden image (CPU backend) checked in CI with a tolerance, and numeric probes at named points.

## 11. Order of work

1. `render/light` maths in Axle (units, attenuation, BRDF, tone map, SH) + suites for §2/§3 laws. **No GPU needed.**
2. `LightingScene` data + CPU reference path tracer + test scenes + `LightExplain`.
3. `OccluderWorld`/`LightField` traits + a voxel adapter prototype (port voxel's flood, hemisphere bake, sun bake).
4. CPU tile rasteriser with the shared library; shadow maps; golden images.
5. axle2glsl + Vulkan backend (after smalt offscreen targets). Parity tests on hardware.
6. Probes, lightmap baker, SSAO, atmosphere, post chain.

## 12. Per-source behaviour: what is configurable, and where

A light is configured where it is made, not by the block it sits in.

| Behaviour | Where it lives | Honoured by |
|---|---|---|
| Colour, intensity, radius, range, cone | `LightSource` (`point`, `spot`, ...) | direct shading (`lightIncidence`) |
| Which surfaces it lights | `includeLayers`, `excludeLayers`, `excludeObject` on the light, `layer` on the surface | direct shading only; the flood does not look at layers |
| Colour and strength of a lamp **cell** | `VoxLightFlood::setEmitter(x, y, z, r, g, b, pass)`, 0..1023 per channel (a lamp block is 255); `clearEmitter` gives the cell back to its block | the flood (an override replaces what the block emits; a rebuild keeps it, `setBlock` drops it) |
| Which obstacles it shines through | obstacle classes (`BlockLight.classes`, one bit each, game-defined) and a **pass mask** per lamp (`setEmitter`'s last argument) or per ray (`VoxRayTracer::setPass`) | the flood and the voxel ray tracer: a block sharing a bit with the mask is air for that lamp or ray |
| Switching a lamp off | `setEmitter(..., 0, 0, 0, ...)` | the flood |
| How its shadow is found | `LightSource.shadowMode` | **not by the library**: the shading takes a `LightShadowQuery`; `examples/lumen` reads the mode (`Ray` traces, `None` does not) |
| Flicker, per-lamp animation | game data (`examples/lumen`: `LumenLampSpec`) | the game, which scales `intensity` per frame |

Laws, each with a test (`tests/src/voxlight_emitter.axle`): the override is what the cell emits; clearing it
returns the block's emission; any sequence of emitter and block edits equals a rebuild key for key (the
sum-of-fields rule is kept); a pass mask changes the lamp that has it and no other; the ray tracer honours the
same mask.

Not done, on purpose: a per-lamp falloff curve (the flood shares one curve; strength changes the reach only
through the curve), a spot or area emitter inside the flood (they are direct lights), and any of this for
entities that are not voxel cells. That last one needs the `world` layer (ECS) and the `LightingScene` of §1; the
emitter and the pass mask are the data such a component will carry.
