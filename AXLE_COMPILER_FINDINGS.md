# LLVM IR audit — compiler findings from a real Axle workload

**Workload**: `ludax/examples/rendering/lumen` — a CPU voxel renderer (Amanatides–Woo DDA over a 320×64×320 flat
grid, baked-light volume sampling, per-pixel shading, 23 worker threads). This is a hot-loop,
scalar-heavy, branchy workload — the hard case for a young compiler, and a realistic one for a game engine.

**Method**: `axle build --emit llvm` at `-O1` and `-O3` (4.1 MB vs 17.4 MB of IR), plus `--emit asm`,
plus A/B benchmarks per optimization level and per target CPU. Every number below was measured, not
estimated. Compiler: `axle 0.19.0-dev`, Windows x64.

---

## Headline numbers (same machine, same session, moving-camera bench)

| build | trace ms | display ms | fps |
|---|---|---|---|
| `-O0` | 37.4 | 22.1 | 15.5 |
| `-O1` (HIR transforms + canonicalization) | 9.6 | 3.7 | 70.9 |
| `-O2` | 9.4 | 3.2 | 74.3 |
| `-O3` | 9.2 | 3.2 | 75.1 |
| `-O3 --target-cpu native` | **11.1 vs 13.5 measured back-to-back (−18 %)** | | |

---

## What the compiler already does well (do not "fix" these)

1. **HIR inlining without the LLVM pipeline.** At `-O1` — where LLVM runs canonicalization only —
   `inside()`, `index()`, `brickOf()` and friends are already inlined into `LumenScene.trace` (the call
   list shows only casts, panic calls and 2 `llvm.assume`). The HIR transforms do the heavy lifting;
   that is why `-O1` is within 5 % of `-O3`.
2. **No fast-math reassociation.** Zero `fast` flags on `fadd/fmul/fsub`. Element-wise math keeps its
   evaluation order; a determinism-sensitive engine relies on this. (But see F2 — `contract` is a
   different story.)
3. **Struct copies are elided.** Zero `memcpy` in the lamp-shading path (`shLamp`, `lumenShade`,
   `lumenPoint`, `LumenLamps.lightAt`): returning structs by value compiles to first-class aggregates.
4. **Saturating casts.** `f32 → i32` compiles to `llvm.fptosi.sat` — defined behaviour, cheap, correct.
5. **Branch weights on guards.** Panic branches carry `!prof !8` (unlikely) — good metadata hygiene.
6. **SLP vectorization works.** `LumenWorker.radiance` contains 347 `<2 x float>` ops: the SLP pass
   pairs the x/y components of `Vec3` math into 2-lane vectors without any change of semantics.
   `LumenLight.sample` (trilinear, 8 corners) gets 12 `<4 x float>` ops at `-O3`.

---

## Findings

### F1 — `--target-cpu native` is not reachable from the project file (−18 % measured, trivial fix)

`axle build --target-cpu native` is 18 % faster end-to-end than the default build (portable `x86-64`
baseline = SSE2 only, so AVX2/FMA sit idle). But `[profile]` in `axle.toml` accepts only `dev` and
`release` — `target-cpu = "native"` is rejected as an unknown field, and the flag only exists as a CLI
argument. A real project cannot opt into its own machine's codegen.

**Recommendation**: accept `target-cpu` (and `target-features`) in the project profile table, resolved
where `[profile]` is parsed (axle_cli `commands/build.rs` → `BuildIntent` → `codegen_options.rs
::effective_cpu_attrs()`). ~20 lines. This is the single highest-value item in this document.

### F2 — `contract` is stamped on 94.6 % of FP operations (FMA contraction by default)

20 432 of 21 605 FP arithmetic ops in the `-O3` IR carry the `contract` fast-math flag (plus 1 071
`fcmp contract`). Consequence: wherever the target has FMA, LLVM may fuse `a*b + c` into `fma`, whose
rounding differs from separate mul-then-add.

- Per-binary determinism holds (the same executable always produces the same bits) — a selftest
  comparing two runs of one binary stays valid.
- **Cross-target reproducibility does not**: a `native` build (FMA) and a baseline build can produce
  different low bits in the same computation. If "same source ⇒ same bits" is a project value, this
  is a silent violation that only appears when someone changes `--target-cpu`.

**Recommendation**: make it a deliberate, documented choice — either stamp `contract` only where the
language allows contraction (it currently reads like a blanket default), or expose a project knob
(`[profile] contraction = on/off`). At minimum, document it next to the fast-math section of the
language manual.

### F3 — every FP division carries a trap guard; ~9–13 survive in the hottest functions

Axle traps on float division by zero, so each division compiles to
`fcmp == 0 → br (likely ok) / panic block`. Measured on the `-O3` IR: `LumenScene.trace` retains ~9
guard branches, `LumenWorker.radiance` ~13 (`-O1` starts higher: ~12 and ~19; LLVM folds the ones
behind `max(dist, 0.001)`-style source guards once `max` is inlined). The survivors guard things like
`1.0 / dx` for ray directions — genuinely possibly-zero by type, never zero by construction.

Impact per guard is small (well-predicted branch ≈ 1 cycle), but they split basic blocks, inhibit LICM
and SLP around the division, and bloat the hot loop's code (see F5 for the duplicated panic bodies).

**Recommendation, in order of preference**:
1. A HIR range-analysis pass that elides guards whose divisor is provably non-zero (the source already
   writes `max(dist, 0.001)` patterns that the analysis could recognise; the sema decision-journal
   infrastructure (`--emit decisions`) looks like the right home).
2. An explicit `unchecked_div` / IEEE-division builtin for hot paths where the caller guarantees the
   divisor (our ray directions are normalised-or-axis-flagged by construction).
3. Long term: consider IEEE semantics for float division (inf/nan like every other language) and keep
   trapping only for integer division — `isFinite()` already exists for the rare explicit check.

### F4 — two bounds checks per DDA step that are provable in principle

`LumenScene.trace`'s walk loop retains `axle_panic_oob` for `bricks[brick]` (vs a runtime length) and
`blocks[at]` (vs the compile-time-constant 6 553 600 — LLVM *knows* the allocation size but loses the
proof across the loop phi, where `at` advances by ±stride). Both indices are dominated by an
`inside(x, y, z)` guard whose condition implies the index bound; the proof only needs range reasoning
through one induction variable.

**Recommendation**: a HIR bounds-check-elimination pass driven by the existing range/decision
machinery, seeded by the dominance of prior comparisons (`x < lowX || x >= highX` directly precedes
the access chain). Honest expected impact: small on its own — the branches are predicted — but the
proofs also unblock LICM/SLP around the accesses and shrink the hot loop. (We removed one check at
the source level by enlarging a table so the u8 index became provable; it worked exactly as this
analysis predicts, and no behaviour changed.)

### F5 — 472 duplicated panic bodies; one string referenced 238 times

The `-O3` IR contains 472 `call void @axle_panic_msg` sites, each with its own compare+branch+cold
block; a single message (`panic.cstr.423`) is referenced from 238 sites. The blocks are cold, but they
bloat `.text` (the `-O3` IR alone is 17 MB), dilute the i-cache around hot loops, and cost link time.

**Recommendation**: outline each distinct panic into one shared cold thunk (equivalent of
`__attribute__((noinline, cold))`), or run an LLVM `MergeICmps`-style/similar consolidation pass after
codegen. Mechanical, low-risk, and shrinks every program.

### F6 — the `-O1` pipeline performs no vectorization at all

`LumenLight.sample` has 0 vector instructions at `-O1` and 16 `<4 x float>` at `-O3`; `radiance` goes
0 → 363 (all SLP, zero `vector.body`). Since `-O1` is described as "every HIR transform with only the
canonicalisation pipeline", this is presumably intended — but it means *every loop vectorization in
the ecosystem requires `-O2`+*, and `-O1`'s near-`-O3` benchmark numbers hide that (this workload's
loops are gather/branch-dominated, so the gap is small; numeric code would differ strongly).

**Recommendation**: document it on the `-O` help text ("no loop vectorization at `-O1`"), and consider
a `-O1.5`/`-Os`-style level that adds `loop-vectorize` without the full pipeline for dev builds of
numeric code.

### F7 — the trilinear core is not inlined into its hottest caller

`LumenLight.sample` (8-corner trilinear read, called 2–4× per shaded pixel) survives as an outlined
`internal fastcc` call even at `-O3` (3 call sites in `radiance`). Its body already vectorizes
internally, so this is not a measured loss — but cross-function value propagation (the caller knows
`scene.sx/sy/sz` are constants, the callee does not) and call overhead sit on the hottest path.

**Recommendation**: try an inline hint (or an inline threshold bump for `internal fastcc` single-crate
callees of hot size) and measure; the function is ~290 lines of IR post-pipeline, borderline by
classic thresholds.

### F8 — `Vec3` is SLP-paired as `<2 x float>` with the z component left behind

347 of `radiance`'s 363 vector ops are `<2 x float>`: the SLP pass pairs x/y but z rides scalar
(observed via the op mix: 347 `<2 x float>` vs only 22 `<4 x float>`). A padded `<4 x float>` lowering
for `Vec3` (w unused) would let whole `Vec3` expressions compile to single 4-lane ops.

**Recommendation**: experiment, measure, keep only if it wins — the SLP pairing already captures most
of the ILP, and a padded layout changes ABI/struct layout, which is a language-level decision.

---

## Verified non-findings (checked, fine as-is)

- No `fast` reassociation flags (see above) — element-wise FP order is the source's order.
- No `memcpy` in struct-return paths; first-class aggregates work.
- `llvm.assume` hints are emitted (7 sites) — good; the tracer could use more after F4's pass exists.
- `llvm.fptosi.sat` for float→int casts — defined, cheap.
- The two remaining hot-loop bounds checks are *predicted* branches; removing them via source
  contortions is not worth it — this needs the compiler pass (F4), not source gymnastics.

### F9 — a partial struct literal fails to resolve field defaults

Writing `FluidRules { dt: ..., k: ... }` with some fields omitted — relying on the declaration's
defaults — fails to resolve a default whose value is an enum path (`strategy : FluidStrategy::ActiveSet`):
`E0017 Undefined namespace or type: FluidEmitters`-style errors pointing at the *declaration* file.
Workaround used by every caller: write all fields explicitly.

**Recommendation**: partial literals must pull omitted fields' defaults through sema unchanged.

### F10 — a `Shared<T>` reached through a trait-typed launch argument is counted without atomics (memory corruption)

**Severity: soundness.** Found on 2026-11-10 with axle 0.20.0 in `games/blockland`: the game ended in
`shared refcount: strong count underflow` or a segfault, almost every run with `--threads 2`, about one run in three
with three threads on a flat world, rarely with twenty-three.

**What happens.** `hir_analyses::memory::thread_locality` stamps a class's refcount traffic `Plain` (load, add,
store) when no instance can reach a spawned thread, and leaves it `Atomic` otherwise. It seeds the escaping set from
the *static types* of a launch's arguments and of the launched function's signature, then closes it over the field
graph. For a trait-typed value `collect_nested_class_ids` pushes the trait's own id
(`field_types.rs`, `HirType::TraitObject { trait_id, .. } => out.push(*trait_id)`), and `type_fields` of a trait is
empty (`HirTypeDef::Trait { .. } => Vec::new()`). The classes that *implement* the trait are never visited, so
nothing they hold is marked escaping. `seed_spawn_target` does walk `trait_dispatch_rows`, but only for a launch
whose *call target* is a trait method, not for a trait-typed *argument*.

**Where it bites.** Any thread pool that takes its work as a trait. `src/core/jobs/pool.axle`:

```axle
constructor(workers : i32, kernel : RangeKernel) { ... Thread::run(jobsWorker, self.gate, kernel); ... }
```

`McFrame : RangeKernel` holds `env : Shared<McEnv>`; `McEnv` holds `Shared<McView>`, `Shared<McBake>`,
`Shared<McRenderTable>`, `Shared<McAtlas>`; they hold `Shared<McWorld>` and `Shared<McAssets>`. In the `-O 3` IR of
the game all seven were plain: 44 plain increments and 79 plain decrements, against 12 and 11 atomic ones (worldgen
classes, which do cross a launch under their own type). `axle build --emit decisions` says of 445 refcount nodes
`applied(ProvenThreadConfined): no instance of the class reaches a spawned thread`. The pool's threads and the main
thread then retain and release the same block with unsynchronised read-modify-writes; an update is lost now and
then, the count drifts, and the object is freed while in use.

**Repro.** `tools/axle_repro/shared_trait_race` (one file, no dependency). A `Work : Job` holds a `Shared<Table>`;
a `Pool` launches `worker(gate, job : Job)`. Both threads retain and release the table in a loop.

```sh
cd tools/axle_repro/shared_trait_race
axle build -O 1 --emit llvm -o out.ll
grep -c "atomicrmw" out.ll                       # 0: no atomic refcount operation is left
grep "rc.inc.* = add i32" out.ll                 # plain increments, in @main and in @"__trait_call$Job$spin"
axle build -O 1 --emit decisions -o d.txt && grep -c ProvenThreadConfined d.txt
axle build -O 0 --emit llvm -o out0.ll && grep -c atomicrmw out0.ll   # 7: the analysis does not run at -O 0
```

The repro does not crash on its own (a lost update is as likely to raise the count as to lower it, and it starts
at three); the game does, because it has hundreds of sites and seven classes. The IR is the proof.

**The same hole, one step sideways.** A value typed as a base class can be an instance of a subclass with more
fields: `field_successors` walks `base_chain` (upward) but not the subclasses. Worth a test.

**Recommendation.** In the seed and in the closure, a `TraitObject { trait_id }` must reach every class that
implements `trait_id` (`trait_dispatch_rows` already lists them), and a `User(id)` every subclass of `id`. Missing a
disqualification is a data race; missing a promotion costs one atomic. A regression test: the repro's IR at `-O 1`
must contain `atomicrmw` on `Table`'s count.

**Workaround in place.** `games/blockland/src/app/mc_env.axle` ends with a function that is never called and launches
a thread with a `Shared<McEnv>` argument, which is what the analysis does read. With it the game's IR has 0 plain
refcount operations and 160 atomic ones, and eight runs out of eight with `--threads 2` end normally. The library's
other users of `JobPool` (`examples/rendering/lumen`, the voxel and fluid runners) hold their shared state the same
way and need the compiler fix.

### F11 — `f32x8.fma` goes through the dispatch trampoline and runs 9× slower than `a * b + c`

**Severity: performance.** Found on 2026-11-23 with axle 0.22.0-dev and confirmed with axle 0.23.0. A post-process
loop over 921 600 pixels (exposure, a 3×3 matrix, `x / (1 + x)`), planar `f32[]` in and out:

| form of the loop | ns a pixel, one thread |
|---|---|
| scalar `f32` | 1.31 |
| `f32x8` with `.fma()` for the matrix | 3.77 |
| `f32x8` with `*` and `+` | 0.41 |

The SIMD page says the `fma` of the dispatched shapes (`f32x4`, `f32x8`, `f64x2`, `f64x4`) calls a kernel chosen at
start-up. That call is not inlined into the loop, so every lane group pays a call and loses the registers of the
loop. Plain `*` and `+` are left to LLVM, which contracts them into `vfmadd` anyway under F2's `contract` flag.
**Rule in ludax until fixed:** never call `.fma()` in a loop; write `a * b + c` (`src/render/lux/simd`).

### F12 — a vector `store` through a parameter does not count as writing it (E0281 asks to drop the `mut`)

**Severity: soundness of the `mut` rule.** Axle 0.22 requires `mut` on an array parameter that is written through,
and refuses a `mut` that is never used (E0281). `v.store(buf, i)` on an `f32x8` writes `buf`, yet a parameter
written only that way is reported as "never mutated" and must be declared without `mut`, so the signature claims a
read-only buffer that the function overwrites. Repro: `fn f(o : f32[]) { f32x8.splat(z).store(o, 0); }` builds,
`fn f(mut o : f32[])` fails with E0281.

### F13 — a struct literal of a struct declared later in the same file fails (E0016)

**Severity: ergonomics.** Found on 2026-11-24 with axle 0.23.0 in `examples/rendering/dusk/src/world/scene.axle`.
`SceneRay { ox: ox, ... }` inside a method of a class declared above `struct SceneRay` fails with `E0016 Field 'ox'
not found on type 'SceneRay'`, for every field, whatever their visibility. Moving the struct above the class fixes it.
The same order dependence decides `pub(file)` visibility: a class declared above another cannot call the other's
`pub(file)` method, nor read its `pub(file)` field ("only the file declaring it reaches it"), although both are in one
file (`examples/rendering/dusk/src/light/lightvol.axle`, `LvBlock` and `LumenLight`; worked around with free
functions declared first). Type declarations and file visibility should be order-independent within a file, as
functions are.

### F14 — a small struct built or returned on every iteration of a hot loop is not kept in registers

**Severity: performance.** Same file and date. A walk step that called a method returning a 6-field struct (`bool`,
`f32`, three `i32`, `bool`) every iteration, or that built an empty one every iteration to mean "nothing", ran 17 %
slower (188 → 220 ns a ray) than the same logic split into a `bool` test and a struct built only when used. Scalar
replacement of aggregates (SROA) should make the two forms equal.

### F15 — a float literal is an `f64` whenever it meets an `f32` in arithmetic; the language has no way to say otherwise

**Severity: ergonomics, with a risk of silent `f64` math.** Axle 0.23.0, measured 2026-11-26 on a one-file package
(`let a : f32 = 2.0;` then the line under test):

| Line | Result |
|---|---|
| `let b : f32 = 0.5;` | compiles (the declared type types the literal) |
| `half(0.5)` for a parameter `f32` | compiles (the parameter types it) |
| `let b : bool = a > 0.5;` | compiles (a comparison widens nothing) |
| `let b : f32 = a * 0.5;`, `0.5 * a`, `a + 1.0` | **E0001**: declared `f32`, initializer is `f64` |
| `b = b + 1.0;` (`b : f32`) | **E0001**: cannot assign `f64` to a slot of type `f32` |
| `a < 1.0 ? 0.0 : 1.0` | **E0001**: the arms are `f64` |
| `0.5f32`, `0.5_f32`, `(0.5 : f32)`, `f32(0.5)` | **parse errors**: there is no literal suffix and no conversion call |
| `0.5 as f32` | compiles: the only form |

So the literal's type is decided by its own expression and not by what it is combined with, which is the opposite of
what the first three rows suggest: the same `0.5` is an `f32` in one position and an `f64` in the next. The rule cannot
be read from the code, only learnt by failing.

**What it costs in ludax.** About 419 `(N as f32)` in `src/` and 3 300 in the programs (211 in one shading file), a
reviewer reading `(0.5 as f32)` where `0.5` was meant, and a standing risk: a bare literal in a position that happens to
compile (a comparison, an argument) is correct, one in an expression silently widens a neighbouring `f32` to `f64` if the
result is bound to an untyped `let`. the typed constants of `core/math/scalar` (`PI`, `TAU`, `HALF_PI`, `EPSILON`, `HUGE`) cover only the named numbers;
every other literal in an expression is cast by hand, or bound to an annotated `let` first (`let half : f32 = 0.5;`),
which is the same cost in more lines.

**What would fix it.** Any one of: (1) type a literal by the other operand (as Rust and C do: `a * 0.5` is `f32` when `a`
is); (2) a literal suffix, `0.5f32`; (3) at least make the error name the literal and suggest `as f32`. (1) removes the
casts outright and makes the first three rows and the next three rows agree.

## Reproduction

```sh
axle build -O 3 --emit llvm -o out-O3.ll        # post-pipeline IR
axle build -O 1 --emit llvm -o out-O1.ll
axle build -O 3 --target-cpu native -o app-native.exe
axle build -O 3 --emit decisions                 # what sema proved and refused, per site
# hot functions to look at first:
#   LumenScene.trace / LumenScene.visibility   (DDA walk, 2 bounds checks + ~9 div guards)
#   LumenWorker.radiance                       (SLP <2 x float>, ~13 div guards, sky atan2D)
#   LumenLight.sample                          (trilinear, vectorized corners, 3 calls/pixel)
```

## Priority order for the compiler

1. **F1** — project-level `target-cpu` (−18 % for every numeric workload, trivial).
2. **F5** — outline panic bodies (mechanical, shrinks everything).
3. **F2** — make `contract` a documented, knobbed decision.
4. **F3.1** — range-driven division-guard elision.
5. **F4** — range-driven bounds-check elision.
6. **F6/F7/F8** — documentation and experiments.

**F10 comes before all of these**: it is the only finding that corrupts memory.

**F15** costs no speed and no memory but the most keystrokes of any finding here, and a silent `f64` where a cast is
forgotten: (1) of its list is a type-checker change only.
