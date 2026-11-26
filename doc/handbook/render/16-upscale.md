# 3.16 Temporal super-resolution

## 1. Contract

`LuxUpscale` (`src/render/lux/temporal/lux_upscale.axle`) rebuilds a picture at the output's size from a smaller
picture computed each frame with every sample shifted by the same sub-pixel offset. It knows nothing of cameras: the
program gives, per computed pixel, its previous screen position, its distance to the previous and present eye, and the
most samples its output pixels may keep (`LUX_MOTION_STRIDE` floats, written by `luxMotionWrite`). How it is fed is a
`LuxUpscalePolicy`: a cycle of 16 Halton offsets (`luxUpscaleOffsetX/Y`) and the caps, 8 samples while the view changes,
48 still, 4 where the surface moves by itself (water). dusk uses it in the window (`--no-upscale` turns
it off; `--upscale` for `--frame` and `--bench`).

## 2. Why

The shading of dusk costs about 486 ns a pixel on one thread: at 60 frames a second the CPU computes about 300 000
pixels, a 1080p screen has two million. Scaling a 640 × 360 picture up (bilinear, then the system's stretch) was what
the owner called 480p. A history at the output's size, fed with jittered samples, converges to the output's resolution
when the view is still and keeps most of it moving.

## 3. Mathematics

```
offset    (jx, jy) = Halton(2, 3) point k of 16, centred: sample (i, j) is taken at (i + 1/2 + jx, j + 1/2 + jy)
history   H = history at X + (previous position - present position of the nearest sample), bilinear; refused when the
          distance stored there differs from the sample's distance to the previous eye by more than 6 % + 0.2 m
gather    c = Σ wᵢ Lᵢ / Σ wᵢ over the 2 × 2 samples round X, wᵢ = (1 - d²/r²)²,
          r² = 1 + (r_n² - 1) min(n / 8, 1),  r_n = max(1.6 · computed px per output px, 0.55)
clamp     H into the 3 × 3 colour box of the nearest sample, widened by 15 % (boxes computed once per computed pixel)
blend     n' = min(n + Σ wᵢ, cap),  out = H + (c - H) Σ wᵢ / n'          cap 8 moving, 48 still, 4 for water
```

The kernel narrows as the history fills (FSR 2's rule): wide while a pixel holds little (no hole), once full `LUXU_NARROW = 1.6` computed
pixels per output pixel, never under `LUXU_NARROW_MIN = 0.55` computed pixels: 1.6 times the computed pixels that one
output pixel spans, so about an output pixel of reach plus the margin the 2 × 2 gather needs (each sample counts where
it was taken). The computed picture's own history is limited to 1 frame, which
`frameFold` turns into a blend of the new sample at weight 1/2 with the last (found by the exact-optimisation audit; an
earlier version of this page said it kept none). Dropping it would sharpen the sub-pixel detail and add noise: a change
of the picture, left to the owner.

Footprints (the waves' fade, texture mips) are sized by the **shown** pixel when upscaling: sized by the computed
pixel, a governor at 480 × 272 washed the waves out whenever the view moved.

## 4. Algorithm

Per frame: trace with the frame's offset, write the motion buffer; `Upscale` (per output row: each job first computes
the 3 × 3 colour boxes of the band of computed rows its output rows read, then rebuilds its rows); particles drawn into the output (`splat`); the display composes the output, its bloom taken from the
computed picture (`LumenPost.fitUpscaled`), straight into the window's pixels. Because the particles are drawn into the output and `swap` makes the output the
history, they **do** reach the upscaler's history: a sprite that moves leaves a faint trail, bounded by the next frame's
3 × 3 colour-box clamp (the sprite is not in the computed picture, so the box cuts it back at once, as it cuts any ghost).
A change of the computed size keeps the
output history (the view keeps converging); a change of the output size starts it again.

## 5. Complexity

| Pass | Cost, measured (1920 × 1056 out, 640 × 352 computed, 23 threads) |
|---|---|
| `Upscale` | first version 4.5 ms (3 × 3 gather and box per output pixel, divisions); boxes once per computed pixel, 2 × 2 gather, reciprocals: about 3.0 ms (about 35 ns an output pixel on one thread); boxes per job band instead of a pass and a buffer of their own: the same time or a little less (the band's rows are hot in the cache when the job reads them) |
| display at output size | 8.4 ms; bloom from the computed picture, exposure meter capped at 60 000 samples, no copy of the words: 5.2 ms |
| memory | 40 bytes an output pixel (two colour histories, two states); the boxes live only in a job's band (a few computed rows), not in a picture-sized buffer (22 MB at 1280 × 720 computed) |

Checks (`tests/src/lux_temporal.axle`): a flat picture stays flat to 1e-5 over 16 frames; vertical stripes of 5 output
pixels (finer than the computed picture can hold) are rebuilt from 32 jittered frames with under 70 % of the error of
one frame scaled bilinearly.

## 6. Quality, measured

**A still view blinked, and why (2026-11-26).** A player standing still saw the silhouettes against the sky, the walls
seen edge on and the halos round the sun shimmer, the more the longer they stood. `--flicker --steady` reproduces it
(the camera still, the world's clock running as the window's does, frames measured long after the history is full),
`--shown WxH` puts it in the window's own configuration (880 × 496 shown at 1280 × 720, not a whole multiple). Traced
pixel by pixel, two causes:

1. **The depth test threw a still view's history away.** A history was kept only when the distance it was taken at
   matched the nearest sample's. On a silhouette the nearest sample is the tower on one frame and the sky on the next as
   the sub-pixel offset moves; on a wall seen edge on, an offset moves the distance by tens of metres (118, 111, 135,
   156 m on successive frames of one pixel). The history's count was 0 on every frame there, and the pixel showed each
   frame's samples alone, the same values every 16 frames (the offset cycle). A sample that has not moved on the
   screen cannot have revealed anything: its history is now kept whatever its distance, and the colour clamp still
   cuts what the present no longer supports. A sample that moved keeps the test. Checked by `lxtStillWall`, which
   failed before (mean change 0.18 a frame) and passes after.
2. **The bloom moved with the computed picture.** It was taken from the computed picture, whose bright points (the
   sun between two towers, a lit window) move by a sub-pixel offset every frame, and their halos with them. A still
   view's bloom is now taken from the shown picture (`LumenFrame.chooseBloom`, `LumenPost.takeBloomFrom`); a moving
   one keeps the computed picture (from the shown one, a moving picture measured worse against the references).

Against native references (1920 × 1056, 256 samples) of viewpoints 1 and 2, still (64 frames) and after 24 frames of
`--drift`, and the window's configuration for the steady shimmer:

| Measure | before | after |
|---|---|---|
| mean error, still 1 / still 2 | 3.96 / 5.87 | 3.43 / 5.67 |
| PSNR, still 1 / still 2 (dB) | 28.39 / 25.24 | 28.87 / 25.42 |
| moving 1 and 2 | | the same to the bit |
| `--flicker --upscale` | 0.65 | 0.49 |
| `--settle --upscale` | 24.2 | 19.1 |
| `--flicker --steady`, upper half, viewpoint 2 | 0.48 | 0.06 |

The "detail" proxy (Laplacian energy over the reference's) went down on still pictures (0.16 to 0.14): it was the
staircase of the edges that blinked, which a look at the pictures shows smoothed as in the reference.

What did not help, measured on the way (so as not to try it again): the still cap (48, 96, 128 changed nothing: the
count never reached it while the history was thrown away), the clamp opened on still frames, the blend and the
gather in a tone-mapped space x / (1 + luma), and taking the computed picture's own history away (a half-blend,
`limit` 1: without it the facades' lamp light shimmered more; it stays). The governor's floor went from 0.2 to 0.5 of
the window: 256 × 144 at 60 a second was a blur.

**The 16-frame shimmer (second round, 2026-11-26).** After the two fixes above a still view still shimmered on fine
detail (lit windows, the sun's gap between two towers), with a strict period: the autocorrelation of the worst pixels was
0.83 at lag 16, the length of the offset cycle. `--flicker --steady --dump PREFIX` writes the measured frames and
`scratchpad`-style analysis (variance map, autocorrelation) finds where and at what period. The cause is arithmetic,
not a bug: the history is an exponential mean of samples taken at a cycle of T offsets, and such a mean keeps a ripple
of about `1 / (2 sin(pi / T))` of its weight `1 / cap`. `lux_steady` measures it on a synthetic still view of bars
(interior, mean peak to peak, contrast 0.8):

| cap | cycle 16 | cycle 8 |
|---|---|---|
| 12 | | 0.0193 |
| 48 | 0.0064 | 0.0047 |
| 192 | 0.0016 | 0.0012 |
| 1000 | | 0.0002 |

so the ripple falls as `1 / cap` and a shorter cycle ripples less and faster (less visible). What changed:

1. **The cycle is 8, not 16** (`LuxUpscalePolicy.cycle`; for an enlargement up to 2, eight positions cover a pixel): the
   shimmer falls 30 % for 0.26 dB; a cycle of 4 falls 56 % but costs 1.3 dB and aliases.
2. **The memory has three tiers**, chosen per pixel by `LumenWorker.gChange` from what its rays met: *steady* (nothing
   moves with the time) keeps 192 samples; *slow* (only what the pixel reflects moves: a window onto the sea) 96;
   *restless* (the pixel's own light moves: water, a portal, a lantern's texels, a surface a flickering lamp reaches) 32
   still and **4 moving**. A moving sea must keep a short memory: its reflection is a virtual image that does not move
   with the surface the history is reprojected by, so a longer memory made the buildings' reflection slide behind the
   camera until it stopped. The cloud shade drifts 0.012 cells a second, so a long memory costs it no lag; the colour
   clamp bounds the lag of everything flat (`lxsFlatFollows`).
3. **A bug on the picture's edge**: a history whose place was on the last row or column, or a hair off the first by
   rounding, was *refused* (`0 <= px < ow - 1`), so the outer pixels never had a history and showed the raw samples of
   each frame: their ripple was 0.130 against 0.0012 inside. They are now read with the edge repeated
   (`lxsRipple`, ring band).
5. **The colour clamp is a ghost killer, and a still sample has no ghost.** The history of a pixel is cut to the box of
   this frame's 3 x 3 samples (widened 15 %). For a pixel that has not moved on the screen and keeps the long memory
   (*steady*, and *slow*) the box is dropped (`LUXU_STILL_SLACK`, `LUXU_STEADY_FROM`): a detail smaller than a pixel (a lit
   window far down a street) was cut whenever the offset left it out of the box, and the whole facade of lit windows
   whenever the governor changed the computed size: **2 281 pixels of a facade changed by more than 20 levels in one
   frame, 14 with no clamp** (measured by resizing a still view in `--flicker --steady`). A restless pixel (the sea)
   keeps the close clamp, which is what bounds its lag. Lanterns, the lit windows, are not restless: their 8 % texel
   flicker is erased by the memory anyway (`LumenAtlas.animates`: lava and crystals only).
6. **The rules live in the engine**, not in the demonstrator: `LuxChange` (what a pixel's rays met), `LuxUpscalePolicy.cap`
   (the memory it gets, still or moving), `LuxSpriteUndo`; dusk only says what it met.
7. **The sea's Fresnel** is the exact dielectric equations, not Schlick's approximation (`luxViewFresnel`): 6 to 10 % too
   high at the angles a camera at the water's edge sees (0.769 against 0.722 at 3 degrees above the surface).

4. **The cycle's phase** is `luxuPhase` (a negative frame counts back from the end; a cycle under 1 is 1): `%` keeps the
   sign of its left side and a cycle of 0 trapped.

Measured against the first version of the day (the half-blend, caps 8/4, cycle 16): `--flicker --upscale` 0.65 to 0.20,
`--settle --upscale` 24.2 to 5.1 (6 % of the bytes moving visibly instead of 47 %), mean error to the native reference
3.96 to 3.21 (still), 7.83 to 3.82 (moving); the steady shimmer of viewpoint 4 (the street) 0.148 to 0.07.

## 7. History

| Date | Change | Measured | Kept? |
|---|---|---|---|
| 2026-11-24 | the picture finished at the window's size, scaled from the computed one | 480 × 256 scaled to 1920: "480p" | replaced |
| 2026-11-24 | `LuxUpscale`, 3 × 3 gather | 24 ms a frame at 1080p | improved |
| 2026-11-24 | bloom from the computed picture, bounded meter, no copy, boxes once, 2 × 2 gather, reciprocals | 20 ms | yes |
| 2026-11-24 | the full output size computed when still | 8 frames a second at 1080p: frozen | **withdrawn** |
| 2026-11-24 | footprints by the shown pixel | moving water keeps its waves | yes |
| 2026-11-26 | the computed picture without a history of its own while upscaled; caps 16 moving, 12 water | sharper, but a still view's silhouettes shimmered (steady 0.79 against 0.52) | **withdrawn** |
| 2026-11-26 | the governor's floor 0.5 of the window (was 0.2) | no 256 × 144 blur at 60 a second | yes |
| 2026-11-26 | a still sample keeps its history whatever its distance; a still view's bloom from the shown picture | a still view's silhouettes and walls stop blinking (steady 0.48 to 0.06) | yes |
| 2026-11-26 | cycle 8; three memories by what the pixel's rays met; a history on the picture's edge is read, not refused | still shimmer 0.65 to 0.20, settle 24 to 5, edge ripple 0.130 to 0.001 | yes |
