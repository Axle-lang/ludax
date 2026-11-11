# 2.1 Hot-loop rules

[Handbook](../README.md) · previous: [1.3 The cost model](../concepts/03-cost-model.md) · next: [2.2 Shared buffers](02-shared-buffers.md)

A hot loop is code that runs for every pixel, every ray step or every cell. These are the rules such code follows in
ludax. Each was paid for: the last column is what breaking it cost, measured on one thread at 1280 x 720.

## 1. The rules

| # | Rule | What breaking it cost | Where it was found |
|---|---|---|---|
| R1 | **No integer division or remainder.** Wrap an index with a comparison, a mask, or a subtraction from an anchor. | 13 ns a ray at the horizon | `McView.slotOf` did four `%` a section |
| R2 | **No exact trigonometry for a table lookup.** Use `atan2Quick` / `asinQuick`; better, compare a sine. | 18 ns a ray | the skyline took a square root, a division and an `atan2` |
| R3 | **No string in a loop.** Anything derived from a name is a table built once. | per hit on birch and spruce leaves | `McRenderTable.fixedColor` called `endsWith` three times |
| R4 | **Bind fields to locals before the loop.** A store through an array may alias any field, so the compiler reloads every field it reads, each iteration. | 13 ms a frame in the display | `LumenPost.compose` |
| R5 | **One lookup, not several, when the levels can be folded once.** | 2 bilinear reads a pixel | the bloom read four levels a pixel; three are folded into one a frame |
| R6 | **Hoist what is constant along a row.** | part of R4's 13 ms | the vertical weights of a bilinear read |
| R7 | **A cache may not change an answer**, and is reset where its inputs may change. | correctness | the tracer's last-biome cache |
| R8 | **Prefer a comparison to arithmetic that needs a square root.** A unit vector's `y` is the sine of its elevation. | see R2 | `McSkyline.clear` |
| R9 | **Skip empty space at every size it comes in**, exactly. | 250 ns a sky ray | sections above a column's content were crossed one by one |
| R10 | **Do not replace a branch by arithmetic without measuring.** | +25 ns a ray when tried | the DDA's axis choice ([3.2](../render/02-visibility.md) §6) |
| R11 | **A value that is smooth is not computed per pixel** ([1.1](../concepts/01-smooth-and-sharp.md)). | the frame | light, sky, clouds |
| R12 | **f32 in the loop; f64 only for world positions.** A float literal beside an `f32` is `f64`: write `(0.5 as f32)`. | a conversion each way | `CLAUDE.md` |

## 2. The rules, one by one

### R1 — No integer division

`x % n` with `n` not a compile-time power of two is a `div` instruction: 20 to 40 cycles, more than a ray step.

```axle
// Before: two remainders an axis, to floor a possibly negative number.
let mx : i32 = ((cx % self.side) + self.side) % self.side;

// After: the anchor is a multiple of `side` just below the window, so the difference is a few sides at most.
let mut mx : i32 = cx - self.anchorX;
while (mx >= side) { mx = mx - side; }
while (mx < 0)     { mx = mx + side; }
```

The loops run zero or one time inside the window and stay correct outside it. A division by a **constant** (`/ 255`)
is fine: the compiler turns it into a multiplication.

### R2 and R8 — Trigonometry

To find the row of a direction in a table you need the angle to a fraction of a cell, not to a rounding of `f32`.
`atan2Quick` is a five-term polynomial within `1e-5` radian ([3.6](../render/06-sky.md) §4). Better still is not to
need the angle: `dir.y` of a unit direction **is** `sin(elevation)`, and sine is monotonic on `[-90°, 90°]`, so two
elevations compare as their sines do.

### R4 — Fields and aliasing

```axle
for (x of 0..self.w) {                       // self.w loaded each time
    self.out[i] = f(self.lv1[j], self.exposure);   // the store may have changed self.lv1 and self.exposure
}
```

Axle arrays are pointers; a store through `self.out` could, for all the compiler can prove, overwrite the memory
`self` lives in. So after each store it loads `self.w`, `self.lv1`, its length and `self.exposure` again. Bind them:

```axle
let w : i32 = self.w;
let lv1 : f32[] = self.lv1;
let mut out : i32[] = self.out;
let exposure : f32 = self.exposure;
```

### R9 — Empty space

A ray spends its time where there is nothing. Each size of nothing gets its own exact skip
([3.2](../render/02-visibility.md) §3): the whole sky above the window, the air above a column, an empty section,
the clear cube round a cell. Exact means a ray that takes the skip hits what it would have hit without it.

### R10 — Branches

The cell-by-cell step picks the axis whose boundary comes first. Written without branches (three 0-or-1 numbers
applied by multiplication) it was **25 ns a ray slower**: the multiplications lengthen the chain that carries `t`
from one step to the next, and the branch was well predicted, since consecutive rays take nearly the same turns.
Measure; do not assume.

## 3. What the compiler adds

These are not rules for us but costs to know (`AXLE_COMPILER_FINDINGS.md`):

| Cost | Size | Finding |
|---|---|---|
| A bounds check on every array access | 24 in `SkyGrid.look`, 41 in the ray walk | F4 |
| A guard on every float division | 110 in the ray walk | F3 |
| No vectorisation of a loop containing `sqrt` | the display's encode | measured by `tests/bench/game_numerics/tonemap_srgb`: 810 ms against 92 ms in C |
| Trilinear and bicubic reads 2 to 3 times slower than C | sky grid, baked light | `probe_trilinear`, `bicubic_sample` |
| Split builds lose inlining across units | 10 % | build the game with `--codegen-units 1` |

## 4. A checklist before calling a loop done

1. Is there a `%` or a `/` on integers? (R1)
2. Is there a `sin`, `cos`, `atan2`, `asin`, `pow` or `exp`? Is it needed to that precision? (R2)
3. Does it read `self.` inside the loop while it stores through an array? (R4)
4. Is anything computed for the pixel that is the same along the row, or the frame? (R6)
5. Does `axle build --emit llvm` show a call in it that should have been inlined?
6. Has it been measured before and after, twice, and compared with `cmp`? ([1.3](../concepts/03-cost-model.md) §4)

## 5. History

| Date | Rule | Change | Gain |
|---|---|---|---|
| 2026-11-10 | R2 | `atan2Quick`, `asinQuick` in `core/math/trig` | 10 ns a sky lookup |
| 2026-11-10 | R9 | column skip (`MCT_ABOVE`), window ceiling | sky ray 350 to 95 ns |
| 2026-11-10 | R1 | `slotOf` by anchor | horizon ray 143 to 120 ns |
| 2026-11-10 | R3 | `fixed` colour table | part of the above |
| 2026-11-10 | R2, R8 | skyline as sines | ray 86 to 73 ns |
| 2026-11-10 | R4, R5, R6 | `composeWords` | display 53 to 40 ms |
| 2026-11-10 | R10 | branchless step tried and withdrawn | −25 ns avoided |
