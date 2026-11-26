# Problems glossary: core, world, runtime, openworld

"I want X" -> the mathematical or algorithmic means the code uses, and what it costs. Zone: `src/core/**`,
`src/world/**`, `src/runtime/**`, `src/openworld/**`. Every formula, constant and complexity below was read in the
file cited; `UNVERIFIED` marks what could not be confirmed from code or docs. Costs marked "derived" are counted from
the expression in the source, not measured. Nothing was built or run for this glossary.

Docs referred to by short name: `job-pool` = `doc/handbook/engine/01-job-pool.md`; `determinism` =
`doc/handbook/concepts/02-determinism.md`; `hot-loop` = `doc/handbook/standards/01-hot-loop-rules.md`; `sky` =
`doc/handbook/render/06-sky.md`; `view-layers` = `doc/handbook/render/15-view-layers.md`; `shapes` =
`doc/handbook/render/18-shapes.md`; `REVIEW_CORE` = `doc/handbook/history/core-review.md` (a review log with measurements, not a
mechanism chapter); `CORE_EXTRACTION` = `doc/handbook/history/core-extraction.md` (a move log).

---

## Scalars, angles and trigonometry

### C-01. I want to clamp, interpolate and remap a number without a divide-by-zero trap
- **Means:** branchy `clamp`/`saturate`, `lerp`, `inverseLerp` (0 when the span is 0), `remap = lerp(out, inverseLerp(in))`; f64 twins with a `D` suffix.
- **Mathematics:** `lerp(a,b,t) = a + (b-a) t`; `inverseLerp(a,b,v) = (v-a)/(b-a)`, defined as 0 when `a == b`; `remap(v) = lerp(outLo, outHi, inverseLerp(inLo, inHi, v))`, unclamped. Invariant: no division happens when the divisor is 0 (Axle traps on float divide by zero).
- **Instructions:** one compare plus one divide for `inverseLerp`; `lerp` is one multiply-add; `clamp` is two compares.
- **Cost:** O(1), no memory. No measured figure.
- **Why this and not another:** guarded divides are the project rule ("Float division by zero traps"); `lerp` is the `a + (b-a)t` form (exact at t=0, not at t=1 in floating point; UNVERIFIED that this was a deliberate choice).
- **Where:** `src/core/math/scalar.axle:106-183` (f32), `:276-308` (f64).
- **Docs:** MISSING.

### C-02. I want a smooth ease-in/ease-out between two edges
- **Means:** Hermite `smoothstep` and quintic `smootherstep` over a saturated parameter.
- **Mathematics:** `t = saturate((v-e0)/(e1-e0))`; `smoothstep = t^2 (3 - 2t)` (flat first derivative at both ends); `smootherstep = t^3 (t (6t - 15) + 10)` (first and second derivatives vanish at both ends, per the doc comment). `e0 == e1` degenerates to a step (0 below, 1 at or above).
- **Instructions:** one divide, one saturate, 3 (Hermite) or 5 (quintic) multiplies in Horner/product form. The f32 versions write constants as `(3.0 as f32)` to avoid an f64 promotion. There is no f64 `smootherstep` twin.
- **Cost:** O(1). No measured figure.
- **Why this and not another:** not documented. The sky and light code use `smoothstep` for fades (see C-56 where the field footprint fade is `1 - smoothstep(1, 4, fp f)`).
- **Where:** `src/core/math/scalar.axle:186-207`, `:311-320`.
- **Docs:** MISSING.

### C-03. I want to compare floats for "equal enough"
- **Means:** absolute tolerance below 1, relative above (scale = max(1, |a|, |b|)).
- **Mathematics:** `|a-b| <= EPSILON * max(1, |a|, |b|)`; `EPSILON = 1e-6` (about ten f32 steps near 1), `EPSILON_D = 1e-12`. `approxEqWithin` takes an explicit absolute tolerance.
- **Instructions:** three `abs`, two `max`, one multiply, one compare.
- **Cost:** O(1).
- **Why this and not another:** not documented.
- **Where:** `src/core/math/scalar.axle:24-25`, `:210-218`, `:323-331`.
- **Docs:** MISSING.

### C-04. I want an angle wrapped to (-pi, pi] without a loop
- **Means:** round the angle to the nearest whole number of turns and subtract.
- **Mathematics:** `turns = round(a / TAU)`; `a' = a - turns * TAU`, computed in f64. Non-finite or `|a| > 1e15` answers 0 (beyond that the turn count would not fit an `i64` and the angle "has no meaning left").
- **Instructions:** one divide (by a constant: a multiply), one `round`, one multiply-subtract. The f32 `wrapAngle` widens to f64 first.
- **Cost:** O(1), independent of how many turns.
- **Why this and not another:** a loop of `while (a > pi) a -= tau` would be O(turns); the closed form is exact for any range the guard allows.
- **Where:** `src/core/math/scalar.axle:236-238`, `:344-350`.
- **Docs:** MISSING.

### C-05. I want sin and cos that are bit-identical on every machine
- **Means:** Cody-Waite argument reduction by quarter turns, then the msun/fdlibm minimax kernels on [-pi/4, pi/4] (the code names "FreeBSD msun library (Sun's fdlibm)").
- **Mathematics:** `n = round(x * 2/pi)` (`TRIG_INV_PIO2`); `r = ((x - n p1) - n p2) - n p3` with `pi/2 = p1 + p2 + p3` split so `n * p_i` is exact for `n < 2^20`; quadrant `n & 3` selects `sin`, `cos`, `-sin`, `-cos` of `r`. `sinKernel(r) = r + r z P(z)`, `z = r^2`, P a degree-5 polynomial in z; `cosKernel(r) = 1 - z/2 + z^2 Q(z)`, Q degree 5. Arguments beyond `1e6` are first wrapped by whole turns (accuracy then degrades with `|x|`).
- **Instructions:** one multiply, one `round`, three fused-style multiply-subtracts, a 6-coefficient Horner polynomial (about 7 multiplies and 6 adds), a 4-way `match` on the quadrant. Only IEEE-754 add, multiply, divide are used, so results do not depend on libm. f32 `sin`/`cos` widen to f64, evaluate, round once.
- **Cost:** O(1), no table, no memory. Header measurement (by `tests/src/math_trig.axle`): f64 within 1e-15 absolute (worst 4.5e-16) for |x| up to 1e3 in the sweep; f32 versions within 1.3e-7 absolute (`trig.axle:11-17`). No timing is stated for these exact versions; `atan2Quick` is said to be "about fifteen times cheaper" than the exact atan2 (`trig.axle:310`).
- **Why this and not another:** the header says the C library's `sin`/`cos` "are allowed to differ between platforms and versions, which would make a replay or a lock-step simulation drift" (`trig.axle:3-6`). Deterministic-by-construction is the stated reason.
- **Where:** `src/core/math/trig.axle:24-38`, `:57-132`, `:259-267`.
- **Docs:** `determinism` covers the policy in general (UNVERIFIED that it names these kernels); formulas MISSING.

### C-06. I want atan, atan2, acos, asin that never produce NaN and never trap
- **Means:** msun atan argument reduction onto [0, 7/16] around atan(0.5), atan(1), atan(1.5), pi/2, then an odd+even polynomial split; `atan2` by dividing the smaller by the larger; `acos`/`asin` via `atan2` with `sqrt((1-x)(1+x))`.
- **Mathematics:** breakpoints 0.4375, 0.6875, 1.1875, 2.4375. Reductions: `(2x-1)/(2+x)` (about atan 0.5), `(x-1)/(x+1)` (atan 1 = pi/4), `(x-1.5)/(1+1.5x)`, `-1/x` (pi/2). Result `hi - ((a (odd+even) - lo) - a)` with `hi`/`lo` the split angle constant. `atan2`: if `|x| >= |y|` use `atan(y/x)` and shift by `+-pi` when `x<0`; else `pi/2 - atan(x/y)` or `-pi/2 - atan(x/y)`. `acos(x) = atan2(sqrt((1-x)(1+x)), x)`; `asin(x) = atan2(x, sqrt((1-x)(1+x)))`. Edge answers: `atan2(0,0) = 0`; `acos` of `x >= 1` is 0; of `x <= -1` is pi; NaN input to `atan` is 0.
- **Instructions:** one divide in the reduction, then a 6-term odd and a 5-term even Horner polynomial in `z = a^2`, `w = z^2`; branch on the interval. `sqrt` is the hardware instruction wrapped to return 0 for negative/NaN (`sqrt`, `sqrtD`).
- **Cost:** O(1). Accuracy: within 1e-15 absolute in f64, f32 within 1.3e-7 (`trig.axle:11-17`).
- **Why this and not another:** the quick version in C-07 exists because this one is too costly "for every pixel" (`trig.axle:296-297`).
- **Where:** `src/core/math/trig.axle:40-54`, `:150-257`, `:274-292`.
- **Docs:** MISSING.

### C-07. I want a cheap angle for a table lookup by direction (a sky map, a horizon), for every pixel
- **Means:** Abramowitz and Stegun 4.4.47 five-term polynomial in f32 plus octant folding.
- **Mathematics:** `atan(q) ~= q (a1 + a3 q^2 + a5 q^4 + a7 q^6 + a9 q^8)` for `0 <= q <= 1`, with `a1 = 0.9998660, a3 = -0.3302995, a5 = 0.1801410, a7 = -0.0851330, a9 = 0.0208351`; error below `1.2e-5` rad (0.0006 degree). Folding: `q = min(|x|,|y|)/max(|x|,|y|)`; if `|y| > |x|` then `a = pi/2 - a`; if `x < 0` then `a = pi - a`; if `y < 0` then `a = -a`. `asinQuick(v) = atan2Quick(v, sqrt(1 - v^2))` with `v` clamped to [-1,1].
- **Instructions:** one f32 division (`q = lo/hi`), about six multiplies (`q*q`, four in the Horner chain, one outer `q`), 4 adds, three conditional folds; origin returns 0 before the divide.
- **Cost:** O(1); "about fifteen times cheaper than the exact one" (`trig.axle:310`); `sky` section 4 tabulates "f32, one division, five multiplications" against f64 minimax. No memory.
- **Why this and not another:** not for "anything that integrates" (`trig.axle:311`). `hot-loop` R2/R8 add that the best option is not to need the angle at all: `dir.y` of a unit direction is `sin(elevation)` and sine is monotonic on [-90, 90] degrees.
- **Where:** `src/core/math/trig.axle:294-361`.
- **Docs:** `sky` section 4 (`doc/handbook/render/06-sky.md:106-125`) and `hot-loop` R2/R8.

### C-08. I want a square root and a tangent that cannot return NaN or infinity
- **Means:** guarded hardware sqrt; tangent as `sin/cos` with a pole answer of `+-HUGE`.
- **Mathematics:** `sqrt(x) = x.sqrt()` for `x > 0`, else 0 (also for NaN, because the test is `!(x > 0)`); `tan(x) = sin(x)/cos(x)`, and when `cos == 0` exactly, `+-HUGE_D` by the sign of `sin`.
- **Instructions:** one compare plus the hardware `sqrtss/sqrtsd` (IEEE-fixed, so deterministic); `tan` is two kernel calls plus one divide.
- **Cost:** O(1); `tan` costs about two `sin`/`cos` evaluations (derived).
- **Why this and not another:** the header notes that pi/2 in floating point is not exactly pi/2, so the pole "rarely happens".
- **Where:** `src/core/math/trig.axle:41-54`, `:138-148`.
- **Docs:** MISSING.

---

## Vectors

### C-09. I want dot, cross, length, distance and normalisation of 2/3/4-vectors
- **Means:** value-type `struct`s (`Vec2`, `Vec3`, `Vec4`) with named methods; no operator overloading.
- **Mathematics:** `a.b = sum a_i b_i = |a||b| cos(theta)`; `a x b = (ay bz - az by, az bx - ax bz, ax by - ay bx)` (right-handed, length = parallelogram area); `Vec2.cross` is the scalar z-component; `normalized = v * (1 / sqrt(|v|^2))`. `lengthSquared`/`distanceSquared` avoid the root for comparisons. A vector with squared length not above `V3_TINY = 1e-20` has no direction: `normalized` returns zero, `normalizedOr(fallback)` returns the fallback.
- **Instructions:** `normalizedOr` is one `lengthSquared` (3 multiplies, 2 adds), one compare, one `sqrt`, one reciprocal (`1/sqrt`) then 3 multiplies, so one divide per normalisation, not three. The reciprocal is `(1.0 as f32) / lenSq.sqrt()`.
- **Cost:** O(1), 12 bytes (`Vec3`), copied by value, stored inline in arrays.
- **Why this and not another:** value types so "never aliased"; `*In` forms for hot loops (C-10).
- **Where:** `src/core/math/vec3.axle:57-127`, `src/core/math/vec2.axle:47-120`, `src/core/math/vec4.axle:47-90`.
- **Docs:** MISSING (conventions: `doc/guide/style.md` and the file header).

### C-10. I want to reflect, project and build a perpendicular frame
- **Means:** closed forms in `Vec3`.
- **Mathematics:** `reflect(v, n) = v - 2 (v.n) n` (n unit); `projectOn(v, u) = u (v.u)/(u.u)`, zero when `u` is zero; `anyPerpendicular(v)` crosses `v` with the unit axis of its smallest `|component|` and normalises (smallest component keeps the cross product far from zero). `Quat.fromTo` uses it for antiparallel input.
- **Instructions:** reflect: one dot, scale, subtract; `anyPerpendicular`: 3 `abs`, 2 compares, one cross, one normalise.
- **Cost:** O(1).
- **Why this and not another:** axis choice by smallest component is the stable choice; the code states only "some unit vector perpendicular" (`vec3.axle:168`).
- **Where:** `src/core/math/vec3.axle:154-180`.
- **Docs:** MISSING.

### C-11. I want to update a vector in place in a hot loop
- **Means:** `mut self` methods named `...In`: `addIn`, `subIn`, `scaleIn`, `mulAddIn` (the integrator step `v += o*k`), `negateIn`, `crossIn`, `normalizeIn`, `set`.
- **Mathematics:** none: plain arithmetic. `crossIn` computes all three components into locals before writing back (so `self` may appear on both sides).
- **Instructions:** component-wise loads/stores; `normalizeIn` repeats the `V3_TINY` guard and one reciprocal.
- **Cost:** O(1), no allocation.
- **Why this and not another:** the project rule ("The forms that update a value in place are `mut self` methods named `...In`") because Axle has no operator overloading.
- **Where:** `src/core/math/vec3.axle:194-258`, `src/core/math/vec2.axle:141-180`, `src/core/math/vec4.axle:108-146`.
- **Docs:** MISSING.

---

## Rotations, matrices and transforms

### C-12. I want to compose rotations and rotate a vector without matrices
- **Means:** unit quaternion `Quat`, Hamilton product, vector rotation by `v + 2 w (u x v) + 2 u x (u x v)`.
- **Mathematics:** `a.mul(b)` is the Hamilton product (apply `b` then `a`, the same order as matrices); `conjugate = (-x,-y,-z,w)` is the inverse of a unit quaternion; `inverse = conjugate / |q|^2`; `rotate(v)`: `t = 2 (u x v)`, `v' = v + w t + u x t` where `u = (x,y,z)`; `yaw` is `atan2(-f.x, -f.z)` of the rotated -Z. Drift is removed with `normalized` (one reciprocal square root); methods assume unit length rather than pay a root per call.
- **Instructions:** `mul`: 16 multiplies, 12 adds; `rotate`: 2 crosses (12 multiplies, 6 subtracts), a scale, 2 adds, no matrix built.
- **Cost:** O(1), 16 bytes. No measured figure.
- **Why this and not another:** the header explains the convention (counter-clockwise from the positive axis, right-handed, +Y up) and that it agrees "exactly" with `Mat4::rotationX/Y/Z`.
- **Where:** `src/core/math/quat.axle:129-196`, `:273-277`.
- **Docs:** MISSING.

### C-13. I want a rotation from an axis and angle, from Euler angles, or the shortest turn between two directions
- **Means:** half-angle form; yaw-pitch-roll product; `fromTo` via cross and `1 + dot`.
- **Mathematics:** `q = (u sin(a/2), cos(a/2))`; `fromEuler(yaw,pitch,roll) = Ry(yaw) Rx(pitch) Rz(roll)` (+Y up, camera looking -Z, positive pitch nose up, positive yaw turns left); `fromTo(a,b)`: `q = normalize(a x b, 1 + a.b)` (this is the half-way quaternion identity; the code states "shortest rotation"); when `a.b < -0.999999` (`Q_ANTIPARALLEL`) the axis is `anyPerpendicular(a)` with `w = 0` (a half turn).
- **Instructions:** `fromAxisAngle`: one normalise, one `sin`, one `cos`; `fromEuler`: 3 axis-angle quaternions and 2 Hamilton products.
- **Cost:** O(1) (about 6 trig evaluations for Euler, derived).
- **Why this and not another:** not documented.
- **Where:** `src/core/math/quat.axle:52-88`.
- **Docs:** MISSING.

### C-14. I want to blend two rotations smoothly (animation, camera)
- **Means:** `slerp` along the great arc with a shortest-path flip, falling back to `nlerp` when nearly parallel.
- **Mathematics:** `d = q1.q2`; if `d < 0` negate `q2` (shortest arc); if `d > 0.9995` (`Q_NEAR_PARALLEL`) use `nlerp`; else `theta = acos(d)`, `q = (sin((1-t) theta) q1 + sin(t theta) q2) / sin(theta)`. `nlerp = normalize((1-t) q1 + t q2)` (cheaper, speed uneven). `sameRotation` accepts `q` and `-q` as equal via `|q1.q2| >= 1 - tol`.
- **Instructions:** slerp: 1 dot, 1 `acos`, 1 reciprocal `1/sin(theta)`, 3 `sin`, 8 multiplies, 4 adds; nlerp: 8 multiplies, then normalise (one reciprocal square root). The `0.9995` threshold keeps `sin(theta)` from vanishing.
- **Cost:** O(1); slerp uses 4 trig calls vs 0 for nlerp (derived).
- **Why this and not another:** the doc comment on `nlerp`: "cheaper than `slerp`, with uneven speed". `Transform.lerp` always uses slerp.
- **Where:** `src/core/math/quat.axle:197-229`, `:261-264`; `src/core/math/transform.axle:90-97`.
- **Docs:** MISSING.

### C-15. I want to convert between a rotation matrix and a quaternion
- **Means:** `toMat3` from products of components; `fromMat3` by the four-branch trace method (branch on the largest of trace, m00, m11, m22).
- **Mathematics:** `toMat3`: diagonal `1 - 2(yy+zz)` etc., off-diagonals `2(xy -+ wz)`. `fromMat3`: if `trace > 0`: `s = 2 sqrt(trace + 1)`, `w = s/4`, `x = (m21 - m12)/s`...; otherwise the same with the largest diagonal element as pivot so the square root argument stays well away from 0. Requires a proper rotation (orthonormal, determinant 1).
- **Instructions:** `toMat3`: 9 shared products, 9 outputs, no trig; `fromMat3`: one sqrt, one divide (reused `s`), 3 divisions (derived: three `/ s` per branch).
- **Cost:** O(1).
- **Why this and not another:** branching on the largest pivot is the numerically safe form; the code does not state it. `UNVERIFIED` that this is the stated intent.
- **Where:** `src/core/math/quat.axle:90-127`, `:231-259`.
- **Docs:** MISSING.

### C-16. I want to multiply and apply 4x4 transforms with a fixed, documented convention
- **Means:** `Mat4` of 16 named `f32` fields (no fixed arrays, because Axle 0.18.3 miscompiles writes through them); column vectors `v' = M v`; row-major field names `mRC`.
- **Mathematics:** `(A B)_ij = sum_k A_ik B_kj` (`B` applied first); `transformPoint` uses the top three rows plus translation; `transformVector` omits translation; `transformVec4` is the full product; `projectPoint` divides by `w` and answers zero when `w == 0`.
- **Instructions:** `mul`: 64 multiplies, 48 adds, no loop, no allocation (derived from the expression); `transformPoint`: 9 multiplies, 9 adds; `projectPoint`: 16 multiplies + one reciprocal. Right-handed world, +Y up, camera looks down -Z; projections land in Vulkan clip space (depth 0..1, +Y down in NDC).
- **Cost:** O(1), 64 bytes per `Mat4`.
- **Why this and not another:** header: named fields so "`m21` cannot be mistaken for `m12` the way index arithmetic can" and no heap.
- **Where:** `src/core/math/mat4.axle:1-33`, `:269-288`, `:450-489`.
- **Docs:** MISSING.

### C-17. I want a perspective projection with good depth precision (including an infinite far plane)
- **Means:** three constructors: standard, reversed-Z, and reversed-Z with infinite far plane, all in Vulkan clip space.
- **Mathematics:** `f = 1/tan(fovY/2)`. Standard: `m00 = f/aspect`, `m11 = -f`, `m22 = far/(near-far)`, `m23 = near far/(near-far)`, `m32 = -1`, `m33 = 0` (depth 0 near, 1 far). Reversed: `m22 = near/(far-near)`, `m23 = near far/(far-near)` (near -> 1, far -> 0). Infinite reversed: `m22 = 0`, `m23 = near` (depth `-> 0` with distance). Invalid input (fov outside `0..3.14`, non-positive aspect or planes) answers the identity.
- **Instructions:** one `tan`, 2 reciprocals, a few multiplies; use a greater-or-equal depth test and a depth buffer cleared to 0 for the reversed forms.
- **Cost:** O(1) per camera, once per frame.
- **Why this and not another:** the header says reversed depth "spends float precision where a perspective projection needs it", and the infinite variant is "the usual choice for open worlds, since nothing is ever clipped at the far end".
- **Where:** `src/core/math/mat4.axle:135-189`.
- **Docs:** MISSING.

### C-18. I want an orthographic projection (shadow maps, 2D, UI)
- **Means:** box to clip volume mapping; ordinary and reversed depth.
- **Mathematics:** `m00 = 2/(r-l)`, `m03 = -(r+l)/(r-l)`, `m11 = -2/(t-b)` (+Y down in NDC), `m13 = (t+b)/(t-b)`, `m22 = -1/(f-n)`, `m23 = -n/(f-n)`; reversed: `m22 = 1/(f-n)`, `m23 = f/(f-n)`. An empty box (any pair equal) answers the identity.
- **Instructions:** 3 reciprocals, a handful of multiplies.
- **Cost:** O(1).
- **Why this and not another:** not documented.
- **Where:** `src/core/math/mat4.axle:191-235`.
- **Docs:** MISSING.

### C-19. I want a view matrix for a camera looking at a target
- **Means:** orthonormal basis from forward and up, translation by dot products.
- **Mathematics:** `f = normalize(target - eye)`; `s = normalize(f x up)`; `u = s x f`; rows `s`, `u`, `-f`, translations `-s.eye`, `-u.eye`, `f.eye`. If `eye == target` only the translation applies; if `up` is parallel to `f`, `s = f.anyPerpendicular()`.
- **Instructions:** 2 normalisations (2 sqrt, 2 reciprocals), 2 crosses, 3 dots.
- **Cost:** O(1).
- **Why this and not another:** not documented; the degenerate fallbacks avoid NaNs.
- **Where:** `src/core/math/mat4.axle:237-266`.
- **Docs:** MISSING.

### C-20. I want the determinant and general inverse of a 4x4 (projection matrices, picking)
- **Means:** 2x2 sub-determinants ("s" and "c" terms) of the upper and lower halves, Laplace expansion, adjugate.
- **Mathematics:** `s0..s5` are the six 2x2 minors of rows 0-1, `c0..c5` of rows 2-3; `det = s0 c5 - s1 c4 + s2 c3 + s3 c2 - s4 c1 + s5 c0`; inverse entries are 3-term products of `s`/`c` terms times `1/det`. Singular (`|det| <= 1e-30`, `M4_TINY`) answers the identity; `isInvertible` asks first.
- **Instructions:** 12 two-term minors (24 multiplies), 6 for the determinant, 48 multiplies for the entries plus 16 for the scale; one reciprocal. Derived by counting.
- **Cost:** O(1). Roughly 94 multiplies in total (12 + 12 + 6 + 48 + 16, derived). The singular test is the absolute value `|det| > 1e-30` (see Doubts).
- **Why this and not another:** `inverseAffine` (C-21) is the cheaper path for non-projection matrices (doc comment `mat4.axle:362`).
- **Where:** `src/core/math/mat4.axle:338-399`.
- **Docs:** MISSING.

### C-21. I want to invert a rigid or affine transform cheaply
- **Means:** invert the 3x3 block and re-solve the translation.
- **Mathematics:** `M = [A | t]`; `M^-1 = [A^-1 | -A^-1 t]`. `Mat3.inverse` is cofactors times `1/det` (`det` threshold `M3_TINY`). Only valid when the bottom row is `0 0 0 1`.
- **Instructions:** 9 cofactors (18 multiplies) + determinant (9 multiplies) + reciprocal + 9 scale multiplies + a 3x3 vector transform.
- **Cost:** O(1), about 45 multiplies against about 94 for C-20, so roughly twice as cheap by multiply count (derived).
- **Why this and not another:** doc comment: "a projection needs `inverse`" (`mat4.axle:403-406`).
- **Where:** `src/core/math/mat4.axle:407-428`, `src/core/math/mat3.axle:119-152`.
- **Docs:** MISSING.

### C-22. I want the matrix that transforms normals correctly under non-uniform scale
- **Means:** inverse transpose of the 3x3 block.
- **Mathematics:** `N = (M^-1)^T`; equals `M` for a pure rotation, differs under non-uniform scale (file comment).
- **Instructions:** `inverse().transposed()`: cofactor inverse plus a move of 9 fields.
- **Cost:** O(1).
- **Why this and not another:** not documented.
- **Where:** `src/core/math/mat3.axle:154-157`.
- **Docs:** MISSING.

### C-23. I want to place and animate objects as translation, rotation and scale, and still get a matrix
- **Means:** `Transform` (T, Quat R, S) with `T R S` order; `mul`, `inverse`, `lerp`, `toMat4`.
- **Mathematics:** `p' = R (S p) + T`; `parent.mul(child)`: translation `parent.transformPoint(child.t)`, rotation `normalize(parent.r * child.r)`, scale `parent.s * child.s` (componentwise). `inverse`: `S^-1 = 1/s` per axis (0 stays 0), `R^-1 = conj(R)`, `t' = -(R^-1 (t S^-1))`. `lerp` is lerp of T and S, slerp of R. The TRS product is exact only for uniform scale (or quarter-turn rotations); under non-uniform scale a rotated child shears, which a TRS triple cannot represent (`transform.axle:7-10`); the exact route is `toMat4` plus `inverseAffine`.
- **Instructions:** `toMat4`: `toMat3` (9 products) then 9 scale multiplies; `mul`: one Quat product, one rotation, one normalise.
- **Cost:** O(1); 40 bytes in f32 (`Vec3` + `Quat` + `Vec3`), 80 in f64 (derived).
- **Why this and not another:** "three small parts that can be blended, instead of a 4x4 matrix that cannot" (`transform.axle:3-4`).
- **Where:** `src/core/math/transform.axle:48-118`.
- **Docs:** MISSING.

### C-24. I want to upload a matrix to the GPU without a transpose
- **Means:** write the 16 floats column-major into a caller buffer.
- **Mathematics:** `out[4 c + r] = m_rc`, the layout of a GLSL `mat4` / Vulkan uniform (header: "so the same matrix goes to the shader without a transpose").
- **Instructions:** 16 stores into a `f32[]`; the caller guarantees `offset + 16` elements.
- **Cost:** O(1), 64 bytes.
- **Why this and not another:** not documented beyond the header.
- **Where:** `src/core/math/mat4.axle:514-531`.
- **Docs:** MISSING.

### C-25. I want positions in a very large world and a renderer that does not jitter
- **Means:** keep world positions in f64; subtract the camera in f64, then narrow to f32 ("camera-relative").
- **Mathematics:** `p_local = float( p_world_f64 - camera_f64 )`. The comment gives the motivation: narrowing an absolute position directly "would lose centimetres at ten kilometres from the origin". `narrowQuat` renormalises; `widen*` is exact.
- **Instructions:** three f64 subtractions and three narrowing conversions per vector.
- **Cost:** O(1); an f64 `DVec3` is 24 bytes vs 12 (derived).
- **Why this and not another:** the project rule "f32 on hot paths, f64 for positions in the world" (CLAUDE.md) and `terrain.axle` ("a position 100 km from the origin keeps its millimetres").
- **Where:** `src/core/math/convert.axle:1-83`.
- **Docs:** MISSING.

### C-26. I want the same vector/matrix/geometry library in f64 without maintaining two copies
- **Means:** source-to-source generation: the f32 files are the source and `tools/gen_math_f64.sh` rewrites them to `d*.axle` (f32 -> f64, `T -> DT`, scalar functions to `D` twins, private constants prefixed).
- **Mathematics:** none: plain arithmetic.
- **Instructions:** n/a (a build-time script). Modules: vec2, vec3, vec4, mat3, mat4, quat, transform, geom, intersect (`gen_math_f64.sh:13`).
- **Cost:** none at run time. `frustum`, `trig`, `scalar` and `convert` are not generated (UNVERIFIED for scalar/trig: they hold their own f64 versions).
- **Why this and not another:** the script header: Axle "has no generics over number types".
- **Where:** `tools/gen_math_f64.sh:1-20`; outputs `src/core/math/dvec2.axle` ... `dintersect.axle`.
- **Docs:** CLAUDE.md and `doc/guide/architecture.md` mention the rule; the mechanism chapter is MISSING.

---

## Geometry, intersection and culling

### C-27. I want bounding boxes I can grow, merge, test and transform
- **Means:** `Aabb` (min/max corners), an `empty()` box at (+HUGE, -HUGE) so the first `expandedToPoint` yields exactly that point.
- **Mathematics:** `merged = (min(min), max(max))`; `closestPoint(p) = clamp(p, min, max)`; `volume = sx sy sz`; `surfaceArea = 2 (sx sy + sy sz + sz sx)`; `transformed(M)`: transform all 8 corners (`corner(i)` picks max on axis k when bit k of `i` is set) and re-box them, the smallest axis-aligned box of the moved box. `Sphere.enclosing(box)`: centre = box centre, radius = `|halfSize|` ("holds the box, though it is not the smallest such ball").
- **Instructions:** `transformed`: 8 affine point transforms (72 multiplies) plus 8 component min/max pairs (derived). `contains`: 6 compares.
- **Cost:** O(1) per op; `Aabb` is 24 bytes, `Sphere` 16.
- **Why this and not another:** `transformed` re-boxes all corners (exact for the rotated box); a cheaper abs-matrix form is not used (UNVERIFIED that it was considered).
- **Where:** `src/core/math/geom.axle:17-135`, `:137-164`.
- **Docs:** MISSING.

### C-28. I want the signed distance of a point to a plane, and planes from points or equations
- **Means:** unit-normal `Plane` with `n.p + d = 0`.
- **Mathematics:** `signedDistance(p) = n.p + d` (positive in front); `fromPointNormal`: `d = -n.point`; `fromTriangle`: normal `(b-a) x (c-a)` (front is counter-clockwise); `fromEquation(a,b,c,d)`: divide all four by `|(a,b,c)|`; a zero normal becomes the plane `(0,0,0,d=1)` "in front of which every point lies"; `closestPoint(p) = p - n signedDistance(p)`.
- **Instructions:** one dot + add for a distance; normalisation: one sqrt, one reciprocal, 4 multiplies.
- **Cost:** O(1), 16 bytes.
- **Why this and not another:** not documented.
- **Where:** `src/core/math/geom.axle:190-241`.
- **Docs:** MISSING.

### C-29. I want to know where a ray meets a plane, a box, a sphere or a triangle
- **Means:** four closed-form tests returning `RayHit {hit, t, u, v}`; `t` is in units of the direction's length.
- **Mathematics:**
  - plane: `t = -(n.o + d)/(n.dir)`; miss when `|n.dir| < 1e-10` (`X_TINY`) or `t < 0`.
  - box: slab method: per axis `t_near,t_far = (min-o)/dir, (max-o)/dir` swapped to be ordered, intersected into `[lo, hi]` starting from `[0, HUGE]`; parallel axes (`|dir| < X_TINY`) only test `min <= o <= max`; hit at `lo` when `lo <= hi` (so `t = 0` from inside).
  - sphere: `a = dir.dir`, `b = oc.dir`, `c = oc.oc - r^2`, `disc = b^2 - a c`; `t = (-b -+ sqrt(disc))/a`; miss if `disc < 0` or exit `< 0`; inside answers 0.
  - triangle: Moeller-Trumbore (named in the doc comment): `p = dir x e2`, `det = e1.p`, `u = (o-a).p/det`, `q = (o-a) x e1`, `v = dir.q/det`, `t = e2.q/det`; optional back-face culling (`det < X_TINY`).
- **Instructions:** plane: 1 dot, 1 dot, 1 divide; box: up to 3 reciprocals (an early exit between axes via `alive`), no branches on the hot path beyond ordering; sphere: 1 sqrt, 2 divides; triangle: 2 crosses, 3 dots, 1 reciprocal.
- **Cost:** O(1) each; no allocation ("Every test ... nothing here allocates or divides by a value that may be zero").
- **Why this and not another:** the header sets conventions: touching counts as overlapping, and a ray starting inside a solid hits it at `t = 0`.
- **Where:** `src/core/math/intersect.axle:40-151`.
- **Docs:** MISSING. The slab test for sub-cell boxes is explained in `shapes` (see C-77).

### C-30. I want fast overlap tests between boxes and balls
- **Means:** per-axis interval overlap; squared-distance compare.
- **Mathematics:** boxes overlap iff `a.min <= b.max && a.max >= b.min` on all three axes (empty boxes never overlap); balls overlap iff `|ca - cb|^2 <= (ra + rb)^2`; ball vs box iff `|c - closestPoint(c)|^2 <= r^2`.
- **Instructions:** 6 compares; or 3 subtracts + 3 multiplies + 2 adds with no sqrt.
- **Cost:** O(1).
- **Why this and not another:** squared compare avoids the root (`Vec3.distanceSquared`).
- **Where:** `src/core/math/intersect.axle:153-176`.
- **Docs:** MISSING.

### C-31. I want to cull objects against the camera cheaply and conservatively
- **Means:** six frustum planes extracted from the view-projection matrix (Gribb-Hartmann, named in the header), sphere and box tests against each plane.
- **Mathematics:** with `vp` rows `r0..r3`: left `= r3 + r0`, right `= r3 - r0`, bottom `= r3 + r1`, top `= r3 - r1`, depth0 `= r2`, depth1 `= r3 - r2` (Vulkan clip volume `-w <= x,y <= w`, `0 <= z <= w`); each normalised. A sphere is Behind a plane if `dist < -r`, Straddling if `dist < r`, else In front; a box uses its corner farthest/nearest along the plane normal (`cornerAlong`: component of `max` where `sign(n) == farthest`). Per-plane verdicts combine as the minimum (`Behind=0 < Straddling=1 < InFront=2`). Conservative: a ball just outside an edge may read `Intersecting`, but a partly visible one never reads `Outside`. Works for ordinary/reversed depth, finite/infinite far (an absent plane comes out as one that every point is in front of).
- **Instructions:** extraction: 6 normalisations (6 sqrt, 6 reciprocals); a sphere test: 6 dot products; a box test: 6 x (2 corner selections of 3 compares + 2 dot products).
- **Cost:** O(1) per object, O(n) per scene; `Frustum` is 6 `Plane` = 96 bytes. No measured figure.
- **Why this and not another:** not documented. The `Intersecting` result lets a hierarchical caller stop testing children of an `Inside` node.
- **Where:** `src/core/math/frustum.axle:55-174`.
- **Docs:** MISSING.

---

## Hashing, ids and interning

### C-32. I want a hash that is the same on every machine and run
- **Means:** FNV-1a 64 for strings and byte ranges; SplitMix64 finalizer as the integer mixer; a boost-style `hashCombine` that ends in the mixer.
- **Mathematics:** FNV: `h = offset (0xcbf29ce484222325 as the i64 -3750763034362895579)`, then per byte `h = (h xor byte) * 1099511628211` (prime `0x100000001b3`); mix: `z = x + gamma; z = (z xor (z>>>30)) * A; z = (z xor (z>>>27)) * B; return z xor (z>>>31)` with `gamma = -7046029254386353131` (equal to 0x9e3779b97f4a7c15 read as a signed 64-bit number, checked by arithmetic: 11400714819323198485 - 2^64; the multipliers likewise read as 0xbf58476d1ce4e5b9 and 0x94d049bb133111eb); `hashCombine(a,b) = hashMix(a xor (b + gamma + (a<<6) + (a>>>2)))`. Neither depends on a process seed, unlike `std`'s per-process-seeded `HashMap` (header).
- **Instructions:** FNV: 1 xor + 1 multiply per byte (serial dependency); mix: 3 xor-shifts, 2 multiplies, 1 add; all `i64` wrapping arithmetic.
- **Cost:** FNV O(bytes); mix O(1), about 6 ops. No memory. No measured figure.
- **Why this and not another:** "fixed by their definition" so a content hash on disk and a simulation both need them; used by `Map` for integer keys.
- **Where:** `src/core/id/hash.axle:10-56`.
- **Docs:** MISSING.

### C-33. I want a generational handle so a stale reference can be detected
- **Means:** `EntityId {index, generation}`, 64-bit packable with `bits()`/`fromBits`.
- **Mathematics:** `bits = (generation << 32) | (index & 0xFFFFFFFF)`; `none = {-1, 0}`; `isNone = index < 0`. A slot's generation rises on each retirement, so an old id no longer equals the new tenant's.
- **Instructions:** one shift and one mask to pack; two compares to compare.
- **Cost:** O(1), 8 bytes. `i64` bits are used as map keys (`Map<i64,...>`).
- **Why this and not another:** header: Axle 0.18.3 cannot build a typed `Handle<T>`, so one id type serves all.
- **Where:** `src/core/id/entity_id.axle:9-51`.
- **Docs:** MISSING.

### C-34. I want ids that are reproducible: same calls, same ids
- **Means:** `IdAllocator`: slot numbers dense from 0, retired slots on a stack (last-freed-first), generation +1 on destroy, wrap skips 0.
- **Mathematics:** none: plain arithmetic. Generation starts at 1 so a zeroed id never names a live slot; `next = gen + 1; if next <= 0 then 1`.
- **Instructions:** `create`: one `Vec.push` or `pop`; `isAlive`: one bound check, two `Vec.get`.
- **Cost:** O(1) amortised per call; memory per slot: 4 (generation) + 1 (alive) + 4 (retired stack entry while free) bytes (derived from the three `Vec`s).
- **Why this and not another:** "the sequence of ids depends only on the order of `create` and `destroy` calls" (`id_allocator.axle:3-5`).
- **Where:** `src/core/id/id_allocator.axle:14-80`.
- **Docs:** MISSING.

### C-35. I want a small integer instead of a string for names, tags and paths
- **Means:** `StringInterner` (`HashMap<string,i32>` + `ArrayList<string>`), first-seen numbering; `StringId.raw`.
- **Mathematics:** none: plain arithmetic. Ids depend only on first-seen order, so they are the same on every run; the `HashMap` is only asked for single keys, never walked, "so its per-process seed cannot show in the ids".
- **Instructions:** `intern`: one hash lookup, possibly one insert and one append; `name(id)`: bounds check + list read.
- **Cost:** O(1) expected per call; memory per distinct text: the string twice (key and list; UNVERIFIED that `std` shares the bytes). Texts are never forgotten.
- **Why this and not another:** `Vec`/`Map` cannot hold strings in Axle 0.18.3 (generic arrays of strings double-free on growth).
- **Where:** `src/core/id/string_id.axle:37-75`.
- **Docs:** MISSING.

---

## Collections

### C-36. I want a growable array of numbers or plain structs
- **Means:** `Vec<T>` over a `malloc`'d `T[]`, doubling growth, never shrinking.
- **Mathematics:** capacity doubles when full (`grow(room * 2)`), so a push is amortised O(1) (total copy work < 2 n for n pushes: standard doubling argument, not stated in the code).
- **Instructions:** push: one compare, store; grow: copy loop of `len` elements; removal forms: `swapRemove` (O(1), order changes) and `removeAt` (O(n) shift); `reserve(n)` pre-sizes. Index failures abort via `panicMsg`; `getOr`/`popOr`/`has` ask first.
- **Cost:** O(1) amortised push/pop/get; `removeAt` O(n); memory `capacity * sizeof(T)`, up to 2x the live size. `T` may not be a `string` or class (compile-time refusal).
- **Why this and not another:** `std`'s `ArrayList<T>` "cannot hold a struct of ours as a field or a parameter" (header).
- **Where:** `src/core/collections/vec.axle:22-199`.
- **Docs:** MISSING.

### C-37. I want a map keyed by integer, with a stable and visible iteration order
- **Means:** insertion-ordered open-addressing hash map: entries in parallel arrays (`keys`, `values`, `live` byte), probe table of entry indices (`i32`), linear probing, mixer `hashMix`.
- **Mathematics:** probe `p = hashKey(key) & mask`, then `p = (p+1) & mask` until an empty cell; table size = 2 x entry capacity (a power of two), so occupancy is at most 1/2 counting removed entries; `hashKey` for `i32`/`i64` is `hashMix` (C-32). `remove` marks the entry dead and leaves its table cell; `rebuild` (when the entry array is full) squeezes out dead entries keeping order and doubles capacity only if more than half are live (`count*2 > room`).
- **Instructions:** lookup: hash (about 6 ops), mask, loop reading `table[p]` then `live[e]`, `keys[e]`; iteration walks `0..used` skipping dead slots. Slots are valid until the next `put` of a new key or `clear`.
- **Cost:** find/put/remove O(1) expected; iteration O(used) (includes dead slots); `clear` O(used + table cells) because it resets the table. Memory per entry slot for `Map<i64,i32>`: 8 + 4 + 1 + 2 x 4 = 21 bytes (derived). Replacing a value keeps its position; remove then re-put moves it to the end.
- **Why this and not another:** `std::HashMap` "is seeded per process and iterates keys only, so what a game does with it can differ from one run to the next" (header).
- **Where:** `src/core/collections/map.axle:40-262`.
- **Docs:** MISSING.

### C-38. I want the same map for string keys
- **Means:** `StringMap<V>` = private `StringInterner` + `Map<i32,V>`.
- **Mathematics:** none: plain arithmetic (string -> small number -> C-37).
- **Instructions:** `find`: one `std` hash lookup for the id then a `Map.find`; `put` interns first.
- **Cost:** O(1) expected per op; a removed key's text stays in the interner ("a few bytes"), so memory is monotone in distinct keys ever put.
- **Why this and not another:** `Map` cannot hold strings.
- **Where:** `src/core/collections/string_map.axle:13-105`.
- **Docs:** MISSING.

### C-39. I want a stack-friendly handle-addressed pool where stale handles are caught
- **Means:** `Slab<T>`: `IdAllocator` for ids + `T[]` slots addressed by index, doubling.
- **Mathematics:** none: plain arithmetic. Slots never move; free slots are reused most-recently-freed first; iterate `0..slotCount()` with `isLiveAt`.
- **Instructions:** insert: allocator create + store (+ one doubling when the slot index equals capacity); get: an `isAlive` check then an array read.
- **Cost:** O(1) amortised; a removed value's bytes stay until the slot is reused (so an owning `T` keeps its memory until then).
- **Why this and not another:** a `Vec` would shift indices; a generation makes a dangling id detectable instead of silently reading the new tenant.
- **Where:** `src/core/collections/slab.axle:21-124`.
- **Docs:** MISSING.

### C-40. I want to iterate every item with a component quickly, and look one up by entity index in O(1)
- **Means:** `SparseSet<T>`: dense arrays `keys`/`values` + a `sparse` index array indexed by key.
- **Mathematics:** invariant `dense[sparse[k]] == k` for present `k`; `remove` swap-moves the last dense element into the hole and fixes `sparse[lastKey]`. Keys must be small non-negative (the sparse array is as long as the largest key seen).
- **Instructions:** has/get: two bounds checks and one indirection; insert: grow `sparse` with `-1` fill up to the key, push key and value; iteration is a contiguous `0..len()`.
- **Cost:** O(1) per op; memory `4 x (maxKey + 1) + 4 x n + sizeof(T) x n` bytes (derived from the three `Vec`s). Order after a removal is still a pure function of the call sequence.
- **Why this and not another:** "The classic ECS component store" (header); a hash map would iterate scattered and cost a hash per lookup.
- **Where:** `src/core/collections/sparse_set.axle:16-125`.
- **Docs:** MISSING.

### C-41. I want a fixed-capacity queue with no allocation in steady state
- **Means:** `Ring<T>`: circular buffer, `push` refuses when full, `pushOverwrite` drops the oldest; `get(0)` is the oldest.
- **Mathematics:** slot of age `i` is `(head + i) mod room`, done as one conditional subtract (no `%`).
- **Instructions:** one add, one compare, one subtract per access.
- **Cost:** O(1) all ops; memory `capacity x sizeof(T)`, fixed at construction.
- **Why this and not another:** for "input events, a trail of recent positions, a frame-time history" (header); the caller chooses between refusing and overwriting.
- **Where:** `src/core/collections/ring.axle:11-117`.
- **Docs:** MISSING.

### C-42. I want a priority queue whose pop order is fully determined
- **Means:** binary min-heap keyed by `i64`, ties broken by push sequence number (FIFO among equal keys).
- **Mathematics:** parent of `i` is `(i-1)/2`, children `2i+1`, `2i+2`; ordering `(key, serial)` lexicographic. Floats must be quantised to `i64`; a max-heap pushes the negated key.
- **Instructions:** `push`: three `Vec.push` + sift-up of swaps over three parallel arrays; `pop`: `swapRemove(0)` on each array + sift-down; `before` compares key then serial.
- **Cost:** O(log n) push/pop, O(1) peek; memory `16 + sizeof(T)` bytes per element (keys + serials + values, derived).
- **Why this and not another:** closures capture only scalars and traits cannot be called through a generic free function, so ordering is data (header). The serial makes the pop order independent of heap layout.
- **Where:** `src/core/collections/heap.axle:17-144`.
- **Docs:** MISSING (`doc/guide/names.md` lists the name only).

### C-43. I want a set of small integers with fast bulk operations
- **Means:** `BitSet` over `Vec<i64>` words (64 bits each): `set`/`unset`/`has`, `count` by `popcount64`, `nextSet` by `trailingZeros64`, `unionWith`/`intersectWith`/`subtract` a word at a time.
- **Mathematics:** word `bit >> 6`, mask `1 << (bit & 63)`; `nextSet(from)`: mask the first word with `~0 << (from & 63)`, then scan whole words.
- **Instructions:** shifts/masks; `popcount` and trailing-zero count intrinsics; no division.
- **Cost:** set/has O(1); count and set operations O(n/64); memory n/8 bytes.
- **Why this and not another:** "flags per entity, visited marks, component masks" (header).
- **Where:** `src/core/collections/bitset.axle:29-152`.
- **Docs:** MISSING.

### C-44. I want to store many small integers (palette indices, ids) in as few bits as they need
- **Means:** `PackedCells`: `bits` per entry in `u64` words; entries never span two words.
- **Mathematics:** `per = 64 / bits`; cell `i` is in word `i / per` at shift `(i mod per) * bits`; mask `(1<<bits) - 1`. 4 bits: 16 per word; 5 bits: 12 (4 bits of padding); 15 bits: 4. `bitsFor(n, minBits)`: the smallest `bits >= minBits` with `2^bits >= n`.
- **Instructions:** `get`: three integer divisions by a runtime value (`64 / bits`, `i / per`, `i % per`; `REVIEW_CORE:191`), shift, mask; `set`: the same plus a read-modify-write of the word (`& ~(mask << shift) | v << shift`). C-45 removes the divisions.
- **Cost:** O(1) per cell; memory `ceil(cells / per) * 8` bytes. Measured (`REVIEW_CORE`): "PackedCells.get/set with a constant width 2490 / 1035 Mcells/s ... LLVM folds the division when the width is a constant" (`doc/handbook/history/core-review.md:304`).
- **Why this and not another:** one definition of the layout "so they cannot disagree about where entry `i` lives" (header).
- **Where:** `src/core/collections/packed_cells.axle:45-92`.
- **Docs:** MISSING as a chapter; measurements only in `REVIEW_CORE` and `CORE_EXTRACTION`.

### C-45. I want to find the word and bit of a packed cell without an integer divide
- **Means:** a precomputed reciprocal `PackedLayout.magic = floor(2^32 / per) + 1`; `word = (i * magic) >> 32`.
- **Mathematics:** `i / per == (i * (floor(2^32/per) + 1)) >> 32` for every `i < 2^26` (`PACKED_FAST_LIMIT = 67108864`); above that the code divides. The limit is stated in the code; the proof is not written down. Derived here: `magic = 2^32/per + e` with `0 < e <= 1`, so `i*magic/2^32 = i/per + i e/2^32`, and the floor stays right while `i e/2^32 < 1/per`, i.e. `i < 2^32/per`; with `per <= 64` (1-bit entries) that is `i < 2^26`, matching the constant. The shift is `(i - word*per) * bits`.
- **Instructions:** one 64-bit multiply, one shift, one multiply-subtract; branch on `i < limit`.
- **Cost:** O(1). Measured (`REVIEW_CORE`): `PalettedPool.get` 5-bit palette 1020 -> 1390 Mcells/s with `PackedLayout` ("multiply instead of divide, exact below 2^26 cells, divide above") (`doc/handbook/history/core-review.md:300`).
- **Why this and not another:** `hot-loop` R1: an integer divide is "20 to 40 cycles, more than a ray step"; "a division by a constant is fine: the compiler turns it into a multiplication" - here the width is a runtime value so the constant is built once.
- **Where:** `src/core/collections/packed_cells.axle:30-42`, `:66-75`, `:94-115`.
- **Docs:** `hot-loop` R1 explains the rule; the magic-number construction is MISSING.

### C-46. I want to pack and unpack a whole run of cells without any per-cell division
- **Means:** word-at-a-time loops: `packRun` (through a palette map), `packValues` (raw), `unpackRun`.
- **Mathematics:** for each destination word, OR `per` entries shifted by `k * bits`; `unpackRun` peels `bits` at a time from each word with `word >>= bits`.
- **Instructions:** one shift per entry, one store per word; no divide.
- **Cost:** O(cells). Measured (`REVIEW_CORE`): `PalettedPool.pack` 1380 -> 1790 Mcells/s with `packValues` (`doc/handbook/history/core-review.md:302`); `expand` 2020 vs 1800 Mcells/s (slower, "not understood", `:303`).
- **Why this and not another:** the same bytes `set` would write, without `set`'s division (header).
- **Where:** `src/core/collections/packed_cells.axle:117-199`.
- **Docs:** `REVIEW_CORE` only.

### C-47. I want many small paletted containers (voxel sections) without an object each
- **Means:** `PalettedPool`: per container five small numbers (bits, single value, palette start/size, data start) in struct-of-arrays, plus two shared growable pools (`u16` palette, `u64` data); three forms: single (bits 0, no pool space), paletted (`minBits..maxPaletteBits`, default max 8), direct (`directBits`, up to 16).
- **Mathematics:** palette capacity `2^b` entries per paletted container; data `ceil(cells / (64/b))` words. For the header's 4096-cell sections (derived): 4 bits = 256 words = 2048 B + 32 B palette; 8 bits = 512 words = 4096 B + 512 B palette; direct 16 bits = 1024 words = 8192 B. Per-container fixed cost `PALETTED_PER_CONTAINER = 13` bytes (u8 + u16 + i32 + u16 + i32). Garbage in the pools is compacted only when `garbage >= 256` and `garbage*2 >= used` (else pools double).
- **Instructions:** `get`: form branch, `PackedCells.getIn` (multiply instead of divide), a palette read; `set` on a paletted container: tries the last `(container, value)` hit before a linear `indexOf` over up to 256 entries; a full palette triggers `grow`.
- **Cost:** `get` O(1); `set` O(palette) worst, O(1) on a run; `grow` O(cells) with an 8 KB `u16[cells]` allocation per call (`REVIEW_CORE:236` and `:310`, still true at `paletted_pool.axle:390-428`); `bytesUsed`/`bytesReserved` report live and allocated bytes. Measured (`REVIEW_CORE`): `set` incl. growth 112 -> 143-160 Mcells/s (`:301`).
- **Why this and not another:** "an object with its own palette array and data array costs a few hundred bytes for a section that is nothing but air" (header).
- **Where:** `src/core/collections/paletted_pool.axle:1-134`, `:168-181`, `:327-373`, `:651-663`.
- **Docs:** `REVIEW_CORE` / `CORE_EXTRACTION` (move log) only.

### C-48. I want to convert a flat array of states to the smallest container form, and back
- **Means:** `pack` (scratch map from state id to palette position, first-seen order), `expand`/`expandAt`, `prepareWrite`, `load` from a disk form.
- **Mathematics:** `pack`: one pass builds `list` and `map` (`map[v] < 0` means new); `distinct == 1` -> single; `> 2^maxPaletteBits` -> direct; else `bits = bitsFor(distinct, minBits)`. `load`: validates the palette index range by scanning words (skipped when the palette fills its width: `paletteCount == 1<<b`); damage turns the container into its first palette state; a width outside `minBits..maxPaletteBits` is re-expressed cell by cell through `pack` (`loadWide`, which allocates a new `PalettedScratch` of `1 << directBits` entries per call).
- **Instructions:** `expandAt` hoists `per` and the mask, peels `bits` from each word and maps through the palette; `pack` resets only the touched entries of the shared scratch map afterwards.
- **Cost:** O(cells) each; `PalettedScratch` memory: `4 x idRange + (2 + 8 + 2) x cells` bytes (derived: `i32 map`, `u16 list`, `u64 longs`, `u16 flat`).
- **Why this and not another:** "one per thread" scratch avoids allocation per call.
- **Where:** `src/core/collections/paletted_pool.axle:44-76`, `:430-511`, `:516-648`.
- **Docs:** `REVIEW_CORE` only.

### C-49. I want a bump allocator for per-frame scratch
- **Means:** `Arena`: one `calloc`'d block, a cursor, `alloc(bytes, align)` returns a byte offset (or -1), `mark`/`rewindTo`, `reset`.
- **Mathematics:** `start = (cursor + align - 1) & ~(align - 1)` for a power-of-two `align`; fails when `start + bytes > size`.
- **Instructions:** one add, one mask, one compare per allocation; typed accessors are bounds-checked per access (`check`). `reset` is a `memset` of the used prefix.
- **Cost:** alloc O(1); reset O(used); memory fixed at construction. The block cannot grow because "growing would move memory that earlier offsets name".
- **Why this and not another:** `REVIEW_CORE:241-246` records that the arena is used only by its test and recommends deleting it in favour of typed per-worker scratch members (decision left to the user); see Doubts.
- **Where:** `src/core/mem/arena.axle:24-199`.
- **Docs:** `REVIEW_CORE` section "What the compiler does for allocation, and `Arena`".

---

## Random numbers and noise

### C-50. I want deterministic random numbers per system, replayable and seedable
- **Means:** `Pcg32`, the PCG-XSH-RR 64/32 generator (named in the header, M.E. O'Neill); explicit `seed` and `stream`.
- **Mathematics:** LCG `state' = state * 6364136223846793005 + inc` with `inc = (stream << 1) | 1` (so there are `2^63` streams per seed); output from the old state: `xorshifted = (((s >>> 18) xor s) >>> 27) as u32`, `rot = s >>> 59`, result `rotr(xorshifted, rot)`. Construction: `step; state += seed; step`. The reference sequence of `new Pcg32(42, 54)` begins `0xa15c02b7, 0x7b47f409` (test-pinned per the header).
- **Instructions:** one 64-bit multiply-add per draw, two shifts, one xor, one rotate; no memory but 16 bytes of state.
- **Cost:** O(1) per draw. No timing figure.
- **Why this and not another:** a 128-bit Pcg64 is "not offered: Axle has no 128-bit integer". No global generator and no clock seeding: "where a seed comes from is a decision of the caller".
- **Where:** `src/core/rng/pcg32.axle:25-57`.
- **Docs:** `determinism` section 2.1 (general policy; UNVERIFIED that it explains Pcg32 itself).

### C-51. I want unbiased random integers in a range and a fair shuffle
- **Means:** rejection sampling (`nextBelow`), `range`, Fisher-Yates `shuffle` (named in the doc comment), `permutation`.
- **Mathematics:** `threshold = (2^32 - bound) mod bound = 2^32 mod bound`; redraw while `r < threshold`; result `r mod bound`. The rejection probability is `threshold / 2^32 < bound / 2^32` (derived), at most 1/2. `range(lo,hi) = lo + nextBelow(hi - lo)` with width computed in `i64`. Shuffle: `for i = n-1 down to 1: swap(items[i], items[nextBelow(i+1)])`.
- **Instructions:** one `u32` modulo for the threshold and one for the result (two integer divisions per call: this is not a hot-loop primitive); shuffle: `n-1` draws.
- **Cost:** `nextBelow` expected under 2 draws; shuffle O(n); `permutation` allocates `n` `i32`.
- **Why this and not another:** "without modulo bias" (doc comment).
- **Where:** `src/core/rng/pcg32.axle:77-125`.
- **Docs:** MISSING.

### C-52. I want uniform floats in [0,1) that never reach 1.0
- **Means:** take the top 24 bits (f32) or 53 bits (f64) and scale by `2^-24` / `2^-53`.
- **Mathematics:** `nextF32 = (u32 >>> 8) * 2^-24` (every value exactly representable); `nextF64 = ((u64) >>> 11) * 2^-53`; `rangeF32(lo,hi) = lo + (hi - lo) f`.
- **Instructions:** a shift, an integer-to-float convert, one multiply. `nextF64` consumes two 32-bit draws.
- **Cost:** O(1).
- **Why this and not another:** "1.0 never occurs" is stated in the doc comment (`pcg32.axle:60`).
- **Where:** `src/core/rng/pcg32.axle:16-21`, `:63-70`, `:100-103`.
- **Docs:** MISSING.

### C-53. I want deterministic "random" per lattice point, cell or pixel with no stored state
- **Means:** hash the coordinates and a seed with the SplitMix64 finalizer and use the bits; or seed a `Pcg32` from the hashed coordinates.
- **Mathematics:** lattice corner (noise): `h = x*73856093 xor y*19349663 xor seed*2654435761`; `corner = (hashMix(h) >>> 40) * 2^-24` in [0,1). World cell: `h = hashCombine(hashCombine(seed, cx), cz)`; `Pcg32(hashMix(h), stream = 17)` (the same cell gives the same content whichever way the player arrived).
- **Instructions:** three multiplies and xors, then the 6-op mix; no table.
- **Cost:** O(1), no memory.
- **Why this and not another:** order-independence: "the order cells are visited in changes nothing, and a world needs no storage beyond its seed" (`partition.axle:11-13`).
- **Where:** `src/core/field/lux_noise.axle:26-31`, `src/openworld/partition.axle:202-203`.
- **Docs:** `determinism` (policy) and `view-layers` for the noise corner (UNVERIFIED that it names the constants).

### C-54. I want smooth 2D noise with its exact derivative
- **Means:** value noise on a unit lattice with a cubic fade and an analytic gradient (`luxNoise2`).
- **Mathematics:** corners `a,b,c,d` hashed at (ix,iy), (ix+1,iy), (ix,iy+1), (ix+1,iy+1) in [0,1); `s(t) = t^2 (3 - 2t)`, `s'(t) = 6 t (1 - t)`; `top = a + (b-a) s(fx)`, `bottom = c + (d-c) s(fx)`, `n = top + (bottom - top) s(fy)`; `dn/dx = s'(fx) ((b-a) + ((d-c) - (b-a)) s(fy))`, `dn/dy = s'(fy)(bottom - top)`. The slope is at most `1.5` per lattice cell (`|s'| <= 1.5`, corners in [0,1)), exported as `LUX_NOISE_SLOPE`, the Lipschitz bound a domain warp needs.
- **Instructions:** 4 hashes, 2 `floor`s (integer truncation with a fix-up for negatives), about 20 multiplies; the value and two derivatives are written into a caller `f32[]` ("a struct built per call is not kept in registers", F14).
- **Cost:** O(1) per sample; "a gradient costs a few multiplies more than the value, not two more evaluations" (header). Measured: a field node "a noise octave 4 hashes" (`view-layers` section 5).
- **Why this and not another:** exact gradients let a normal or a bend be taken from a composition without finite differences.
- **Where:** `src/core/field/lux_noise.axle:1-66`.
- **Docs:** `view-layers` sections 3.2-3.3 and 5 (`doc/handbook/render/15-view-layers.md`).

### C-55. I want to describe a wobbling quantity (a swirl, heat haze, wind) as data and evaluate it with its gradient at every hit
- **Means:** `LuxFieldTape`: a DAG of ops (`Point`, `Scale`, `Scroll`, `Warp`, `Pixelate`, `Fbm`, `Const`, `Add`, `Mul`, `Remap`) built in dependency order and evaluated flat, forward-mode differentiation through a Jacobian.
- **Mathematics:** a point node carries `(x, y, footprint, J = [[j00,j01],[j10,j11]], base footprint)`, a value node `(v, dv/du, dv/dv)`. `Scale k`: all of `x, y, J` times `k`, footprint times `|k|`. `Warp(p, a, b, amount)`: `x' = x + amount (a - 1/2)`, `y' = y + amount (b - 1/2)`, `J' = J + amount [[da/du, da/dv],[db/du, db/dv]]`. `Fbm`: sum of octaves `sum amp_i (keep_i n_i + (1 - keep_i)/2)` times `1/sum amp_i`, with gradient `(gx j00 + gy j10, gx j01 + gy j11)` weighted likewise. `Mul`: product rule `(a'b + ab')`. Lacunarity `2.03` ("not exactly 2, so the lattices never line up"); octaves 1 to 8; per octave seed `seed + 31 o`.
- **Instructions:** nodes in ascending order, a `match` over the op code per node into free functions; registers `LUX_FIELD_SLOT = 8` floats per node in one `f32[]` per worker; `evaluate` binds the tape arrays to locals once ("a store through `r` could change them for all the compiler knows"); `prepare` packs flat arrays when nodes were added and computes scroll offsets once per frame.
- **Cost:** O(nodes) per hit plus 4 hashes per octave; memory 8 floats per node per worker (32 B) plus 4 constants per node on the tape; "the portal ... 112 ns a hit, one thread; 14 nodes, 448 bytes a worker" (`view-layers` section 5).
- **Why this and not another:** a DAG "by construction" (a node can only name earlier nodes) needs no compiler or cycle check; a trait per node would add dispatch. Domain warping is credited to Quilez in the op comment.
- **Where:** `src/core/field/lux_field.axle:1-35`, `:111-470`, `:496-623`.
- **Docs:** `view-layers` (`doc/handbook/render/15-view-layers.md`).

### C-56. I want a field that does not alias when a pixel covers many noise cells
- **Means:** per-octave footprint fade: an octave finer than the pixel's footprint is replaced by its mean 1/2.
- **Mathematics:** `keep = 1 - smoothstep(1, 4, fp * freq)`; contribution `amp (keep n + (1 - keep) 1/2)`; the gradient is weighted by `keep`. A warp widens the footprint by `|amount| * bound * baseFootprint` where `bound = max(Lipschitz(a), Lipschitz(b))`; the exact bound for two fields would be `sqrt(La^2 + Lb^2)` "up to sqrt 2 times more when both slopes line up", so a strongly warped field "filters a little less than it should" (kept as is because the portal and the regress pins are tuned on it, `lux_field.axle:17-21`). A build-time Lipschitz bound `lip` is stored per node: `Scale` `|k| lip(p)`, `Add`/`Mul` sum, `Remap` `|hi-lo| lip`, `Fbm` `lip(p) * sum(amp |freq| 1.5) / sum(amp)`.
- **Instructions:** one `smoothstep` per octave; an octave with `keep == 0` skips its noise evaluation entirely.
- **Cost:** O(octaves kept); fine octaves are free.
- **Why this and not another:** "as the water taught" (header; ocean cascades use the same fade). The `Mul` bound assumes both operands in [0,1].
- **Where:** `src/core/field/lux_field.axle:12-21`, `:198-208`, `:227-258`, `:550-604`.
- **Docs:** `view-layers` section 3.3 (the footprint is stated safe there, line 56 of that file, by `|p'(x)-p'(y)| <= (1+sL)|x-y|`).

### C-57. I want a scrolling field that does not drift after hours of play
- **Means:** compute each scroll offset once per frame in f64 and wrap it by 4096 units.
- **Mathematics:** `offset = wrap4096(velocity * seconds)` in f64, `wrap(x) = x - floor(x/4096) * 4096`; one add of an `f32` per point. An f32 clock's step "is a quarter of a millisecond after an hour, and grows" (header).
- **Instructions:** per frame per scroll node: 2 f64 multiplies and wraps; per point: one add.
- **Cost:** O(scroll nodes) per frame; a jump every `4096 / speed` seconds (over two hours at 0.5 units a second).
- **Why this and not another:** the f32-clock alternative is the failure mode quoted above.
- **Where:** `src/core/field/lux_field.axle:22-23`, `:34-36`, `:318-330`, `:486-494`.
- **Docs:** `view-layers` section 3.4.

---

## Jobs, time, profiling and logging

### C-58. I want to run a loop on all cores and get identical results with 1 or N workers
- **Means:** `JobPool` + `RangeKernel`: the loop `[0, count)` is cut into chunks of `grain` consecutive items; a shared atomic cursor hands out chunks; the kernel writes only at its own indices.
- **Mathematics:** chunk `c` covers `[c*grain, min(count, (c+1)*grain))`; `chunks = ceil(count / grain)`; the cut depends on `count` and `grain` alone, never on the thread count or scheduling. Determinism contract: write only inside your range (or your chunk's slot `begin/grain`), read only what no chunk writes.
- **Instructions:** `run`: set `total`, `grain`, `cursor = 0`; send one `GO` token per helper (`min(workers, chunks)`); each worker loops `chunk = cursor.incrementAndGet() - 1` until `>= chunks`; the caller waits for as many reports. Kernel and gate are `Shared`.
- **Cost:** `run` O(chunks) atomics + O(workers) channel messages. Measured (`job-pool` and header): channel op about 5 microseconds, atomic increment 6 nanoseconds; "2000 empty loops of 180 chunks on 23 workers: 35 microseconds a loop"; idle 4 s: 0.00 s of processor time; pure arithmetic scales 15.3x on 23 workers (Ryzen 9 9900X: 12 cores / 24 threads), frame trace + fill 6.4x; the next 11 workers over 12 give 12 percent.
- **Why this and not another:** "tokens and an atomic cursor rather than one channel message per chunk" (header). `runSerial` is the reference a parallel run must match.
- **Where:** `src/core/jobs/kernel.axle:19-75`, `src/core/jobs/pool.axle:38-168`.
- **Docs:** `job-pool` (`doc/handbook/engine/01-job-pool.md`), `determinism` section 2.3.

### C-59. I want a good chunk size and a parallel-for over a component store
- **Means:** `FanOut.grainFor`: about four chunks per worker, never below `minGrain`.
- **Mathematics:** `grain = max(count / (workers * 4), minGrain, 1)`; `FAN_CHUNKS_PER_WORKER = 4`. `job-pool` rule 4: a chunk should be "a few hundred microseconds".
- **Instructions:** one integer divide per call (not per item); `forCount` calls `pool.run`.
- **Cost:** O(1) to choose; a worker count of 0 or less means `cpuCount() - 1`.
- **Why this and not another:** four chunks a worker gives load balancing without many atomics (UNVERIFIED reasoning; the code states the constant only).
- **Where:** `src/runtime/fan_out.axle:14-51`; `src/core/jobs/pool.axle:109-112`.
- **Docs:** `job-pool` section 6 (kernel rules).

### C-60. I want a fixed simulation step with smooth rendering at any frame rate
- **Means:** `FixedStep`: integer-nanosecond accumulator, whole steps released, fraction `alpha` for interpolation, spiral-of-death cap.
- **Mathematics:** `banked += frameNanos` (capped at `maxBanked = stepNanos * maxStepsPerFrame`, the excess counted in `droppedNanos`); `takeStep` while `banked >= stepNanos`; `alpha = banked / stepNanos` in [0, 1); `atHertz(h)`: `stepNanos = 10^9 / h` (integer division, so a step like 1/60 s is rounded to whole nanoseconds). Integers make the step count "exact and the same on every machine".
- **Instructions:** compares and subtracts on `i64`; one f64 divide for `alpha`.
- **Cost:** O(1) per call, 40 bytes of state.
- **Why this and not another:** physics stability and exact replays (header); the cap drops real time instead of owing more steps each frame.
- **Where:** `src/core/time/fixedstep.axle:26-100`.
- **Docs:** MISSING (the usage block is in the file header).

### C-61. I want a cooldown or spawn timer that behaves the same in a replay
- **Means:** `Timer` counts integer nanoseconds of simulation time; one-shot or repeating.
- **Mathematics:** `advance(dt)`: if `dt < left` subtract; else for repeating: `over = dt - left`, `extra = over / length`, `left = length - over mod length`, returns `1 + extra` expiries. `fraction = 1 - left/length`.
- **Instructions:** one division and one modulo only when a period ends.
- **Cost:** O(1) regardless of how many periods one `dt` spans.
- **Why this and not another:** driven by the fixed step instead of a clock (header).
- **Where:** `src/core/time/timer.axle:10-66`.
- **Docs:** MISSING.

### C-62. I want real time for profiling and frame pacing, and nowhere else
- **Means:** `nowNanos()` = `monotonicNanos`; `Stopwatch` with `lap`; `secondsToNanos` rounds to nearest, negative counts as 0.
- **Mathematics:** `nanos = (seconds * 1e9 + 0.5) as i64`; durations are `i64` nanoseconds (292 years of range).
- **Instructions:** one clock read; `lapAt(now)` lets tests supply a clock.
- **Cost:** O(1).
- **Why this and not another:** this file is "the entire wall clock surface of the engine and easy to audit" (header); nothing in the simulation may call it.
- **Where:** `src/core/time/clock.axle:11-87`.
- **Docs:** `determinism` (UNVERIFIED that it names `clock`).

### C-63. I want to see where a frame's time goes without allocating
- **Means:** `Profiler`: scoped `begin`/`end` into a preallocated ring of frames; `endFrame` folds samples into one line per scope, ranked by inclusive time.
- **Mathematics:** inclusive = `end - start`; self = inclusive minus `childTime` (a child adds its length to its parent's `childTime`); ranking by insertion sort descending, ties keep the lower scope id first (deterministic). A scope deeper than 64 loses parent attribution.
- **Instructions:** off: `begin` is one flag test returning -1, `end(-1)` one compare (per the header; but see Doubts for `beginFrame`); on: two clock reads and four array stores per scope.
- **Cost:** memory `frames x samplesPerFrame x 28` bytes (i32 + 3 i64, derived); `summarise` O(samples + scopes); insertion O(scopes^2) worst. The game loop's profiler: 8 scopes, 8 frames, 16 samples = 3584 B (derived from `game_loop.axle:33-35`).
- **Why this and not another:** "profiling never allocates and the history of the last N frames is always there" (header).
- **Where:** `src/core/profile/profiler.axle:29-273`, `src/core/profile/names.axle:10-60`, `src/core/profile/entry.axle`.
- **Docs:** `doc/spec/rendering.md` mentions `Profiler` (UNVERIFIED depth); the mechanism chapter is MISSING.

### C-64. I want leveled logs I can read back in-engine, with no wall-clock stamps
- **Means:** `Logger<S : LogSink>` with a threshold, a record sequence number and a frame number; sinks `StdoutSink`, `MemorySink` (ring), `TeeSink`.
- **Mathematics:** none: plain arithmetic. Records are numbered by a counter and stamped by the frame, so two runs of the same simulation write the same log; `MemorySink.at(i)` reads slot `(next - size + i + slots) mod slots` (oldest first).
- **Instructions:** `enabled(level)` lets the caller skip building a message; `MemorySink` copies the two strings (`+ ""`) because a record's text is only borrowed.
- **Cost:** O(1) per record; `MemorySink` memory: `capacity` x (2 strings + 4 + 8 + 8) and never reallocates.
- **Why this and not another:** `Logger` is generic over its sink because Axle cannot store a class in a trait-typed field (E0709); parallel arrays because containers of structs holding strings are rejected (header).
- **Where:** `src/core/log/logger.axle:12-89`, `src/core/log/memory.axle:13-91`, `src/core/log/sink.axle`.
- **Docs:** MISSING.

---

## World: entities, components, scenes

### C-65. I want entities that can be created, destroyed and checked for life
- **Means:** `World` over `IdAllocator` (C-34): existence only.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** see C-34.
- **Cost:** O(1) per op.
- **Why this and not another:** "this file owns existence and nothing else, so a store can ask 'is this still alive' without knowing about transforms or names" (header).
- **Where:** `src/world/world.axle:13-50`.
- **Docs:** MISSING.

### C-66. I want to store a component per entity densely and skip dead entities safely
- **Means:** `ComponentStore<T>` = `SparseSet<T>` of values + `SparseSet<i32>` of the generation each had when it got its component; `sweep` drops dead entities' components.
- **Mathematics:** a component belongs to `id` iff `lives[id.index] == id.generation` and `world.isAlive(id)`. `sweep` walks the dense array from the end so swap-removes do not skip elements.
- **Instructions:** `has`: alive check + one sparse lookup; `get` skips the check (join callers already did it).
- **Cost:** O(1) per op; `sweep` O(n); memory two sparse sets: about `4 x (maxIndex+1) x 2 + (4+4+sizeof(T)+4) x n` bytes (derived).
- **Why this and not another:** a destroyed entity's component stays until `sweep`, but `has`/`getOr` already refuse it (header).
- **Where:** `src/world/store.axle:14-109`.
- **Docs:** MISSING (`doc/spec/rendering.md` mentions it; UNVERIFIED depth).

### C-67. I want every entity that has components A and B (and C)
- **Means:** `Join2`/`Join3`: walk the smaller store's dense array and test the other(s) with `has`.
- **Mathematics:** cost follows the rarest kind: `Join2` chooses which store to walk at construction by `sizeB < sizeA`; `Join3` walks the first store, which the caller must make the smallest ("by contract").
- **Instructions:** a cursor `at` over `0..len`, `a.has(world,e) && b.has(world,e)`; the join holds only a position so stores can be mutated through `setValueAt`/`set` while joining; add/remove/sweep during a join is unsupported.
- **Cost:** O(min(|A|,|B|)) per full pass, O(1) per `has`; no allocation.
- **Why this and not another:** "the cost follows the rarest kind and the order is the smallest store's dense order, the same on every run".
- **Where:** `src/world/query.axle:20-95`.
- **Docs:** MISSING.

### C-68. I want a parent/child tree with O(1) attach and detach
- **Means:** `Hierarchy`: per slot `parent`, `first`, `last`, `next`, `prev`, `kids` (all `i32`), children in attach order.
- **Mathematics:** attach is refused when `newParent` is `index` or a descendant (`isSelfOrAncestor(index, newParent)` walks up from `newParent`); the child becomes the last child (tail link).
- **Instructions:** detach: 4 link updates; attach: cycle walk then detach + tail link.
- **Cost:** attach O(depth) (the ancestor walk), detach O(1); memory 24 bytes per slot (six `i32`, derived).
- **Why this and not another:** linked sibling lists give O(1) change with no allocation and a deterministic walk order.
- **Where:** `src/world/hierarchy.axle:14-124`.
- **Docs:** MISSING.

### C-69. I want world transforms of a scene tree that are recomputed only where something changed
- **Means:** `Scene`: local `DTransform` per entity; dirty flags; `update` walks roots in slot order and children in attach order with an explicit stack, recomputing an entity when it is dirty or its parent moved.
- **Mathematics:** `placed(child) = placed(parent) * local(child)` (`DTransform.mul`: `t = parent.rotation.rotate(child.t * parent.s) + parent.t`, `r = normalize(r_p r_c)`, `s = s_p * s_c`; exact only for uniform scale). Results are f64 and do not depend on anything but the calls made.
- **Instructions:** `update` first clears the `moved` flags of every slot, then visits every root's subtree: the traversal is O(slots) per pending update even if one entity changed (derived from `scene.axle:304-325`), but only dirty entities and their descendants pay the transform multiply.
- **Cost:** O(slots) traversal + O(changed subtree) multiplies; memory per slot: two `DTransform` (2 x 80 B = 160 B) + flags + name index (derived). `worldTransform(id)` calls `update` first.
- **Why this and not another:** header: "recomputed lazily and only below what changed". The `Vec`-backed arrays are indexed by slot number.
- **Where:** `src/world/scene.axle:25-326` (`refresh` `:287-301`, `update` `:304-325`).
- **Docs:** MISSING.

### C-70. I want to reparent an entity and keep it where it is in the world
- **Means:** `attachKeepWorld` and `detach` recompute the local transform from world transforms.
- **Mathematics:** `local_new = parentWorld^-1 * before_world`; `detach`: `local = before_world`. `DTransform.inverse` is exact for uniform scale (see C-23).
- **Instructions:** two `worldTransform` calls (each runs `update` if pending), one inverse and one multiply.
- **Cost:** O(slots) for the implicit `update` if anything is pending, plus O(1).
- **Why this and not another:** `attach` (keep local) vs `attachKeepWorld` (keep world) are both provided.
- **Where:** `src/world/scene.axle:197-233`.
- **Docs:** MISSING.

### C-71. I want to destroy an entity and everything below it
- **Means:** detach, then a stack walk over children; each dead entity's name is forgotten from `byName` only if it still points there.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `pushChildren` per popped slot; `world.destroy`.
- **Cost:** O(subtree size); returns the number destroyed.
- **Why this and not another:** a stack avoids recursion depth limits (UNVERIFIED stated reason).
- **Where:** `src/world/scene.axle:117-149`.
- **Docs:** MISSING.

### C-72. I want to dump a scene as stable text for diffs, and save/load it as JSON
- **Means:** `SceneInspector.dump`/`dumpStructure` (positions rounded to 1/1000 with integer arithmetic) and `SceneJson.save`/`load` (parents before children, parent as file index).
- **Mathematics:** `milli(v)`: `n = (v*1000 + 0.5)` as `i64` (or `-0.5` when `v < 0`), printed with sign, whole, 3-digit fraction. JSON: `{"format":"ludax.scene","version":1,"entities":[{name?, parent, t, r, s}]}`; a load refuses a parent index `>= i` ("does not come before it"); ids are not stored.
- **Instructions:** explicit stacks, children pushed in reverse so they pop in attach order (`childrenReversed` allocates a `Vec<i64>` per node).
- **Cost:** O(entities) in work, but the text is built with `out = out + line` (`inspect.axle:35,55`), which is O(n^2) in total length if Axle string concatenation copies (UNVERIFIED).
- **Why this and not another:** "two equal scenes give equal text and a diff of two dumps says what moved".
- **Where:** `src/world/inspect.axle:17-115`, `src/world/scene_json.axle:1-313`.
- **Docs:** MISSING.

### C-73. I want a broad-phase "what is near this box"
- **Means:** `SpatialGrid`: uniform grid hash from cell to an intrusive chain of entries; boxes larger than 12 cells go to a short list tested exactly; queries walk the covered cells (or every chain for a query wider than 48 cells).
- **Mathematics:** cell `floor(v / cell)`; key packs three cells in 21 bits each after adding a bias of `2^20` (so worlds of about +-10^6 cells stay distinct; beyond that keys alias); a box is "big" when its widest span `x1 - x0 >= 12` cells; a query switches to walking all chains when `span >= 48` (four times 12). Results come in cell order, then insertion order; each entity once (via a `seen` map); a result may include boxes that miss by less than a cell.
- **Instructions:** insert: for each touched cell one `Map.getOr`, two `Vec.push`, one `Map.put`; query: for each cell a chain walk with `seen.put`. Rebuilt each frame (`clear` then `insert`) rather than updated.
- **Cost:** insert O(cells touched) up to `12^3 = 1728` per box (derived); query O(cells covered + entries met) plus O(big boxes); `seen.clear()` costs O(used + table) so it is paid per query (see Doubts). Memory per entry 12 B (`bits` i64 + `chain` i32) plus the head map (21 B per distinct cell).
- **Why this and not another:** "for things that move every frame that is cheaper than moving entries" (header).
- **Where:** `src/world/spatial.axle:42-206`.
- **Docs:** MISSING.

### C-74. I want rays and shadows against small shapes inside one cell (a flower, a lever, a torch)
- **Means:** `ShapeBank`: a handful of axis-aligned boxes per block in sixteenths of the cell; slab ray test; diffuse light by cover.
- **Mathematics:** slab: for each axis `t0,t1 = (lo-o)/d, (hi-o)/d`; `enter = max(near)`, `leave = min(far)`, the face struck is the axis entered last; parallel axis (`|d| < 1e-7`): inside the slab all along or never (no division). A ray starting inside a box reports `t = max(enter, from)`. Diffuse openness: `open = 1 - (min(ax,1) + min(ay,1) + min(az,1)) / 3`, `ax = sum of sy*sz` over the boxes (the cover seen along x), boxes taken as disjoint. A full cube gives 0.
- **Instructions:** three reciprocals once per call (or 0 for a parallel axis, selected without a branch via `?:`); per box 3 axis intervals; keep the smallest `t`.
- **Cost:** `intersect` O(boxes of that block); `seal` O(blocks x boxes) once; memory 24 bytes per box (`6 f32`) plus 4 arrays of `blocks` entries.
- **Why this and not another:** exactness: "a flower hides what it covers and nothing else, and its shadow is its own outline" (header).
- **Where:** `src/world/shape/shape_bank.axle:1-244`.
- **Docs:** `shapes` (`doc/handbook/render/18-shapes.md`).

---

## Runtime: loop, systems, input, settings

### C-75. I want a main loop whose behaviour depends only on the frame durations it is told
- **Means:** `GameLoop<M : GameModule>`: clamp the frame, bank it in a `FixedStep`, run `simulate` per whole step, `render(alpha)` once.
- **Mathematics:** `dt = clamp(frame, 0, maxFrameNanos)` (default 250 ms, the excess counted); `banked += dt * scaleMilli / 1000` (integer thousandths so banked time stays exact); standard config: 60 Hz, at most 8 steps a frame. `module.wantsQuit()` is asked after every step so a run ends on the very tick. The smoothed frame time is a mean of the last 8 frames, for display only.
- **Instructions:** order `input`, then clock, then `simulate` x steps, then `render`; the profiler (8 scopes, 8 frames, 16 samples) reads the real clock only for people.
- **Cost:** O(steps) per frame; the module is a type parameter, so there is no virtual call.
- **Why this and not another:** a class cannot be stored in a trait-typed field (E0709), so the loop takes the module as an argument of each `frame` call (`game_module.axle` header).
- **Where:** `src/runtime/game_loop.axle:68-185`, `src/runtime/game_module.axle:13-25`.
- **Docs:** MISSING.

### C-76. I want pause, single-step and slow motion that keep replays exact
- **Means:** `setPaused`, `requestStep` (while paused, each request banks exactly one step), `setTimeScale` in thousandths.
- **Mathematics:** while paused each owed step does `fixed.advanceNanos(stepNanos)`; unpaused `dt * scale / 1000` in integers (truncating).
- **Instructions:** integer multiply and divide per frame.
- **Cost:** O(1) per frame.
- **Why this and not another:** thousandths, an integer, "so the banked time stays exact".
- **Where:** `src/runtime/game_loop.axle:152-162`, `:197-223`.
- **Docs:** MISSING.

### C-77. I want systems to run in a declared order without a hard-coded list
- **Means:** `Scheduler`: "A before B" constraints resolved by a topological ordering that always picks the lowest-numbered ready system (registration order breaks ties). The code does not name the algorithm; it is an in-degree count with repeated selection (`countWaiting`, `firstReady`, `release`).
- **Mathematics:** `waiting[s] = number of constraints ending at s`; repeat `n` times: choose the first unplaced `i` with `waiting[i] == 0`, place it, decrement `waiting` of its successors; no candidate means a cycle (reported with the names left). Unknown names and `x before x` are reported by `bindEdges`.
- **Instructions:** O(n) scan per step plus O(E) edge scan per placement; `run` hands each enabled system's number to a `SystemRunner` which returns its cost; over-budget runs are counted.
- **Cost:** `resolve` O(n^2 + n E) (derived); `run` O(n); the order is a function of the declarations alone.
- **Why this and not another:** "lets a module add a system without knowing the others" (header); a class cannot be stored in a trait field, so the scheduler holds names and the caller a `match` on the number.
- **Where:** `src/runtime/scheduler.axle:43-342`.
- **Docs:** MISSING.

### C-78. I want one frame of input as comparable, hashable plain data
- **Means:** `InputState`: 320 digital codes in ten 32-bit words (keys 0..255, mouse 256..271, pad 272..319), previous-frame words for edges, 8 analog axes and two mouse deltas as integers in 1/4096 units.
- **Mathematics:** code `c`: word `c >> 5`, bit `c & 31`; `wasPressed = down & ~prev`; quantise `q = floor(v*4096 + 0.5)` for `v >= 0`, `-floor(-v*4096 + 0.5)` otherwise (half away from zero); axes clamped to `[-4096, 4096]`; `hash` folds words, axes and deltas with `hashCombine` from a seed constant.
- **Instructions:** shifts and masks; `beginFrame` copies 10 words.
- **Cost:** O(1) per query; `downCount` O(320); memory 120 bytes per state (10+10+8 i32 + 2 i32, derived).
- **Why this and not another:** integers make a snapshot "exactly comparable, hashable and recordable", so a replay feeds bit-for-bit what the live run saw.
- **Where:** `src/runtime/input_state.axle:45-231`.
- **Docs:** MISSING.

### C-79. I want to record input and replay it exactly, with corruption detected
- **Means:** `InputTape`: delta-coded snapshots with a 20-bit change mask, big-endian words, CRC-32 trailer.
- **Mathematics:** per snapshot a 20-bit mask of which of the 20 fields (10 words, 2 mouse, 8 axes) differ from the previous snapshot (the first against all zeros), followed by only those words; the file is tag `LXIT`, version, count, snapshots, CRC-32 of everything before. A cut, edited or damaged tape fails to load with a reason.
- **Instructions:** per snapshot 20 compares to build the mask; reading rejects counts above the body size, masks naming fields above 19, trailing bytes.
- **Cost:** O(snapshots x 20); size about `4 + 4 x changedFields` bytes a snapshot (derived), in memory 80 bytes a snapshot (20 `i32`).
- **Why this and not another:** a bug report "carries its own reproduction" (header).
- **Where:** `src/runtime/input_tape.axle:42-231`.
- **Docs:** MISSING.

### C-80. I want "jump" and "steer" to mean what the player means, across keys, chords and sticks
- **Means:** `ActionMap`: named actions fed by key, chord, axis (with dead zone and scale) and key-pair bindings; the strongest binding wins.
- **Mathematics:** dead zone `v = sign(raw) (|raw| - d)/(1 - d)` for `|raw| > d`, else 0 (the value still reaches the full range); a key pair gives `+scale` for the positive key and `-scale` for the negative (both cancel); action value = the binding with largest `|v|` (first on a tie), clamped to [-1,1]; down when `|v| >= 0.5`.
- **Instructions:** one `read` per binding then a per-action max; edges from `nowDown`/`prevDown` between `evaluate` calls.
- **Cost:** O(actions + bindings) per `evaluate` (call once per simulation step); `clearBindings` O(bindings) with `removeAt`.
- **Why this and not another:** rebinding starts with `clearBindings`; not otherwise documented.
- **Where:** `src/runtime/action_map.axle:37-223`.
- **Docs:** MISSING.

### C-81. I want typed settings with defaults, ranges and a cheap "did anything change"
- **Means:** `Settings`: each key declared once (int, real, bool, text) with default and limits; every setter validates; `version` counts accepted changes.
- **Mathematics:** none: plain arithmetic. `setReal` rejects NaN by writing the test as `!(v >= lo) || !(v <= hi)`; text may not hold quotes or line breaks (the file format cannot escape them). Declaration order is the print order, so "a settings file written twice is the same file".
- **Instructions:** one `StringMap` lookup per access; a struct row per setting copied in and out.
- **Cost:** O(1) expected per get/set; `changedSince(seen)` is one integer compare.
- **Why this and not another:** a system that caches something computed from a setting "compares one number per frame instead of re-reading every key".
- **Where:** `src/runtime/settings.axle:1-485` (`setInt` `:290`, `setReal` `:308`, `setFromText` `:367`).
- **Docs:** MISSING.

### C-82. I want a settings file and command line that keep going after a typo
- **Means:** `SettingsText`: `key = value` lines, `[section]`, `#` comments, quotes; `--section.key=value` and `--flag`; a `ParseReport` of line/column problems.
- **Mathematics:** none: plain arithmetic. A later line wins; every good line applies, every bad one is reported; writing then reading then writing gives the same text.
- **Instructions:** line cutting by `TextScan.lineAt(text, n)` per line, which rescans from the start each time.
- **Cost:** O(lines x bytes) for `read` (quadratic in the file size, derived from `settings_text.axle:56` calling `lineAt` for each index; `lineAt` scans from byte 0, `text.axle:139-153`); fine for a settings file, poor for a large one. The mission text parser has the same shape (`mission_text.axle:378-380`).
- **Why this and not another:** "one typo does not throw away the rest of a player's file".
- **Where:** `src/runtime/settings_text.axle:48-262`, `src/runtime/text.axle:139-158`.
- **Docs:** MISSING.

### C-83. I want to parse numbers from text identically on every machine
- **Means:** `TextScan.isInt/toInt/isDecimal/toDecimal`: gather digits as an integer and scale by a power of ten, no libm.
- **Mathematics:** `value = mantissa * 10^(exp - fractionDigits)` (division when negative); `pow10` by repeated squaring, "exact up to 10^22"; integers up to 18 digits (so an `i64` cannot overflow); the decimal result is "the nearest double for up to 15 significant digits" (doc comment).
- **Instructions:** one multiply-add per digit; one `pow10` (about log2(n) multiplies); one divide or multiply.
- **Cost:** O(digits).
- **Why this and not another:** "the same text always means the same number on every machine" (header). Not exact for more than 15 digits (the mantissa accumulates in f64).
- **Where:** `src/runtime/text.axle:218-399`.
- **Docs:** MISSING.

---

## Open world

### C-84. I want to cut an unbounded world into cells with stable keys
- **Means:** `Cells.index` (floor division), `key`, `keyX`/`keyZ`, `distance` (to the nearest point of a cell).
- **Mathematics:** `index = floor(p / size)` (via truncation plus fix-up, so negatives work); `key = (cx << 32) | ((cz + 2^31) & 0xFFFFFFFF)`; `distance = sqrt(max(|dx|-h,0)^2 + max(|dz|-h,0)^2)` with `h = size/2` and `dx` the offset from the cell centre (0 inside).
- **Instructions:** one divide per axis (by a runtime size), a compare/fix-up; one sqrt for distance.
- **Cost:** O(1).
- **Why this and not another:** the distance to the nearest edge (not the centre) is what the streamer's radius means.
- **Where:** `src/openworld/partition.axle:54-92`.
- **Docs:** MISSING.

### C-85. I want a world that needs no storage beyond its seed, with the same content whichever way the player arrives
- **Means:** `WorldPartition.ensure`: an unauthored cell is filled once by a scatter rule from a `Pcg32` seeded by the world seed and the cell coordinates; authored cells are left alone.
- **Mathematics:** `Pcg32(hashMix(hashCombine(hashCombine(seed, cx), cz)), stream 17)`; per entry: `pick = nextBelow(totalWeight)` mapped to a template by subtracting weights in order (weight 0 never picked), then `x = (cx + nextF64) * size`, `z`, `yaw = nextF64 * TAU`, `y = ground.heightAt(x, z)`.
- **Instructions:** per entry: 1 bounded draw, 3 float draws (6 `u32` draws), a linear walk over templates, one `GroundHeight` call (a trait call).
- **Cost:** O(perCell x templates) per new cell; per-cell lists are intrusive linked entries (`heads`, `tails`, `counts` maps + `nextEntry`).
- **Why this and not another:** "the order cells are visited in changes nothing" (header). Authoring must happen before a cell's first use.
- **Where:** `src/openworld/partition.axle:95-216`.
- **Docs:** MISSING.

### C-86. I want only the cells near the player to exist as entities, without flicker
- **Means:** `CellStreamer`: load cells whose nearest edge is within `loadRadius`, release those beyond `loadRadius + hysteresis`, both budgeted per update, nearest-first to load and farthest-first to unload, ties by cell key.
- **Mathematics:** `reach = floor(loadRadius/size) + 1`; scan the `(2 reach + 1)^2` cells around the player's cell; candidates kept sorted by `(distance, key)` with an insertion sort; defaults: load 600 m, hysteresis 200 m, 8 loads and 16 releases per update. `activeSetHash = sum hashMix(key)` and `contentHash = sum hashMix(hashCombine(...template, mm positions))` are order-independent (sums).
- **Instructions:** release pass over the active map; activate pass over the window; each spawn creates `scene.add("")` + `setLocal`; despawn scans all members to find the cell's entities.
- **Cost:** per update O(window cells + candidate sort k^2 + active); `despawnCell` is O(members) per released cell, plus a `sweep` O(members) (derived from `streamer.axle:252-264`); with a 256 m cell (the field default of `WorldPartition`, `partition.axle:96`) and the default 600 m load radius the window is 49 cells (derived: `reach = 600/256 + 1 = 3`, `7 x 7`).
- **Why this and not another:** hysteresis stops "a player pacing back and forth across the edge" from making a cell flicker; budgets spread "a long jump" over frames (header).
- **Where:** `src/openworld/streamer.axle:64-386`.
- **Docs:** MISSING.

### C-87. I want a time of day that gives sun direction and a cheap light tint
- **Means:** `SkyClock`: integer nanoseconds inside a day; `SkyClock.at(t, tilt)` as a pure function.
- **Mathematics:** `angle = (t - 0.25) 2 pi`; `sun = normalize(cos angle, sin angle, tilt)`; `daylight = smoothstep(-0.12, 0.3, sun.y)`; `warm = smoothstep(0, 0.45, sun.y)`; `green = lerp(0.45, 0.97, warm)`, `blue = lerp(0.2, 0.9, warm)`; sun light `(daylight, green daylight, blue daylight)`; moon `= -sun`; `isDay = sun.y > 0`. Time of day: 0 midnight, 0.25 sunrise, 0.5 noon, 0.75 sunset ("the lighting library's" convention).
- **Instructions:** one deterministic `sin`, one `cos`, one normalise, 2 smoothsteps.
- **Cost:** O(1); clock advance subtracts whole days in a loop (O(days spanned) per call).
- **Why this and not another:** the tint is "only for things that do not want the full model" (the `LightSky::atDayTime` atmosphere exists in `src/render/light/light_sky.axle`).
- **Where:** `src/openworld/sky_clock.axle:59-150`.
- **Docs:** `sky` covers the full atmosphere; this cheap tint is MISSING.

### C-88. I want weather that changes on its own, deterministically, and can be saved by seed and time
- **Means:** `Weather`: five kinds, spells of random length between min and max, a weighted draw of the next kind, a linear transition blend.
- **Mathematics:** `spell = minSpell + floor(nextF64 * (maxSpell - minSpell))`; next kind by weights from a per-kind table (`never` 0 ... `almost always` 6) with `nextBelow(sum)` and a cumulative scan; blend `t = 1 - transLeft/transTotal`, every output `lerp(profileA, profileB, t)`; `advance(dt)` loops spending the transition then the spell, so a large `dt` crosses several changes with the same result as small ones.
- **Instructions:** O(1) draws per change; outputs are 5 `f64` lerps.
- **Cost:** O(changes crossed) per `advance`.
- **Why this and not another:** "a save needs only the seed and the elapsed time" (header).
- **Where:** `src/openworld/weather.axle:40-354`.
- **Docs:** MISSING.

### C-89. I want an arcade car that is a pure function of (parameters, state, input, ground)
- **Means:** `VehicleModel.step`: substeps of a model with four spring-damper wheels, an automatic gearbox, a torque curve, drag, rolling resistance, slope pull, friction-circle tyres, a kinematic-bicycle yaw rate, and a final no-tunnelling ground clamp.
- **Mathematics:**
  - torque: below peak `T = Tpeak (0.55 + 0.45 (r - idle)/(peak - idle))`, above `T = Tpeak (1 - 0.45 ((r - peak)/(redline - peak))^2)`, 0 at redline.
  - force at road: `F = pedal * T(max(wheelRpm, launchRpm)) * gear * finalDrive * efficiency / wheelRadius`, capped by `grip * normalLoad * driveShare`.
  - rpm from speed: `|v| / r * ratio * finalDrive * 60/(2 pi)`.
  - drag `0.5 rho CdA v^2`; downforce `0.5 rho ClA v^2`; rolling `Crr m g`.
  - spring: `F = k c + d closing`, plus a bump stop with stiffness `10 k` beyond travel `restLength - minGap`, never pulling.
  - steering: `angle = steer maxSteer / (1 + (v / steerSpeedRef)^2)` (halved at `steerSpeedRef`), rate-limited; yaw rate target `v tan(angle)/L` clamped to `+-(0.95 grip N / m) / max(|v|, 0.5)` (`N` the tyre normal load, `m` the mass).
  - sideways: tyre `dv` capped by `sqrt(sideGrip^2 - usedGrip^2)/m * h` (friction circle).
  - retarding forces "bring the car to rest and no further".
- **Instructions:** per substep: 12 `GroundHeight` calls (8 in `loads` including the look-ahead at `p + v h`, 4 in `lowestBody`), 4 sin and 4 cos (derived), ~12 small structs passed by value; default `substeps = 2`.
- **Cost:** O(substeps) per step with a trait call to the ground per wheel; memory O(1), the state is a plain `VehicleState`.
- **Why this and not another:** "an arcade model on purpose: believable numbers, a handful of knobs, no tyre lookup tables" (`vehicle_params.axle:11-12`); it uses `sinD`/`cosD`/`sqrtD` so "the answer is the same on every machine" (`vehicle_model.axle:5-6`).
- **Where:** `src/openworld/vehicle_model.axle:275-320`, `:323-657`; `src/openworld/vehicle_params.axle:202-247`.
- **Docs:** MISSING.

### C-90. I want a ground the world and vehicles can stand on, supplied by the game
- **Means:** `GroundHeight` trait; library grounds `FlatGround` and `RollingGround` (two crossed sines).
- **Mathematics:** `h = A (0.5 sin(k x) + 0.5 sin(0.7 k z + 1.3))`, `k = 2 pi / wavelength`; "must be a pure function of its arguments".
- **Instructions:** 2 deterministic `sinD`.
- **Cost:** O(1).
- **Why this and not another:** the open world "does not own a terrain" (header).
- **Where:** `src/openworld/terrain.axle:12-57`.
- **Docs:** MISSING.

### C-91. I want multi-stage missions authored as data, checked for mistakes, and played as a state machine
- **Means:** `MissionBook` (definitions: stages of objectives, prerequisites, rewards, failures; a text format via `MissionText`), `MissionBook.validate`, `MissionBoard` (play state fed by events).
- **Mathematics:** a stage completes when all non-optional objectives are done; `update` order: queued events, then time (stage timers, then time-limit failures, so a mission that finishes in the step its time runs out has finished), then `refresh` re-checks prerequisites to a fixed point and starts `auto` missions. Validation: missing stages, no required objective, unknown prerequisites, self-requirement, and prerequisite loops by a stack-based reachability search (`reaches`: depth-first from each mission with a `seen` array). Objective tests: `reach` and `escort` use `dx^2 + dz^2 <= r^2`; kill/collect count `min(count + amount, target)`.
- **Instructions:** each event is offered to every active mission's open-stage objectives (`handle`); name lookup `missionOfWord` is a linear scan.
- **Cost:** `update` O(events x active objectives + missions) plus `refresh` passes O(missions^2) in the worst case (derived); `validate` O(missions x (missions + edges) x missions) due to the linear `missionOfWord` inside `reaches` (derived).
- **Why this and not another:** events and a fixed order make "a run ... a function of the definitions, the events and the time steps alone".
- **Where:** `src/openworld/mission_book.axle:554-649`, `src/openworld/mission_board.axle:238-507`, `src/openworld/mission_text.axle:376-409`, `src/openworld/mission_check.axle:1-50`.
- **Docs:** MISSING.

### C-92. I want mission progress saved to bytes, refused when the definitions changed, and never half-applied
- **Means:** `MissionBook.fingerprint` (a hash of every definition) + `MissionSave` (tag `LXMS`, version, fingerprint, per-mission 24-byte and per-objective 8-byte records, flags, paid rewards, CRC-32); `load` validates everything before touching the board.
- **Mathematics:** fingerprint = `hashCombine` fold over word hashes (FNV-1a 64) and every table field, positions rounded to the millimetre; load checks tag, version, CRC, fingerprint, counts, then every status/stage/progress "is possible", then applies.
- **Instructions:** big-endian 32-bit words; a 64-bit value is two words.
- **Cost:** O(missions + objectives + flags) both ways.
- **Why this and not another:** all-or-nothing load: "a save from other definitions is refused, not misapplied".
- **Where:** `src/openworld/mission_book.axle:651-693`, `src/openworld/mission_save.axle:85-325`, `src/openworld/mission_raw.axle`.
- **Docs:** MISSING.

---

## Tests

### C-93. I want a suite whose exit status is the number of failed checks
- **Means:** `Checks`: `that(name, ok)`, `sameInt`, `near(got, want, tolerance)`; each miss prints `FAIL <name>`; `failures()` is the process exit status.
- **Mathematics:** `near` passes when `|got - want| <= tolerance` (a NaN difference fails, because the comparison is false).
- **Instructions:** two counters; one `println` per failure.
- **Cost:** O(1) per check.
- **Why this and not another:** "so 0 is a pass and CI needs no parser" (header).
- **Where:** `src/core/test/checks.axle:9-43`.
- **Docs:** `CLAUDE.md` ("Checks" section); a mechanism chapter is not needed.

---

## Missing documentation

Nothing of this zone is covered by a dedicated handbook chapter except the job pool, the field graph and the shapes
(and parts of quick trigonometry and determinism). The table lists what is not written down anywhere in `doc/`.

| Mechanism | File | What is not written down |
|---|---|---|
| Exact trigonometry | `src/core/math/trig.axle` | the Cody-Waite split, the kernel polynomials and the atan breakpoints exist only in code comments; only the accuracy figures are in the header; `doc/handbook` has no chapter on determinism of `sin`/`cos` beyond policy |
| Scalar helpers and f64 twins | `scalar.axle`, `tools/gen_math_f64.sh` | what is generated and what is hand-written (`trig`, `scalar`, `convert`, `frustum` are not generated); the `wrapAngle` closed form; the `approxEq` rule |
| Vector, quaternion, matrix conventions | `vec3.axle`, `quat.axle`, `mat3.axle`, `mat4.axle` | the conventions are in file headers only; the slerp threshold `0.9995`, antiparallel threshold `-0.999999`, `fromMat3` branch rule, matrix inverse by 2x2 minors, the perspective/ortho/reversed-depth matrices (no derivation anywhere) |
| TRS transform limits | `transform.axle`, `scene.axle` | when `Transform.mul`/`inverse` and the scene's world transforms are inexact (non-uniform scale under rotation) is stated only in a header |
| Camera-relative f64 to f32 | `convert.axle` | the precision argument ("centimetres at ten kilometres") is a comment; no chapter says how renderers must use `relativeVec3` |
| Geometry and intersection | `geom.axle`, `intersect.axle` | slab, sphere and Moeller-Trumbore formulas and their tolerances (`1e-10`); only the sub-cell slab test is documented (`shapes`) |
| Frustum culling | `frustum.axle` | the row combinations (Gribb-Hartmann), the three-state verdict and why it is conservative |
| Hashing | `id/hash.axle` | FNV-1a and SplitMix64 constants, `hashCombine`, and which structures use which hash |
| Insertion-ordered `Map`, `StringMap` | `collections/map.axle`, `string_map.axle` | the probe/tombstone/rebuild policy, memory per entry, the `clear` cost |
| `Vec`, `Ring`, `Slab`, `SparseSet`, `Heap`, `BitSet` | `collections/*.axle` | complexity and memory tables; the `Heap` tie-break by push serial; where each is used (`Heap<i32>` in navigation; `Ring<i64>` in the voxel light queue) |
| `PackedCells` and the division-free index | `collections/packed_cells.axle` | the proof that `(i * magic) >> 32` equals `i / per` below `2^26`; padding waste per width |
| `PalettedPool` | `collections/paletted_pool.axle` | the three forms, growth, compaction trigger (`garbage >= 256` and half the used pool), bytes per container and per width; measurements exist only in `doc/handbook/history/core-review.md` |
| `Arena` | `mem/arena.axle` | its role; `doc/handbook/history/core-review.md:241` says it has no user besides its test |
| Entity ids and the allocator | `id/entity_id.axle`, `id/id_allocator.axle` | generation rules (starts at 1, wrap skips 0, last-freed-first reuse) |
| `Pcg32` | `rng/pcg32.axle` | the output function, stream selection, rejection sampling; `doc/handbook/concepts/02-determinism.md` states policy only |
| Value noise with exact gradient | `field/lux_noise.axle` | the corner hash constants (`73856093`, `19349663`, `2654435761`) and the `1.5` slope bound |
| `FixedStep`, `Timer`, `Stopwatch` | `time/*.axle` | integer-nanosecond accumulator, `alpha`, drop counter, `atHertz` rounding |
| `Profiler`, `Logger` | `profile/*.axle`, `log/*.axle` | ring layout, inclusive/self definitions, memory per sample |
| Scene graph | `world/scene.axle`, `hierarchy.axle`, `store.axle`, `query.axle`, `world.axle` | lazy update, traversal order, dirty/moved flags, join cost rule ("walk the smallest store") |
| Scene text and JSON | `world/inspect.axle`, `scene_json.axle` | the file format (`ludax.scene` version 1) and rounding to 1/1000 |
| `SpatialGrid` | `world/spatial.axle` | the thresholds 12 and 48 cells, 21-bit cell keys, rebuild-per-frame policy |
| Main loop and scheduler | `runtime/game_loop.axle`, `scheduler.axle`, `fan_out.axle` | the frame order, clamp (250 ms), step cap (8), time scale in thousandths, scheduler tie rule and cost |
| Input | `runtime/input_state.axle`, `input_tape.axle`, `action_map.axle` | the 320-code layout, the 1/4096 quantisation, the tape byte format (`LXIT`), dead-zone formula |
| Settings and text parsing | `runtime/settings.axle`, `settings_text.axle`, `text.axle` | the file grammar, the number parser's exactness (15 digits, `10^22`), error reporting |
| Cell partition and streaming | `openworld/partition.axle`, `streamer.axle` | cell key packing, scatter rule and its seed derivation, hysteresis and budgets |
| Sky clock tint | `openworld/sky_clock.axle` | the dawn/warm smoothstep ranges and the green/blue ramps (-0.12..0.3, 0..0.45, 0.45..0.97, 0.2..0.9) |
| Weather | `openworld/weather.axle` | the profile numbers and the transition table |
| Vehicle model | `openworld/vehicle_model.axle`, `vehicle_params.axle`, `vehicle_state.axle` | every formula in C-89: torque curve, friction circle, steering law, spring, bump stop, ground clamp |
| Missions | `openworld/mission_*.axle` | the text grammar, the update order, the save byte format (`LXMS`), the fingerprint |
| Test harness | `core/test/checks.axle` | (small; covered in `CLAUDE.md`) |

## Doubts

1. **A hash seed that is not what its comment says.** `src/runtime/input_state.axle:32-33` says the seed `1469598103934665603` is "the FNV-1a 64-bit offset basis", and `src/openworld/mission_book.axle:38-39` calls its seed an FNV-1a fingerprint start. The real basis is `14695981039346656037` (`0xcbf29ce484222325`), which is `-3750763034362895579` as the signed constant in `src/core/id/hash.axle:10`. The seed in the two files has 19 digits: it is the real one with its last digit dropped. It only seeds a fold of `hashCombine`, so nothing breaks, but the comment is wrong, and changing the constant would change saved fingerprints (`MissionBook.fingerprint`) and input hashes.
2. **`Scene.find` after the newest same-name entity dies.** `src/world/scene.axle:10-11` (header) and `:105` say `find` answers "the most recently created living entity of that name". `add` overwrites the name entry (`:81`) and `forgetName` removes it when the entity goes (`:145-147`); an older living entity with the same name is not restored, so `find` then answers the none id.
3. **Profiler reads the clock when disabled.** `src/core/profile/profiler.axle:14-15` says that with the profiler disabled "no clock is read", but `beginFrame` and `endFrame` call `nowNanos()` unconditionally (`:106-108`, `:180-182`) before checking the flag. `src/runtime/game_loop.axle:7-8` ("only the optional profiler reads real time") is still true in effect (no simulation reads it), but one clock read a frame happens with profiling off.
4. **Unguarded divisions despite the "every divide is guarded" rule.** `VehicleParams.torqueAt` divides by `peakRpm - idleRpm` and `redlineRpm - peakRpm` (`src/openworld/vehicle_params.axle:202-213`); equal values trap. `VehicleModel.turning` divides by `cosD(angle)` (`vehicle_model.axle:520-548`), which is zero at `maxSteer = pi/2`. `VehicleModel.loads` divides by `h` (`:333-355`), guarded only by the `dt <= 0` test in `step` (`:275-282`). `Mat4.perspective` and the other constructors are guarded; these are not.
5. **Singular tests are absolute, not relative.** `Mat4.inverse` treats `|det| <= 1e-30` as singular (`mat4.axle:28-29`, `:378`); `Mat3` the same (`mat3.axle:10-11`). A uniform scale of `1e-8` has a 4x4 determinant of `1e-32` and would be treated as non-invertible (derived). The vector guard `V3_TINY = 1e-20` is on a squared length, so vectors shorter than `1e-10` normalise to zero.
6. **`SpatialGrid.query` clears a map every call.** `spatial.axle:145` calls `seen.clear()`, and `Map.clear` walks `used` entries and the whole probe table (`map.axle:147-155`); the table only ever grows, so after one very large query every later query pays for it. Also the comment at `spatial.axle:42` ("wider than this many cells") disagrees with the test `span >= 12`, where `span = x1 - x0` is the width minus one cell (`:105`): a box 12 cells wide is already "big". Cell keys alias beyond about +-1,048,576 cells (`:49-53`).
7. **Streamer despawn is quadratic in members.** `streamer.axle:252-264` scans every member for each released cell and then sweeps all members; releasing `k` cells costs O(k x members). `activeKeyAt` (`:284-295`) is O(active).
8. **Scheduler failure message.** `scheduler.axle:123-126` says after a failed `resolve` "the old order (if any) stays", but `resolved` was cleared by `add`/`before` (`:87`, `:115`), so `run` returns false while `orderAt` still returns the stale order.
9. **`settings_text` and `mission_text` read quadratically.** Both call `TextScan.lineAt(text, n)` per line (`settings_text.axle:56`, `mission_text.axle:380`), and `lineAt` scans from the start (`text.axle:139-153`). Harmless for small files.
10. **Exponent overflow in the number parser.** `TextScan.readExponent` accumulates `e = e * 10 + digit` in an `i32` with no limit (`text.axle:356-378`); a long exponent wraps. Also `toDecimal` is exact only for up to 15 significant digits (its own doc comment, `:304-307`).
11. **Stale statements in `doc/handbook/history/core-review.md`.** Lines 191-195 describe `PackedCells.get/set` as three divisions with a reciprocal exact "for `i < 4096`"; the code now has `PackedLayout` exact below `2^26` (`packed_cells.axle:15-19`) and the measured table at `doc/handbook/history/core-review.md:300` shows it. Line 241 says `Arena` is used only by its test: still true (a search finds it only in `src/core/mem`, `src/lib.axle` and `tests/src/mem.axle`), so the recommendation to delete it is open.
12. **`LuxFieldTape.pack` computes a normaliser for every node.** `lux_field.axle:465` reads `konst[1]`, `konst[2]` as octaves and gain for every node, not only noise nodes; harmless (unused values) but a latent surprise if a new op uses those slots. The warp widening under-estimates the footprint by up to sqrt 2, which the header admits (`:17-21`).
13. **`loadWide` allocates a large scratch per call.** `paletted_pool.axle:563-586` builds a `PalettedScratch(1 << directBits, cells)` (a `65536`-entry `i32` map plus three arrays of `cells`) for every container read in a non-native width; and `grow` allocates `u16[cells]` per call (`:390-428`, `REVIEW_CORE:310`).
14. **`Heap` keys.** `Heap` keys are `i64` only; the header says floats must be quantised by the caller, so two float keys closer than the quantum tie and fall back to push order (by design, not a defect).
15. **`ShapeBank.volumeOf`/`openOf` do not bounds-check** (`shape_bank.axle:130-137`) while `shaped` does (`:125-127`); an id of `blocks` or more reads out of range.

## Summary

The glossary has 93 entries (C-01 to C-93) over scalars and trigonometry, vectors, rotations and matrices, geometry and culling, hashing and ids, collections (including packed and paletted storage), random numbers and noise (including the field graph), jobs, time, profiling and logging, the world (entities, stores, joins, hierarchy, scene transforms, spatial grid, shape bank), the runtime (loop, scheduler, input, settings, text) and the open world (partition, streamer, sky clock, weather, vehicle, missions). Every file group in the zone was read: `src/core/math` except the generated `d*.axle` twins (checked through their generator script and the `dgeom` header, not diffed line by line), `core/collections`, `core/id`, `core/rng`, `core/jobs`, `core/time`, `core/mem`, `core/profile`, `core/log`, `core/field`, `world/**`, `runtime/**` and `openworld/**`; for the larger mission, settings and scene-JSON files the read covered the headers and the algorithmic functions, not every accessor. Not verified: anything that needs running (no build, no test, no timing); the Axle string-concatenation cost, whether `std` shares string bytes between a `HashMap` key and an `ArrayList` entry, and the reason for several design choices (marked `UNVERIFIED` or `not documented`). Measured numbers are quoted only from `doc/handbook/engine/01-job-pool.md`, `doc/handbook/render/15-view-layers.md`, `doc/handbook/history/core-review.md` and source comments; all other costs are counted from the code and labelled "derived". Existing coverage is thin: the job pool, the field graph, the shapes and the quick trigonometry have chapters; almost everything else lacks a mechanism chapter.
