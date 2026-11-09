# texlab

The image and texture layers of ludax, end to end, with no window and no dependency but ludax.

It draws four patterns in code, saves one as a PNG with ludax's own encoder, reads it back through the image cache,
builds mip-mapped textures in linear light and writes four pictures you can open:

- `texlab-mips.png`: the mip chain of the brick pattern, down to one texel;
- `texlab-floor-checker.png` and `texlab-floor-bricks.png`: a floor receding to the horizon read three ways, left to
  right nearest (it sparkles), bilinear (still aliased far away) and trilinear (calm);
- `texlab-floor-moss.png`: the trilinear floor, larger.

```sh
cd examples/engine/texlab
axle build -O 3
./target/texlab.exe
```

## What it shows

| Idea | Where |
|---|---|
| PNG written and read with our own deflate and inflate; the picture comes back identical | `ImageAssets`, `PngCodec` |
| Mips are averaged in linear light, not in encoded values: a checker of sRGB 235 and 20 ends at 173, not 127 | `Texture`, `src/main.axle` |
| Transparent texels do not tint a cut-out's mips | the leaves pattern |
| What footprint-driven filtering does to a receding plane | `src/view/floor.axle` |

The exit status is the number of checks that failed.
