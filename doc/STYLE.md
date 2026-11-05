# Style

The house style of Ludax, learned from the platform library [`smalt`](../../vendor/smalt) it is built on and
stated here so a file can be read on its own. `tools` enforces nothing but `axle fmt`; these rules are the
review.

## A file is an argument

Every file starts with `// name — what it is`, a blank comment line, then prose. The prose says what the file
owns, what it deliberately does not do, and which design choice a reader would otherwise question. `smalt`'s
`audio/clip.axle` spends twenty lines explaining why clips are mono, 16-bit, nearest-neighbour resampled, and why
a bad file yields silence rather than an error; its `io/file.axle` explains why it calls libc instead of the
standard library. Our headers carry the same weight: `src/render/cpu/cpu_bvh.axle` and
`src/sim/kinetic/world.axle` are the models.

A header that only repeats the file name is a defect. A comment that restates the next line is noise; a comment
that says *why* is the point.

## Every public thing says what it is for

`pub` fields, methods, constants and suites carry `/** … */`, one sentence, ending with a period, describing the
contract — not the implementation. Where the contract has a trap, the doc states it:

```axle
/**
 * This vector at unit length.
 *
 * A vector shorter than `VEC_EPSILON` has no meaningful direction, and dividing by its length would trap.
 * It answers the zero vector, which every consumer treats as "no contribution".
 */
pub fn normalized(self) : Vec3 {
```

A `pub` item with no doc is a review failure even when the name is obvious.

## Values, not argument runs

A run of same-typed arguments is unreadable at the call site and easy to transpose. Pass a value:

- `scene.trace(ox, oy, oz, dx, dy, dz, tmax, …)` → `trace(ray : Ray, tmax, …)`;
- `mesh.addPortal(a, b, x0, y0, x1, y1)` → `addPortal(a, b, from : Vec2, to : Vec2)`;
- `bakeSun(world, scene, dir, halfAngle, rays, from, count)` → `bakeSun(job : SunBake)`.

When the value is built inline and the call would nest two literals, bind it on the line above so both lines stay
short:

```axle
let ray : Ray = Ray::make(Vec3::make(ox, oy, oz), dir);
let hit : LumenHit = scene.trace(ray, 60.0, true, 0);
```

Prefer, in this order: an existing value type (`Vec2`, `Vec3`, `Ray`, `Rect`), a small `struct` of the values
that belong together, an `enum` when the argument chooses behaviour, and only then positional numbers.

## No out-parameters

A struct is copied by value; an array argument is a borrowed pointer. Neither makes an out-parameter honest.
Return the value:

- `tileRange(t, out : i32[])` → `tileRange(t) : CpuTileRange`;
- `column(w, x, z, out : i32[])` → `column(w, x, z) : WalkColumn`;
- resize in place is fine; writing results through `out[]` is not.

## Blocks, not walls

Inside a function, leave a blank line between phases: inputs, the work, the write-back. A function longer than
about forty lines is usually two functions. Nesting beyond three levels is a missing `continue` or a missing
helper:

```axle
for (k of 0..9) {
    if (dx == 0 && dy == 0) { continue; }
    if (xi < 0 || xi >= self.w) { continue; }
    // …
}
```

`axle fmt` owns layout (indentation, chain breaks, spacing); it preserves the blank lines inside a block. Never
hand-align columns.

## Messages are interpolated

Build the value, then interpolate it. Concatenating `.toString()` chains is a defect:

```axle
println("smoke: ticks=${opts.smoke} seed=${opts.seed} runs=${game.runs} score=${w.score.points}");
```

When the expression is long, hoist it first:

```axle
let worst : f64 = self.worst;
let at : string = self.at;
c.that("${name} (max error ${worst} at ${at}, budget ${budget})", worst <= budget);
```

## Names

- Types are nouns (`SpatialGrid`, `FrameSet`); verbs are methods (`trace`, `resolve`, `blend`); booleans read as
  assertions (`isLoaded`, `hasUvs`, `canRun`).
- Abbreviations only where the domain owns them (`bvh`, `dda`, `brdf`, `aabb`); otherwise spell it out.
- Constants are area-prefixed (`FRAME_EPS`, `WAV_BITS`, `INPUT_WORDS`) because top-level names are package-wide.
- Free helpers are prefixed (`lightRel`, `frameAt`); a `static fn` of the class that owns them is better when the
  helper is not shared.

## Failure values, not branches everywhere

Choose one "absent" value and let callers test it once: an empty clip, a zero count, `-1` from a lookup.
Document it in the header and in the method. A failure that a loader can handle must not unwind the program.

## Numbers

A literal with a reason gets a name and a doc: `FRAME_SURFACE_MAX`, `CTRI_GUARD`, `GISS_ROOM`. A literal with no
reason — a shift mask, a magic index, an epsilon reused for a different comparison — is a defect the review
names.

Widths are part of the contract, not an optimisation to taste:

- a closed set is an `enum` backed by `i8`, which the compiler proves fits (a discriminant past 127 fails the
  build); an enum used as a bit mask is backed by its unsigned width (`u8` for up to 128 classes, `u32` for
  layer masks), never signed;
- a field that holds a code, an axis, a level or a small kind is `i8`/`i16` only when every producer has been
  read and its bound written down; a capacity (`room`, `used`, `count`) grows by doubling and stays `i32`;
- an index into a library array, a hash, a key, a nanosecond count or a seed stays `i64` — Axle indexes with
  `i64`, and a clock or a run can outlive 32 bits;
- a value in `0..255` (a colour channel, a light level) does not fit a signed byte; keep it `i32` or make it
  `u8` at the moment its whole storage moves, not field by field;
- `f64` in the lighting integrators and tables is reference arithmetic compared against analytic forms at
  `1e-8`; it is not narrowed to `f32`.

When a feature could add values to an enum or widen a count, choose the width for the set the feature can
reach, not for today's count.

## Structure

One file, one job, about 700 lines at most. The seams of `smalt` (a `sys/` record per platform, a backend behind
a contract) are the model: a file that needs an `if` to choose between two jobs is two files. A trait needs one
implementation inside the library; a class owns identity and changing state; a struct is copied plain data; an
enum with `match` replaces a tag ladder.

Determinism is part of readability: no wall clock, no hash-ordered iteration, no thread-ordered writes.
