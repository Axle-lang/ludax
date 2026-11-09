# Fluid

Two water engines live in `src/sim/fluid`:

| Engine | Files | Units | Use |
|---|---|---|---|
| `FluidWorld` (legacy) | `fluid_*.axle` | cell units, f64 | the column ("virtual pipes") model with a position-based particle layer; geyser, river and intermittent examples |
| `HydroWorld` | `hydro_*.axle` | metres, seconds, f32 | rivers, lakes, weirs and waterfalls over a terrain heightfield |

Decision: `HydroWorld` is the engine for new work. `FluidWorld` stays untouched until the scene agent needs the
three old examples on the new engine; then geyser, river and intermittent migrate to `HydroWorld` (a vent is an
inflow plus `pour`, a drain a sink) and `fluid_*` is deleted. Until then it costs nothing and breaks nothing.

## HydroWorld: design

A shallow-water solver on a regular grid of square cells over a bed the game passes as a plain `f32[]`; a layer
of ballistic particles for water that leaves a lip and falls; and a ledger that says where every cubic metre is.

```
constructor(width, depth, cellSize, params)      setBed(heights, width, depth, cellSize)   setBedAt(x, z, h)
setOutflowBoundary(sides)   fillTo(level, mask)  fillRect(level, x0, z0, x1, z1)   fillBasin(level, x, z)
addInflow(x, z, q) setInflow(id, q)   addSink(x, z, q) setSink(id, q)   pour(x, z, depth)
step(dt)   wakeAll()   close()
depthAt  bedHeightAt  surfaceHeightAt  surfaceVelocityAt  foamAt  turbulenceAt     (x, z grid-local metres)
particleCount  particleAt(k)  particlePositions  particleVelocities  particleRadii  particleKinds
ledger()  volume()  airborneVolume()  faceDischargeX(x, z)  time()  substepCount()  cellStepCount() ...
```

Positions are grid-local metres (x, z from the grid corner, y in the bed's datum). `origin()` places the grid in
the world. The bed is copied once into a padded array (`setBed` keeps no reference to the caller's array).

### Scheme and why

Finite volumes on a collocated grid, unknowns `h` (depth), `qx`, `qz` (discharge per metre), forward Euler with
Courant-limited substeps. Per face: minmod-limited linear reconstruction of the *surface* `bed + h` and of the
velocities, Audusse hydrostatic reconstruction against the higher of the two beds, HLL flux with Davis speeds
and Toro's dry-side speeds, hydrostatic correction terms for the cell momentum. Chosen over keeping the
linearised pipe model because it is the cheapest scheme that has all of:

- **well balanced**: a lake at rest is a flat surface, the limited slopes vanish exactly, both face states are
  equal and the momentum balance of a cell is a difference of equal numbers. Checked over a rough bed with a 2 m
  step (surface error 0 after 20 forced-awake steps) and over a rim with islands and thin films;
- **positive**: each cell scales its wanted outflow to what it holds; a face is paid by its donor on both sides,
  so volume is conserved to rounding. Dry cells carry no velocity;
- **sharp but monotone**: second order in space where the stencil is wet, first order at rims; bores and fronts
  keep a few cells without overshoot;
- **robust**: Manning friction is semi-implicit (`q / (1 + dt g n^2 |u| / h^(4/3))`), viscosity is a conservative
  momentum flux limited to its explicit bound, speed is capped, momentum under `restSpeed` is dropped.

Substep: `dt = cfl * cellSize / max(|u| + sqrt(g h))` (cfl 0.25; the unsplit scheme is positive below 0.5), cut
evenly so a step is a whole number of equal substeps. It is deterministic: it depends on the state only.

Known cost of the scheme: a sudden step in the bed loses head (hydrostatic reconstruction does not conserve
energy across a discontinuity). A broad-crested weir with a sharp upstream edge passes 0.78 of the ideal
`Q = 1.705 b H^1.5`; with the edge ramped over 8 m it passes the ideal within 0.4 % (test `weir`). Both are
reported by `measured` lines.

### Passes of a substep (hydro_passes, hydro_runner)

`ghosts` (serial, perimeter) -> `faces` -> `scale` -> `update` (parallel over active tiles, a barrier between
each) -> boundary books, lips launch, inflows/sinks (serial) -> particle `fly` (parallel) -> `settle` (serial) ->
`surface` (turbulence, foam; parallel). Each pass writes only what its own tile or particle owns, and reads what
no other item of the pass writes; fixed grains by index, so 1 and N workers are bit-identical (tested, also with
particles). An open side is a free outfall: a dry ghost at the edge's bed level.

**Rule learned the hard way:** never copy a `Shared<...>` into a local in code a worker thread runs. The count is
not atomic; a `let g = self.grid` in `runRange` crashed the process once a pass had more than a few chunks.
Pass `self.grid` as a borrowed argument.

### Activity and sleeping

Tiles of 32 x 8 cells. A tile with a flag runs, with its eight neighbours; the flag is cleared by a tile whose
speeds are all under `restSpeed` and whose face surface jumps are all under `restJump` (relative). A face next
to a sleeping tile carries no mass (but keeps its hydrostatic push), written by the running tile alone, so each
face has one writer. Anything that adds water or momentum from outside sets the flag. A calm lake costs a flag
scan (tested: zero cells awake).

### Overfall (hydro_lips, hydro_particles, hydro_air)

A *lip* is a face whose bed drops by more than `dropThreshold` (1.5 m). The HLL flux there is the free-overfall
discharge (critical flow emerges by itself); the donor loses it as usual, the receiving cell is told nothing, and
the lip accumulates it in an f64 carry. Particles are launched in layers: `ceil(cellSize / curtainSpacing)` across
the crest and a layer every `curtainSpacing / landingSpeed` seconds, so the gap in space at landing speed is the
spacing and never larger (tested: gap along the crest 0.5 m, along the fall 0.25 m for a spacing of 0.5 m). Exit
speed is the critical `(g q)^(1/3)`. A lip passing less than `minDischarge`, or a full pool, pours its carry
straight into the cell below, so water is never lost. Particles fall under the world's gravity with implicit
quadratic drag; an unstable parcel (gas Weber number above 12 for a time of order `d/v sqrt(rho_w/rho_a)`) splits
into two exact halves flying apart; landing deposits depth and a share of the horizontal momentum, a hard landing
throws a crown of spray (volume taken from the parcel) and writes
foam and turbulence. Particles per metre of crest alive: about `fallTime * landingSpeed / spacing^2` (a 10 m fall
at 0.5 m spacing: about 580 per metre of crest, 9.2 k for a 16 m crest). The pool is bounded by `capacity`.

### Books

`ledger()`: grid + airborne (particles + lip carries) + outflow + sunk + soaked = poured + inflow.
Measured on the waterfall (1152 m3 in): residual 1.7e-4 m3, 1.5e-7 relative; it is f32 rounding of cell depths.

## Memory budget

| Item | Bytes per cell |
|---|---|
| bed, depth | 8 |
| discharge qx, qz | 8 |
| velocity u, w | 8 |
| face fluxes (12 arrays) | 48 |
| lip flags | 2 |
| positivity scale | 4 |
| foam (two buffers), turbulence | 12 |
| deposit credit (error feedback, see `addDepth`) | 4 |
| total without dye | **94** |
| dye tracers (dye, concentration, credit), per tracer | 12 |
| total with the default 4 tracers | **142** |

512 x 512: 24.6 MB without dye, 37 MB with 4 tracers; 1024 x 1024: 98 MB and 149 MB. Per particle: pos 12 + vel 12 + radius 4 + volume 4 + kind 1 + clock 4
+ fate 1 = **38 bytes** plus 4 per tracer (54 with 4); 100 000 particles 3.8 MB, 5.4 MB with 4 tracers. Per tile: 24 bytes. Nothing allocates after construction
(`setBed`/`fillBasin` allocate once per call; `detect` allocates the lip list).

## Measured (this machine, 23 hardware threads, -O 3)

| Case | Result |
|---|---|
| grid 512 x 512, 47 104 cells awake (18 %), 1 worker | 2.72 ms per substep, 64 ms per million cell-steps |
| same, 8 workers | 0.58 ms per substep, 13.8 ms per million cell-steps |
| 93 761 particles falling, 8 workers (grid included) | 0.47 ms per substep, 5.2 ms per million particle-steps |
| 47 886 particles, 1 worker (grid included) | 16.7 ms per million particle-steps |

The target (512 x 512 at 30 %, 100 k particles, a few ms per substep) is met with margin; single-threaded the
grid is about 57 ns per cell-step, which is the main thing left to optimise (the face flux is not inlined).

## Checks

`tests/src/hydro.axle` (grid), `hydro_flow.axle` (weir, river), `hydro_fall.axle` (waterfall, gravity, threads,
cost): lake over rough bed and step, rim with islands, dam break positivity and volume, wave speed `sqrt(g h)`,
gravity scaling, friction and viscosity damping, open side, 1 vs 8 threads (grid and particles), repeatability,
sleeping, thin film, broad-crested weir within 15 % (measured 0.4 %), sharp-edged weir, reservoir at rest,
meandering river (every section carries the inflow, outflow equals inflow, books close), waterfall (curtain
spacing, plunge pool, steady state, foam, books, fall speed `sqrt(2 g H)`), cost.

## Audit of the legacy `FluidWorld`

Read: `fluid_world`, `field`, `tick`, `pipes`, `pool`, `runner`, `coupling` and the headers and parameter files of
the rest; the others (`liquid`, `aloft`, `surface`, `foam`, `vent`, `emit`, `impact`, `sample`, `noise`) were
skimmed for structure, not line by line. Findings, none fixed (see the decision above):

- the pipe model is linearised and has no hydrostatic reconstruction: no wet/dry well-balancing over a bed step,
  waves in deep water are slowed by the stability cap (`FLUID_STABILITY`) instead of substepping;
- everything is f64 in cell units, positions of particles included; the pools grow by doubling with `Vec`-like
  copies, awake lists are `Vec<i32>` rebuilt each tick;
- `FluidTick` keeps `i64` stamps (`awakeGen`, `touchCol`, `touchStamp`) where `i32` would do;
- one serial `FluidCoupling::settle` per tick walks all pools; a spawn that finds a pool full is handled
  (the volume stays with the particle), the books close (their tests pass);
- no volume leak was found; the determinism contract (fixed grain, serial settle) holds and is tested.


## Jets, edges and the readout (round 3)

- **Vents** (`hydro_vents`): `addVent(x, z, HydroVentParams)`, `setVent(id, discharge)`, `setVentPower(id, power)`. Liquid
  parcels leave a disc along an axis (tilt, azimuth) inside a cone, at a given speed; they break into spray, land and
  persist like the curtain. A vent draws from the grid cells around it (`fromGrid`, the default: the books close
  with no new term, the water returns when it lands) or books an external inflow. At most `maxRate` parcels a
  second (default 20 000; a parcel is `max(minParcel, discharge / maxRate)`), so a default jet keeps about 60 k alive
  at 0.5 m3/s; pulsed jets use `pulsePeriod`/`pulseDuty`. Measured: apex 10.2 m for 15 m/s (v^2/2g = 11.5; air drag
  takes 11 %), 2.72 m at 4g (2.87), ratio 3.74; discharge 0.50 m3/s drawn; books close to 6e-5 m3 of 1600; pulsed
  vent 1.004 m3 for 1.0 expected. What the three legacy examples use of `FluidWorld`, and its `HydroWorld` call:
  geyser `addSource`/`addSink`/`pour`/`sampleGround`/`levelAt`/`tick` -> `addInflow`/`addSink`/`pour`/`setBed`/`depthOfCell`/`step`
  (the chamber's discharge is `addVent(..., fromGrid = true)` or `setVent`; its own droplets are replaced by the vent's
  parcels); river `addSource`/`addSink`/`sampleGround` -> `addInflow`/`setOutflowBoundary`/`setBed`; intermittent the
  same plus `setGround` -> `setBedAt` and a time-varying `setInflow`. None of the three uses loads, impacts or the
  legacy particle layer.
- **Velocity readout**: `surfaceVelocityAt` is the staggered mean of the two face discharges over the depth.
- **Open sides**: a particle past an open side leaves (`HYDRO_FATE_LEAVE`) and is booked as outflow.
- **Inflows** pour only onto block cells whose bed is under the water of the centre cell.
- **Cliffs** are found over runs of up to three cells (`cliffSlope`), not only one.
- **Deposits** carry an error-feedback credit per cell: depositing the same tiny parcel thousands of times on a
  still pool lost water systematically (0.2 %); now the books close to 4e-8 relative.
- **Sharp step**: the 0.78 discharge coefficient is grid independent (the same at 1 m and 0.25 m cells), which is the
  Borda-Carnot loss of the momentum-conserving weak solution of an abrupt contraction; measured sharp-edged
  broad-crested weirs sit at 0.85 to 0.9. A ramped crest gives 0.996. I did not find a hydrostatic-reconstruction
  variant that is closer without breaking the exact rest balance.
- **Cost**: hoisting the arrays of the update pass into locals and skipping the friction cube root at rest gained about
  5 % single-threaded (63.2 to 60.3 ms per million cell-steps, same machine, alternating runs). The face flux is
  already inlined with a single division; its 26 bounds checks and the per-face reconstruction are the cost.


## Dye tracers and compartments (round 4)

`HydroParams.tracers` (default 4, 0 to 8; 0 turns them off) passive dyes. Per cell a tracer is the depth of dyed
water `dye` (concentration = dye / depth, 0 to 1); the positivity pass stores each concentration in `conc`, and the
update moves dye with the same face fluxes, the same donor factors and the donor's concentration (first-order upwind:
bounded and positive by construction, since the dye a cell loses is its water loss times its own concentration;
there is no limited second-order dye, so fronts smear by about a cell). Particles carry a dye fraction per tracer
(copied to the halves of a split and the drops of a crown, taken from the donor cell at a lip, from the pool at a
vent) and give it back where they land; every deposit uses an error-feedback credit like the water's. Dye
leaves with `drain`, sinks, open sides and particles that fly out. Tags: `addInflowDyed` / `setInflowTracer`,
`HydroVentParams.tracer` (external vents; a pool-fed vent throws what the pool holds), `fillToDyed`, `dyeRegion`.
Reads: `tracerAt` (what the renderer colours with), `tracerMass`, `airborneTracerMass`, `tracerLedger(k)`
(`residual()`), `volumeOfMask`. Memory: 12 bytes per cell per tracer (dye, concentration, credit) and 4 bytes per
particle per tracer; cost about 20 % more per cell-step with 4 tracers. Infiltration (default 0) removes water
without its dye, so with it on the dye books are not exact.

Measured: dam break 5e-8 relative dye residual; a steady-channel dye front 1.40 m/s against 1.45 m/s of water;
a lake dyed red drains over a lip, 876.2451 m3 left it and 876.2451 m3 of red water is below, dye residual 1.4e-8;
a jet in a dyed pool 6e-8; 1 and 8 workers identical; a closed world with a curtain and a jet (62 000 particles,
120 s) drifts 2.4e-8 relative (ledger and total agree), worst sample 4.8e-8, f32 grid with f64 books.

## Drifters (round 5)

`hydro_drifters`: up to `HydroParams.drifters` (default 2048, 0 off) Lagrangian markers. Floating, a marker is moved
by the engine's own velocity readout with the explicit midpoint rule over the engine's substep; it rides the water of
its own cell (an interpolated surface across a cliff would put it half way down), slides along walls and banks, is
stranded under 1 cm of water and floats again over 3 cm, and is gone past an open side. Crossing a lip face it
becomes a ballistic parcel with the local speed along the fall (at least `minExitSpeed`), a small `Pcg32` scatter and
the curtain's air drag, flies in micro-steps of at most 20 ms, and lands where the grid has water. Trails: a ring of
128 positions sampled every `trailInterval` (0.25 s). Memory per marker about 1.6 kB (trail 1536 B + 49 B), 3.3 MB
for 2048; stepping is serial in index order, so any worker count gives the same markers. `HydroSample::surface`
now ignores cells whose water is more than a cell above or below the nearest one (the far side of a cliff).

Measured: a marker on a steady channel moves at 1.4437 m/s, the mean surface velocity along its path 1.4437 m/s;
in the meandering channel it rides 97 m of path to the open foot, never farther than 1.2 m from the centre line;
over the 12 m lip it falls 11.91 m in 1.570 s (sqrt(2H/g) = 1.558 s) and 11.84 m in 0.780 s at 4g (0.777 s); it
lands 1.3 m from the wall; markers released within 6 m of the lip of a closed lake reach the pool in under 6 s.

A depth-averaged field is slower and stiller than what a float feels, so floating markers have two documented
corrections. **Surface layer:** the grid velocity is multiplied by `drifterSurfaceFactor` (1.2; the surface of a
turbulent stream runs 1.15 to 1.3 times the mean; 1.0 disables). **Eddy mixing:** each substep a marker is displaced by
`sqrt(2 D dt) N(0, 1)` along x and along z, with `D = drifterDiffusion * h * (u* + turbulence * sqrt(g h))`, where
`u* = sqrt(g) n |u| / h^(1/6)` is the friction velocity of the Manning bed and `turbulence` is the engine's 0..1 field
(shear and landing energy); the normal number is four stateless hash uniforms summed, keyed by marker id, substep
and axis, so it is identical for any worker count. The default 0.5 gives `D` = 0.05 m2/s in the calm 0.5 m deep
channel (1.4 m/s): a 1.2 m spread after 20 s on a 29 m drift, and about 0.6 m2/s under a curtain where
the turbulence is 1, enough to carry a marker out of the plunge pool in a minute. Measured: 200 markers on the
channel drift at 1.7312 m/s against 1.2 x 1.4444 = 1.7333 m/s (0.1 %), their spread is 1.20 m against
`sqrt(2 D t)` = 1.41 m (the channel's mixing is a little under the model's, which uses the mid-channel values);
24 markers released above the 12 m lip of the cascade-like world all leave the pool through the outlet, on average 34.5 s
after release (the last at 96.7 s); in a closed pool all 12 still float and move 4 minutes later.

## Aerated parcels (round 7)

A conservative splash-aeration emitter: a parcel landing faster than `aerationSpeed` (6 m/s, a kinetic-energy
threshold) hands `aerationShare` (4 %) of its water to up to `aerationPerLanding` (32) aerated parcels of
`aerationParcel` (5e-5 m3) each, drawn at a radius of 0.1 to 0.4 m (`radius`), launched at up to 0.6 of the impact
speed, mostly upward (vertical share 0.7 to 1 of the launch speed, horizontal radial up to half of it at a random
azimuth, plus a fifth of the parent's horizontal velocity), each living 0.5 to 1.5 times `aerationLife` (2 s). The
scatter is a stateless hash of the landing number and the parcel, so 1 and N workers agree. The kind is
`HYDRO_AERATED` (2), counted apart: `aerationCapacity` (150 000) parcels on top of the water pool, and at most
`aerationPerStep` (60 000) launched per substep; when the cap or the budget is reached the landing keeps its water,
so the emitter degrades by making less froth, never by losing water. Aerated parcels are braked as if their density
were `aerationDensity` (100 kg/m3), do not break up, and at the end of their life (or on touching water) pour their
volume, their dye and a share of their momentum back into the cell under them, without a splash of their own. Default
4 % is the order of the air a plunging jet entrains; at 12 m3/s about 10 000 parcels are alive at once, at 100 m3/s the
cap. Renderers: `particleKinds()` gives 2, `particleRadii()` the radius to draw, `particleAges()[k] /
particleLives()[k]` (0 to 1) the fade. Memory: 38 + 4 (life) + 4 per tracer bytes per parcel, pooled once at
construction (150 000 parcels about 6 MB without tracers, 8 MB with 4).

Measured on the 12 m fall (12 m3/s, 8 workers): up to 10 517 aerated parcels with 2 418 liquid; 0.459 ms per substep
against 0.359 without the emitter; the water ledger residual 3.9e-6 m3 of 528; under a cap of 500 the count peaks at
500 with the books closed (2e-5 m3); a closed world with the emitter running (27 000 parcels) drifts -4.9e-8
relative; 1 and 8 workers are bit-identical.
## Still weak

- `surfaceVelocityAt` is built from face discharges and agrees with the flow meter (3.000 against 3.000 m3/s in the
  steep bend), but `dischargeXOfCell` still returns the momentum variable, which ran 35 % ahead of the mass there.
- Entry loss at a sharp step (above); the engine is not energy conserving across a discontinuity.
- First-order time stepping; second-order in space only.
- A curtain falling a long way breaks only after the Weber time; the spray is cosmetic.
- Lip detection and `setBed` allocate; `setBedAt` re-detects every lip (fine for edits, not per frame).
- The legacy engine is unchanged and still f64.
