# lumen

A voxel valley lit by the Ludax lighting library and ray traced on the CPU: a lake under a snowy mountain, a
cabin and pier with lanterns, a forest, a watch tower with a beacon, and a crystal cave over a lava pool.

The valley sits in the middle of a world of 320 x 64 x 320 cells: around it a ring of snowy mountains, then open land
with lakes, forests, four more cabins and two more towers, all generated from the same seeds. Fly with Shift for
the sprint (110 cells a second); `--map out.bmp` writes a top view of the whole world.

```sh
cd examples/rendering/lumen
axle build -O 3
./target/lumen.exe                                   # the window
./target/lumen.exe --frame out.bmp --size 960x540 --samples 128 --shot 1 --time 0.75   # one picture, no window
./target/lumen.exe --frame out.bmp --x 120 --z 330 --altitude 30 --yaw 3.0   # from anywhere in the world
```

## What it shows

| Effect | Where it comes from |
|---|---|
| Physical sky, sun and moon, day cycle | `LightSky` (single scattering), radiance map in `light/sky.axle` |
| Soft sun shadows, cloud shadows | shadow rays over the sun's disc, `light/shade.axle` |
| Coloured block light flooded through voxels | `VoxLightWorld` flood and sky-access bake, copied to `light/lightvol.axle` |
| Every lamp is its own: colour, strength, reach, flicker, layers lit, obstacles passed, shadow mode | `world/lampspec.axle`; the flood's per-cell emitters and pass masks (`VoxLightFlood::setEmitter`), `light/lamps.axle` |
| Real point lights with shadows and GGX highlights | `lightIncidence` and `lightBrdf`, `light/shade.axle` |
| One traced diffuse bounce (colour bleeding) | `light/shade.axle` |
| Lake: waves, Fresnel, reflection, refraction, absorption, caustics | `render/worker.axle` |
| Height fog and light shafts | `render/worker.axle` |
| Auto exposure, bloom, tone curve, sRGB | `render/post.axle` with `lightDisplay` |

Nothing in the picture is left to chance except where the camera samples each pixel, which is what keeps a still
world still. This is how voxel-axle lights a world, and why it does not shimmer.

## Where the light comes from

- **Sun and moon**: the light engine bakes, for the shell of cells beside every light-blocking block, how much of the
  sun's disc the cell sees (a soft shadow). The renderer reads it back with a trilinear blend (`light/lightvol.axle`),
  so a shadow edge is the same on every frame. When the time of day moves, a twelfth of the shell is re-baked toward
  the new sun each frame, so shadows glide (as voxel-axle's `bakeSunSlice`).
- **Sky and bounce**: the dome's SH9 through the baked sky access and the baked bounce tint (what colour the sky rays
  hit), so a red roof tints the snow beside it.
- **Lamps**: the flood gives block light its colour and fall-off through the voxels; each lamp is also a point light
  with a hard shadow ray and GGX highlights (`light/shade.axle`).
- **Clouds** shade the ground by moving over it; a lake reflects and refracts with Fresnel, absorption and caustics.

## How the picture is made

- **Textures** are read through a mip chain (16 x 16 down to 1 x 1, averaged in linear light) at the level the size of
  a pixel on the surface asks for, and the relief fades as the texel shrinks below a pixel. Holes in leaves and the
  frames of glass, which are texel-sized, stop being resolved past 26 cells, where they could only flicker.
- **Fog** is aerial perspective, a function of depth alone: a surface dissolves into the colour of the air behind it
  by `1 - exp(-(z / 320)^2)`. Around the sun the air takes the sky's ambient colour, not the sun's glare.
- **Light shafts** are a pass over the finished picture: each pixel marches toward the sun and sums the open sky it
  passes over, so shafts follow silhouettes and can never shine through a wall.
- **Time**: each frame traces one sample per pixel with a sub-pixel jitter from a Kronecker sequence and blends it with
  last frame's picture (`render/frame.axle`): the history of a pixel is found by projecting its position through the
  previous camera and is accepted only from a pixel on the same plane; the albedo is accumulated too, so a texel
  does not change with the jitter; pixels at an edge between two surfaces accumulate radiance, which anti-aliases
  a silhouette; a short history while moving (3 frames) and the whole pixel's jitter only when still keep it sharp, and a contrast-adaptive sharpening takes back the softness of scaling up; the edge-avoiding spatial filter exists (`R`) but is off, because baked light leaves no noise for it to remove.

`--selftest` checks, among other things, that the baked sun agrees with a ray cast from the same cell before and after
the sun moves, that the lean shadow walk agrees with the full walk, and that a frame, history and filter included, is
identical on one thread and on four. `--flicker` measures how much the picture changes between frames and `--prof` times the renderer's inner loops one call at a time. The renderer's options reach every mode, window included: `--no-lamps`, `--no-bounce`, `--no-rays`, `--denoise`, `--fog F`, `--bloom F`, `--exposure STOPS` and `--softness R` (see `app/options.axle`).

## Performance

`./target/lumen.exe --bench` times the stages on your machine, still and moving. On a 12-core machine at 640 x 360
traced and shown at 1280 x 720: 65 to 90 frames a second moving (trace 5-10 ms, temporal and filter about 1-2 ms,
display 3 ms). Raise the internal size with `--size 960x540` for a sharper picture.

The world is 320 x 320 cells: the start takes about 2 s to build and bake the light and the process peaks near 500 MB.
The sun's shadow re-bakes in slices while it moves, so the frame rate does not drop.

Without a shadow ray, a bounce ray or a shaft ray per pixel, a pixel costs its primary ray, a texture read and a few
lookups; lamps are rejected by distance and faintness before any shading, and what is seen in a reflection or
through water is shaded from the baked light alone. A picture that has settled stops being drawn.

## Controls

Click to capture the mouse (Esc releases it, Esc again quits), WASD move, Space up, Shift down, Ctrl sprint,
Q/E time of day, T auto day, 1-4 viewpoints,
V debug view (albedo, normal, direct, indirect, depth, flood, access, raw), B bounce, L lamps, G shafts, F fog,
O bloom, X auto exposure, R spatial filter, I invert the mouse, H overlay, F12 screenshot.

`./target/lumen.exe --selftest` checks the renderer against the engine (walker agreement, lamp colours and masks, the sky map, and that a frame is the same on 1 and on 4 threads).

## Layout

```text
src/main.axle   entry
src/app/        command line, session, window and headless front ends
src/world/      blocks and their classes and layers, textures, lamp specs, world generation, the flat scene and its ray walker
src/light/      sky, baked light volumes, lamps, shading
src/render/     environment, settings, camera, workers, frame accumulation, post-processing
```
