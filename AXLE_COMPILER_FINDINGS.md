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
