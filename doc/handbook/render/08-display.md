# 3.8 Display

[Handbook](../README.md) · previous: [3.7 Accumulation](07-accumulation.md) · next: [3.9 Baked shadows](09-baked-shadows.md)

## 1. Contract

`LumenPost` (`src/render/pathlight/pathlight_post.axle`) turns a picture of linear radiance into display words.

- **In**: `hdr` (`f32 x 3`, `W x H`), the settings (bloom strength, automatic or fixed exposure), the time since the
  last frame.
- **Out**: `out`, `W scale x H scale` words `0x00RRGGBB`.
- **Guarantee**: the same `hdr` and exposure give the same words; the dither is fixed in space and time.

## 2. The chain

| # | Step | Formula | Resolution |
|---|---|---|---|
| 1 | Meter | `mean = exp2(avg(log2(max(Y, 2e-5))))` over one pixel in 16 | `P / 16` |
| 2 | Exposure | `want = clamp((0.17 / mean)^0.78, 0.04, 90)`, eased | scalar |
| 3 | Bright | `keep = max(m - 1, 0) / m` with `m = max channel of min(hdr * exposure, 6)`; mean of 2 x 2 | `P / 4` |
| 4 | Blur | 1-4-6-4-1 across then down, at each of four levels | `P/4 .. P/256` |
| 5 | Fold | `lv3 = 0.6 lv3 + 0.5 up(lv4)`; `lv2 = 0.75 lv2 + up(lv3)`; `lv1 = 0.9 lv1 + up(lv2)` (pass `Fold`, on the pool) | `P/64`, `P/16`, `P/4` |
| 6 | Sharpen | `c + 0.6 (c - mean of 4 neighbours)`, clamped to the range of the neighbours and `c` | `P` |
| 7 | Expose, bloom | `e = c * exposure + 0.35 strength up(lv1)`, one level, read at exactly twice its size | `P` |
| 8 | Vignette | `e *= 1 - 0.9 r^2`, `r` the distance from the centre in picture units | `P` |
| 9 | Highlight roll-off | `e = lerp(e, grey, 0.85 saturate((peak - 0.8) / (peak + 2.5)))` | `P` |
| 10 | Grade | `e = grey + 1.12 (e - grey)` | `P` |
| 11 | Tone | `e *= T(m) / m`, `m` the largest channel | `P` |
| 12 | Encode | sRGB transfer | `P` |
| 13 | Dither, pack | `code = floor(255 v + n + 0.5)`, `n` in ±0.5 from a 64 x 64 tile | `P` |

## 3. Mathematics

### 3.1 Exposure

The eye adapts to the **geometric** mean of what it sees, not the arithmetic one: a small bright sun should not
darken a whole landscape.

```
mean  = 2^( (1/n) sum log2(max(Y_i, 2e-5)) )         Y = 0.2126 R + 0.7152 G + 0.0722 B
want  = (key / mean)^follow                          key = 0.17, follow = 0.78
```

`follow < 1` makes up only most of the difference: a cave stays darker than noon, so a lamp in it still glows.
The exposure moves toward `want` in log space, `blend = saturate(9 dt)`: about a tenth of a second to settle.
The game caps it at 4 so that night stays dark.

**Sampling.** The mean of a logarithm over one pixel in 16 (57 600 pixels) differs from the mean over all by less
than the third digit, and this runs on the thread that waits for the frame: 0.7 ms a frame, measured (it read one
pixel in four before).

### 3.2 Bloom

Light above display white spills round its source. The source is what exceeds 1 after exposure, with its colour:

```
c    = min(hdr * exposure, 6)
keep = max(max(c) - 1, 0) / max(max(c), 1e-4)
src  = c * keep
```

It is halved four times and each level blurred with the binomial kernel `(1, 4, 6, 4, 1) / 16`, separably. Added
with weights 0.9, 0.75, 0.6, 0.5, the levels make a glow that is tight near the source and wide far from it.

**Folding.** Reading four levels bilinearly for every pixel was 16 texel reads. Bilinear upsampling is linear, so
the three coarser levels can be summed once, each at the next finer level's resolution:

```
lv3 <- 0.6 lv3 + 0.5 up(lv4)        P / 64 pixels
lv2 <- 0.75 lv2 + up(lv3)           P / 16 pixels
pixel: 0.9 bilinear(lv1) + bilinear(lv2)
```

The result differs from the four separate reads only by the order of interpolation of two blurs.

### 3.3 Tone curve

Linear up to a knee, then an exponential shoulder that reaches 1 only at infinity:

```
T(x) = x                                       x <= k        (k = 0.6)
T(x) = k + (1 - k)(1 - exp(-(x - k) / (1 - k)))   x > k
```

`T` is continuous with slope 1 at the knee. It is applied to the **largest** channel and the others follow
(`e *= T(m) / m`), which keeps hue. `T(m) / m` comes from a table of 4097 entries over `m` in 0..40, read linearly.

### 3.4 sRGB

```
enc(x) = 12.92 x                       x <= 0.0031308
enc(x) = 1.055 x^(1/2.4) - 0.055       otherwise
```

A table over `x` would need most of its entries near 0, where the curve is steep. Indexed by `sqrt(x)` the curve is
nearly straight (`x^(1/2.4) = (sqrt x)^0.83`), so 4097 evenly spaced entries serve the whole range.

**Nearest entry.** With `s = sqrt(x)`, `enc = 12.92 s^2` below `s = 0.056` (slope `25.84 s <= 1.45`) and
`1.055 s^0.833 - 0.055` above (slope `0.879 s^-0.167 <= 1.42`). So one step of the table (1/4096) moves the output by
at most `3.5e-4`, an eleventh of a display code (1/255 = `3.9e-3`), and the nearest entry is within `1.8e-4` of the
interpolated one: far under the ±0.5 code of dither. Measured: 1.5 % of the bytes of a
picture change, by one code.

### 3.5 Dither

Eight bits cannot hold a smooth gradient of the sky: without noise it shows bands. A value in ±0.5 code is added
before rounding; the noise is a fixed 64 x 64 tile of a hash, the same every frame, so a still picture does not
shimmer.

### 3.6 Reading a level at exactly twice its size

A pixel `x` of the picture lies at `x / 2 - 1/4` in the half-size level: a quarter of a coarse pixel from the centre
of its own coarse pixel `j = x >> 1`, toward `j - 1` when `x` is even and toward `j + 1` when it is odd. So

```
up(x) = 3/4 c_j + 1/4 c_(j-1)      x even
up(x) = 3/4 c_j + 1/4 c_(j+1)      x odd
```

and the same down the rows. A row of the picture is a walk along two rows of the level, blended 3/4 and 1/4 once:
three columns are carried (`j - 1`, `j`, `j + 1`) and one new column is read for every two pixels. No floor, no
clamp but at the last column, 6 loads for 2 pixels instead of 24 for 1.

### 3.7 The code table without a square root

The sRGB code is read from a table over the linear value itself, in two linear segments split at 1/16:

```
i = x * 65536                         x < 1/16      4096 entries, step 1.5e-5, slope <= 12.92: 2e-4 a step
i = 4096 + (x - 1/16) * 4369.07       otherwise     4096 entries, step 2.3e-4, slope <= 2.2:  5e-4 a step
```

The nearest entry is within a fifteenth of a display code. The entry is an integer, `256 (255 code + 0.5)`, and the
dither tile is `256 n` as an integer in -128..127, so a channel is `(entry + n) >> 8`: no conversion from float, no
clamp (the sum lies in 0..65535).

## 4. Algorithm at scale 1

When the picture is shown at its own size, steps 6 to 13 run in **one loop** (`composeWords`) that writes the words
directly; there is no intermediate display buffer and the pack pass has no rows.

- Every field the loop reads is bound to a local first ([2.1](../standards/01-hot-loop-rules.md) R4).
- The two rows a bloom read lies between, and their weight, are computed once a row (R6).
- The neighbours of the sharpen are read only for interior pixels.

At another scale the general path runs: `compose` writes encoded values, `pack` scales them bilinearly and dithers.

## 5. Complexity

| Pass | Work | ms a frame, one thread |
|---|---|---|
| Meter | `P / 16` logarithms | 0.7 |
| Bright, two blurs, coarse levels, fold | `P / 4 * (4 + 10)` + smaller | 4.2 |
| Compose and pack | `P * (5 + 8 + 3 sqrt + ...)` | 39 |
| Copy to the window's surface | `P` words | 0.3 |
| **Display** | | **44** |

Memory: the four levels and a scratch (`P/4 * 3 * 2 + ...` = 6.4 MB), `disp` (11 MB, used only away from scale 1 or
in the raw view), `out` (3.7 MB).

## 6. Observations

- The composition is 42 ns a pixel and is now the largest single loop after the ray walk. What is left in it: twelve
  neighbour loads for the sharpen, eight for the bloom, three square roots, one division.
- The square roots keep the loop from vectorising. `axle/tests/bench/game_numerics/tonemap_srgb` measures exactly
  this: 810 ms in Axle against 92 ms in C, where the loop is vectorised. This loop would gain the most from the
  compiler.
- Bloom is cheap (4 ms): it was assumed to be the cost of the display, and was not.

## 7. History

| Date | Change | Display, ms |
|---|---|---|
| before | compose to a float buffer, then pack; four bloom reads; hashed dither; meter on one pixel in 4 | 67 to 70 |
| 2026-11-10 | meter on one in 16; dither tile; bloom folded to two reads; words written by compose at scale 1 | 53 |
| 2026-11-10 | `composeWords`: locals, row weights hoisted, nearest sRGB entry | 44 |
| 2026-11-11 | one bloom level read by the walk of §3.6 (the helper `pkAcross` was two calls a pixel, never inlined); integer code table and dither (§3.7); the highlight's division only above the knee | 21 (compose 39 to 17; 1 to 2 % of the bytes change, by one level) |

## 8. Source

`src/render/pathlight/pathlight_post.axle` (`adapt`, `bright`, `coarse`, `composeWords`, `compose`, `pack`),
`pathlight_bloom.axle` (the pyramid's arithmetic: `pkShrink`, `pkBlurAcross`, `pkBlurDown`, `pkFoldRows`, `pkBilinear`),
`src/render/light/light_color.axle` (`lightToneCurve`, `lightSrgbEncode`).
