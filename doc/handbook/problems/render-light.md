# Problems of light and display (`src/render/pathlight`, `src/render/lux`)

A glossary of needs: "I want X" -> the mathematical or algorithmic means the code uses, and what it costs in CPU and RAM. Every
formula, constant and complexity below was read in the file named in **Where**; a claim that could not be checked is marked
`UNVERIFIED`. Line numbers are those of the working tree when this file was written (`path:line` or `path:first-last`).

Zone: `src/render/pathlight/*.axle` (bloom, a-trous filter, sky grid, sky, clouds, celestial bodies, face cache, sparse light,
shading, shafts, post, noise, camera), `src/render/lux/**` (graph, cache, key, scheduler, budget, tiles, view, simd, ocean, fft,
look, thin, medium, interface, immersion, sprites, clip, upscale) and the two files of `src/core/field` that the lux looks read
(`lux_field.axle`, `lux_noise.axle`), plus `atan2Quick`/`asinQuick` of `src/core/math/trig.axle` which the sky uses.

Symbols used throughout: `P` pixels of the picture (921 600 at 1280 x 720), `W x H` its sides, `s` stride between samples, `L` layers
of a lux graph, `E` edges (reads and writes) of that graph, `N` the side of an FFT grid, `n` samples. Costs marked "measured" are
quoted from the file or handbook chapter named beside them, never re-measured here (nothing was built or run).

Existing prose: handbook chapters `doc/handbook/render/01..18`, `concepts/01..04`, `standards/01..03`. The complexity ledger
(`doc/handbook/concepts/04-complexity-ledger.md`) is cited as "ledger" with its section and row.

---

## Display: from radiance to pixels (`pathlight_post`, `pathlight_bloom`)

### L-01. I want the picture's brightness to follow what an eye would adapt to, without one small sun darkening a landscape
- **Means:** an exposure computed from the geometric mean of the picture's luminance, read on a sparse grid of pixels, pushed toward
  a key value by a power less than 1, and clamped.
- **Mathematics:** `Y = 0.2126 R + 0.7152 G + 0.0722 B` (Rec. 709, weights add to 1); `mean = 2^((1/n) sum log2 max(Y_i, 2e-5))`
  (the exponential of the mean logarithm); `want = clamp((0.17 / mean)^0.78, 0.04, 90) * 2^bias`. None other than that identity;
  the floor `2e-5` stops a black pixel dragging the mean to minus infinity.
- **Instructions:** `log2`, `exp2` and `pow` are the library's deterministic `lightLog2/lightExp2/lightPow`, not libm; the luminance
  weights are scalar constants (no `Vec3` built); the loop starts at pixel (1, 1) and steps `s` each way; `s` starts at 4 and
  grows by one until `(W/s)(H/s) <= 60 000`, so the meter's work is bounded whatever the picture size.
- **Cost:** `O(n)` with `n = (W/s)(H/s) <= 60 000` logarithms a frame, no memory. 720p reads 57 600 samples at `s = 4`; 1080p reads
  57 600 at `s = 6` (derived from the loop, `320 x 180`). Measured: "a 1080p picture took 1.4 ms" before the cap
  (`pathlight_post.axle:254-255`); 0.7 ms a frame at 720p (`doc/handbook/render/08-display.md` §3.1, with "it read one pixel in four
  before").
- **Why this and not another:** handbook 08 §3.1: the arithmetic mean would let a small bright sun darken the whole landscape. Reading
  one pixel in 16 gives the mean of all "to the third digit" (`pathlight_post.axle:253-255`). Ledger §5 row 2 records "meter on 1
  pixel in 16" inside the 67 -> 53 ms step. No rejected alternative to the geometric mean is measured.
- **Where:** `src/render/pathlight/pathlight_post.axle:44-49,57-69,247-285`.
- **Docs:** `doc/handbook/render/08-display.md` §3.1.

### L-02. I want brightness to settle in about a tenth of a second, so turning toward the sun does not drift but a lantern flash does not pump
- **Means:** the exposure moves toward its target in log space (stops) by a share that is linear in the frame's length.
- **Mathematics:** `blend = saturate(9 dt)`; `log2 E' = log2 E + (log2 want - log2 E) blend`. Linear in `dt`, not `1 - e^(-9 dt)`: a frame of
  1/9 s or longer snaps to the target (`pathlight_post.axle:27-32`).
- **Instructions:** two `log2` and one `exp2` a frame; `instant` skips the ease (first frame, jumps).
- **Cost:** `O(1)` a frame, 4 bytes of state.
- **Why this and not another:** the file explains the two bounds (fast enough not to follow a turn toward the sun, slow enough not to pump
  on a lantern flash, `pathlight_post.axle:3-7`); the choice of a linear share over an exponential is stated, not compared:
  `not documented`.
- **Where:** `src/render/pathlight/pathlight_post.axle:27-32,285-291`.
- **Docs:** `doc/handbook/render/08-display.md` §3.1 (the doc says the game caps exposure at 4; that cap is not in this file, see Doubts).

### L-03. I want light above display white to spill round its source like a lens glow
- **Means:** a bloom pyramid: keep only what exceeds 1 after exposure, halve it four times with 2 x 2 boxes, blur each level with the
  binomial kernel 1-4-6-4-1, add the levels back with decreasing weights.
- **Mathematics:** source `c = min(rgb * E, 6)`; `keep = max(max(c) - 1, 0) / max(max(c), 1e-4)`; `src = c * keep`, averaged over each 2 x 2 box.
  Kernel `(1, 4, 6, 4, 1)/16 = (0.0625, 0.25, 0.375, 0.25, 0.0625)`, separable (a row pass then a column pass). Level weights
  `0.9, 0.75, 0.6, 0.5`; total gain `strength * 0.35`. The binomial row is the discrete approximation of a Gaussian (the file only
  says "binomial", `pathlight_bloom.axle:3-5`).
- **Instructions:** separable blur: 5 multiply-adds a channel a pass instead of 25; `pkClamp` replicates the border; rows are cut into
  `[begin, end)` so each pass is a pool job that writes only its rows; coarser levels (a few thousand pixels) stay on one thread.
- **Cost:** with `P` the picture's pixels: level 1 holds `P/4` pixels, levels 2..4 `P/16, P/64, P/256`. Memory: five `f32` planes of 3 channels,
  about `7 P` bytes (6.4 MB at 1280 x 720, `doc/handbook/render/08-display.md` §5; derived from `PostPlanes`, `pathlight_post.axle:112-127`).
  Measured: bright + two blurs + coarse levels + fold 4.2 ms one thread (handbook 08 §5).
- **Why this and not another:** the source comment gives only the physics (`pathlight_post.axle:7-9`); the cost alternatives are in L-04.
- **Where:** `src/render/pathlight/pathlight_post.axle:41-42,90-97,457-486`, `src/render/pathlight/pathlight_bloom.axle:12-15,111-167`.
- **Docs:** `doc/handbook/render/08-display.md` §3.2.

### L-04. I want the bloom to cost one texture read per pixel, not four
- **Means:** fold the three coarser levels each into the next finer one, weights included, once a frame, so the picture reads a single
  level.
- **Mathematics:** bilinear up-sampling is linear, so `0.9 up(lv1) + 0.75 up(lv2) + 0.6 up(lv3) + 0.5 up(lv4)` regroups to
  `lv3 <- 0.6 lv3 + 0.5 up(lv4)`, `lv2 <- 0.75 lv2 + up(lv3)`, `lv1 <- 0.9 lv1 + up(lv2)`, and the picture reads `lv1` only. The
  result differs from four separate reads "only by the order of interpolation of two blurs" (handbook 08 §3.2).
- **Instructions:** one fold function `pkFoldRows(fine, keep, coarse, share)` does all three (`fine = fine*keep + share*up(coarse)`);
  the first two folds run on one thread inside `coarse()`, the last as pool pass `Fold`.
- **Cost:** the folds touch `P/64 + P/16 + P/4` pixels, `O(P)` with a small constant; saves 3 bilinear reads (12 texel loads) a pixel
  (hot-loop rule R5, `doc/handbook/standards/01-hot-loop-rules.md`). Measured: ledger §5 rows 1 -> 4: 67-70 ms -> 21 ms for the whole
  display, of which this is one step (the ledger does not split the step).
- **Why this and not another:** ledger §5 row 1 "4 bloom levels read bilinearly: 16 + 16 loads, 3 pow, 67 to 70 ms: no", row 4 "one bloom
  level ... 15 + 3 loads ... 21 ms: yes".
- **Where:** `src/render/pathlight/pathlight_bloom.axle:34-94`, `src/render/pathlight/pathlight_post.axle:429-455,409-419`.
- **Docs:** `doc/handbook/render/08-display.md` §3.2; `standards/01-hot-loop-rules.md` R5.

### L-05. I want to read a bloom level at exactly twice its size without a floor, a clamp or four loads a pixel
- **Means:** at exactly half size a fine pixel sits a quarter of a coarse pixel from the centre of its own coarse pixel, so the weights are
  fixed at 3/4 and 1/4 each way; a row of the picture walks two rows of the level and takes one new column for every two pixels.
- **Mathematics:** `up(x) = 3/4 c_j + 1/4 c_(j-1)` for even `x`, `3/4 c_j + 1/4 c_(j+1)` for odd `x`, `j = x >> 1`; the same down the rows
  (`pathlight_bloom.axle:34-37`; handbook 08 §3.6).
- **Instructions:** the vertical blend (`rowA * 3/4 + rowB * 1/4`) is done once per new column and carried in `pr/cr/nr` registers; the
  parity `x & 1` selects which two carried columns to blend; `(0.75 as f32)` literals to stay `f32`.
- **Cost:** per pair of pixels 6 loads (2 rows x 3 channels) instead of 24 for one (handbook 08 §3.6, "6 loads for 2 pixels instead of 24
  for 1"). Applies only when the bloom picture is exactly `W/2 x H/2` (`half` flag, `pathlight_post.axle:513`); otherwise a bilinear
  read per pixel (`pathlight_post.axle:582-597`).
- **Why this and not another:** hot-loop rules R4/R6 (bind fields, hoist what is constant along a row) in handbook 08 §4; no measured
  comparison of this step alone.
- **Where:** `src/render/pathlight/pathlight_bloom.axle:34-94`, `src/render/pathlight/pathlight_post.axle:511-567,598-619`.
- **Docs:** `doc/handbook/render/08-display.md` §3.6.

### L-06. I want a lamp to glow without flooding the picture
- **Means:** the bloom source is capped before it is spilled.
- **Mathematics:** none: plain arithmetic. `c = min(rgb * E, 6)` per channel (`POST_BLOOM_CEILING = 6`).
- **Instructions:** three scalar `min`s and one `max` of channels a pixel in the bright pass; no division except `max(m, 1e-4)`.
- **Cost:** `O(P)` loads (12 floats per level-1 pixel, 3 for each of the 4 source pixels) a frame; no extra memory.
- **Why this and not another:** `not documented` beyond the constant's comment, "a lamp glows, it does not flood the picture"
  (`pathlight_post.axle:41-42`).
- **Where:** `src/render/pathlight/pathlight_post.axle:41-42,458-486`.
- **Docs:** `doc/handbook/render/08-display.md` §3.2 (the cap 6 is shown in the formula).

### L-07. I want a tone curve that keeps hue and rolls highlights off smoothly, without an `exp` per pixel
- **Means:** apply the curve to the largest channel only and scale the others by the same gain; read the gain `T(m)/m` from a table.
- **Mathematics:** `T(x) = x` for `x <= k`, `T(x) = k + (1-k)(1 - e^(-(x-k)/(1-k)))` for `x > k`, knee `k = 0.6` (`light_color.axle:24-53`);
  gain `g(m) = T(m)/m` (entry 0 is 1). Table: 4097 entries over `m in [0, 40]`, entry `i` at `m = 40 i/4096`, read by linear
  interpolation; `m >= 40` falls back to the curve itself. `T` is continuous with slope 1 at the knee.
- **Instructions:** `f = m * (4096/40)`, `i = f as i32`, `lerp(tone[i], tone[i+1], f - i)`: one float-to-int and two loads; the table's
  constant `toneScale` is hoisted out of the loop.
- **Cost:** 16 388 bytes for the table (4097 `f32`); per pixel 2 loads + 1 lerp instead of an `exp` and a division. Measured: not given
  for the table alone.
- **Why this and not another:** comment `pathlight_post.axle:9-11`: "the curve and the encode are smooth, so interpolating a table of them is
  exact to well under one 8-bit code, and a table lookup is much cheaper than a power function a million times a frame". Ledger §5.
- **Where:** `src/render/pathlight/pathlight_post.axle:51-55,105-106,229-243,640-649,737-746`; `src/render/light/light_color.axle:24-53`.
- **Docs:** `doc/handbook/render/08-display.md` §3.3.

### L-08. I want the sRGB transfer function for a million pixels a frame without `pow`
- **Means:** two lookup tables of the exact transfer: a float table indexed by `sqrt(x)` for the general path, and an integer table over the
  linear value itself, in two linear segments, for the fused path.
- **Mathematics:** `enc(x) = 12.92 x` for `x <= 0.0031308`, else `1.055 x^(1/2.4) - 0.055`. Indexed by `s = sqrt(x)` the curve is nearly straight
  (`x^(1/2.4) = (sqrt x)^0.83`), so 4096 equal steps serve the whole range (handbook 08 §3.4). The integer table (`word`) has 4096 entries over
  `[0, 1/16)` (`i = x * 65536`) and 4096 over `[1/16, 1]` (`i = 4096 + (x - 1/16) * 4369.0667`); the nearest entry is within 0.03 of a
  display code below the split and 0.07 above (comment `pathlight_post.axle:99-100`). The split is where the transfer is steepest.
- **Instructions:** `pkWordIndex` clamps, compares with the split and does one multiply-add and a float-to-int with `+0.5` for the nearest
  entry; no `sqrt` and no float-to-int of the result. Entries are integers `256 * (255 code + 0.5)`, so adding the integer dither and `>> 8`
  is the rounding (see L-09).
- **Cost:** `word` table: 8193 `i32` = 32 772 bytes; `code` table 4097 `f32`. Per channel: 1 compare, 1 multiply-add, 1 convert, 1 load.
  Measured: ledger §5 row 3 "nearest sRGB entry over sqrt" 44 ms, row 4 "integer code table over the linear value; integer dither" 21 ms
  (display total, with other changes in the same row).
- **Why this and not another:** ledger §5: compose-then-pack with 3 `pow` 67-70 ms (no); sqrt-indexed table 44 ms (superseded by the integer
  table). The handbook gives the reasoning for the split at 1/16 (steepest near black, `doc/handbook/render/08-display.md` §3.7).
- **Where:** `src/render/pathlight/pathlight_post.axle:99-103,224-228,748-757,798-814`.
- **Docs:** `doc/handbook/render/08-display.md` §3.4, §3.7.

### L-09. I want to compose, tone, encode, dither and pack a pixel in one pass with no float-to-int for the code
- **Means:** `composeWords` writes the framebuffer word `0x00RRGGBB` directly when the picture is shown at its own size; every stage of the
  chain (sharpen, expose, bloom, vignette, highlight roll-off, grade, tone, encode, dither, pack) runs in one loop.
- **Mathematics:** none: plain arithmetic, but the integer identity `code8 = (word[idx] + n) >> 8` with `word = 256 (255 enc + 0.5)` and
  `n = floor(256 * dither)`, `dither in [-0.5, 0.5)`: the add is the dither and the shift is the round (`pathlight_post.axle:193-195,650-653`).
  The sum lies in 0..65535, so no clamp.
- **Instructions:** every field is bound to a local before the loop (a store through `out` may alias any field, rule R4); row-constant
  terms are hoisted (the two bloom rows, `dy2`, the dither row offset); the sharpen is only computed for interior pixels; the division
  of the highlight roll-off is only paid when `peak > 0.8`.
- **Cost:** `O(P)`; compose 17 ms of 21 ms for the display (ledger §5 row 4, one thread, 1280 x 720). Memory: `out` `P` words (3.7 MB at 720p);
  no intermediate display buffer.
- **Why this and not another:** the general path (`compose` + `pack`, 3 `sqrt` a pixel, a display buffer of `3P` floats, 11 MB at 720p) is kept
  for any other scale and for the raw view: handbook 08 §4-5.
- **Where:** `src/render/pathlight/pathlight_post.axle:497-658` (fused), `661-693,760-786` (general).
- **Docs:** `doc/handbook/render/08-display.md` §4; `standards/01-hot-loop-rules.md` R4, R6.

### L-10. I want 8-bit gradients without banding and without shimmer on a still picture
- **Means:** a fixed 64 x 64 tile of hashed noise added before rounding, the same on every frame, read with two masks.
- **Mathematics:** `dither(tx, ty) = lnUnit(tx, ty, 0, 977) - 0.5` in `[-0.5, 0.5)`; index `((y & 63) * 64) + (x & 63)`; the amplitude is one display
  code (`pkCode`: `v*255 + n + 0.5`).
- **Instructions:** two bit masks instead of a hash per output pixel; the integer twin `grain = floor(256 dither)` is built once from the tile.
- **Cost:** 4096 `f32` + 4096 `i32` = 32 768 bytes; `O(1)` a pixel. 
- **Why this and not another:** comment `pathlight_post.axle:189-190`: "the same noise for every frame, so a still picture does not shimmer, read
  with two masks instead of hashed for every output pixel". A random dither per frame is the implied alternative; no measurement.
- **Where:** `src/render/pathlight/pathlight_post.axle:71-75,189-195,213-223,821-830`.
- **Docs:** `doc/handbook/render/08-display.md` §3.5.

### L-11. I want a dark vignette, highlights that desaturate as they clip, and a touch of contrast
- **Means:** three cheap per-pixel operations after exposure and bloom: a radial dim, a saturation roll-off above a knee, a lerp away from grey.
- **Mathematics:** `dim = 1 - 0.9 (dx^2 + dy^2)` with `d` the offset from the centre in picture fractions; `grey = Y(rgb)`; for `peak > 0.8`:
  `fade = min((peak - 0.8)/(peak + 2.5), 1) * 0.85`, `rgb += (grey - rgb) fade`; grade `rgb = grey + (rgb - grey) * 1.12`.
- **Instructions:** the squared distance is separable (`dy2` once a row, `dx*dx` a pixel); the roll-off division is guarded by the knee test.
- **Cost:** `O(P)`, about 12 multiply-adds and one conditional division a pixel; no memory.
- **Why this and not another:** `not documented` beyond "like film: a lantern on grass goes yellow-white, not neon" (`pathlight_post.axle:701-702`).
  Note `compose` uses `saturate((peak - knee)/(peak + range))` through `lerp` while `composeWords` uses `min(..., 1)` inside the `peak > knee` branch;
  the same result for `peak > knee` (the ratio is positive there).
- **Where:** `src/render/pathlight/pathlight_post.axle:77-88,621-639,697-713`.
- **Docs:** `doc/handbook/render/08-display.md` (chain, §2; the constants themselves are not derived there: `MISSING` for the highlight law).

### L-12. I want back the detail an upscaled picture loses, without halos on edges
- **Means:** an unsharp mask clamped to the range of the pixel's four neighbours and itself.
- **Mathematics:** `sharp = c + 0.6 (c - mean4(l, r, u, d))`, then `min(max(sharp, min(lo, c)), max(hi, c))` with `lo, hi` the min and max of the four
  neighbours. The clamp means no output leaves the local range, so an edge cannot overshoot (no halo).
- **Instructions:** `pkSharp` is scalar per channel (the loop's hot path); `sharpened` is the `Vec3` twin with `componentMin/Max`; borders and
  `x == 0 / w-1` pixels are left alone.
- **Cost:** 4 neighbour loads per channel, `O(P)`; no memory. Measured: not given.
- **Why this and not another:** comment `pathlight_post.axle:715-718`: a picture drawn at half size and scaled up with a resampled history is
  softer; this "takes back about what that cost". No alternative documented.
- **Where:** `src/render/pathlight/pathlight_post.axle:34-35,574-578,715-735,789-796`.
- **Docs:** `doc/handbook/render/08-display.md` §4-5 mention the sharpen's neighbour loads only; the formula, the share 0.6 and the clamp are `MISSING`.

### L-13. I want a picture shown at any window size, with the same sample positions however it is cut into jobs
- **Means:** the finished picture is bilinearly resampled from the display picture in a pack pass, one output row range per job; buffers only
  grow, so a resize allocates nothing after the largest size is seen.
- **Mathematics:** output sample `(ox + 1/2)/ow, (oy + 1/2)/oh` read with `pkBilinear` (`fx = u w - 1/2`, border clamp); the division is
  kept "not multiplied by a reciprocal: the same sample positions to the last bit" (`pathlight_post.axle:780`).
- **Instructions:** `scale == 1` skips the resample; `packRows()` is 0 when `composeWords` already wrote words; `fit/fitUpscaled/levelsFor/displayIfPacked`
  replace the buffers when the size asked is larger than the capacity.
- **Cost:** pack `O(ow * oh)` bilinear reads; memory `disp` `12 P` bytes only when packing; `out` `4 ow oh` bytes (`bytes()` reports it). Measured:
  display at output size 8.4 ms -> 5.2 ms with bloom from the computed picture, meter capped and no copy (`doc/handbook/render/16-upscale.md` §5,
  1920 x 1056, 23 threads).
- **Why this and not another:** buffers grow and are reused "changing size in a loop allocates nothing after the first time"
  (`pathlight_post.axle:296-298`); the first version rebuilt the frame per resize and leaked (`doc/handbook/render/13-dusk.md` §3.9).
- **Where:** `src/render/pathlight/pathlight_post.axle:299-374,759-786`; `src/render/pathlight/pathlight_bloom.axle:17-32`.
- **Docs:** `doc/handbook/render/13-dusk.md` §3.9; `doc/handbook/render/16-upscale.md` §5.

### L-14. I want a buffer that grows without leaking in this compiler
- **Means:** the arrays are held by a small owner object that is replaced whole when a bigger size is asked; the object a store displaces is freed
  with everything it holds.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `PostPlanes`, `PostDisplay` (here) and `LuxuHistory` (the upscaler) each hold the arrays; the loops borrow them as locals.
- **Cost:** a reallocation of the whole set on growth only (`O(size)` once); steady state free.
- **Why this and not another:** comment `pathlight_post.axle:108-111`: Axle frees the array a field store displaces only when its value never leaves
  the object (ledger section 862 in the Axle repository). Memory note `axle-field-leak-862`. The Axle repository's ledger text itself was
  not read: `UNVERIFIED` beyond the comment.
- **Where:** `src/render/pathlight/pathlight_post.axle:108-139,352-364`; `src/render/lux/temporal/lux_upscale.axle:62-78`.
- **Docs:** `doc/handbook/standards/03-types-and-memory.md` (not verified to cover it): `MISSING` as a named rule.

---

## Sky and clouds (`pathlight_sky`, `pathlight_skygrid`, `pathlight_cloud`, `pathlight_celestial`)

### L-15. I want the colour of the sky along any direction at constant cost for every pixel, haze and reflection
- **Means:** bake the radiance of the sky once a time-of-day step over a latitude-longitude grid, in parallel; every lookup afterwards reads that
  grid.
- **Mathematics:** grid of `128 x 64` cells, azimuth around (wraps) and elevation from nadir to zenith (clamped); cell centres at
  `elev = ((row + 1/2)/64 - 1/2) pi`, `az = ((col + 1/2)/128) 2 pi`; each cell is the single-scattering integral of `LightSky` plus the moon's lifted
  share (`moonShare = 2.5e-6 * (26000 - 1)`). Direction -> cell: `u = atan2Quick(x, z)/2 pi` (wrapped), `v = asinQuick(y)/pi + 1/2`.
- **Instructions:** the bake is 2 rows a job on the pool (`SKY_ROWS_PER_JOB = 2`, 32 jobs); each row is written by one job only.
- **Cost:** bake `128 * 64 = 8192` integrals; memory 98 304 B + 6 144 B (32 x 16) + 384 B (8 x 4), all `f32` x 3. Measured: 0.16 ms an integral, 1.3 s
  one thread (`doc/handbook/render/06-sky.md` §2.1, §7); the source comment says "some two and a half seconds of work" for the baker
  (`pathlight_sky.axle:228-229`): the two numbers differ (Doubts). Lookup `O(1)`: 24 loads (L-16).
- **Why this and not another:** ledger §3 row 1 "physical sky evaluated a pixel: far too slow: no", row 2 "radiance grid over direction, baked when the
  sun moves: yes, O(1), 55 ns".
- **Where:** `src/render/pathlight/pathlight_sky.axle:35-40,43,125-170,484-491,531-543`.
- **Docs:** `doc/handbook/render/06-sky.md` §2.

### L-16. I want a sky with no visible bands between grid rows
- **Means:** linear interpolation round the azimuth (which wraps) and Catmull-Rom along the elevation (clamped), written out as eight weighted
  loads a channel.
- **Mathematics:** `t = ty`, `w0 = (-t^3 + 2 t^2 - t)/2`, `w1 = (3 t^3 - 5 t^2 + 2)/2`, `w2 = (-3 t^3 + 4 t^2 + t)/2`, `w3 = (t^3 - t^2)/2`;
  value `= max(0, sum_j w_j [(1 - tx) c(x0, y_j) + tx c(x0+1, y_j)])`. Catmull-Rom has a continuous first derivative through every row; linear
  blending has a slope break every row (every 2.8 degrees, about 25 pixels on screen, `pathlight_skygrid.axle:49-52`). `max(0, .)` removes the
  undershoot a cubic can make.
- **Instructions:** the azimuth wrap is a comparison (an integer remainder "costs more than the eight texels"); the two azimuth weights are folded into
  the four row weights (`ka0 = w0 sa`, `kb0 = w0 tx`, ...), so each channel is one sum of eight products; the elevation rows are clamped by `clampRow`.
- **Cost:** `O(1)`, 24 loads, 8 multiplies a channel plus the weight setup. Measured: ledger §3 row 2 "55 ns" for the lookup; rows 5-6 give 68 ns with
  exact angles and 58 ns with the quick ones (the three numbers are not on one common base: the ledger does not say what each includes).
- **Why this and not another:** doc 06 §2.3: linear shows kinks as bands; cubic is smooth through every row. No measured alternative.
- **Where:** `src/render/pathlight/pathlight_skygrid.axle:48-123`.
- **Docs:** `doc/handbook/render/06-sky.md` §2.3.

### L-17. I want the angle of a direction for a table lookup at a fraction of the price of `atan2`
- **Means:** `atan2Quick` and `asinQuick`, a degree-9 odd polynomial with argument folding.
- **Mathematics:** Abramowitz and Stegun 4.4.47: `atan(q) = q (a1 + a3 q^2 + a5 q^4 + a7 q^6 + a9 q^8)` on `[0, 1]` with `a1 = 0.9998660, a3 = -0.3302995,
  a5 = 0.1801410, a7 = -0.0851330, a9 = 0.0208351`; `q = min(|x|,|y|)/max(|x|,|y|)`; fold: `a = pi/2 - a` if `|y| > |x|`, `a = pi - a` if `x < 0`, sign of `y`.
  `asinQuick(s) = atan2Quick(s, sqrt(1 - s^2))`, input clamped to `[-1, 1]`. Error below `1.2e-5` rad (trig.axle:298; the sky's comment says `1e-5`, handbook 06 says
  `2e-5`: Doubts).
- **Instructions:** one division, four multiply-adds in Horner form on `q^2`, a few compares and a sqrt for asin; purely IEEE `+ - * /` so deterministic.
- **Cost:** `O(1)`; "about fifteen times cheaper than the exact one" (`trig.axle:309-311`). Measured: 68 ns -> 58 ns a lookup (ledger §3 rows 5-6).
- **Why this and not another:** the exact `atan2` (f64 minimax, 1.3e-7) rejected for a lookup that "needs an angle good to a small fraction of a table
  cell": 1e-5 rad is 1/5000 of a cell of 0.05 rad (`pathlight_sky.axle:529-531`). Hot-loop rule R2.
- **Where:** `src/core/math/trig.axle:294-361`; used at `src/render/pathlight/pathlight_sky.axle:531-538`.
- **Docs:** `doc/handbook/render/06-sky.md` §4; `standards/01-hot-loop-rules.md` R2, R8.

### L-18. I want a rough surface to reflect a blurred sky and a mirror a sharp one, reading only the levels the answer needs
- **Means:** two coarser copies of the grid (box means of 4 x 4 and 16 x 16 cells) and a blend by roughness.
- **Mathematics:** `sharp` below roughness 0.18; `lerp(sharp, mid, (r - 0.18)/0.32)` between 0.18 and 0.5; `lerp(mid, low, saturate((r - 0.5)/0.5))` above.
  Levels: `128 x 64` (full), `32 x 16`, `8 x 4`, each a block mean (`downsampleInto`, share `1/(bw bh)`).
- **Instructions:** only the levels in the blend are read (a rough surface never reads the sharp grid); one `gridPlace` for all.
- **Cost:** a lookup is `O(1)`, 24 loads a level read, at most 2 levels; blur levels cost `O(grid)` once a bake: 8192 + 512 adds.
- **Why this and not another:** comment `pathlight_sky.axle:3-6` "blurred copies stand in for a prefiltered environment"; no alternative measured.
- **Where:** `src/render/pathlight/pathlight_sky.axle:45-47,550-563`, `src/render/pathlight/pathlight_skygrid.axle:133-154`.
- **Docs:** `doc/handbook/render/05-shading.md` §3.4 (not verified in detail); `doc/handbook/render/06-sky.md` §2.1 mentions the two copies.

### L-19. I want the sky to follow a moving clock with no freeze
- **Means:** the sun, moon and derived lights are closed-form and set at once; the radiance grid and the dome are baked on one background thread and
  swapped in when finished, then the next bake is started.
- **Mathematics:** none: plain arithmetic (the sun/moon directions come from `LightSky::atDayTime`).
- **Instructions:** `glide(dayTime)` updates `sunDir/moonDir/irradiance`, `night = saturate(0.12 - sunY * 4)`; if `baker.ready()` it copies the grid, redoes the two
  down-samples, takes the dome, releases the baker and returns `true`; then `request(dayTime)`.
- **Cost:** per call `O(1)` plus, when a bake lands, a copy of 98 304 B and two down-samples. Measured: p99 392 -> 35 ms (ledger §3 rows 3-4); the old way
  was "365 ms every 0.85 s" (handbook 06 §6).
- **Why this and not another:** ledger §3 row 3 "bake on the frame's thread: 365 ms every 0.85 s: a freeze a second: no", row 4 "bake on a background thread, swapped in: yes".
- **Where:** `src/render/pathlight/pathlight_sky.axle:464-481`.
- **Docs:** `doc/handbook/render/06-sky.md` §6.

### L-20. I want a background bake never seen half written, and a program that can exit while one runs
- **Means:** a three-state gate (`IDLE`, `BUSY`, `READY`) held in an atomic; the baker thread sleeps on a channel; `stop` sends a stop message and waits on a second channel.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `request` returns false unless idle; the worker writes the kernel's grid and the gate's dome, then `state.set(READY)`; the owner reads only when `READY` and
  calls `release` to return to `IDLE`; `stop` waits for `gone` so the thread has left before the buffers are freed.
- **Cost:** one thread, one `AtomicI32`, two bounded channels; one grid is shared (the baker's kernel), so no extra grid copy beyond `lut.copyFrom` at the swap.
- **Why this and not another:** comment `pathlight_sky.axle:286-288`: "a program that ended in the middle of one crashed on its way out" (the reason for `stop` waiting).
  Axle's atomic and reference-count behaviour in this pattern is in the memory note `axle-shared-trait-race`; the Axle-side record was not read: `UNVERIFIED`.
- **Where:** `src/render/pathlight/pathlight_sky.axle:172-301`.
- **Docs:** `doc/handbook/render/06-sky.md` §6 (mentions "a thread, a gate, two channels"); the memory ordering argument is `MISSING`.

### L-21. I want clouds that do not sizzle at the horizon when the camera moves
- **Means:** the cloud noise is averaged over one sample's footprint on the deck: layers finer than the footprint are replaced by their mean, and the threshold is
  applied after the averaging.
- **Mathematics:** a sample of angle `sample` (0.0068 rad) at slant `dir.y` covers `across = reach * sample * blur / dir.y` blocks (`reach = (150 - 24)/dir.y`); layer `o` of
  wavelength `wave_o = 1/2.03^o` (noise cells) is kept with `keep = saturate(wave/finest - 1)`, `finest = 2 * across * 0.011`; `n = sum a_o (keep v_o + (1 - keep)/2)/sum a_o`;
  `cover = smoothstep(0.5, 0.78, n)`. The mean of the noise, 0.5, is exactly the cloud threshold, so where no layer is kept there is no cloud (doc 06 §3.1): cover of the
  averaged noise, not the average of the cover.
- **Instructions:** the keep weight is a single saturate; when `keep <= 0` the noise lookup is skipped and `amp * 0.5` added; the second (sunward) lookup is skipped for blurred views.
- **Cost:** `O(octaves kept)` (at most 5 lookups of value noise), fewer far away: overhead all five; 17 degrees two; 11.5 degrees one; under 7.9 degrees none (doc 06 §3.1). Measured: two
  consecutive frames of a slow turn, mean difference 0.65 -> 0.19 levels (doc 06 §3.1; ledger §3 row 8).
- **Why this and not another:** ledger §3 row 7: "5 octaves of noise a lookup: aliasing at the horizon: replaced by 8".
- **Where:** `src/render/pathlight/pathlight_noise.axle:60-84` (`lnFbm2Soft`), `src/render/pathlight/pathlight_cloud.axle:108-117,150-184`.
- **Docs:** `doc/handbook/render/06-sky.md` §3.1.

### L-22. I want a cloud deck that does not come closer when I fly up, lit from the sun's side with a silver lining
- **Means:** the deck is a plane at height 150 seen from a fixed height of 24; thickness toward the sun darkens it and an edge facing the sun glows.
- **Mathematics:** `reach = (150 - 24)/dir.y`, none when `dir.y < 0.02`; point `p = eye_xz + dir_xz * reach`; `thick = saturate(cover(p + 14 sun_xz) - cover(p) + 0.55)`;
  `lit = (sunIrr/pi * saturate(3 sunY) * (0.25 + 0.9 (1 - thick)) + moonIrr/pi * saturate(3 moonY) * 0.5 + zenith) * (0.97, 0.97, 1)`;
  `alpha = cover * saturate(6 dir.y) * 0.92`; drift `(0.012, 0.004)` blocks a second.
- **Instructions:** `lumenCloudDistance` is one division and a compare; blurred viewers (`blur > 1`, a rippled mirror) take `thick = 0.55` and save the second noise reading.
- **Cost:** a `veil` lookup is one grid look + up to 2 cloud-cover evaluations of 5 octaves; no memory.
- **Why this and not another:** the comment `pathlight_cloud.axle:184-185` "flying up must not bring the clouds closer". The 30-times-too-fast drift is a recorded bug
  (`pathlight_cloud.axle:5-8`). No alternative cloud model is compared.
- **Where:** `src/render/pathlight/pathlight_cloud.axle:16-40,89-95,119-125,150-184`.
- **Docs:** `doc/handbook/render/06-sky.md` §3.

### L-23. I want the ground shaded by clouds drifting over it, consistent with the sky I see
- **Means:** the same cover function as the sky is evaluated where a point's ray to the sun crosses the deck, removing up to 78 % of that body's light.
- **Mathematics:** `reach = (150 - y)/toward.y`; `vis = baked * (1 - 0.78 cover(x + toward.x reach, z + toward.z reach, t))`.
- **Instructions:** `lumenCloudDistance` first (no cloud when the ray does not rise 0.02 or the point is above the deck); the moon is only shaded when `night > 0.05`.
- **Cost:** one 5-octave noise evaluation a shaded point and body, no memory (the sun-lit pixels pay it once; see L-33 for what is cached).
- **Why this and not another:** `not documented` (the file says only "the clouds shade the ground by moving over it", `pathlight_shade.axle:99-102`).
- **Where:** `src/render/pathlight/pathlight_shade.axle:40-41,99-110,134`.
- **Docs:** `doc/handbook/render/05-shading.md` §3.2 (not read in detail).

### L-24. I want a moon bright enough to see by without changing the physics of the night
- **Means:** the moon's light, its scattered sky and its dome are all scaled by one named constant.
- **Mathematics:** `moonShare = SKY_MOON_RATIO * (SKY_MOON_LIFT - 1)` with ratio `2.5e-6` (the real moon's share of the sun) and lift `26 000`; grid cell `= day + moonLit * tint * moonShare`,
  tint `(0.8, 0.9, 1.15)`; the dome gets the same scaling; stars show from `night = saturate(0.12 - sunY * 4)`.
- **Instructions:** one scalar multiplication per cell; the lifted irradiance is also fed to the cloud light and the discs.
- **Cost:** a second `LightSky` evaluation a grid cell (the night sky) inside the same bake: `runRange` computes both for every cell (`pathlight_sky.axle:164-165`), so the
  bake work is about double (derived from the loop; no timing of the split is given: UNVERIFIED).
- **Why this and not another:** comment `pathlight_sky.axle:8-10`: "the night keeps its physics and only its scale is chosen".
- **Where:** `src/render/pathlight/pathlight_sky.axle:58-70,157-169,201-208,498-501`.
- **Docs:** `MISSING` (handbook 06 §5 describes the bodies, not the lift).

### L-25. I want fixed stars that twinkle, and a moon with seas and craters, with no texture
- **Means:** a star is one cell of a direction grid selected by a hash; the moon's face is two octaves of value noise on the disc.
- **Mathematics:** cell `floor(260 d)` (componentwise), `h = lnUnit(cell, 331)`; a star where `h >= 0.9975` (a quarter of a percent of cells); brightness `k^2 * (0.9 + 0.1 sin(3 t + 40 warm))`,
  `k = (h - 0.9975)/0.0025`; colour `lerp(cold, warm, warm)`. Moon: `dim = 1 - 0.55 smoothstep(0.45, 0.7, sea) - 0.18 crater`; radiance `moonIrr dim / (pi sin^2 r)`, `r = 0.017`.
- **Instructions:** pure hash, no table; the moon uses `anyPerpendicular` and `cross` to make the disc's frame, two `lnValue2` lookups.
- **Cost:** a star test is three floors, one hash, one compare a pixel (cheaper still when `night = 0`: the test is skipped); the moon disc only inside `cos(r)`. No memory.
- **Why this and not another:** doc 06 §5: "A star is one direction cell, so it is one or two pixels: it must be evaluated per pixel and must not be averaged with a reprojected history".
- **Where:** `src/render/pathlight/pathlight_celestial.axle:15-19,40-57,73-107`; `src/render/pathlight/pathlight_sky.axle:639-657`.
- **Docs:** `doc/handbook/render/06-sky.md` §5 (it says brightness `0.75 + 0.25 sin`, the code has `0.9 + 0.1 sin`: Doubts).

### L-26. I want distant surfaces to dissolve into the colour of the air, and a mountain in front of the sun hazed rather than lit by it
- **Means:** the air colour is the sky just above the horizon in that direction, except near the sun where it is the dome's smooth ambient instead.
- **Mathematics:** `flat = normalize(dir.x, dir.y * 0.25 + 0.05, dir.z)`; `sky = grid(flat)`; `near = saturate((flat . sun - 0.55)/0.4)`; `haze = lerp(sky, dome.irradiance(flat) * 0.9, near)`.
- **Instructions:** one normalisation, one grid look, one SH9 evaluation only when `near > 0`.
- **Cost:** `O(1)`; the SH9 term costs 9 coefficients' evaluation only in the glare cone.
- **Why this and not another:** comment `pathlight_sky.axle:659-662`: "so a mountain between you and the sun is hazed, not lit up by a sun it hides". No alternative compared.
- **Where:** `src/render/pathlight/pathlight_sky.axle:85-94,664-673`.
- **Docs:** `doc/handbook/render/05-shading.md` §4.1 (lines 105-109: the flattening `0.25 y + 0.05` and the dome's colour round the sun); the glare constants (0.55, 0.4, 0.9) are `MISSING`.

### L-27. I want ground beyond the loaded world to blend into the horizon, with no second horizon
- **Means:** below the horizon the grid is read only at the horizon (a sine of 0.02), then blended toward a dimmed horizon colour mixed with the earth's own colour over about 24 degrees of dip.
- **Mathematics:** `horizon = grid(normalize(dir.x, 0.02, dir.z))`; `earth = lerp(horizon * 0.6, albedo(0.13, 0.15, 0.10) * groundLit, 0.25)`; result `lerp(horizon, earth, saturate(-dir.y * 2.5))`
  (sine of the dip = 1/2.5, i.e. asin(0.4) = 23.6 degrees).
- **Instructions:** only one of `ground`/`base` is evaluated (`backdrop` branches on `dir.y < 0`).
- **Cost:** `O(1)`, one grid look.
- **Why this and not another:** comments `pathlight_sky.axle:99-104,106-108,677-678`: reading the map below the horizon drew a halo (the map holds the sky mirrored); a faster blend drew a second, olive horizon.
- **Where:** `src/render/pathlight/pathlight_sky.axle:96-108,629-636,675-688`.
- **Docs:** `MISSING`.

### L-28. I want the sun reflected in rippled water to be a stable glow, not dots that jump every frame
- **Means:** in the rippled mirror the sun and the moon are not discs but a lobe `spread` radians wide that carries the same irradiance.
- **Mathematics:** `off = (2 - 2 d.sun)/w^2` (about `theta^2/w^2`), lobe `= irr * skyLobe(off) * 1.0625/(pi w^2) * clear`, with `skyLobe(x) = (1 - x/16)^16` as `e^-x` for `x in [0, 7)`; cut where `e^-7` is `0.0009` of the peak;
  `1.0625` restores the 5.9 % the cut and the polynomial lose (`integral_0^7 skyLobe = 16/17 (1 - (9/16)^17) = 0.9411`; `1/0.9411 = 1.0625`). The polynomial is within two percent of the peak of `e^-x`
  everywhere on the range (absolute, not relative to `e^-x`: at `x = 7` it is `1.0e-4` against `9.1e-4`).
- **Instructions:** four multiplies by repeated squaring (`a^2, a^4, a^8, a^16`) and one compare to cut; no libm `exp`.
- **Cost:** `O(1)`, 2 body tests a reflection lookup; clouds fade into the mirror between sines 0.08 and 0.3 (`SKY_MIRROR_LOW/CLOUDS`).
- **Why this and not another:** comment `pathlight_sky.axle:595-599`: "under one pixel of water the ripples tilt the mirror by more than a disc is wide, so the disc itself would be met by one pixel in two: a dotted line that jumps with every move". Handbook 10 §2.3: the polynomial cut at 7 integrates to 0.9411 where the exponential gives 0.9991, hence the factor 17/16, "found in review: the reflected sun was 6 % dim". The lobe's width is floored at 0.005 rad.
- **Where:** `src/render/pathlight/pathlight_sky.axle:303-326,600-627`.
- **Docs:** `doc/handbook/render/10-water.md` §2.3 (the sky in a rippled mirror).

### L-29. I want caustic lines on a lake bed without simulating a surface
- **Means:** a repeating, moving pattern of bright lines from two phase-bent sine wave trains.
- **Mathematics:** `a = sin(1.3 x + 1.1 t + 1.5 sin(0.9 z + 0.7 t))`, `b = sin(1.1 z - 0.9 t + 1.4 sin(0.8 x + t))`, `v = 1 - |a b|`, result `0.3 + 2.6 v^4` (`v^2` squared twice).
- **Instructions:** four `sin` calls (the deterministic `core::math::trig::sin`), two squarings; no table.
- **Cost:** `O(1)`, 4 sines a lit lake-bed point; no memory.
- **Why this and not another:** `not documented` (the function is "a repeating, moving pattern of bright lines", `pathlight_shade.axle:88`); the light under water of the newer path is in L-80.
- **Where:** `src/render/pathlight/pathlight_shade.axle:71-97,138-140`.
- **Docs:** `doc/handbook/render/10-water.md` (not verified for this function): `MISSING` as a derivation.

---

## Light of surfaces: sparse light, face cache, filter, shafts (`pathlight_sparse`, `pathlight_facecache`, `pathlight_filter`, `pathlight_shaft`, `pathlight_shade`)

### L-30. I want to shade only one pixel in `s x s` and give every other pixel a light that is right for its own surface
- **Means:** a pixel blends the light of the four samples round it bilinearly, but only those samples whose key equals its own; the weights are renormalised.
- **Mathematics:** `w_a = (1-tx)(1-ty)`, `w_b = tx(1-ty)`, `w_c = (1-tx)ty`, `w_d = tx ty`, `tx = (x & mask)/s`; `E = sum_{i in M} w_i E_i / sum_{i in M} w_i` where `M` is the set of the four with `key_i == key`; not `ok` when the
  weight sum `<= 1e-4` or the key is `SPARSE_NO_KEY = -1`. Why it is right: a trilinear light restricted to a plane is bilinear in its two coordinates, and a plane in perspective is nearly affine over a few pixels, so
  bilinear interpolation reproduces it to first order (handbook 04 §2.1; error table §2.4).
- **Instructions:** the stride is a power of two held as `shift` and `mask`: "a division there was four divisions a pixel" (`pathlight_sparse.axle:103-104`); the last block reads its own sample twice
  (`corners` clamps `gx1/gy1`); `light` and `fog` are stored apart so the pixel's albedo multiplies only the light: `radiance = albedo * light + fog`.
- **Cost:** `S = P/s^2` samples shaded and `P` blends of 4 (`O(S + P)`). Memory per sample: light 12 B + fog 12 B + place 12 B + key 8 B = 44 B (derived: 2.5 MB at 1280 x 720, `s = 4`, 57 600 samples).
  Measured: ledger §1 rows 1-3: shading every pixel 350 ns a pixel; blending on its plane "fill 134 ms a frame, one thread".
- **Why this and not another:** ledger §1 rows 1-5 give each rejected form: one random sample per pixel (grain, ghosts); copy to the block (block-sized texture and edges); the plane only (leaves of one height flip light);
  the face only (held at block borders); all superseded by the face cache (L-33).
- **Where:** `src/render/pathlight/pathlight_sparse.axle:1-26,96-172,185-203,278-343`.
- **Docs:** `doc/handbook/render/04-sparse-light.md` §1.1, §2; `doc/handbook/concepts/01-smooth-and-sharp.md`.

### L-31. I want a leaf not to take the light of a leaf three trees away that lies in the same plane
- **Means:** each sample also stores where it is, and a pixel only takes samples of its key within a reach of its own place along every axis.
- **Mathematics:** `|p_i - at|_inf <= reach` (a box test: three comparisons pairs, `serves`); `reach` is the distance over which the caller's light is known smooth (one cell of a light volume).
- **Instructions:** one extra `Vec3` read a sample; the same blend as L-30 with the extra test; `putAt` stores the place.
- **Cost:** `O(S + P)` as L-30 with 6 compares a sample tested; the place array is 12 B a sample (included above).
- **Why this and not another:** the header explains it: near the eye all four samples are a hand's breadth apart and count, far away none does and "the caller lights the pixel itself" (`pathlight_sparse.axle:12-17`). Alternative (key by plane) is the failure.
- **Where:** `src/render/pathlight/pathlight_sparse.axle:205-257`.
- **Docs:** `doc/handbook/render/04-sparse-light.md` §1.1.

### L-32. I want a face too small for any sample to land on to be lit once and read by every pixel of it
- **Means:** a per-chunk memo keyed by face, stamped by frame, direct-mapped.
- **Mathematics:** none: plain arithmetic. Slot `(key ^ (key >> 13) ^ (key >> 29)) & mask`; an entry is valid when its stamp equals the frame stamp and its key matches; an empty slot is stamped `-1`.
- **Instructions:** nothing is cleared between frames (the stamp does the invalidation); a collision overwrites, which "costs a recomputation and never a wrong light".
- **Cost:** `O(1)` a lookup; 36 bytes a slot (key 8 + stamp 4 + 6 floats 24); one memo per chunk.
- **Why this and not another:** `not documented` beyond the comment (`pathlight_sparse.axle:356-362`).
- **Where:** `src/render/pathlight/pathlight_sparse.axle:356-411`.
- **Docs:** `doc/handbook/render/04-sparse-light.md` §1.0 (not verified in detail).

### L-33. I want the light of a surface kept where the surface is, so shadow edges do not crawl when the camera turns
- **Means:** the face cache keeps the light of a face (a patch named by a 64-bit key) at nine points; a pixel reads it at its own `(u, v)`; an entry is good for one epoch.
- **Mathematics:** nine points `(i/2, j/2)`, `i, j in 0..2`, because a light volume blended between cell centres has a slope break at the middle of every cell: the corners and middle of a face are exactly where
  its light changes slope (`pathlight_facecache.axle:9-14`). Read: `q = (2u, 2v)`, pick the quarter, bilinear inside it: continuous over the face and equal to the stored light at the nine points
  (a light linear over the face, or with a kink at its middle, is returned exactly: handbook 11 §3.1). A face that covers fewer than 8 pixels (`t * pixel * 8 >= 1`) is kept flat, one light (handbook 11 §3.2).
- **Instructions:** `faceMix` splits `fu >= 1` into cell index and fraction with two compares and clamps; weights `wa..wd` once; one load of 12 floats; slot `((key ^ key>>17 ^ key>>31 ^ key>>47) * 40503) & mask` (direct mapped).
- **Cost:** read `O(1)`, 12 float loads; a miss costs 9 shadings (or 1); `O(F E)` faces times changes of light rather than `O(S)` a frame (ledger §1). Memory 124 bytes a face (8 key + 8 stamp + 27 x 4); 131 072 faces = 16.3 MB, plus
  360 chunk batches of 256 faces = 11.4 MB (doc 11 §6). Measured (12 workers, 1280 x 720, head turning): ground, clock stopped 32 -> 24 ms; trees at 16:00 38 -> 24 ms; walking under a running clock median 31-58 -> 25-29 ms (doc 11 §6;
  ledger §1 row 6).
- **Why this and not another:** ledger §1 rows 3-5: three ways with samples on a plane or face "equal to 3, no" (light flipped between leaves, stairs in shadows, hidden centres lit); row 6 kept.
- **Where:** `src/render/pathlight/pathlight_facecache.axle:1-67,69-126,212-268`.
- **Docs:** `doc/handbook/render/11-face-cache.md` §3; `doc/handbook/concepts/04-complexity-ledger.md` §1.

### L-34. I want a cache that is never seen half written, however many threads draw
- **Means:** the shared cache is read by every thread and written by none while a picture is drawn; each chunk computes misses into its own batch; between two stages one thread publishes the batches.
- **Mathematics:** none: plain arithmetic. Two chunks that computed the same face computed the same numbers, so the order of publication does not matter.
- **Instructions:** `LumenFaceBatch.begin` queues a slot once (`queued[s]`, `pending[]`); `drainInto` calls `cache.take`; `take` refuses to replace a lattice entry (stamp `epoch*2+1`) by a flat one of the same face and epoch
  (`self.stamps[to] == stamp + 1 && (stamp & 1) == 0`).
- **Cost:** publish `O(new faces)` serial per stage (ledger §7 row 4: "deterministic; `O(new faces)` serial a stage"); a batch slot costs 124 B + 4 B pending + 1 B queued.
- **Why this and not another:** ledger §7 row 3 "a cache written by every thread as it goes: data race: no".
- **Where:** `src/render/pathlight/pathlight_facecache.axle:19-24,129-209,244-267`.
- **Docs:** `doc/handbook/render/11-face-cache.md` §4; `doc/handbook/concepts/02-determinism.md` §2.3.

### L-35. I want a light that drifts all the time to be followed a few faces a frame, not all at once
- **Means:** each face has its own epoch `faceStagger(key, base, phase, spread)` so that a drifting light re-lights one face in `spread` a step.
- **Mathematics:** `turn = (key ^ key>>16 ^ key>>29 ^ key>>42) & (spread - 1)`; `epoch = base * 2^32 + (phase + turn)/spread`; each face changes epoch once every `spread` steps and one face in `spread` does at any step
  (`spread` a power of two, at most 1024). A 64-bit epoch so a game left running never revisits one; the stamp is `epoch * 2 + full` so `epoch * 2` overflows `i64` once `base >= 2^30` (UNVERIFIED that any caller reaches it).
- **Instructions:** an integer hash of the key, one mask, one integer division by `spread` (a power of two, `O(1)`).
- **Cost:** `O(1)` per face request; the amortised relighting is `1/spread` of the visible faces a step. Measured (doc 11 §3.3): 4000 keys: between 125 and 500 faces a step, 250 expected for `spread = 16`;
  p99 of a walk under a running clock 55-83 ms against 35-46 ms staggered.
- **Why this and not another:** doc 11 §3.3: lighting all of them in one frame "was a slow frame every time it happened".
- **Where:** `src/render/pathlight/pathlight_facecache.axle:47-61,114-126`.
- **Docs:** `doc/handbook/render/11-face-cache.md` §3.3.

### L-36. I want the noisy light of a pixel with few samples cleaned without blurring across edges
- **Means:** an edge-avoiding a-trous filter: three rounds of a 3 x 3 kernel at strides 1, 2, 4, each neighbour weighted by its distance to the centre in units of what the centre allows.
- **Mathematics:** kernel centre 4, axis 2, diagonal 1; a neighbour counts only if same surface id and `|pos_j - pos_i|^2 < reach^2`, `reach = (0.012 d_eye + 0.12) * stride`; weight
  `w = kernel / (1 + 2 (r^2 + chroma^2))` with `r = (Y_q - Y_c)/sigma`, `chroma = |q - c|/(0.35 (Y_c + 0.1))`; `sigma = 0.6 (Y_c + 0.1)` when the history holds fewer than 4 samples, else
  `4 sqrt(max(m2 - m1^2, 0)) + 0.02` (the pixel's own variance from its first and second moments); pixels with 24 or more samples or `sid < 0` (sky, water, mirrors) return unchanged.
  The result is `sum / weight`. Three rounds of a 3 x 3 kernel at doubled strides reach a 15-pixel span (a-trous: a wide kernel for the price of three small ones, `pathlight_filter.axle:1-6`).
- **Instructions:** `invSigma` computed once per pixel (`1/tolerance`) and multiplied; the falloff `1/(1 + 2 x^2)` replaces an exponential ("no exponential needed"); the surface-id test is an integer compare first, then the position test.
- **Cost:** per pixel at most `3 rounds x 8 neighbours` weighted reads; `O(P)`; no memory beyond the `mom` and `cnt` history planes (2 + 1 floats a pixel). Measured: not given for the filter.
- **Why this and not another:** `not documented` here; the ledger has no row for the filter. (The settings default `denoise = false`, `pathlight_settings.axle:104`.)
- **Where:** `src/render/pathlight/pathlight_filter.axle:12-46,107-178`.
- **Docs:** `doc/handbook/render/07-accumulation.md` mentions the temporal history; the a-trous filter itself is `MISSING` as a chapter.

### L-37. I want light shafts that follow the sky's silhouette through gaps in leaves, with no random pattern in the picture
- **Means:** average the open sky over `S x S` blocks, then for each block march 24 steps toward the sun's place in the picture, reading the averaged sky bilinearly, with a smooth window at the border and a glare falloff.
- **Mathematics:** `p` the block's middle, `q` the sun's place; march a share `sigma = min(0.92, 0.55 max(W,H)/|q - p|)` of the way; `x_k = p + (q - p) sigma (k + 1/2)/24`; weight `0.93^k`;
  window `smoothstep(0, 0.12 min(W,H), distance to border)`; `march = (sky/max(seen, 0.35 total)) / (1 + (|q-p|/(0.5 max(W,H)))^2)`.
  Gain `= sunIrr * 0.1 * saturate(8 sunY) * (1 - 0.94 smoothstep(0.15, 0.5, sunY)) * open`; air share `smoothstep(3, 40, distance)`.
- **Instructions:** the window is answered `1.0` without its division where `nearest >= margin` ("the same bits for most of the 24 steps of a march"); `air` returns 1 without a root for `d^2 >= 40^2`;
  steps are incremental adds (`sx += stepX`) rather than multiplied; the clamp to the block grid is `shaftUpTo`.
- **Cost:** per block `O(24)` steps, `P/64` blocks at `S = 8` (one march for 64 pixels) read back bilinearly: handbook 01 §5.3. `skyShare` is `O(P)` reads of the sid plane (one compare each). Memory `P/64` floats for the share plane plus `P/64` for the marches.
  Measured: shafts + resolve 27.3 -> 21.9 ms a frame with the two exact shortcuts (ledger §4 row "dusk/lumen per-pixel march", 640 x 360, one thread, bit-identical); 27 -> 5 ms for the block march against the jittered per-pixel march (ledger §4 rows 1-3).
- **Why this and not another:** ledger §4: a march a pixel `24 P`, no; a 2 x 2 jittered march + history 9.3 -> 2.5 ms "not deterministic, no"; the 8 x 8 block march over the averaged sky "no random number, no history": yes.
- **Where:** `src/render/pathlight/pathlight_shaft.axle:19-57,138-215,221-261`.
- **Docs:** `doc/handbook/render/01-frame.md` §5; `doc/handbook/render/13-dusk.md` §3.4.

### L-38. I want a per-pixel jittered shaft march whose pattern does not alias into columns
- **Means:** each frame jitters the start of the march and the offset of its steps from a hash of the pixel and the frame; the frame averages frames.
- **Mathematics:** `(jx, jy, offset) = lnUnit(x, y, frame, 1..3)`, start `p = pixel + 1/2 + (j - 1/2) 2 * 3` pixels, step fraction `(k + offset)/24`; the same weights as L-37; frames are blended with `keep(fresh, sameCam)`: 0 on a fresh frame,
  0.88 with a still camera, 0.65 otherwise.
- **Instructions:** three hashes a pixel; the window/air shortcuts of L-37.
- **Cost:** `O(24)` a marched pixel; the history keeps an extra plane (not in this file).
- **Why this and not another:** the block march of L-37 replaced it in the dusk/lumen picture where the averaged sky needs no jitter (handbook 01 §5.1: "over the averaged sky they do not [alias], so the march draws no random number").
  The header of `pathlight_shaft.axle` still describes only the jittered design (Doubts).
- **Where:** `src/render/pathlight/pathlight_shaft.axle:92-131,264-272`.
- **Docs:** `doc/handbook/render/01-frame.md` §5.1.

### L-39. I want the direct and ambient light of a point as separate terms I can show and sum
- **Means:** `lumenShadeCorePrepared` returns `LumenLit {direct, ambient, emitted}`: the sun and the moon through their baked soft shadows and the cloud deck, the dome's SH9 through baked sky access and the bounce tint, the specular of a traced or prefiltered mirror, the flooded block light, and emission.
- **Mathematics:** `direct = (diffuse + specular) * light.color * irradiance * baked * cloudShade`; `ambient = diffuse * dome.irradiance(n) * (0.35 + 0.65 access) * sky * tint + specAlbedo * specIn + diffuse * block * 0.3`;
  `specIn = mirror.radiance` if traced, else `prefiltered(reflect, rough) * sky * access` (the lookup is skipped when traced). A body below `-0.04` of horizon or dimmer than `1e-5` is not shaded at all.
- **Instructions:** `lumenPrepare` (split-sum terms at `N.V`) is computed once and can be passed again for a caller's lamps; the moon is only shaded when `night > 0.05`.
- **Cost:** `O(1)` a shaded point: two body evaluations (BRDF + cloud cover noise each), one SH9 evaluation, one sky lookup; no memory.
- **Why this and not another:** `not documented` beyond "nothing here is left to chance, which is what keeps a picture of a still world still" (`pathlight_shade.axle:3`); deterministic baked shadows instead of per-frame shadow rays.
- **Where:** `src/render/pathlight/pathlight_shade.axle:31-47,66-69,112-257`.
- **Docs:** `doc/handbook/render/05-shading.md` §3.

### L-40. I want integer noise that is the same on every run and every thread
- **Means:** a SplitMix64-finalised hash of integer lattice coordinates; no libm, no wall clock, no iteration order.
- **Mathematics:** `h = x*73856093 xor y*19349663 xor z*83492791 xor seed*2654435761` (as `i64`), `lnHash = hashMix(h) >>> 40` (24 bits), `lnUnit = lnHash * 2^-24` in `[0, 1)`. The constants are the classic spatial-hash primes; the quality of the mix is the finaliser's.
- **Instructions:** three multiplies, three xors, the finaliser, a shift and a convert; no table; `lnFloor` is a convert and a compare.
- **Cost:** `O(1)`, a few ns a hash (UNVERIFIED: no number in the files); no memory.
- **Why this and not another:** `doc/handbook/concepts/02-determinism.md` §2.1 describes the policy (hash not generator state); the comparison of hashes is `not documented`.
- **Where:** `src/render/pathlight/pathlight_noise.axle:10-33`, `src/core/field/lux_noise.axle:20-29`.
- **Docs:** `doc/handbook/concepts/02-determinism.md` §2.1.

### L-41. I want smooth noise on the ground plane, and an `fbm` with its octaves cut off beyond what a reader can see
- **Means:** value noise with a cubic fade, summed over octaves; the soft variant replaces octaves finer than the reader's footprint by their mean.
- **Mathematics:** `lnFade(t) = t^2 (3 - 2t)`; value `lerp(lerp(a, b, fx), lerp(c, d, fx), fz)`; fbm `sum 0.5^o v(x 2.03^o)/sum 0.5^o` (lacunarity `2.03`, not 2, so lattices never line up); `lnFbm2Soft` keep weight `saturate(wave/finest - 1)`.
- **Instructions:** one hash per corner (4 a lookup per octave); the soft variant skips the lookup when `keep <= 0`.
- **Cost:** `O(octaves)` lookups of 4 hashes each; no memory.
- **Why this and not another:** `not documented` for value noise over Perlin/simplex; the 2.03 lacunarity is explained in `lux_field.axle:38`.
- **Where:** `src/render/pathlight/pathlight_noise.axle:35-101`.
- **Docs:** `doc/handbook/render/06-sky.md` §3.1 (the soft variant).

### L-42. I want a camera ray per pixel with no trigonometry in the loop
- **Means:** `aim` rebuilds the basis (forward, right, up, half field of view) once a frame; `ray(u, v)` is a handful of multiplies and a normalisation.
- **Mathematics:** `fwd = (sin yaw cos pitch, sin pitch, -cos yaw cos pitch)`, `right = (cos yaw, 0, sin yaw)`, `up = right x fwd`, `halfH = tan(fov/2)`; `ray = normalize(fwd + right (2u - 1) aspect halfH + up (1 - 2v) halfH)`. `project` inverts it.
- **Instructions:** pitch is clamped `0.01` rad short of the poles so the basis never degenerates; `project` returns `z = -1` for a point behind `0.01` along the axis.
- **Cost:** `aim` `O(1)` a frame; `ray` 9 multiplies, a sqrt and a division; no memory.
- **Why this and not another:** hot-loop rule R2; `not documented` otherwise.
- **Where:** `src/render/pathlight/pathlight_camera.axle:58-72,98-117`.
- **Docs:** `doc/handbook/standards/01-hot-loop-rules.md` R2.

---

## Lux: keys, caches, layers, scheduler, governor (`src/render/lux/graph`, `lux/simd`)

### L-43. I want to know whether a cached light computation is stale without comparing floats or hashing
- **Means:** a cache is keyed on six integers (`LuxKey`: world epoch, sun step, camera cell, timecycle epoch, settings epoch, frame); a layer names the parts it depends on with a bit mask.
- **Mathematics:** none: plain arithmetic. `differsIn(other, mask)` is true iff some masked integer differs; `changes(other)` returns the mask of the inputs that differ. Bits: world 1, sun 2, camera 4, timecycle 8, settings 16,
  frame 32, all 63.
- **Instructions:** at most six `i64` compares guarded by mask tests; no float, no hash, so "two keys are equal exactly when their inputs are, the comparison costs six loads" (`lux_key.axle:8-10`).
- **Cost:** `O(1)`, 48 bytes a key (six `i64`); one key stored per layer and per cache generation.
- **Why this and not another:** `lux_key.axle:8-11`: integers only, because they compare the same on every machine and thread count; continuous inputs enter through steps and cells (L-44). Handbook 12 §2 explains the hand-written rules this replaces.
- **Where:** `src/render/lux/graph/lux_key.axle:13-97`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §2, §3.1.

### L-44. I want a cache made at one sun position to stay valid until the next, and the camera to re-centre a cache only when it crosses a cell
- **Means:** continuous inputs are quantised into steps: the sun into 1440 a day, the camera into 16 m cells.
- **Mathematics:** `sunStep = floor(dayTime * 1440)` (0.25 degrees of turn, one minute of the day); `sunBlend = dayTime * 1440 - sunStep in [0, 1)`, the weight of the next generation; `cameraCell`: `floor(eye / 16)` per axis, masked to 21 bits
  and packed `x | y << 21 | z << 42` (range +-1 048 575 cells, 16 000 km). `luxFloorI64` is a convert and a compare.
- **Instructions:** one f64 multiply and floor a sun step; three f64 divisions by the constant 16 (a power of two: exact) a camera cell.
- **Cost:** `O(1)` a frame; `LuxView` is a copied struct of about 124 bytes (derived from its fields).
- **Why this and not another:** comment `lux_view.axle:4-11`: a continuous float would force a refresh every frame, and the step lets a reader blend two generations instead of popping. The view is a struct copied whole "so nothing can change it behind a worker's back".
- **Where:** `src/render/lux/graph/lux_view.axle:23-30,74-113`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §3.2-3.3.

### L-45. I want a cache that is never seen half written while a heavy refresh takes several frames
- **Means:** two copies of the data; readers see the front one, the refresh writes the back one, `publish` swaps them on the main thread between two frames.
- **Mathematics:** none: plain arithmetic. A version counter rises by one per publication; each generation remembers the key it was made from.
- **Instructions:** `read()` and `write()` return one of two arrays by the `front` flag; `carry()` copies front to back before a partial refresh; the data is planar (a plane a channel, see `lux_simd`).
- **Cost:** memory `2 (planes * size + 1)` floats; `publish` is `O(1)` (one integer flip); `carry` `O(planes * size)` only for a refresh that rewrites part of the cache.
- **Why this and not another:** `lux_cache.axle:1-9`: otherwise "a pixel would mix two suns, or two worlds, and the picture would tear for a frame". The alternative of locking is not considered in the files: `not documented`.
- **Where:** `src/render/lux/graph/lux_cache.axle:19-102` (`read` 43-48, `write` 51-56, `carry` 74-81, `publish` 87-91).
- **Docs:** `doc/handbook/render/12-lux-layers.md` §4, §5.

### L-46. I want a heavy cache to cost a fixed share of each frame instead of a hitch
- **Means:** a layer declares `slices`; its refresh runs one slice a frame and is published whole after the last one; the previous generation stays visible meanwhile.
- **Mathematics:** none: plain arithmetic. `endFrame` advances the slice counter and, when `next >= slices`, ends the refresh and publishes (`version += 1`, swap flag).
- **Instructions:** a layer in the middle of a refresh does its next slice whatever else changed ("a refresh always finishes, so a cache keyed on something that changes every frame still gets published").
- **Cost:** per frame `O(runs)` integer work; a sliced refresh of total cost `C` costs `C/slices` a frame; the front copy keeps the old generation (L-45).
- **Why this and not another:** handbook 12 §2 names a budgeted surface cache as the model; the complexity ledger has no row for it. No measurement: `UNVERIFIED`.
- **Where:** `src/render/lux/graph/lux_scheduler.axle:111-125,163-189`; `src/render/lux/graph/lux_layer.axle:1-17,34-52`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §3.1.

### L-47. I want a layer to run only when something it reads has changed
- **Means:** a layer is stale if it never ran, if the frame's key differs from its last refresh's key in an input it declared, if the sum of the versions of the layers feeding it changed, or if its period elapsed.
- **Mathematics:** `stamp(l) = sum over q in F(l) of version(q)`; versions only grow, so the sum changes exactly when one of them does. `stale = !ran || key.differsIn(made, inputs) || stamp != seen || (every > 0 && idle + 1 >= every)`.
- **Instructions:** one loop over the layer's feeds (a flat `Vec<i32>` range), integer additions; a layer done in one slice raises its version when scheduled so later layers of the same frame see it as new.
- **Cost:** `plan` is `O(L + sum of feeds)` integer operations a frame (handbook 12 §5; the code is at `lux_scheduler.axle:94-105,163-211`); the scheduler keeps about a dozen parallel vectors of `L` words.
- **Why this and not another:** handbook 12 §2: each hand-written invalidation rule of the earlier pictures led to faults that "were two of those rules disagreeing"; the key approach states them once.
- **Where:** `src/render/lux/graph/lux_scheduler.axle:94-105,163-211`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §3.1.

### L-48. I want a layer that reads last frame's result (a history) without forcing an order
- **Means:** two kinds of read: `reads` (this frame's result, creates an ordering edge) and `readsPrevious` (a declared cache as the previous frame left it, no ordering).
- **Mathematics:** none: plain arithmetic. Only an imported (cache) resource can be read this way; otherwise a `WrongKind` issue is recorded at `compile`.
- **Instructions:** `readsPrevious` appends to two parallel vectors; `layerReads` and `feedsLiveLayer` consult both the render graph's edges and these lists.
- **Cost:** `O(1)` per declaration; compile cost in L-49.
- **Why this and not another:** `lux_graph.axle:9-13`: "so the shading can read last frame's history at the start of the frame while the temporal layer rewrites it at the end".
- **Where:** `src/render/lux/graph/lux_graph.axle:9-13,96-131,299-313`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §2, §4.

### L-49. I want layers nobody needs not to run, and to know which layers feed which
- **Means:** liveness by a fixed point from the frame's declared outputs, then per-layer feed lists, both computed once at `compile`.
- **Mathematics:** a layer is live if it writes an output or a buffer some live layer reads (this frame's or the previous one's); iterated until nothing changes, at most once per layer. A cache no live layer reads does not keep its writer alive.
  Ordering and cycle detection are the render graph's (Kahn, lowest id first, handbook 12 §4).
- **Instructions:** nested scans over the edge list (`writesOutput`, `feedsLiveLayer`, `readsFrom`, `layerReads`) with `Vec` reads; fine for tens of layers compiled once.
- **Cost:** the file says "quadratic in the edges" (`lux_graph.axle:28-29`); handbook 12 §5 says `O(L^2 E)`. Counting the loops of `findLive` -> `feedsLiveLayer` -> `layerReads` (edges x layers x edges per pass, up to `L` passes), the bound is higher than either text:
  about `O(L^3 E^2)` in the worst case (derived from the loop nest, not measured: UNVERIFIED; irrelevant for tens of layers, see Doubts). Memory `O(L + feeds)`.
- **Why this and not another:** `not documented`; the file justifies the simple scans by size: "a frame has tens of layers and is compiled once, not every frame".
- **Where:** `src/render/lux/graph/lux_graph.axle:15-29,137-168,225-313`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §4-5.

### L-50. I want consecutive screen layers to run in one walk over tiles so the pixels stay in the processor's cache
- **Means:** live screen layers of one scale form a fused group; a layer that reads a group buffer around a pixel starts a new group; groups run tile by tile (`64 x 16` pixels).
- **Mathematics:** none: plain arithmetic. A tile is 1 024 pixels; with about eight `f32` planes a lit pixel carries (depth, normal, albedo, light) that is about 32 KB, inside the 48 KB first-level data cache of the reference machine (Zen 5)
  (`lux_tiles.axle:1-12`). A row of 64 `f32` is four 64-byte cache lines and eight `f32x8` groups.
- **Instructions:** `findGroups` walks the ordered live layers once; `readsGroupAround` checks edges whose reach is not 0 against the group's writers; `LuxTiles.tile(i)` clips the last tile row and column to the picture.
- **Cost:** `O(L)` groups a frame; memory 0 beyond the buffers. Measured: not given (the 48 KB claim is the file's reasoning about the cache, not a measurement: UNVERIFIED).
- **Why this and not another:** the file's reason is cache locality (tiles wide and short because rows are contiguous). The alternative of one pass per layer is implied, `not documented`.
- **Where:** `src/render/lux/graph/lux_graph.axle:325-364`, `src/render/lux/graph/lux_tiles.axle:14-17,49-77`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §4.

### L-51. I want the frame to stay inside its time by choosing the resolution the picture is computed at, without hunting
- **Means:** a governor measures frame nanoseconds and moves the computed scale by 1/16, quick to fall and slow to rise, with a predicted cost for the next step and a patience that doubles on hunting.
- **Mathematics:** target `T = 16 666 667 ns` (60 Hz, `LUX_FRAME_60`). Fall: 3 frames in a row with `t > 0.95 T` lowers the scale by `1/16`. Rise: after `patience` frames in a row whose predicted cost at the next step stays under 85 % of `T`.
  Prediction `(nanos - scaled) + scaled (next/now)^2` (cost grows with pixels, so with scale squared; `scaled` is the part that grows, a display at a fixed output size does not). Patience starts at 30, doubles after a fall right after a rise (the sign of
  hunting) up to 480. The floor is held above 1/16 so the prediction never divides by a zero scale.
- **Instructions:** all integer/f64 compares per frame; `holdScale` fixes the scale and disables the governor.
- **Cost:** `O(1)` a frame; the scale is the lever on `O(P)`: a step of 1/16 changes the pixel count by about 12 % near scale 1 (`1 - (15/16)^2`, derived).
- **Why this and not another:** `lux_budget.axle:8-12` records the rejected rule: "rising on 'under 75 %' alone hunted on the first try: 560 x 320 cost 72 %, 640 x 368 cost 97 %, and the picture restarted every second". Taking all of the frame as growing "kept an upscaled
  1080p picture at its floor of 384 x 208, where 9 of its 13 ms were the output's own" (`lux_budget.axle:83-86`). The governor reads wall-clock time, so a reproducible run holds the scale (determinism cost, `lux_budget.axle:14-16`).
- **Where:** `src/render/lux/graph/lux_budget.axle:20-33,81-124`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §3.4; `doc/handbook/render/13-dusk.md` §3.9 (which still says "up after 30 frames below 75 %": Doubts).

### L-52. I want each layer's measured cost beside the cost it declared
- **Means:** an exponential running mean per layer of weight 1/8, about the last eight frames.
- **Mathematics:** `mean' = mean + (now - mean) / 8`; the first measurement seeds the mean (`old == 0`).
- **Instructions:** one `f64` multiply-add per recorded layer per frame.
- **Cost:** `O(1)` a record; `L` doubles of state.
- **Why this and not another:** `not documented`.
- **Where:** `src/render/lux/graph/lux_budget.axle:33,61-69`.
- **Docs:** `MISSING` for the meter (handbook 12 §3.4 describes the governor and `endFrameSplit`, not the running mean).

### L-53. I want the computed picture's sides to be multiples of 16, and a start size that holds the frame rate
- **Means:** the shown size is the window rounded down to 16; the computed size is each side the nearest multiple of 16 of `shown * scale`; the start scale holds about a chosen pixel count.
- **Mathematics:** `shown = max(16, floor(n/16) 16)`; `computed = max(1, floor((x + 8)/16)) * 16` where `x = shown * scale`; `startScale = min(1, sqrt(pixels/(shown.w shown.h)))`. The pixel count a start uses is the caller's (handbook 13 §3.9 says about 640 x 360).
- **Instructions:** integer division by the constant 16, a square root once.
- **Cost:** `O(1)`.
- **Why this and not another:** the stages want multiples of 16 (`pathlight_post.axle:201`); alternative sizes not documented.
- **Where:** `src/render/lux/graph/lux_budget.axle:172-197`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §3.4; `doc/handbook/render/13-dusk.md` §3.9.

### L-54. I want eight pixels at a time, with the compiler doing the easy parts and my lanes doing the rest
- **Means:** planar (one plane per channel) `f32[]` buffers, so a plain loop is vectorised by the compiler; hand-written `f32x8` lanes only where it will not: a call (`exp`), a branch-free select, a long body.
- **Mathematics:** none: plain arithmetic. `luxMin8/Max8` are `select(a < b, a, b)`; `luxClamp8` clamps with two selects, and a NaN lane comes out as `hi`, never NaN.
- **Instructions:** never `.fma()` on a dispatched shape (a call through a start-up trampoline; 9 times slower: F11); write `a * b + c`, which LLVM contracts to `vfmadd`. A literal splat needs an `f32` binding first (`luxSplat`).
- **Cost:** measured on 2026-11-23 (Ryzen 9 9900X, one thread, 921 600 pixels): exposure + 3 x 3 matrix + `x/(1+x)` over planar buffers 0.32 ns/px, scalar-and-vectorised equal to the lane code; interleaved RGB stays scalar at 1.31 ns/px
  (`lux_simd.axle:1-9`; handbook 12 §5 says 0.29: Doubts).
- **Why this and not another:** `lux_simd.axle:3-9`: the layout is most of the gain; lanes by hand pay where the vectoriser stops.
- **Where:** `src/render/lux/simd/lux_simd.axle:1-19,44-67`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §5-6.

### L-55. I want `e^-x` for eight lanes of attenuation at once, fast and exact enough for fog and Beer-Lambert
- **Means:** `2^y` by splitting `y` into its rounded integer and a fraction in `[-1/2, 1/2]`; the integer goes into the exponent field, the fraction through a degree-6 polynomial; `e^x = 2^(x/ln 2)`.
- **Mathematics:** `e^x = 2^(x log2 e)`; `2^f` by the Taylor series of `e^(f ln 2)` to `f^6`: coefficients `0.693147, 0.240227, 0.0555041, 0.00961813, 0.00133336, 0.000154035`; truncation under `1.3e-7` relative on `|f| <= 0.5` (the file's figure; the next term at `|f| = 0.5` is about `1.2e-7`).
  Lanes below `-126` return 0, lanes above 0 return 1. Rounding without a float-to-int: adding `1.5 * 2^23` (`12582912.0`) leaves `round(y)` in the low mantissa bits, read back with `reinterpret` minus its own bits (`1262485504 = 0x4B400000`).
- **Instructions:** the integer `n` becomes the scale `f32x8.reinterpret((n + 127) << 23)`; Horner on six coefficients with `p * f + c` (contracted to FMA by the compiler); a select for the underflow lane.
- **Cost:** `O(1)` a lane; relative error under `2e-7` for `2^y`; for `e^x` the product `x/ln 2` rounded to `f32` adds `|x| 6e-8`: under `2e-6` down to `x = -20`, under `1e-5` down to -80 (`lux_simd.axle:91-98`).
  Measured: Beer-Lambert fog 14.0 ns/px with `lightExp` against 0.53 ns/px with `luxExpNeg8`, 26 times less (`lux_simd.axle:5-9`; handbook 12 §5 says 13.2 to 14.0).
- **Why this and not another:** the scalar `exp` call stops the vectoriser (`lux_simd.axle:5-9`); rejected: `.fma()` (3.77 ns/px, F11).
- **Where:** `src/render/lux/simd/lux_simd.axle:25-41,69-110`.
- **Docs:** `doc/handbook/render/12-lux-layers.md` §5-6.

---

## Water surface: spectrum, FFT, cascades, footprint (`src/render/lux/fluid`)

### L-56. I want waves of the whole sea, in every position at any time, with a transform instead of a sum over waves
- **Means:** build the surface in the frequency domain: one complex amplitude per wave vector; move each by the speed deep water gives it; bring it to the surface by an inverse FFT (Tessendorf, SIGGRAPH course 2001, as cited in `lux_ocean.axle:3`).
- **Mathematics:** `h(k, t) = h0(k) e^{i omega t} + conj(h0(-k)) e^{-i omega t}`, `omega = sqrt(g |k|)` (deep water), `g = 9.81`; the second term makes `h(-k) = conj(h(k))`, so the surface is real; slope `= IFFT(i k h)`. The
  mirror `-k` index is `((n - row) & (n-1), (n - col) & (n-1))` (the grid is periodic).
- **Instructions:** `cos(omega t)` and `sin(omega t)` once per cell per update; the slope field is written straight into the two arrays the FFT transforms (L-57, L-58).
- **Cost:** update `O(N^2)` trig + `O(N^2 log N)` butterflies a cascade: 3 cascades of `64 x 64`. Measured: 0.26 ms a frame, one thread (`lux_ocean.axle:48`; handbook 14 §5: 0.25 ms). Memory 7 arrays of `64^2` floats a cascade (344 064 B for three) + the gust table (65 536 B) = 0.4 MB (`lux_ocean.axle:48-49`).
- **Why this and not another:** the earlier water was "three fixed cosine swells plus one octave of value noise: visible stripes, the same on every patch" (handbook 14 §2). Direct summation of `N^2` waves at `N^2` points is `O(N^4)` against `O(N^2 log N)` (plain arithmetic).
- **Where:** `src/render/lux/fluid/lux_ocean.axle:1-49,161-262`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.1, §5.

### L-57. I want both slopes of the surface from a single inverse transform
- **Means:** pack the x and z slopes as the real and imaginary parts of one complex field `S = i k_x h + i (i k_z h)`.
- **Mathematics:** with `h = h_r + i h_i`: `S_r = -k_x h_i - k_z h_r`, `S_i = k_x h_r - k_z h_i`; because both `i k_x h` and `i k_z h` are Hermitian (the transform of each is real), `Re IFFT(S) = dh/dx` and `Im IFFT(S) = dh/dz`.
- **Instructions:** the two arrays `slopeX`/`slopeZ` are the real and imaginary parts handed to `LuxFft.grid(re, im, inverse)` in place.
- **Cost:** one `N x N` transform instead of two: half the butterflies (24 576 for `N = 64`: `2 N lines x log2 N passes x N/2 butterflies`).
- **Why this and not another:** `lux_ocean.axle:19`: "Only the slopes are computed: they are what tilts the normal"; the height itself is never needed.
- **Where:** `src/render/lux/fluid/lux_ocean.axle:238-262`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.1, §3.7.

### L-58. I want a fast transform that gives the same bits on every machine
- **Means:** radix-2 Cooley-Tukey, in place, rows then columns, with twiddles and the bit-reversal table built once with the deterministic `cosD/sinD`.
- **Mathematics:** `X[k] = sum_j x[j] e^{s 2 pi i j k/n}`, `s = -1` forward, `+1` inverse, no `1/n` (the ocean's amplitudes carry their scale); `log2 n` passes of `n/2` butterflies after the bit reversal: `O(n log n)` a line, `O(n^2 log n)` a grid instead
  of the `O(n^3)` of the plain sum (`lux_fft.axle:7-14`).
- **Instructions:** twiddle tables of `n/2 + 1` entries indexed `m * stride` with `stride = n/span`; structure-of-arrays so a pass reads contiguous floats; each line is copied to a scratch row (`rowR/rowI`) and back (a column would otherwise stride by `n`); the inverse flips the sign of the sine.
- **Cost:** `N = 64`: `2 * 64 lines * 6 passes * 32 butterflies = 24 576` butterflies a grid (handbook 14 §3.7), 4 multiplies and 6 additions each; memory `2 (n/2 + 1)` floats of twiddles, `n` ints of bit reversal, `2 n` floats of scratch.
- **Why this and not another:** the plain sum is `O(n^3)`; the file gives no timing of the transform alone: `not documented`.
- **Where:** `src/render/lux/fluid/lux_fft.axle:1-138`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.7.

### L-59. I want a sea that matches a wind's strength and the short fetch of a bay, not a swell of an open ocean
- **Means:** the JONSWAP spectrum (fetch-limited) turned into a spectrum over wave vectors.
- **Mathematics:** `S(omega) = omega^-5 exp(-5/4 (omega_p/omega)^4) gamma^r`, `r = exp(-(omega - omega_p)^2 / (2 sigma^2 omega_p^2))`, `gamma = 3.3`, `sigma = 0.07` for `omega <= omega_p` and `0.09` above; peak `omega_p = 22 (g^2/(U F))^(1/3)`
  (wind `U` floored at 0.5 m/s, fetch `F` at 1 m); `P(k) = S(omega) (d omega/dk) / k * |k_hat . w_hat|^p * exp(-(k l)^2)` with `d omega/dk = g/(2 omega)`, `p = 2` by default, `l = 0.08 m`; waves against the wind keep `against = 0.07` of `P`.
  `h0(k) = (xi_r + i xi_i) sqrt(P/2)`, `xi` standard Gaussian (L-62). For `U = 12 m/s, F = 300 m` the peak is 7.5 rad/s, a wave about 1.1 m (handbook 14 §3.2).
- **Instructions:** `exp` and `pow` through `lightExp2/lightLog2` (`luxoExp`, `luxoPow`), deterministic and libm-free; the constant in front of `S` is irrelevant because the amplitude is rescaled (L-60).
- **Cost:** `O(N^2)` per cascade at construction, once. Memory in L-56.
- **Why this and not another:** `lux_ocean.axle:21-26`: Phillips's spectrum describes a fully developed sea, where "a strong wind piles its energy into long swells; over a bay that turned a gale into a slow, smooth heave". Handbook 14 §6: "Phillips's spectrum with Cox-Munk scaling made a 12 m/s wind look calmer than 2 m/s over the bay".
- **Where:** `src/render/lux/fluid/lux_ocean.axle:71-75,103-122,448-477`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.2.

### L-60. I want the water's roughness to be physical, not a free knob
- **Means:** every cascade's amplitude is scaled by one common factor so the total mean-square slope equals Cox and Munk's value for the wind, times a shelter factor.
- **Mathematics:** Cox and Munk (1954): `sigma^2 = 0.003 + 0.00512 U`; `want = shelter * sigma^2` (shelter 0.6 by default, 1 on open sea); the unscaled expected slope variance of a cascade is `2 sum_k k^2 P(k)` ("both `h0(k)` and `conj(h0(-k))` feed `h(k, t)`: twice the sum");
  `factor = want / (raw_0 + raw_1 + raw_2)`, amplitudes times `sqrt(factor)` (it scales energy).
- **Instructions:** variance accumulated while the cascade is built (`raw += k^2 p`); one division, three `scale` calls; `meanSquareSlope()` reports the result.
- **Cost:** `O(N^2)` once; 8 bytes of variance a cascade.
- **Why this and not another:** `lux_ocean.axle:35-37`; the shelter is the bay's shorter fetch (handbook 14 §3.3). The value 0.6 is a tuning choice, `not documented`.
- **Where:** `src/render/lux/fluid/lux_ocean.axle:83-85,215-219,222-230,347-357`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.3.

### L-61. I want water waves with no visible repeat
- **Means:** three cascades of `64 x 64` grids of incommensurate sizes (97.3, 23.9, 6.1 m), each carrying its own band of wave numbers and each turned by its own angle (0, 31, 67 degrees); the finest band is modulated by a drifting gust field (L-63).
- **Mathematics:** bands `[0, 1)`, `[1, 4)`, `[4, inf)` rad/m, so each wave number belongs to exactly one grid and no energy is counted twice; periodic patterns repeat only at the least common multiple of their periods (Dupuy and Bruneton 2012, as cited in the file); sizes with no small common
  multiple. Turn: sample in the turned frame `lx = x cos + z sin`, `lz = z cos - x sin`, slopes turned back by the inverse rotation; the grid is built with the wind at `angle - turn`. Wrap by `& (n - 1)` (n a power of two).
- **Instructions:** one bilinear read per cascade (`sample`), the wrap is a mask; turn constants `0.5410521`, `1.1693706` rad.
- **Cost:** a sample is three turned bilinear reads + one gust read: 46 ns measured (handbook 14 §5); `O(1)` memory beyond L-56.
- **Why this and not another:** a single `L`-periodic grid "which the eye catches at once on open water" (`lux_ocean.axle:27-29`); one-octave fades between cascades left three visible bands (L-64).
- **Where:** `src/render/lux/fluid/lux_ocean.axle:27-33,64-70,88-92,161-208,264-294,321-345`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.4.

### L-62. I want standard Gaussian numbers for the amplitudes that are the same on every run
- **Means:** Box-Muller from two uniform draws of an explicit `Pcg32(seed, 54)`; one pair per grid cell, drawn for every cell (including those outside the band) so the stream does not depend on the band.
- **Mathematics:** `r = sqrt(-2 ln u)`, `a = r cos(2 pi v)`, `b = r sin(2 pi v)`, with `ln u = log2 u * ln 2` and `u` floored at `1e-7` (the log has no value at 0).
- **Instructions:** `lightLog2`, deterministic `cos/sin`; no libm.
- **Cost:** `O(N^2)` draws a cascade once.
- **Why this and not another:** determinism rule of `CLAUDE.md` ("random numbers from an explicit `Pcg32`"); the choice of Box-Muller over other normal generators is `not documented`.
- **Where:** `src/render/lux/fluid/lux_ocean.axle:192-216,479-494`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.1.

### L-63. I want a patchy, drifting rougher/calmer water (cat's-paws) without a noise evaluation a sample
- **Means:** the finest band is multiplied by a gust field baked once into a seamless `128 x 128` table of 8 m texels and read with one bilinear lookup.
- **Mathematics:** `g(x, z, t) = 1 + 1.1 (fbm(x', z') - 0.5)`, 3 octaves at 0.018 cycles a metre, `(x', z') = (x, z) - w_hat 0.35 U t`; range about `0.45..1.55`. Seamless by the classic blend `T(x, z) = f(x, z)(1-a)(1-b) + f(x-P, z) a (1-b) + f(x, z-P)(1-a) b + f(x-P, z-P) a b`,
  `a = x/P`, `b = z/P`, `P = 1024 m`; the values on opposite edges agree.
- **Instructions:** the table is read with an `& (n-1)` wrap; the bilinear is a `lerp` of a `lerp`.
- **Cost:** one bilinear read replaces a 3-octave noise evaluation (59 -> 46 ns a sample, handbook 14 §3.5, §6); table `128 x 128 x 4 B = 65 536 B`; the bake is 65 536 `lnFbm2` evaluations of 3 octaves (4 a cell, `lux_ocean.axle:529-532`; handbook 14 §5 says 16 384: Doubts).
- **Why this and not another:** the measured saving above; period 1 024 m is "three times the world" (`lux_ocean.axle:33`; the world's size is not in the file: UNVERIFIED).
- **Where:** `src/render/lux/fluid/lux_ocean.axle:94-101,433-440,515-558`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.5.

### L-64. I want distant water to stop sparkling without turning into a flat mirror
- **Means:** each cascade fades out smoothly when the pixel's footprint exceeds its grid spacing, and the slope variance it would have added is returned (`lost`) to widen the reflection instead of being dropped.
- **Mathematics:** keep `w = 1 - smoothstep(1, 4, f/Delta)`, `Delta = L/N`; `lost += (1 - w^2) sigma_c^2 gain^2`. A fade over two octaves, because the cascade sizes step by about four: each cascade starts to fade where the next coarser one is still whole, so together they fall off as one slope.
  The unresolved slopes are Gaussian with variance `lost` by the central limit theorem (Bruneton, Neyret and Holzschuch 2010, as cited), a Beckmann roughness `alpha^2 = lost`, perceptual roughness `lost^(1/4)`.
- **Instructions:** a cascade with `keep <= 0` is not read at all, "so far water costs less" (`luxoAdd`); `smoothstep` of a ratio.
- **Cost:** `O(1)` a sample, at most 3 bilinear reads + 1 gust read; fewer when faded.
- **Why this and not another:** handbook 14 §3.6.1: a one-octave fade left "three distinguishable bands of water with the distance", fixed by the two-octave fade; drawing the unresolved slopes at random per pixel and frame "left visible grain over all distant water" (withdrawn).
- **Where:** `src/render/lux/fluid/lux_ocean.axle:39-46,87-88,420-431,496-513,560-568`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.6, §3.6.1.

### L-65. I want a grazing view of water to filter the way a texture seen edge-on is filtered
- **Means:** anisotropic sampling: up to four taps along the long axis of the pixel's elliptical footprint, the cascades faded by the larger of the short axis and the spacing of the taps.
- **Mathematics:** `taps = clamp(floor(along/across), 1, 4)`; `spacing = along/taps`; `fade = max(across, spacing)`; tap `k` at offset `((k + 1/2)/taps - 1/2) along` along `(dirX, dirZ)`; the result is the mean of the taps (slopes and `lost`).
  Footprint: `across = t theta_px (1 + depth)`, `along = across / max(facing, 0.08)`, axis the view's direction projected on the water (L-76).
- **Instructions:** one tap is the common case (`taps == 1` returns the single sample); the offset per tap is affine in `k`.
- **Cost:** up to 4 samples (about 47 ns each) for grazing water, 1 from above (handbook 14 §3.6.2).
- **Why this and not another:** `lux_ocean.axle:380-386`: "a single sample of an ellipse 20 times longer than wide aliased the long waves along the view into a moire that slid across the water as the camera turned; one fade by the long axis flattened distant water into a mirror". The axis depends on the
  eye's position, not its orientation, so turning the camera does not move the filter (handbook 14 §3.6.2).
- **Where:** `src/render/lux/fluid/lux_ocean.axle:124-140,380-414`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.6.2 (§3.6 still describes the geometric-mean fade that this replaced: Doubts).

---

## Looks, fields and thin surfaces (`src/render/lux/look`, `src/core/field`)

### L-66. I want a surface to respond to fields of the world (colour, glow, tilt, roughness, bend) in a predictable order whatever order I declared them in
- **Means:** a look is a short stack of ops, each driven by a field of the world's tape; ops run in the order of their stage, and within a stage in the order added.
- **Mathematics:** stages: `Albedo` (colour times `ramp(field)`, products), `Normal` (slopes `strength * grad field` add), `Rough` (sums), `Emit` (adds `ramp(field)`), `Bend` (bends add). Products, sums and slope additions commute, so "where the physics makes ops commute" the
  declaration order does not matter (`lux_look.axle:11-14`). A ramp is three stops, linear between them, held beyond, times a strength.
- **Instructions:** `compile` flattens ops into integer/float arrays per look (`order`, `fKind`, `fField`, `fRamp`, `fStrength`, `fRamps`); `shade` walks a range and a `match` on the op code; a look never traces a ray (the program reads the surface, traces what it asks, combines), which "makes looks nest safely".
- **Cost:** `O(nodes + ops)` a hit; the portal (3 scrolls, 2 noises of 2 octaves warping a 3-octave noise, pixelated; emit and bend) 112 ns a hit, one thread (handbook 15 §5). Memory: 13 floats a ramp (`LUXL_RAMP`), 8 floats a node a worker.
- **Why this and not another:** `lux_look.axle:16-19` (no allocation, one `LuxSurface` per hit; no trait dispatch); handbook 15 §2.
- **Where:** `src/render/lux/look/lux_look.axle:1-22,125-173,326-350,489-519`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.5.

### L-67. I want, with a value noise, its exact slope at the price of a few multiplies, so a normal or a bend follows any composition of fields
- **Means:** forward differentiation: every node carries its gradient against the hit's two coordinates; value noise has a closed-form gradient.
- **Mathematics:** `n(x, y) = lerp(lerp(a, b, s(fx)), lerp(c, d, s(fx)), s(fy))` with `s(t) = t^2 (3 - 2t)`, `s'(t) = 6 t (1 - t)`; `dn/dx = s'(fx) ((b - a) + ((d - c) - (b - a)) s(fy))`, `dn/dy = s'(fy)(bottom - top)`. A scale multiplies the Jacobian `J`,
  a warp adds the warping fields' gradients, a noise turns its gradient into the hit's through `J^T`: `df/du = g_x J_00 + g_y J_10`, `df/dv = g_x J_01 + g_y J_11`; `add`, `mul`, `remap` follow the sum, product and scale rules. One octave's slope is at most `1.5` per lattice cell.
- **Instructions:** a node is 8 floats of a per-worker `f32[]` (`LUX_FIELD_SLOT`); a noise writes its value and gradient straight into the caller's registers ("a struct built per call is not kept in registers", F14); `evaluate` binds the tape arrays to locals first (R4); the normalisation `1/sum a_i` of a noise
  is computed once per node at `pack`, not per point.
- **Cost:** "the value plus a few multiplies"; a noise octave 4 hashes (handbook 15 §5); memory `LUX_FIELD_SLOT` floats a node a worker (a tape of 30 nodes is 960 bytes).
- **Why this and not another:** `lux_noise.axle:11`: "a gradient costs a few multiplies more than the value, not two more evaluations" (against finite differences). A node can only name earlier nodes, so evaluation in build order is always right and a shared node is evaluated once.
- **Where:** `src/core/field/lux_noise.axle:1-66`, `src/core/field/lux_field.axle:1-25,343-408,497-623`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.1-3.2.

### L-68. I want a composition of noises and warps never to alias, however far or oblique the view
- **Means:** each octave finer than the pixel's footprint is replaced by its mean, and a warp widens the footprint by a bound fixed at build time.
- **Mathematics:** octave of frequency `f` kept with `w = 1 - smoothstep(1, 4, fp f)` and replaced by `1/2` otherwise (the ocean's rule, L-64); a scale multiplies the footprint by `|k|`; a warp `p' = p + s g(p)` with `g` `L`-Lipschitz widens it by at most `s L fp0`
  (`|p'(x) - p'(y)| <= (1 + sL)|x - y|`); `L_fbm = L_p sum a_i f_i 1.5 / sum a_i`, `L_add = L_a + L_b`, `L_mul = L_a + L_b` (assuming both stay in `[0, 1]`). The exact bound of a warp by two fields is `sqrt(L_a^2 + L_b^2)`, up to `sqrt 2` less than the max the code uses,
  so "a strongly warped field [may] filter a little less than it should (kept as it is: the portal and the regress pins are tuned on it)" (`lux_field.axle:18-21`).
- **Instructions:** the bounds are numbers of the node (`lip`), computed in the builders, so the cost per hit is zero; the octave loop skips the noise lookup when `keep <= 0`.
- **Cost:** `O(octaves kept)` a noise; no memory per hit.
- **Why this and not another:** "as the water taught" (handbook 15 §3.3): same weights as the ocean. The widening by the larger of the two warping fields' bounds is a known loose spot (above).
- **Where:** `src/core/field/lux_field.axle:16-21,186-259,567-604,552-562`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.2-3.3.

### L-69. I want a scrolling field to keep its precision after hours without an f64 per point
- **Means:** each scroll's offset is computed once a frame in f64, wrapped by 4096 units, and added to the point as an f32.
- **Mathematics:** `offset = (v * seconds) mod 4096` computed in f64 (`luxfWrap`: `q = x/4096`, floor, subtract); an f32 clock's step is a quarter of a millisecond after an hour and grows (`lux_field.axle:22-24`); one jump every `4096/speed` seconds (over two hours at 0.5 a second).
- **Instructions:** `prepare(seconds)` loops over the nodes once a frame; `luxfScroll` is two adds and a copy of the Jacobian.
- **Cost:** `O(nodes)` a frame, `O(1)` a point; 2 floats an offset a node.
- **Why this and not another:** comment on the f32 clock above; no measured alternative.
- **Where:** `src/core/field/lux_field.axle:34-36,318-330,487-494,528-534`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.4.

### L-70. I want a hit to evaluate only the field nodes its look needs
- **Means:** `compile` marks, per look, the nodes reachable from its ops' fields by an iterative depth-first walk with a fixed stack, then lists them ascending (each after its children, because a node only names earlier ones).
- **Mathematics:** none: plain arithmetic. A node has up to three children (a warp's third child is kept in its last constant).
- **Instructions:** one `bool` mark array and one stack `3 N + 8` ints reused for every look; the stage order is made by five passes over the ops (`for stage of 0..5`).
- **Cost:** compile `O(looks * (N + ops * 5 + marked nodes))`, once; memory flat arrays only; `shade` is `O(listed nodes + ops)`.
- **Why this and not another:** `not documented`; the flat arrays serve "no `Vec` in the hot loop" (`lux_field.axle:119`).
- **Where:** `src/render/lux/look/lux_look.axle:254-320,430-453`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.1 ("a depth-first mark").

### L-71. I want a ray to pass through a thin perforated surface (a portal's sheet, a stained pane, a curtain of leaves) bent and tinted
- **Means:** no inside to trace: the ray goes on behind the surface along a bent direction, and the surface adds its emission.
- **Mathematics:** `d' = normalize(d + b_u u_hat + b_v v_hat)` with the look's `Bend` ops giving `(b_u, b_v)` in the face's two world axes; `L = tint * L_behind(d') + emit`. The face axes of an axis-aligned normal: `u = x` (or `z` when the normal is along `x`), `v = y` (or `z` on a horizontal face).
- **Instructions:** a normalisation (one sqrt and divisions) per crossing; `luxFaceAxes` is two compares.
- **Cost:** `O(1)` a crossing; no memory.
- **Why this and not another:** `lux_thin.axle:1-12`: a thin surface "has no inside worth tracing"; the program traces the onward ray so thin surfaces nest with any other surface.
- **Where:** `src/render/lux/look/lux_thin.axle:1-45`; interface flag `src/render/lux/look/lux_look.axle:59-78,217-223`.
- **Docs:** `doc/handbook/render/17-media-and-interfaces.md` §3.

---

## Media, boundaries and the view from inside (`lux_medium`, `lux_interface`, `lux_immersion`)

### L-72. I want light seen through water (or smoke, fog, ice) to fade with depth, colour by colour
- **Means:** Beer-Lambert transmittance per channel, `T(d) = exp(-sigma_t d)` with `sigma_t = sigma_a + sigma_s`, evaluated with the lane exponential.
- **Mathematics:** a ray crossing `d` metres sees `T(d) L_behind + G(d)` (L-73). Defaults (a clear bay): `sigma_a = (0.40, 0.07, 0.05)` /m (pure water's, Pope and Fry 1997, with some dissolved matter), `sigma_s = (0.05, 0.06, 0.07)` /m, so `sigma_t = (0.45, 0.13, 0.12)`:
  about eight metres to `1/e` in green and blue. A first choice of three times the scattering "left an eye under water seeing a flat wall of colour past four metres" (handbook 14 §3.8).
- **Instructions:** the three channels go into one `f32x8` (lanes 3-7 padded with the last channel) through `luxExpNeg8`; no allocation, no scalar `exp` call (`luxmExp`, `lux_medium.axle:135-143`).
- **Cost:** `O(1)` a segment: one lane exponential (the measured fog loop with the same exponential costs 0.53 ns/px, L-55), a 3-vector product; `d` is floored at 0. Memory: a medium is 7 floats.
- **Why this and not another:** handbook 14 §3.8: the walk used to multiply a fixed transmittance per water cell (0.45, 0.8, 0.92), so depth "graded in steps, one per block, and the shallows ended in a hard pale band"; now both terms are continuous in the distance.
- **Where:** `src/render/lux/medium/lux_medium.axle:30-40,92-96,135-143`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.8; `doc/handbook/render/17-media-and-interfaces.md` §3.

### L-73. I want the glow of deep water to settle exactly on the colour an artist chose, and the glow to rise smoothly with distance
- **Means:** single scattering with a calibrated source: `G(d) = (sigma_s/sigma_t)(1 - T(d)) J` with `J = deep sigma_t / sigma_s`.
- **Mathematics:** as `d -> infinity`, `T -> 0` and `G -> (sigma_s/sigma_t) J = deep`: a medium of no end shows exactly `deep`. Depth-dimmed source `J(depth) = J T(depth)` (the water above scatters less light the deeper the eye).
- **Instructions:** `luxMediumGlowKept(m, keep, light)` takes the transmittance already computed: "one exponential, not two" per segment; divisions guarded by `max(., 1e-6)`.
- **Cost:** `O(1)` a segment; 3 divisions guarded; no memory.
- **Why this and not another:** `lux_medium.axle:116-119`: the art-directed colour becomes a physical source. Alternative (a fixed fog colour with a distance ramp) is implied by "continuous in the distance"; no measurement.
- **Where:** `src/render/lux/medium/lux_medium.axle:98-133`; `src/render/lux/medium/lux_immersion.axle:81-84`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.8; `doc/handbook/render/17-media-and-interfaces.md` §3.

### L-74. I want a ray to bend entering water and to reflect totally when it cannot leave
- **Means:** Snell's law in vector form with the total-internal-reflection case, and Schlick's Fresnel at the cosine in the less dense medium.
- **Mathematics:** `eta = n1/n2`, `k = 1 - eta^2 (1 - cos^2 theta1)`; `k <= 0`: total internal reflection (`dir` = the mirror, Fresnel 1); else `t = eta i + (eta cos theta1 - sqrt k) n` (normalised) and Schlick `F = F0 + (1 - F0)(1 - cos)^5` with the incident cosine going in, the transmitted
  one coming out. `F0 = 0.0204 = ((1.333 - 1)/(1.333 + 1))^2` ("rounded as the renderers have always used it").
- **Instructions:** one sqrt, one normalisation, `(1 - c)^5` as `m2 m2 m`; the reflection `i - 2 (i . n) n` is built before the branch.
- **Cost:** `O(1)`: one `sqrt` for `cosT`, one normalisation (a `sqrt` and a division) and a Schlick of four multiplications; no memory.
- **Why this and not another:** Schlick here, the exact equations in L-75: the file says "Schlick's approximation, which this replaced" for the view's Fresnel only; this one keeps Schlick for the refraction (the choice is `not documented`).
- **Where:** `src/render/lux/medium/lux_medium.axle:24-28,54-90`.
- **Docs:** `doc/handbook/render/17-media-and-interfaces.md` §3.

### L-75. I want the Fresnel reflectance of water at grazing angles to be right where the whole picture of the water's edge lives
- **Means:** the exact Fresnel equations averaged over both polarisations, for the index of refraction that gives `f0` at normal incidence, instead of Schlick.
- **Mathematics:** `index = (1 + sqrt f0)/(1 - sqrt f0)` (inverse of `f0 = ((n - 1)/(n + 1))^2`, `f0` held to `[0, 0.98]`, 0.02 for water); `sin_t = sqrt(1 - cos_i^2)/index`; `cos_t = sqrt(1 - sin_t^2)`; `r_s = (cos_i - index cos_t)/(cos_i + index cos_t)`,
  `r_p = (cos_t - index cos_i)/(cos_t + index cos_i)`; `F = (r_s^2 + r_p^2)/2`; `cos_i` floored at 0.001. Schlick is 6 to 10 % too high at the grazing angles a camera at the water's edge sees: 0.769 against 0.722 at 3 degrees above the surface, 0.398 against 0.348 at 10 (`lux_interface.axle:150-155`).
- **Instructions:** 3 square roots and 4 divisions; the index depends only on `f0` and is not hoisted out of the pixel loop (a possible hoist, not made: `UNVERIFIED` as a cost).
- **Cost:** `O(1)` a water pixel.
- **Why this and not another:** Schlick rejected on the numbers above (`lux_interface.axle:150-155`). The header of the same file and handbook 17 §3 still say "Schlick's" (Doubts).
- **Where:** `src/render/lux/medium/lux_interface.axle:149-166`.
- **Docs:** `doc/handbook/render/17-media-and-interfaces.md` §3 (stale: shows the Schlick form).

### L-76. I want the patch of water a pixel covers, so the waves can be filtered by what that pixel can resolve
- **Means:** the footprint on a horizontal plane: an ellipse `across` wide and `along` long, its long axis along the view's horizontal direction.
- **Mathematics:** `across = t theta_px (1 + depth)` (`t` the distance along the view, `theta_px` the angle of a pixel, `depth` the bounce, each bounce coarsens it); `along = across / max(facing, graze)` with `facing = -d_y` from above, `d_y` from below, `graze = 0.08`;
  axis `(d_x, d_z)/sqrt(d_x^2 + d_z^2)`.
- **Instructions:** one square root and two divisions; `flat` floored at `1e-6`.
- **Cost:** `O(1)` a water pixel; feeds `sampleFootprint` (L-65).
- **Why this and not another:** handbook 14 §3.6.1 records the failure of using the long side alone for the fade ("distant water a flat mirror: about 8 m at 200 m for a grazing view, where the short side is 0.4 m").
- **Where:** `src/render/lux/medium/lux_interface.axle:26-60,102-123`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.6, §3.6.2.

### L-77. I want a reflection of distant water never to be sent into the water it leaves
- **Means:** the reflected direction is held above the plane at no less than a share of the flat reflection's rise, then renormalised.
- **Mathematics:** `floor = max(-d_y * 0.5, 0.002)`; if `r_y < floor`, `r = normalize(r_x, floor, r_z)`; the floor is set before renormalising, so the rise ends a few percent under it.
- **Instructions:** one compare and, in the corrected case, one normalisation.
- **Cost:** `O(1)`.
- **Why this and not another:** `lux_interface.axle:137-139`: "a fixed floor lifted the grazing reflections of distant water above the foot of what they mirror" (handbook 14 §3.6.1 row 4: the fixed rise 0.02, inherited from the earlier water, made the waterline vanish in distant reflections).
- **Where:** `src/render/lux/medium/lux_interface.axle:31-35,133-147`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.6.1.

### L-78. I want a reflected sky to be blurred by the waves too small to see, but a reflected building to stay a building
- **Means:** blend a reflection that reached the sky toward the sky prefiltered at the unresolved roughness, by the unresolved share; one that struck the world is kept.
- **Mathematics:** `u = saturate(lost / max(sigma^2_total, 1e-6))`; `roughness = lost^(1/4)` (perceptual, from `alpha^2 = lost` with `alpha = roughness^2`); result `lerp(traced, sky_prefiltered(roughness), u)`; `luxMicroRoughness` is 0 for a face with no slopes (`wavy == false`).
- **Instructions:** the roughness uses `lightPow(lost, 0.25)` (deterministic, no libm); the lookup is the sky's prefiltered levels (L-18).
- **Cost:** `O(1)` a reflected-to-sky pixel; a grid read for the blur.
- **Why this and not another:** handbook 14 §3.6.1 row 3: blending every reflection toward the blurred sky made the shore float above its reflection; only a sky hit is blurred.
- **Where:** `src/render/lux/medium/lux_interface.axle:62-100,125-131,168-171`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.6.

### L-79. I want the view from under water: a circular window onto the world, mirror outside it
- **Means:** at the boundary a ray from inside is refracted by `luxRefract` with `from = medium index`, `into = 1`; total internal reflection means only the underside's mirror shows; otherwise the world beyond and the underside's reflection are mixed by Fresnel.
- **Mathematics:** Snell's window is the cone of half-angle `asin(1/n)` of the normal (48.6 degrees for `n = 1.333`) where `k > 0`; `shown = lerp(beyond, underside, F)` inside it, `underside` outside. A ray that does not rise (`d_y <= 0.0001`) reaches no boundary and sees the reach (`immersedReach = 64 m`).
- **Instructions:** the boundary distance is one division `(top - o_y)/d_y`; `luxExit` mirrors `d` in the underside's normal.
- **Cost:** `O(1)` a boundary crossing; handbook 14 §3.9: "a short walk under water (64 m at most) plus, for rays that reach the surface, one ray above it and one reflected below".
- **Why this and not another:** `not documented` (the physics is the standard one).
- **Where:** `src/render/lux/medium/lux_immersion.axle:1-22,26-79`; defaults `src/render/lux/medium/lux_interface.axle:43-59`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.9; `doc/handbook/render/17-media-and-interfaces.md` §3.

### L-80. I want what lies under water to be lit by a sun that is low at dusk, without tracing through dozens of water cells
- **Means:** the sun refracted once at the surface (computed once a frame), its path length through the medium taken as `depth / cos theta_t`, attenuated by Beer-Lambert.
- **Mathematics:** `into = luxRefract(-sunDir, up, 1, n)`; `toSun = -into.dir`; `crossed = 1 - F`; path `s = depth / max(toSun.y, 0.05)`; the sun is within `asin(1/n)` (48.6 degrees) of the normal however low it is. Handbook 14 §3.8 gives the measured failure: the baked straight-line path arrived black at dusk (the bed received 0.001 against 0.0032 for
  the deep colour and about 0.2 for sand in full sun).
- **Instructions:** the refraction is "computed once a frame", not per point; the dive is floored so a path through the medium stays finite.
- **Cost:** `O(1)` a frame for the refraction, `O(1)` a point for the path.
- **Why this and not another:** handbook 14 §3.8: the baked volumes carry the sun in a straight line and dim it by the cells' opacities, so a bed six metres down "arrives black".
- **Where:** `src/render/lux/medium/lux_immersion.axle:23-24,41-48,81-95`.
- **Docs:** `doc/handbook/render/14-water-surface.md` §3.8.

---

## Sprites (`lux_sprites`)

### L-81. I want pixel-art particles drawn into a finished picture, hidden behind nearer surfaces, that never become part of the history
- **Means:** each particle is a square sprite of 4 x 4 texels (a diamond: whole in the middle four, 0.45 on the rim, nothing at the corners), depth-tested against the computed picture's surface position, and every pixel it covers is written down first so it can be put back.
- **Mathematics:** side `= clamp(size / (dist * pixel), minSide, maxShare * H)` with `pixel = fov / H`; `near = smoothstep(0.4, 2.0, dist)` (invisible nearer than 0.4 m, whole from 2 m); the depth test `|pos_under - eye| < dist` skips a covered pixel; texel `((x + 1/2 - x0)/side) * 4`.
  Restore: "last drawn first (a pixel two sprites crossed included)".
- **Instructions:** the computed pixel under an output pixel is `((y*h)/th) * w + (x*w)/tw` (integer, so the test works at any upscale ratio); the undo list is a pair of `Vec` (`i64` pixel offset, 3 `f32` a pixel).
- **Cost:** `O(particles + covered pixels)`, serial; `side <= 0.025 H`, so at most `(0.025 * 720)^2 = 324` pixels a sprite at 720 lines (derived); undo memory `20 bytes` a covered pixel (8 + 3 x 4).
- **Why this and not another:** `lux_sprites.axle:6-12`: drawn before the display so bloom takes the bright ones; put back before the picture is read as a history ("an upscaler's output is the next frame's history"). Handbook 16 §4 says particles drawn into the output "do reach the upscaler's history ... bounded by the next frame's 3 x 3 colour-box clamp":
  that text and the file's header disagree on whether the undo is applied before the swap (Doubts).
- **Where:** `src/render/lux/sprite/lux_sprites.axle:1-163`.
- **Docs:** `doc/handbook/render/15-view-layers.md` §3.6; `doc/handbook/render/16-upscale.md` §4.

---

## Temporal accumulation and super-resolution (`lux_clip`, `lux_upscale`)

### L-82. I want history to be trusted only where the present supports it (no ghosts) without a division by a zero deviation
- **Means:** a colour box in YCoCg: mean `+-` `gamma` deviations of the 3 x 3 neighbourhood; a history outside the box is pulled along the line to the mean until it meets the box's surface.
- **Mathematics:** `Y = R/4 + G/2 + B/4`, `Co = R/2 - B/2`, `Cg = -R/4 + G/2 - B/4`; inverse `R = Y + Co - Cg`, `G = Y + Cg`, `B = Y - Co - Cg`; per channel deviation `sqrt(max(E[x^2] - E[x]^2, 0))`; `reach = max over channels |h - mean|/(gamma dev)`; result `h` if `reach <= 1`, else `mean + (h - mean)/reach`.
  A channel whose box has no width reaches `1e6` as soon as the offset has any length; an offset under `1e-6` counts as none. `gamma = 1.25` ("a deviation and a quarter"). The technique is the one temporal anti-aliasing has used since Karis (SIGGRAPH 2014) and Salvi (GDC 2016), as the file cites.
- **Instructions:** only the moments are accumulated (`sum`, `squares`, `count` as three `Vec3`s and a float), so a box is built one sample at a time with no array; a box of zero size is the mean itself.
- **Cost:** `O(neighbours)` to build, `O(1)` to clip; 28 bytes of moments. `LuxMoments` is exported and tested (`tests/src/lux_temporal.axle`) but the upscaler's own clamp is an RGB min-max box (L-85): the YCoCg clip is not called by `lux_upscale.axle` (a search of `src/` and `examples/` finds it only in `src/lib.axle` and tests).
- **Why this and not another:** `lux_clip.axle:1-17`: YCoCg separates brightness from colour, so a box around a grey neighbourhood is narrow in colour and wide in brightness, "the shape real neighbourhoods have". Alternative (dropping the history on every move) is what "made a picture shimmer for a second after the camera stops". But handbook 13 §3.6 records that the first use of this clip (history kept while moving, 12 frames,
  clipped to the YCoCg box, 2026-11-23) was withdrawn: "repeated bilinear reprojection is a repeated low-pass filter" (the kernel's deviation grows as the square root of the frames, "more than a pixel of blur" with 12) and reflections were lost; the module stays exported and tested.
- **Where:** `src/render/lux/temporal/lux_clip.axle:1-124`.
- **Docs:** `doc/handbook/render/13-dusk.md` §3.6 (the withdrawn use); `doc/handbook/render/07-accumulation.md` §3-4 (the earlier accumulation); the clip's own law is `MISSING` as a chapter section.

### L-83. I want a picture computed small to be rebuilt at the window's size from jittered samples
- **Means:** TAAU-style accumulation: each frame is computed at a fraction of the output with the whole picture shifted by a Halton (2, 3) sub-pixel offset; the stage gathers the 2 x 2 samples round each output pixel with a smooth kernel and blends them into a history at the output's own size.
- **Mathematics:** gather `c(X) = sum w_i L_i / sum w_i`, `w_i = (1 - d^2/r^2)^2` over the four samples (`d` in computed pixels); `r^2 = 1 + (r_n^2 - 1) trust`, `trust = min(count/8, 1)`, `r_n = max(1.6 * computed px per output px, 0.55)`: wide while the history holds little (no hole), narrow once it is full.
  Blend `n' = min(n + sum w_i, cap)`, `out = H + (c - H) sum w_i / n'` (the exponential mean of up to `cap` samples). Still, an output pixel converges to full resolution in `cap / sum w_i` frames.
- **Instructions:** every division of the loop is a multiplication by an `inv*` hoisted before it (`invW, invH, invOw, invOh, invSharp`); the two common kernel radii (empty history, full history) are computed once outside the loop and only `0 < count < 8` divides per pixel; `luxuNearest` clamps with `min/max`
  and a convert; a sample out of the picture is skipped by a compare.
- **Cost:** `O(ow * oh)` a frame with 4 sample reads and one box read a pixel. Measured (1920 x 1056 out, 640 x 352 computed, 23 threads): 4.5 ms for the first version (3 x 3 gather and box per output pixel, divisions) -> about 3.0 ms (boxes once per computed pixel, 2 x 2 gather, reciprocals), about 35 ns an output pixel on one thread
  (handbook 16 §5). Memory 40 bytes an output pixel: two colour histories (3 floats each) + two states (2 floats each) (`LuxuHistory`, `lux_upscale.axle:66-78`).
- **Why this and not another:** handbook 16 §2: shading costs about 486 ns a pixel on one thread, so at 60 frames a second the CPU computes about 300 000 pixels against two million on a 1080p screen; bilinear scaling of a 640 x 360 picture "was what the owner called 480p".
- **Where:** `src/render/lux/temporal/lux_upscale.axle:1-60,81-112,145-346`.
- **Docs:** `doc/handbook/render/16-upscale.md` §2-5.

### L-84. I want history reprojected as the surface moved, refused where it belongs to another surface
- **Means:** each output pixel's history is read at the position it was at last frame (the nearest computed sample's motion), bilinearly; the history is refused when the distance stored there differs from the sample's distance to the previous eye, or when the place falls off the picture.
- **Mathematics:** previous place `(pu, pv) = (ox + 1/2)/ow + motion_prev - sample_now`; refused when `|was - prevDist| > 0.06 prevDist + 0.2 m` (disocclusion) unless the sample has not moved on the screen; a place is inside when its pixel centre is: `-1/2 <= px <= ow - 1 + 1/2` (the edge is repeated, not refused: "a pixel on the picture's
  edge then never had a history and showed each frame's raw samples ... shimmered at the offset cycle"). The per-pixel motion record is 5 floats: previous `u, v`, previous distance (negative: none), present distance, cap (`luxMotionWrite`).
- **Instructions:** edges read with a clamp, not a branch per tap; the history place uses the nearest sample's motion only (one record read a pixel).
- **Cost:** `O(1)` a pixel: 4 colour reads + 1 state read; motion buffer 20 bytes per computed pixel.
- **Why this and not another:** handbook 16 §6: the still view "blinked" because the depth test threw its history away on silhouettes and walls seen edge on (distance moved by tens of metres with the sub-pixel offset); a sample that has not moved cannot have revealed anything, so its history is kept (`lxtStillWall` failed before, passes after).
- **Where:** `src/render/lux/temporal/lux_upscale.axle:31-32,54-60,206-264,445-460`.
- **Docs:** `doc/handbook/render/16-upscale.md` §3, §6.

### L-85. I want the history clamped to what the present supports, loosely for a still pixel, tightly for a moving or restless one
- **Means:** the history is clamped to the min-max box of the 3 x 3 computed samples round the nearest one, widened by a share: 15 % normally, effectively unbounded (1000) for a steady pixel that has not moved and whose memory is long.
- **Mathematics:** `slack = (hi - lo) * share`; `H' = clamp(H, lo - slack, hi + slack)`; `share = 1000` when `unmoved && cap >= 64` (steady: policy `still` 192, `slow` 96), else `0.15`. For a steady pixel "its history is exact and nothing in its rays moves with the time, so there is no ghost to cut".
  Measured: 2281 pixels of a facade changed by more than 20 levels in one frame at a governor step, 14 without the clamp (`lux_upscale.axle:37-41`).
- **Instructions:** the box is computed separably: min and max over three rows column by column, then over three columns (exact: `min` and `max` are exact), six reads a pixel instead of 27; the box band is built per job for the computed rows its output rows read, "at three times the size nine output pixels share each".
- **Cost:** box band `(bandTo - bandFrom) * w * 6 floats` allocated per call, never a picture-sized buffer (22 MB at 1280 x 720 computed saved, handbook 16 §5).
- **Why this and not another:** `lux_upscale.axle:34-43` and handbook 16 §6; the RGB box (not the YCoCg of L-82) is what the upscaler uses.
- **Where:** `src/render/lux/temporal/lux_upscale.axle:34-46,186-191,308-335,502-542`.
- **Docs:** `doc/handbook/render/16-upscale.md` §3, §5, §6.

### L-86. I want the ripple of an exponential mean over a repeating sub-pixel cycle to be small, and the cycle short
- **Means:** the number of Halton frames in a cycle (`cycle = 8`) is chosen from the ripple law of an exponential mean; the sample caps are chosen so the ripple is a small fraction of the contrast.
- **Mathematics:** a mean with weight `alpha` (about `1/cap`) of a signal of period `T` keeps a ripple of about `1/(2 sin(pi/T))` of its weight (`lux_upscale.axle:382-385`): `T = 16` -> 2.56, `T = 8` -> 1.31, `T = 4` -> 0.71 of the weight; "16 left a visible 3.75 Hz shimmer on fine detail, 8 halves it for an enlargement up to 2 (measured: 0.145 to 0.102, for
  0.26 dB), 4 loses 1.3 dB". Halton: `luxuRadical(n + 1, b) - 1/2` with bases 2 and 3 (digit-mirroring about the point), offsets in `(-1/2, 1/2)`.
- **Instructions:** a radical inverse is a `while (i > 0)` loop of `i % b` and `i / b` over the digits; `luxuPhase` wraps a negative index.
- **Cost:** `O(log n)` an offset per frame (a handful of integer operations), 0 memory.
- **Why this and not another:** the measured trade-off in the comment, quoted above; alternatives 16 and 4 recorded there.
- **Where:** `src/render/lux/temporal/lux_upscale.axle:380-387,430-438,462-484,544-550`.
- **Docs:** `doc/handbook/render/16-upscale.md` §3 (it says "k of 16", `cap` 8/48/4; the code has cycle 8, still 192: Doubts).

### L-87. I want each pixel's memory length to match how fast its light changes
- **Means:** a policy turns a pixel's change class (Steady, Slow, Restless) and whether the view moves into the most samples it keeps.
- **Mathematics:** `base = moving ? 8 : 192`; `Steady -> base`; `Slow -> min(base, 96)`; `Restless -> min(base, moving ? 4 : 32)`; `orMore` takes the faster-changing of two ranks, "a pixel's change is the fastest thing its rays met". The reasons: still pixels converge and the cycle's ripple (`~ 1/still` of the contrast) disappears;
  restless ones keep a short memory "but not shorter than the ripple allows (about `1/restless`)" (32 keeps the sea as sharp: gradient energy falls 1.4 % against 12, and a lit window's shimmer 25 % lower); while moving, a restless pixel is mostly sea and what it shows is a virtual image that does not move with the surface the history is reprojected by.
- **Instructions:** a `match` on an `i8` enum; integers and compares only.
- **Cost:** `O(1)` a pixel; 5th float of the motion record.
- **Why this and not another:** the measured values in the field comments (`lux_upscale.axle:382-427`).
- **Where:** `src/render/lux/temporal/lux_upscale.axle:348-428`.
- **Docs:** `doc/handbook/render/16-upscale.md` §3 (stale numbers).

### L-88. I want a picture that stays still when the camera is still
- **Means:** no random number and no wall clock in the picture; every stage uses a fixed or camera-keyed answer. The pieces in this zone:
  the dither is a fixed tile (L-10); the shafts of the block march draw no random number (L-37); the clouds are averaged over the sample's footprint (L-21); the sky's discs are drawn per pixel while its veil is sampled (L-15); the face cache keeps the light with the surface (L-33);
  a steady upscaled pixel keeps its history whatever distance a sub-pixel offset gives (L-84); the bloom of a still view is taken from the shown picture, not the computed one (handbook 16 §6, `LumenPost.takeBloomFrom`, `pathlight_post.axle:318-326`).
- **Mathematics:** none: plain arithmetic.
- **Instructions:** see each entry.
- **Cost:** see each entry; the whole is measured by `--flicker --steady` runs: viewpoint 2 upper half 0.48 -> 0.06 (handbook 16 §6); a still picture reads 1.7 ms a frame, tracing nothing (ledger §1 row 7).
- **Why this and not another:** ledger §1: shading every pixel with a random sample was "grain, ghosts" (row 1); handbook 02 (determinism) lists the three sources: random sampling, history, threads.
- **Where:** as listed in each entry; `src/render/pathlight/pathlight_post.axle:189-193,318-326`.
- **Docs:** `doc/handbook/concepts/02-determinism.md`; `doc/handbook/render/16-upscale.md` §6.

### L-89. I want to know that no part of this zone depends on the order threads run in
- **Means:** each stage reads buffers and writes only its own rows or chunk; shared caches are written between stages from batches on one thread; scheduler and publication run on the main thread between two frames.
- **Mathematics:** none: plain arithmetic. Examples of the rule in the files: a row of sparse samples "is written by the chunk that owns its rows and read only after every chunk is done" (`pathlight_sparse.axle:23-25`); each pass of the display is a row range; the face cache's batches (L-34); the LuxCache swap (L-45).
- **Instructions:** pass functions take `begin, end` row bounds; scratch belongs to a chunk, "not to a thread" (`pathlight_facecache.axle:20-22`).
- **Cost:** none beyond the structure.
- **Why this and not another:** `doc/handbook/concepts/02-determinism.md` §2.3 and ledger §7 (one worker a core: 12, 5.7 times the one-thread frame; a worker a hardware thread, 23: 6.4 times, "12 % more than 12 for twice the processor time").
- **Where:** `src/render/pathlight/pathlight_post.axle:141-155,376-423`, `src/render/pathlight/pathlight_facecache.axle:19-24`, `src/render/lux/graph/lux_scheduler.axle:13-23`.
- **Docs:** `doc/handbook/concepts/02-determinism.md` §2.3; `doc/handbook/standards/02-shared-buffers.md`.

---

## Missing documentation

Mechanisms with a formula or a rule in the code and no, or only a passing, sentence in `doc/handbook` (checked by `grep` of the handbook and design folders for the names and by reading the chapters listed in each entry's **Docs** line).

| Mechanism | File | What is not written down |
|---|---|---|
| Unsharp mask clamped to the neighbours' range (L-12) | `src/render/pathlight/pathlight_post.axle:34-35,715-735,789-796` | the formula, the share 0.6 and the no-halo clamp; handbook 08 mentions only the neighbour loads |
| Vignette, highlight desaturation and grade (L-11) | `src/render/pathlight/pathlight_post.axle:77-88,621-639,697-713` | the laws and their constants (0.9, 0.8, 2.5, 0.85, 1.12) and why |
| Edge-avoiding a-trous filter (L-36) | `src/render/pathlight/pathlight_filter.axle:1-178` | the weights, the tolerance from the pixel's variance, the three rounds, the reach law and why `denoise` is off by default; the ledger has no row for it |
| Moon lift and the night share (L-24) | `src/render/pathlight/pathlight_sky.axle:58-70,157-169,201-208` | the constants (ratio 2.5e-6, lift 26 000), the tint, why the dome and the grid use the same scale |
| Ground beyond the world's edge and the haze glare constants (L-26, L-27) | `src/render/pathlight/pathlight_sky.axle:85-108,664-688` | the glare cone (0.55, 0.4, 0.9), the dip fade 2.5 and the mix constants 0.6 / 0.25; handbook 05 §4.1 has only the flattening and the dome |
| Sky baker thread protocol (L-20) | `src/render/pathlight/pathlight_sky.axle:172-301` | the gate's states, who writes what when, the memory-ordering argument, why `stop` waits |
| Caustic pattern (L-29) | `src/render/pathlight/pathlight_shade.axle:71-97` | the function, its constants and why it is a two-train sine pattern; handbook 14 §3.8 only names `caustic(x, z, t)` |
| Cost meter of the governor (L-52) | `src/render/lux/graph/lux_budget.axle:33,61-69` | the running mean of weight 1/8 and what it feeds |
| Compile complexity of the lux graph (L-49) | `src/render/lux/graph/lux_graph.axle:225-313` | an honest bound (the file says "quadratic in the edges", handbook 12 says `O(L^2 E)`; the loop nest is higher) |
| YCoCg history clip (L-82) | `src/render/lux/temporal/lux_clip.axle:1-124` | its law (reach along the line to the mean), and that the upscaler does not call it (only handbook 13 §3.6 mentions the withdrawn use) |
| Hash primes and quality (L-40) | `src/render/pathlight/pathlight_noise.axle:10-33`, `src/core/field/lux_noise.axle:20-29` | why these constants and the statistical quality of the 24 bits; handbook 02 §2.1 gives the policy only |
| Face cache slot hash and eviction (L-33) | `src/render/pathlight/pathlight_facecache.axle:63-67` | the slot function (`(h * 40503) & mask`) and the expected collision rate; handbook 11 §4 was not read for it (`UNVERIFIED`) |
| Light memo's collision rule (L-32) | `src/render/pathlight/pathlight_sparse.axle:356-411` | handbook 04 §1.0 lists the class; the slot hash and the "a second key takes its place" rule are not described |
| Camera basis and `project` (L-42) | `src/render/pathlight/pathlight_camera.axle:58-117` | the yaw/pitch convention beyond the file's own header, the 0.01 rad pole margin |
| Sprite style and texel (L-81) | `src/render/lux/sprite/lux_sprites.axle:69-82,149-163` | fade distances 0.4 / 2.0 m, the 0.025 share, the 0.45 rim; handbook 15 §3.6 was read only by its heading (`UNVERIFIED`) |
| Shading constants (L-39) | `src/render/pathlight/pathlight_shade.axle:31-47` | the access floor 0.35, flood 0.3, cloud removal 0.78, horizon -0.04; handbook 05 §3 was not read line by line (`UNVERIFIED`) |
| Planar layout and lane helpers (L-54) | `src/render/lux/simd/lux_simd.axle:44-67` | `luxMin8/Max8/Clamp8` semantics (the NaN rule) are in the code only |

## Doubts

Comments or chapters that look stale, wrong or contradicting. Nothing here was changed.

1. `doc/handbook/render/08-display.md` §3.1: "The game caps it at 4 so that night stays dark"; `pathlight_post.axle:48-49` bounds the exposure at `0.04..90` and the cap, if any, is in a program outside this zone (`UNVERIFIED`).
2. `doc/handbook/render/08-display.md` §5 table ("Display 44 ms", compose and pack 39 ms with 3 `sqrt`) against ledger §5 row 4 (21 ms, no `sqrt`) and the code (`pathlight_post.axle:506-658`): the chapter's table describes an older step.
3. `src/render/pathlight/pathlight_sky.axle:228-229`: "some two and a half seconds of work" for one bake; `doc/handbook/render/06-sky.md` §2.1 and §7: 0.16 ms an integral, 1.3 s on one thread.
4. Accuracy of the quick angles: `src/render/pathlight/pathlight_sky.axle:529-530` says 1e-5 radian, `src/core/math/trig.axle:298,310,349` says 1.2e-5, `doc/handbook/render/06-sky.md` §4 table says 2e-5.
5. `doc/handbook/render/06-sky.md` §5: a star's brightness `k^2 (0.75 + 0.25 sin(...))`; `src/render/pathlight/pathlight_celestial.axle:51-52` has `0.9 + 0.1 sin(...)`.
6. `src/render/pathlight/pathlight_shaft.axle:1-13`: the header describes only the jittered per-pixel march and the frame average; `skyShare`/`marchShare` (138-215), which draw no random number, are what the pictures use (`doc/handbook/render/01-frame.md` §5.1).
7. `src/render/lux/medium/lux_interface.axle:11` (header: "Fresnel Schlick's") against `luxViewFresnel` at 149-166 (exact equations, "Schlick's approximation, which this replaced"); `doc/handbook/render/17-media-and-interfaces.md` §3 (`fresnel F = f0 + (1 - f0)(1 - max(-n.d, 0.001))^5`) also shows the old form.
8. `src/render/lux/graph/lux_graph.axle:28-29` ("quadratic in the edges") and `doc/handbook/render/12-lux-layers.md` §5 (`O(L^2 E)`) against the nesting `findLive` -> `feedsLiveLayer` -> `layerReads` (`lux_graph.axle:227-272,299-313`): about `O(L^3 E^2)`; harmless at tens of layers but not what the text says.
9. `doc/handbook/render/12-lux-layers.md` §5: exposure loop "0.29 ns/px" and fog "13.2 to 14.0"; `src/render/lux/simd/lux_simd.axle:5-9`: 0.32 and 14.0.
10. `src/render/lux/simd/lux_simd.axle:8-9`: the sentence is broken ("the exponential bel" then a new line "call to a scalar `exp` stops it"): a word is missing.
11. `src/render/lux/fluid/lux_ocean.axle:296-297`: two comments in a row ("The spacing of the grid ..." and "Bytes the cascade's spectrum ... hold"); the first describes `spacing()` (305) but sits above `bytes()` (298).
12. `doc/handbook/render/14-water-surface.md` §3.6: "The fade uses the side of the square of the same area, the geometric mean `a / sqrt(cos v)`"; §3.6.2 and `lux_ocean.axle:396-397` fade by `max(across, spacing)` of the anisotropic taps (the §3.6 text was superseded and not edited).
13. `doc/handbook/render/14-water-surface.md` §5: "16 384 noise evaluations" at construction; `lux_ocean.axle:529-532` evaluates the gust noise four times a cell (65 536 for `128 x 128`). Update time 0.25 ms (handbook) against 0.26 ms (`lux_ocean.axle:48`).
14. `src/render/lux/temporal/lux_upscale.axle:393-395` ("an exponential mean of a 16-periodic signal") while the default cycle is 8 (386); `doc/handbook/render/16-upscale.md` §3: "Halton(2, 3) point k of 16", "cap 8 moving, 48 still, 4 for water" against the policy defaults 8 / 192 / 32 / 4 / 96 (386-418).
15. `src/render/lux/temporal/lux_upscale.axle:412-418`: the doc comment of `cap` (how the policy cuts the base memory) sits above the field `slow`; the function `cap` (420) has none.
16. `doc/handbook/render/13-dusk.md` §3.9: the governor "steps ... up after 30 frames below 75 %"; `lux_budget.axle:20-33,87-124` rises on a predicted cost under 85 % with a patience that doubles (30 to 480) after hunting (and the file's own header, lines 8-12, says "75 %" alone hunted).
17. Sprites and the history: `src/render/lux/sprite/lux_sprites.axle:8-12` says the program puts the pixels back before the picture is read as a history, "a sprite never enters a history, so it leaves no trail"; `doc/handbook/render/16-upscale.md` §4 says particles drawn into the output do reach the upscaler's history and leave a faint trail bounded by the clamp.
18. `src/render/lux/look/lux_look.axle:5-9`: the header puts `Rough` and `Emit` both at "stage 3", but the codes are 2 and 3 and `compile` orders by those five kinds (`lux_look.axle:30-41,284-290`): harmless because they commute, but the two texts disagree.
19. `doc/handbook/render/11-face-cache.md` §6 "360 chunks x 256 faces x 124 bytes = 11.4 MB" for the batches: a batch slot also holds `pending` (4 B) and `queued` (1 B) (`pathlight_facecache.axle:129-150`), 129 bytes, about 11.9 MB (derived).
20. `src/render/pathlight/pathlight_facecache.axle:48-53,123-126`: the stamp `epoch * 2` overflows `i64` once the caller's base epoch reaches `2^30`; the comment claims "a game left running does not come back to an epoch" (only true below that base; `UNVERIFIED` that any caller gets there).
21. `src/render/lux/fluid/lux_ocean.axle:33`: "period 1 024 m, three times the world": the world's size is not in the file or the handbook chapter read (`UNVERIFIED`).

## Summary

Read in full: every file of `src/render/pathlight` except `pathlight_settings.axle` (only its constants and field list were listed), every file of `src/render/lux` (graph, fluid, look, medium, simd, sprite, temporal), `src/core/field/lux_field.axle`, `src/core/field/lux_noise.axle`, and the quick-trigonometry block of `src/core/math/trig.axle`;
and, in the handbook, the complexity ledger, `render/01` §5, `04` §2, `06`, `07` §3-5, `08` §3-5, `10` §2.3, `11` §3 and §6, `12`, `14`, `15` §3-5, `16` §2-6, `17`, `18`, and the rule table of `standards/01`. Chapters `02`, `03`, `05`, `09`, `13` (apart from §3.6 and §3.9), `concepts/01-03` and `standards/02-03` were only skimmed by heading or grepped
for names, so entries whose **Docs** line cites them for more than a title are marked "not read in detail". The 89 entries (L-01 to L-89) group into display, sky and clouds, sparse light and the face cache, the lux graph and governor, the ocean, looks and fields, media, sprites and the temporal stages. Not verified: any timing (nothing was built or run; every
"measured" figure is quoted with its file), the cost of the hash in L-40, the cache-fit claim of L-50, the `LuxGraph.compile` bound of L-49 (counted from the loops only), the Axle compiler reasons behind L-14 and L-20 (they are quoted from comments), the cap on exposure of Doubt 1, and the world size of Doubt 21. This file was the only one created in the repository; no other repository file was edited.
