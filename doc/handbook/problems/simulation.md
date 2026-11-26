# Problems of the simulation layer (`src/sim`)

A glossary of needs: "I want X" -> the mathematical or algorithmic means the code uses, and what it costs. Every formula,
constant and complexity below was read in the file named in **Where**; a claim that could not be checked is marked
`UNVERIFIED`. Symbols: N bodies, C contact points, M manifolds, J joints, P particles, K cells of a grid. Line numbers are those
of the working tree when this file was written.

Existing prose for this zone: `doc/FLUID.md` (the water engines; the only chapter of its kind), `doc/handbook/render/15-view-layers.md`
section 3.6 (particles) with `doc/design/particles-wind.md`, and one-line summaries in `doc/ROADMAP.md:28-35`. There is no handbook
chapter yet for kinetic, animation, audio or navigation: those entries say `MISSING`.

`src/sim` holds six directories (`animation audio fluid kinetic navigation particles`); `doc/ARCHITECTURE.md:10` also lists
"gameplay", which does not exist (see Doubts).

---

## Rigid bodies: stepping and integration (`src/sim/kinetic`)

### S-01. I want a rigid-body simulation that gives the same state on every run, whatever the frame rate
- **Means:** fixed internal step (`settings.substep`) fed by a time bank; one `advance()` is a full step; no wall clock.
- **Mathematics:** none: plain arithmetic. Step length h = 1/120 s (`physics_settings.axle:15`); `step(dt)` adds dt to a bank and runs
  floor(bank / h) whole steps (1e-12 slack), at most 64 per call; if more than h is left after the cap it is dropped
  (`physics_world.axle:37,423-437`). Simulated time = steps x h (`:481`).
- **Instructions:** one `advance()` runs: integrateVelocities, skipKeys, contacts.beginStep, up to 3 collide passes, solve,
  integratePositions, Sleeper.update (`physics_world.axle:440-455`). All loops run in slot order; slots are issued in creation order
  (`body_store.axle:1-7`).
- **Cost:** O(steps per frame x cost of one step); a frame of dt costs ceil(dt/h) steps, capped at 64 (a frame longer than 0.53 s
  loses time). Memory: see S-02 and S-13. No measured figure in the files read.
- **Why this and not another:** the settings comment says "a stiffer stack wants more velocityIterations, a game with fast small objects
  wants a shorter substep" (`physics_settings.axle:1-6`); a variable step is not offered (header `physics_world.axle:1-8`: "never changes, so
  the same inputs give the same state"). `advance()` exists for callers that pace themselves with a `FixedStep`.
- **Where:** `src/sim/kinetic/physics_world.axle:423` (`step`), `:440` (`advance`), `src/sim/kinetic/physics_settings.axle:10`.
- **Docs:** MISSING (`doc/ROADMAP.md:28-31` has one line).

### S-02. I want bodies to fall, be pushed, drag and spin, and to push a body with an impulse at a point
- **Means:** semi-implicit Euler on velocities with implicit damping; positions advance with the mean of start and end velocity.
- **Mathematics:** v' = (v + (g s + F/m) h) / (1 + h c): g gravity, s the per-body `gravityScale`, F the applied force (cleared after the
  step), c the damping rate; the factor 1/(1 + h c) is "implicit, so any step is stable" (`physics_world.axle:485-508`). Angular: w' =
  (w + I_w^-1 tau h) / (1 + h c_ang). There is no gyroscopic term w x (I w) in this function (read, not tested).
  Position: x += h ((v + v_prev)/2 + pseudo-velocity); orientation q = exp(w h) q via `DQuat::fromAxisAngle(w/|w|, |w| h)`, skipped when
  |w| h <= 1e-12 (`:596-625`); the mean-velocity rule is "exact for constant acceleration" (comment `:603-604`).
  `applyImpulseAt(J, at)`: dv = J/m, dw = I_w^-1 ((at - x) x J), written to both `velocity` and `prevVelocity` so the step sees no jump (`:267-284`).
- **Instructions:** one pass over slots for velocities (skips dead, non-dynamic and sleeping bodies); one pass for positions (skips
  static and sleeping); `refreshInertia` (R diag(1/I) R^T, nine entries unrolled by hand) after every rotation (`body_store.axle:301-316`).
- **Cost:** O(N) per step, f64 throughout. Per-body storage is one `Vec` per field (`body_store.axle:102-130`): about 390 bytes of scalar
  fields (position 24, rotation 32, six DVec3 velocity/force fields 144, invInertiaW 72, the f64 and i32 scalars; counted from the field list)
  plus the `Shape`; assumes `Vec<bool>` packs to one byte, UNVERIFIED.
- **Why this and not another:** not documented beyond "keeps a bounce from adding the energy of half a step" (`:603`).
- **Where:** `src/sim/kinetic/physics_world.axle:485` (`integrateVelocities`), `:596` (`integratePositions`), `:267` (`applyImpulseAt`).
- **Docs:** MISSING.

### S-03. I want a handle to a body that stays invalid after the body is removed and its slot reused
- **Means:** `EntityId` (index + generation) from an `IdAllocator`; the index is the slot; internal loops use slots.
- **Mathematics:** none: plain arithmetic (`slotOf` answers -1 when `ids.isAlive(id)` is false, `body_store.axle:180-185`).
- **Instructions:** a removed body keeps its slot (`live=false`, `asleep=false`); `add` reuses a freed slot in place or appends to all the arrays
  (`body_store.axle:193-262,289-298`); `removeBody` first deactivates every joint of the slot, O(J) (`physics_world.axle:99-112`).
- **Cost:** O(1) per lookup; O(J) per removal; arrays never shrink (slotCount only grows).
- **Why this and not another:** not documented (comment: "stays invalid even after its slot is reused", `body_store.axle:1-7`).
- **Where:** `src/sim/kinetic/body_store.axle:180`, `:193`, `:289`.
- **Docs:** MISSING.

### S-04. I want mass, inertia and a bounding box from a shape
- **Means:** closed-form solid inertia tensors (diagonal, body frame); AABB from the rotated half extents.
- **Mathematics:** sphere I = (2/5) m r^2 (`shape.axle:20`); box I_x = m (Y^2 + Z^2)/12 with Y, Z the full side lengths (`:124-130`); capsule =
  cylinder + two hemispheres, mass shared by volume, hemispheres moved off the centre with the parallel axis theorem, their centre of mass
  3r/8 from the flat face: I_y = m_c r^2/2 + (2/5) m_h r^2, I_x = m_c (3 r^2 + h^2)/12 + m_h ((2/5) r^2 + h^2/4 + 3 h r/8) (`:134-149`; the algebra
  was re-derived and agrees with the code). AABB of a box: extent_i = sum_j |R_ij| half_j (`:171-177`); capsule: |R (0, half_y, 0)| + r per axis (`:179-187`).
  A plane is unbounded (1e30) and may belong to a static body only (`:1-9,17`).
- **Instructions:** `BodyStore.add` stores 1/m and the componentwise inverse of the inertia diagonal (zero where an axis has none: locked); static
  and kinematic bodies get mass 0 (`body_store.axle:266-285`).
- **Cost:** O(1) per body.
- **Why this and not another:** shapes are centred on the centre of mass so the tensor stays diagonal and "a body needs only three numbers" (`shape.axle:1-9`). No compound or mesh shape exists in the zone.
- **Where:** `src/sim/kinetic/shape.axle:115` (`inertia`), `:162` (`aabb`), `:97` (`volume`).
- **Docs:** MISSING.

---

## Rigid bodies: collision detection

### S-05. I want to find the pairs of bodies that might touch without testing all N^2
- **Means:** sweep and prune along X with a stable merge sort; planes tested separately against every body.
- **Mathematics:** none: plain arithmetic. Sort key is the box min.x; for each body the following ones in sorted order are tested while
  `next.min.x <= cur.max.x`, then the Y and Z intervals (`broad_phase.axle:105-124`). Plane vs box: reach = sum |n_i| h_i, test
  n.c - d - reach <= 0 (`:127-146`).
- **Instructions:** `computeBoxes` recomputes every live body's AABB each step (no fattening, no incremental update) (`:85-102`); `KineticSort::indicesByKey` is a bottom-up
  merge sort on indices that ping-pongs two buffers and allocates a scratch `i32[n]` per call (`kinetic_sort.axle:31-52`); a pair is packed `(lo << 32) | hi` into an `i64`
  and the list is sorted at the end (`broad_phase.axle:80`, `kinetic_sort.axle:16,87-108`).
- **Cost:** O(N log N) for the sort + O(N + K_x) for the sweep, K_x being the pairs that overlap in X (worst case O(N^2) when everything overlaps in X);
  planes O(planes x N); final pair sort O(K log K). Memory: order i32 + key f64 per slot, one DAabb per slot, pair list 8 bytes a pair doubling from 64
  (`:16-17,199-208`). The sweep axis is fixed at X. No measured figure.
- **Why this and not another:** the header says the sort and the (lower, higher) pair order make "the pair list the same for the same scene whatever order the sweep found them in" (`broad_phase.axle:1-6`); no grid or tree alternative is discussed.
- **Where:** `src/sim/kinetic/broad_phase.axle:67` (`update`), `:105` (`sweep`), `:127` (`testPlanes`).
- **Docs:** MISSING.

### S-06. I want to switch collisions off between groups, between jointed bodies and between two resting bodies
- **Means:** group/mask bit tests; a sorted skip list of pair keys searched by binary search; a pair is offered only if one body is dynamic and one is awake.
- **Mathematics:** a pair collides iff (g_x & m_y) != 0 and (g_y & m_x) != 0 (`broad_phase.axle:180-184`); the skip test is `lowerBound` on sorted `i64` keys (`kinetic_sort.axle:143-155`).
- **Instructions:** `skipKeys` rebuilds the list of jointed pairs each step (allocates `i64[J+1]`, sorts) unless the joint has `collide` (`physics_world.axle:511-528`);
  `BroadPhase.active`: awake and (dynamic, or kinematic and moving) (`broad_phase.axle:159-169`).
- **Cost:** O(J log J) per step for the skip list, O(log J) per candidate pair.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/broad_phase.axle:173`, `src/sim/kinetic/physics_world.axle:511`.
- **Docs:** MISSING.

### S-07. I want two convex shapes to know if they touch and by how much (sphere, box, capsule, plane)
- **Means:** a pair table ordered by shape kind (sphere 0, box 1, capsule 2, plane 3); a pair given in the other order is swapped and its normal flipped. Result: a normal from first to second and up to 4 points, each with depth and feature id.
- **Mathematics:** none: plain arithmetic at this level (dispatch). The pair tests are S-08 to S-12.
- **Instructions:** `collidePlaced` clears the scratch buffer, orders the pair, calls the test, flips the normal if swapped (`narrow.axle:35-51,81-86`). A plane as first shape answers false.
- **Cost:** O(1) per pair (box-box the largest: S-09).
- **Why this and not another:** "so each combination is written once" (`narrow.axle:1-5`). No GJK/EPA exists in the zone (the box case is a hand-written SAT).
- **Where:** `src/sim/kinetic/narrow.axle:20,35,44`.
- **Docs:** MISSING.

### S-08. I want contacts for spheres, capsules and planes
- **Means:** closest-point problems: a capsule is a segment with a radius; a capsule pair is the nearest points of two segments; a second contact when capsules lie alongside.
- **Mathematics:** sphere-sphere: d = pb - pa, hit iff |d|^2 < (ra + rb)^2, n = d/|d| (fixed +Y when |d| <= 1e-6), depth = ra + rb - |d|, point = pa + n (ra - depth/2) (`narrow_basic.axle:49-73`).
  Sphere-plane: sd = n.p - d, hit iff sd < r, depth r - sd, point p - n (r + sd)/2 (`:76-84`). Capsule-plane: one point per cap end below the plane (`:94-109`). Box-plane: each of the 8 corners below the plane is a point, then `reduceToFour` (`:112-137`).
  Segment-segment: nearest parameters (s, t) by the clamped closed-form solve with denominator a e - b^2 guarded by 1e-12 a e (`kinetic_geometry.axle:35-75`; the textbook algorithm, the file names no source). Capsule pair: n from the nearest points; touching axes use the cross product of the axes, parallel ones any perpendicular (`narrow_basic.axle:187-197`); the second contact is the axis end whose pair vector lies within cosine 0.95 (about 18 degrees) of n and farthest from the main point, kept only if its squared spread exceeds 0.01 (r_a + r_b)^2 (`:220-247`, constants `:15-19`).
- **Instructions:** all f64; every divide guarded; feature ids: sphere 0, capsule ends 0 and 1, capsule pair 0 plus end 1-4, box corners 0-7.
- **Cost:** O(1) per pair; no measured figure.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/narrow_basic.axle:49,76,94,112,152,220`, `src/sim/kinetic/kinetic_geometry.axle:22,35`.
- **Docs:** MISSING.

### S-09. I want box against box contacts that do not flicker when a stack rests
- **Means:** separating axis test over the 15 candidate axes; face contact by clipping the incident face to the four side planes of the reference face; edge contact as one point.
- **Mathematics:** overlap depth along a unit axis L: d(L) = reach_A(L) + reach_B(L) - |D.L|, reach(L) = sum_i half_i |axis_i . L|, D = centre_B - centre_A; d < 0 separates (`narrow_box.axle:80-96`). Axes: 3 faces of A, 3 of B, 9 edge cross products (skipped when |a x b|^2 < 1e-6: parallel). The axis of least overlap decides. Face A is the reference unless B's face depth is below 0.98 of A's (`BOX_FACE_BIAS`, `:21,280`); an edge axis wins only if `edge.depth + 0.0005 < 0.95 face.depth` (`:23-26,284`): "edges are unstable contacts".
  Edge contact: nearest points of the two infinite edge lines, clamped to the half lengths (`:352-374`); the point is the midpoint, id 100 + 3i + j.
- **Instructions:** cheapest groups first (A faces, B faces, edges) with early exit on the first separating axis (`:264-276`); `faceContact` picks the incident face most anti-parallel to the reference normal (`incidentFace`, `:422-451`), clips it against 4 side planes (two `ClipPoly` scratch polygons ping-pong, `:455-478`), keeps vertices below the reference face at half-way height with depth -dist (`:405-412`), then `reduceToFour`.
- **Cost:** O(1) per pair, a few hundred flops (15 axes with 6 absolute dot products each, 9 cross products, 4 clip passes of a polygon of at most 8 vertices). No measured figure.
- **Why this and not another:** face contacts are preferred "which keeps a resting stack from flickering between the two" (`narrow_box.axle:5-9`); the biases 0.98 / 0.95 / 0.0005 are tuned constants with no stated derivation.
- **Where:** `src/sim/kinetic/narrow_box.axle:259` (`boxBox`), `:292`, `:307`, `:330`, `:378`.
- **Docs:** MISSING.

### S-10. I want at most four well-spread contact points per pair
- **Means:** contact-patch reduction: deepest, farthest from it, largest triangle, then the opposite side.
- **Mathematics:** with twice the signed area A(p0, p1, k) = ((p1 - p0) x (p_k - p0)) . n: i0 = deepest, i1 = farthest from i0, i2 = argmax |A|, i3 = argmax of A on the opposite side of i2 plus 1e-6 x squared distance to i2 as tie-break (`contact_buffer.axle:105-124,135-209`; `CONTACT_TIE_WEIGHT` `:15`).
- **Instructions:** four linear scans over the points, then clear and re-add the four.
- **Cost:** O(n), n at most 8 here (a clipped quad, or the 8 corners of box-plane). A manifold keeps `CONTACT_MAX_POINTS` = 4 (`:11`).
- **Why this and not another:** "four well spread points hold a box up; more only cost time" (`contact_buffer.axle:101-104`).
- **Where:** `src/sim/kinetic/contact_buffer.axle:105`.
- **Docs:** MISSING.

### S-11. I want a contact point to be recognised again next step (stable feature ids)
- **Means:** each contact carries a feature id naming the vertex, edge or face that produced it; clipped vertices get ids from a pure function of the cut edge's two ends and the plane.
- **Mathematics:** cut id = 4096 + ((5 ia + 3 ib + plane + 1) & 4095) (`clip_poly.axle:14-19,88-91`; ids are folded, so two cuts can collide); face contact id = (2k+1) x 64 + (2m + side) x 4 + corner (`narrow_box.axle:34-39,444-445`); edge ids start at 100 (`:39`).
- **Instructions:** clip step: for each polygon edge a, b with signed plane distances da, db keep b if inside and add the crossing a + (b - a) da/(da - db) when the sides differ (`clip_poly.axle:60-84`).
- **Cost:** O(vertices) per clip plane.
- **Why this and not another:** "so the same geometric configuration gives the same ids on the next step" (`clip_poly.axle:1-5`).
- **Where:** `src/sim/kinetic/clip_poly.axle:60,88`.
- **Docs:** MISSING.

### S-12. I want a sphere or capsule to collide with a box
- **Means:** closest point of the box to the sphere centre in the box frame (clamp); capsule: golden-section search for the axis point nearest the box, then three sphere tests.
- **Mathematics:** local c = R^T (p - x_box), q = clamp(c, -h, h), delta = c - q; hit iff |delta|^2 < r^2, depth r - |delta|, normal delta/|delta|. A centre inside the box (|delta|^2 <= 1e-18) leaves through the nearest face with depth r + (h_i - |c_i|) (`narrow_box.axle:127-170`). Capsule: the distance to a convex set is convex along a line, so a golden-section search (ratio 0.618..., 40 steps, the interval shrinks by 0.618^40, about 4e-9) finds the nearest axis point (`:172-176,232-256`, `BOX_GOLDEN_STEPS` `:44`); samples are the two caps and that point; the deepest fixes the normal, the others become points when their normal agrees (cosine > 0.9) and they lie more than 1% of r apart (`:177-218`, `:53-54`).
- **Instructions:** about 42 distance-to-box evaluations (clamps) per capsule/box pair.
- **Cost:** O(40) distance evaluations per capsule/box pair (constant); O(1) for sphere/box.
- **Why this and not another:** not documented beyond the convexity remark.
- **Where:** `src/sim/kinetic/narrow_box.axle:116,127,177,232`, `src/sim/kinetic/kinetic_geometry.axle:78`.
- **Docs:** MISSING.

---

## Rigid bodies: constraint solving

### S-13. I want a stack of boxes to rest without sinking, jittering or exploding (non-penetration with friction)
- **Means:** sequential impulses (projected Gauss-Seidel on velocity constraints) with accumulated, clamped impulses and warm starting.
- **Mathematics:** per contact point the effective mass m_N = 1 / (1/m_a + 1/m_b + (r_a x n).I_a^-1 (r_a x n) + (r_b x n).I_b^-1 (r_b x n)) (`contact_solver.axle:82-91`).
  Normal row: lambda = m_N (bounce - v_n); accumulated J_n <- max(J_n + lambda, 0); apply (J_n,new - J_n,old) n (`:126-132`). Friction rows along two
  tangents t1 = n.anyPerpendicular, t2 = n x t1: the accumulated tangent impulse is clamped to the cone |J_t| <= mu J_n with mu = sqrt(mu_a mu_b) (`:108-124`;
  `physics_world.axle:578`); the cone uses the J_n accumulated so far, and friction is applied before the normal row of the same point. Order per iteration: joints, then contacts ("contacts have the last word", `physics_world.axle:457-458`).
- **Instructions:** `state.load` copies v, w, 1/m and the world inverse inertia of every body into flat f64 arrays (176 bytes a slot: vel 48, pseudo 48, invM 8, invI 72; grown by half again), with zero inverse mass for static, kinematic and sleeping bodies so the same formulas serve every pair (`solver_state.axle:40-79`); `prepare` per point; `warmStart`; 10 velocity iterations (`physics_settings.axle:18`).
- **Cost:** O(velocityIterations x (C + J)) per step plus O(N) for load/store. ContactPoint is about 252 bytes of fields (12 f64, six DVec3, three i32) and the set keeps two copies, this step and the last (`contact_set.axle:94-120`). No measured figure.
- **Why this and not another:** not documented (no direct or block solver is discussed).
- **Where:** `src/sim/kinetic/contact_solver.axle:19` (`prepare`), `:103` (`iterate`), `src/sim/kinetic/physics_world.axle:459` (`solve`).
- **Docs:** MISSING.

### S-14. I want a stack to settle quickly (warm starting)
- **Means:** the accumulated impulses of the last step are re-applied at the start of this one for contacts matching by (pair, feature id).
- **Mathematics:** none: plain arithmetic. `inherit` finds the old manifold by binary search on the pair key (manifolds are ordered like the broad-phase pairs) and copies J_n, J_t1, J_t2 of the point with the same feature (`contact_set.axle:133-175`); `warmStart` applies J_n n + J_t1 t1 + J_t2 t2 (`contact_solver.axle:94-100`). `warmStarting=false` zeroes them (`:41-47`).
- **Instructions:** `beginStep` copies all of last step's points and manifolds into the old lists, O(C + M); `inherit` is O(log M + 4) per point.
- **Cost:** O(C log M) per step.
- **Why this and not another:** "which is what lets a stack settle" (`contact_set.axle:1-7`); the alternative is the `warmStarting` switch.
- **Where:** `src/sim/kinetic/contact_set.axle:109,133`, `src/sim/kinetic/contact_solver.axle:94`.
- **Docs:** MISSING.

### S-15. I want a ball to bounce to the right height and rest without hopping (restitution)
- **Means:** target separating speed e (-v_before) taken from the velocities at the start of the step, and only above a speed threshold.
- **Mathematics:** bounce = -e v_n,prev if v_n,prev < -threshold (default 1 m/s, `physics_settings.axle:24`), else 0; e = max(e_a, e_b) (`physics_world.axle:579`). Using the pre-gravity velocity avoids handing the ball "a step of speed it never earned" (`contact_solver.axle:52-69`).
- **Instructions:** reads `prevLinearVelocity` and `prevAngularVelocity` of both bodies at each contact point.
- **Cost:** O(1) per contact.
- **Why this and not another:** explained in the comment of `bounceSpeed` (each bounce would otherwise climb a little higher).
- **Where:** `src/sim/kinetic/contact_solver.axle:57`.
- **Docs:** MISSING.

### S-16. I want overlapping bodies pushed apart without adding energy (split impulse)
- **Means:** a second solve on "pseudo velocities" that move positions only and never enter the real velocities.
- **Mathematics:** push speed s = min(max(depth - slop, 0) x pushFactor / h, maxPushSpeed), reduced by the speed at which the contact already leaves: s' = max(s - max(v_n, bounce), 0) (`contact_solver.axle:74-79`; defaults slop 0.005 m, pushFactor 0.4, maxPushSpeed 4 m/s, `physics_settings.axle:27-33`). Position pass: lambda = m_N (s' - v_n,pseudo), accumulated jp clamped >= 0 (`:138-154`). Positions then advance with v + pseudo (`physics_world.axle:605-614`).
- **Instructions:** 6 position iterations (`positionIterations`, `physics_settings.axle:21`); pseudo arrays zeroed in `load`.
- **Cost:** O(positionIterations x (C + J)) per step.
- **Why this and not another:** "fixing a penetration never adds real energy" (`contact_solver.axle:1-7`).
- **Where:** `src/sim/kinetic/contact_solver.axle:74,138`.
- **Docs:** MISSING.

### S-17. I want a ball-and-socket joint (shoulder, pendulum pivot) that does not drift
- **Means:** a 3-row point constraint solved as a 3x3 block with accumulated impulse; the position error fed back on pseudo velocities.
- **Mathematics:** the relative anchor velocity must vanish: P = -K^-1 (v_B + w_B x r_B - v_A - w_A x r_A) accumulated; K = (1/m_A + 1/m_B) E - [r_A] I_A^-1 [r_A] - [r_B] I_B^-1 [r_B], [r] the skew matrix (`joint_solver.axle:320-338`); position bias b = (p_B - p_A) beta/h with beta = `jointBeta` 0.3 (`:36,90`), position pass P = -K^-1 (v_pseudo,rel + b) (`:198-200`).
- **Instructions:** `prepare` computes anchors, K^-1 (a 3x3 inverse per joint per step), re-applies the carried impulse; velocity loop 10x, position loop 6x. A joint to the world uses the extra solver slot with zero inverse mass (`solver_state.axle:1-8,45`).
- **Cost:** O(J) per iteration, one 3x3 inverse per joint per step.
- **Why this and not another:** the header says "Baumgarte, a fraction `jointBeta` of it per step" (`joint_solver.axle:1-6`); in the code the bias is used only in the position (pseudo-velocity) pass, never in the velocity pass (see Doubts).
- **Where:** `src/sim/kinetic/joint_solver.axle:82` (`preparePoint`), `:153` (`iterate`), `:181` (`iteratePosition`), `src/sim/kinetic/physics_world.axle:289` (`addBallSocket`).
- **Docs:** MISSING.

### S-18. I want a rigid rod between two points (distance joint)
- **Means:** a single scalar constraint along the line between the anchors.
- **Mathematics:** direction u = (p_B - p_A)/|p_B - p_A|; effective mass 1/(1/m_A + 1/m_B + (r_A x u).I_A^-1 (r_A x u) + (r_B x u).I_B^-1 (r_B x u)); lambda = -m (v_rel . u), accumulated; position bias (|p_B - p_A| - L) beta/h (`joint_solver.axle:61-79,162-166,190-193`). L is the anchor distance at creation (`physics_world.axle:312`).
- **Instructions:** one row per joint; the accumulated impulse lives in `lin.x`.
- **Cost:** O(1) per joint per iteration.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/joint_solver.axle:61`, `src/sim/kinetic/physics_world.axle:303`.
- **Docs:** MISSING.

### S-19. I want a hinge (door, knee) with angle limits
- **Means:** a ball-and-socket plus two angular rows keeping the hinge axes parallel and a one-sided limit row.
- **Mathematics:** axes a_w (body A) and b_w (body B); two rows along t1, t2 perpendicular to a_w drive the axes together (error e = b_w x a_w, bias e.t_i beta/h) (`joint_solver.axle:121-130`); each row's angular effective mass is 1/(d.I_A^-1 d + d.I_B^-1 d) (`:298-304`). Angle = atan2((r_A x r_B).a_w, r_A.r_B), r the stored reference directions (`:262-267`); a limit row is live only at or past a limit, with bias -(angle - limit) beta/h and its accumulated impulse clamped to the side that pushes back inside (`:132-148,211-221`).
- **Instructions:** reference directions refA/refB are stored at creation (`physics_world.axle:318-335`); `setHingeLimits(lower, upper)` in radians from the creation pose; `hingeAngle` reads the angle.
- **Cost:** O(1) per joint per iteration: three angular rows plus the 3-row point block.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/joint_solver.axle:108` (`prepareHinge`), `:240` (`iterateHinge`), `:223` (`positionHinge`), `src/sim/kinetic/physics_world.axle:318,338`.
- **Docs:** MISSING.

### S-20. I want resting bodies to cost (almost) nothing, and a stack never to lose its top while the bottom settles (sleeping islands)
- **Means:** rest timers plus union-find islands over contacts and joints; an island sleeps only when every dynamic member has rested long enough.
- **Mathematics:** none: plain arithmetic. Rest when |v| < 0.05 m/s and |w| < 0.08 rad/s; a timer adds h while calm and resets otherwise; sleep when the timer >= 0.5 s for all members (`physics_settings.axle:42-48`, `sleeper.axle:100-113,117-137`). Union-find with path halving; the lower root wins so the result does not depend on call order (`:35-53`). A moving kinematic body touching a dynamic body blocks its sleep (`:176-194`).
- **Instructions:** `Sleeper.update` allocates `parent`, `ready`, `blocked`, `idOf` (n+1 ints each) every step and walks all manifolds and joints (`:59-92,117-172`); sleepers get zero velocities; `SolverState.load` gives sleepers zero inverse mass.
- **Cost:** O(N + M + J) per step with near-linear union-find, plus four O(N) allocations per step. A sleeping body still costs a flag test in every loop over slots.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/sleeper.axle:59` (`update`), `:19` (`wakeIsland`).
- **Docs:** MISSING.

### S-21. I want a sleeping pile to wake when something touches it
- **Means:** a narrow-phase hit on a sleeping body wakes its whole island and the collide pass is redone.
- **Mathematics:** none: plain arithmetic. `wakeIsland(i)` scans all slots for the same island id (`sleeper.axle:19-32`).
- **Instructions:** `collide` answers true when it woke anything; `advance` repeats it at most `WORLD_COLLIDE_PASSES` = 3 times (`physics_world.axle:39-40,447-450,553-558`); setters (`setPosition`, `applyForce`, ...) also wake.
- **Cost:** O(N) per wake (full slot scan), up to 3 broad + narrow passes in a step that wakes something.
- **Why this and not another:** not documented.
- **Where:** `src/sim/kinetic/sleeper.axle:19`, `src/sim/kinetic/physics_world.axle:531`.
- **Docs:** MISSING.

---

## Rigid bodies: queries, measurement, replay

### S-22. I want a ray cast and overlap queries that use the same shape tests as the simulation
- **Means:** per-shape analytic ray tests in the body's frame; overlap = AABB reject, then the real narrow phase with a temporary probe shape.
- **Mathematics:** sphere: m = o - c, b = m.d, cc = m.m - r^2; hit when cc <= 0 (inside, t = 0) or b < 0 and b^2 - cc >= 0, t = -b - sqrt(b^2 - cc) (`physics_query.axle:122-139`). Box: slab method over three axes, tNear/tFar (`:141-182`). Capsule: infinite cylinder in xz (quadratic with discriminant b^2 - a c) clipped to |y| <= half length, plus two cap spheres that count only on their own side (`:184-222`). Plane: half-space (`:110-120`).
- **Instructions:** one loop over all slots; ties go to the lower slot (`:69-70`); overlap tests call `Narrow::collidePlaced`, so "overlaps" means "would collide" (`:235-265`).
- **Cost:** O(N) per query with no acceleration structure (header `physics_query.axle:1-6`); the header's "after a cheap box test" is not what `raycast` does (see Doubts).
- **Why this and not another:** "There is no acceleration structure behind either" (header).
- **Where:** `src/sim/kinetic/physics_query.axle:51` (`raycast`), `:235` (`overlapInto`), `src/sim/kinetic/physics_world.axle:630-642`.
- **Docs:** MISSING.

### S-23. I want to prove two runs of a physics scene agree, and to check energy and momentum
- **Means:** a quantised fold hash of every body; conserved-quantity sums.
- **Mathematics:** h <- hashCombine(h, slot); for each of position, linear velocity, angular velocity, quaternion xyz and w: hashCombine(h, trunc(clamp(x, +-1e9) x 1e9)); NaN or infinity fold to -1; a sleeping body folds in tag 7 (`state_hash.axle:14-65`). Energy: E_k = sum 1/2 m |v|^2 + sum over principal axes 1/2 w_i^2 / invI_i (w in the body frame), E_p = - sum m s g.x (`physics_measure.axle:13-50`); momentum = sum m v (`:52-61`).
- **Instructions:** one pass over slots; quantisation makes the hash "independent of the last bit of a float".
- **Cost:** O(N). The hash is an i64 (the engine's `hashCombine`).
- **Why this and not another:** comment: "which no two correct compilers agree on" (`state_hash.axle:1-6`).
- **Where:** `src/sim/kinetic/state_hash.axle:30`, `src/sim/kinetic/physics_measure.axle`, `src/sim/kinetic/physics_world.axle:703-723`.
- **Docs:** MISSING.

### S-24. I want to see the physics world (shapes, contacts, joints) as lines and points
- **Means:** `DebugDraw` flat arrays (six numbers per line, three per point, 0xRRGGBB colour), coloured by body state.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `debugDraw` outlines every shape (static, kinematic, asleep, awake colours), draws each contact point with a 0.25 m normal and each joint anchor pair (`physics_world.axle:648-683`).
- **Cost:** O(N + C + J) output.
- **Why this and not another:** kinetic "draws nothing itself" (`debug_draw.axle:1-6`).
- **Where:** `src/sim/kinetic/physics_world.axle:648`, `src/sim/kinetic/debug_draw.axle`.
- **Docs:** MISSING.

## Water on a heightfield: `HydroWorld` (`src/sim/fluid/hydro_*`)

`HydroWorld` is the engine for new work (`doc/FLUID.md:1-12`): metres, seconds, f32, a regular grid of square cells over a bed the game hands in as a plain `f32[]`.

### S-25. I want a river, lake or flood over terrain, that is stable and does not need a huge time step budget
- **Means:** second-order finite-volume shallow-water solver on a collocated grid: Audusse hydrostatic reconstruction on the surface bed + h, minmod-limited slopes, HLL flux with Davis speeds and Toro's dry-side speeds ("Audusse et al. 2004/2005 on a Kurganov-Petrova footing", the file's own words, `hydro_flux.axle:3-4`).
- **Mathematics:** unknowns per cell: depth h, discharge per metre qx, qz (= h u, h w). Per face: HLL mass flux F = (S_R m_L - S_L m_R + S_L S_R (h_R - h_L)) / (S_R - S_L), m = h u_n, same form for normal and tangential momentum (`hydro_flux.axle:238-244`); S_L = min(u_L - c_L, u_R - c_R), S_R = max(u_L + c_L, u_R + c_R), c = sqrt(g h); dry side: S_L = u_R - 2 c_R, S_R = u_R + c_R (and mirrored) (`:208-221`); S_L and S_R are clipped to <= 0 and >= 0. Momentum flux per side adds the hydrostatic correction (1/2) g (h_rec^2 - h_face^2) (`:187-189`). Time stepping: forward Euler; the unsplit scheme is positive below Courant 0.5 (`doc/FLUID.md:50`). Forward Euler means first order in time.
- **Instructions:** four passes over the active tiles, a barrier after each: `faces` (flux of the west and north face of every cell, stored in two views of the face), `scale` (positivity factor), `update` (cells), then boundary/lips/sources/particles/drifters (serial), then `surface` and `settleFoam` (`hydro_world.axle:567-604`, `hydro_passes.axle:1-21`). Struct-of-arrays, padded by a 2-cell ghost ring so the 4-cell stencil needs no bounds tests (`hydro_grid.axle:1-10`); array bases hoisted into locals in `update` (`hydro_passes.axle:245-266`); the flux function is the one non-inlined call and holds 26 bounds checks (`doc/FLUID.md:180-182`).
- **Cost:** O(active cells) per substep; per cell about 57 ns single-threaded (`doc/FLUID.md:128`); measured: 512 x 512 grid with 47 104 cells awake (18 %): 2.72 ms per substep and 64 ms per million cell-steps on 1 worker, 0.58 ms and 13.8 ms on 8 workers (`doc/FLUID.md:118-124`). Memory 94 bytes a cell without dye, 142 with the default 4 tracers; 512 x 512 is 24.6 MB (37 MB with tracers), 1024 x 1024 is 98 MB (149 MB) (`doc/FLUID.md:98-116`). The code comment in `hydro_grid.axle:18` says 90 bytes; the listed items sum to 94 (see Doubts).
- **Why this and not another:** `doc/FLUID.md:37-47`: "Chosen over keeping the linearised pipe model because it is the cheapest scheme that has all of" well-balanced, positive, sharp but monotone, robust. Stated price: a sudden bed step loses head (broad-crested weir with a sharp upstream edge passes 0.78 of the ideal Q = 1.705 b H^1.5; a ramped edge 0.996, test `weir`, `doc/FLUID.md:53-56,176-179`).
- **Where:** `src/sim/fluid/hydro_flux.axle:127` (`flux`), `:201` (`solve`), `src/sim/fluid/hydro_passes.axle:63,194,234,387`, `src/sim/fluid/hydro_world.axle:567` (`substep`).
- **Docs:** `doc/FLUID.md` ("HydroWorld: design", "Scheme and why", "Memory budget", "Measured").

### S-26. I want a lake at rest to stay perfectly still over a rough bed, a cliff or a thin shoreline (well balancing)
- **Means:** reconstruct the face states from the surface (bed + h), not from h, with the bed under the face taken as the higher of the two cell beds (Audusse hydrostatic reconstruction); limited slopes vanish on a flat surface.
- **Mathematics:** surface slope in a cell = minmod(d_low, d_mid) with d = (bed_i - bed_j) + (h_i - h_j); face depth = max(h_cell +- slope/2, 0) minus the part under the sill, sill = bed_R - bed_L (`hydro_flux.axle:143-178`). At rest all slopes are exactly 0, both face states are equal, so the momentum balance of a cell is a difference of equal numbers. Checked "over a rough bed with a 2 m step (surface error 0 after 20 forced-awake steps)" and over a rim with islands and thin films (`doc/FLUID.md:40-43`).
- **Instructions:** slopes are used only when the whole stencil is at least `slopeDepth` = 4 x `dryDepth` (0.004 m) deep, else first order (`hydro_flux.axle:147-148`, `hydro_world.axle:557`); bed ghosts repeat the edge (`hydro_grid.axle:268-286`). The surface is never formed as an absolute elevation, only differences of bed + h, so a lake 500 m above the datum is as quiet as at sea level (`hydro_grid.axle:12-16`).
- **Cost:** included in S-25 (no extra pass).
- **Why this and not another:** `doc/FLUID.md:37-47` (the pipe model has no hydrostatic reconstruction: "no wet/dry well-balancing over a bed step", audit paragraph).
- **Where:** `src/sim/fluid/hydro_flux.axle:127-198`.
- **Docs:** `doc/FLUID.md` ("Scheme and why").

### S-27. I want water fronts and bores that stay sharp without overshoot or negative depth
- **Means:** minmod slope limiter (total-variation diminishing) on surface and velocities, HLL Riemann solver, and a per-cell positivity scale.
- **Mathematics:** minmod(a, b) = 0 if a b <= 0, else the one of smaller magnitude (`hydro_flux.axle:104-112`). Positivity: each cell sums the outflow its four faces want, W = (E + W + S + N) dt/dx, and uses s = min(1, h/W); a face is paid by its donor, so both cells use the donor's factor and the water that leaves one cell is exactly the water that arrives in the other (`hydro_passes.axle:194-218,280-300`). Volume is conserved to rounding (`doc/FLUID.md:43-45`).
- **Instructions:** the limiter is switched off (first order) in and next to dry cells; the scale pass also stores each tracer's concentration (`hydro_passes.axle:220-228`).
- **Cost:** one extra O(active cells) pass per substep.
- **Why this and not another:** not documented beyond "second order in space where the stencil is wet, first order at rims" (`doc/FLUID.md:43-45`).
- **Where:** `src/sim/fluid/hydro_flux.axle:104`, `src/sim/fluid/hydro_passes.axle:194` (`scale`), `:234` (`update`).
- **Docs:** `doc/FLUID.md` ("Scheme and why").

### S-28. I want the time step to adapt so the water never outruns the grid
- **Means:** Courant-limited substeps: the requested time is cut into equal substeps, each below cfl x cell / (fastest signal speed).
- **Mathematics:** limit = cfl x cellSize / max(fastest, 1 m/s), fastest = max over wet cells of |u| + sqrt(g h) (stored per tile, `hydro_passes.axle:360`, `hydro_grid.axle:419`); pieces = ceil(remaining / limit), slice = remaining / pieces (`hydro_world.axle:533-538`). cfl default 0.25, values outside (0, 0.45] are reset to 0.25 (`hydro_params.axle:139-141,228-230`). At most `maxSubsteps` = 64 per `step`; time that does not fit is dropped and counted (`lostSeconds`) (`hydro_world.axle:519-545`).
- **Instructions:** the 1 m/s floor (`HYDRO_QUIET_SPEED`, `:42`) bounds the substep of a world with only sources; a world with nothing awake, no particles and no active source/vent returns at once (`:522-530`).
- **Cost:** substeps per step = ceil(dt c_max / (cfl dx)); work scales with it.
- **Why this and not another:** `doc/FLUID.md:50-51`; the legacy pipe model instead caps its push and slows waves in deep water (`fluid_pipes.axle`, see S-43).
- **Where:** `src/sim/fluid/hydro_world.axle:519` (`step`), `:548` (`scheme`).
- **Docs:** `doc/FLUID.md` ("Scheme and why"); the 1 m/s floor is not mentioned there (see Doubts).

### S-29. I want rivers with bed friction and eddy viscosity that cannot destabilise the scheme
- **Means:** Manning friction applied semi-implicitly on discharge; viscosity as a conservative momentum flux limited to its explicit stability bound.
- **Mathematics:** q' = q / (1 + dt g n^2 |u| / h^(4/3)): code `ease = 1 / (1 + drag |u| (1/h) / cbrt(h))` with drag = dt g n^2 (`hydro_passes.axle:243,338-346`); n = Manning roughness, default 0.03 s/m^(1/3). Cube root without libm: a fourth root as the guess and 3 Newton steps y <- (2y + x/y^2)/3 (`:51-58`). Viscous flux -nu h min(.) du/dx per face (`hydro_flux.axle:190-193`), nu limited to 0.5 dx^2/(4 dt) (`hydro_world.axle:46-47,551-552`). Speed cap `maxSpeed` 40 m/s and momentum under `restSpeed` 1e-5 m/s dropped (`:347-357`).
- **Instructions:** friction skipped when the cell is at rest; the cube root is skipped at rest ("skipping the friction cube root at rest gained about 5 %", `doc/FLUID.md:180-182`).
- **Cost:** O(1) per cell per substep.
- **Why this and not another:** semi-implicit "so it is stable at any depth" (`hydro_params.axle:131-133`).
- **Where:** `src/sim/fluid/hydro_passes.axle:234-384`, `src/sim/fluid/hydro_params.axle:127`.
- **Docs:** `doc/FLUID.md` ("Scheme and why", "robust").

### S-30. I want a calm lake to cost nothing, and a localised flood to cost only what moves
- **Means:** activity tiles of 32 x 8 cells with a flag; a flagged tile runs with its eight neighbours; a tile clears its flag when its speeds and surface jumps are below the rest thresholds.
- **Mathematics:** none: plain arithmetic. Rest when all speeds < `restSpeed` and every relative surface jump < `restJump` 1e-4 (`hydro_passes.axle:379-383`, `hydro_flux.axle:196`); water cannot cross more than one cell per substep so it cannot leave the dilated set (`hydro_grid.axle:22-26`).
- **Instructions:** a face next to a sleeping tile is sealed: no mass, no along-face momentum, but the hydrostatic push stays, written by the running tile alone so each face has one writer (`hydro_passes.axle:97-152`); anything adding water or momentum calls `wake`; `buildActive` lists flagged tiles and neighbours in tile order (`hydro_grid.axle:381`).
- **Cost:** a calm world costs one flag scan over the tiles per substep; tile memory 24 bytes (`doc/FLUID.md:115-116`); measured "zero cells awake" for a calm lake (test, `doc/FLUID.md:70-76`).
- **Why this and not another:** not compared; the legacy engine uses a per-column awake list (S-44).
- **Where:** `src/sim/fluid/hydro_grid.axle:381`, `src/sim/fluid/hydro_passes.axle:99`.
- **Docs:** `doc/FLUID.md` ("Activity and sleeping").

### S-31. I want the same water on one thread or on eight, bit for bit
- **Means:** fixed-grain index-based chunking on a `JobPool`; each pass writes only what its own tile or particle owns and reads what no other item writes; whole-grid reductions are serial between passes.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** `HydroKernel` is a dispatcher kernel (a pool serves one kernel for life) with stages Faces, Scale, Update, Surface, SettleFoam, Fly; grain 4 tiles (about 1000 cells) or 2048 particles per chunk (`hydro_runner.axle:18-22,25-43`). Rule learned in the doc: never copy a `Shared<...>` into a local inside worker code (the count is not atomic; it crashed once) (`doc/FLUID.md:66-69`).
- **Cost:** speed-up measured 64 -> 13.8 ms per million cell-steps from 1 to 8 workers (4.6x) (`doc/FLUID.md:122-123`).
- **Why this and not another:** the contract is the job library's (`core/jobs/kernel`), cited at `hydro_runner.axle:5-9`.
- **Where:** `src/sim/fluid/hydro_runner.axle:46` (`HydroKernel`), `:95` (`HydroRunner`).
- **Docs:** `doc/FLUID.md` ("Passes of a substep"); `doc/handbook/engine/01-job-pool.md` for the pool itself (not read for this file).

### S-32. I want walls, open outfalls and water edits (pour, fill a basin, inflows, sinks)
- **Means:** ghost cells (wall = mirror with normal velocity flipped; open side = dry ghost at the edge's bed level, a free outfall); direct edits that keep a ledger; inflow and sink ports that spread a discharge over a block of cells.
- **Mathematics:** wall: h, qx, qz copied from the cell, normal component negated, so the flux is exactly zero by symmetry (`hydro_grid.axle:354-361`). Open: ghost h = 0 so water leaves at the critical rate and never enters (`:343-352`). Inflow: each substep deposits discharge x dt spread equally over the (2r+1)^2 block (r = `inflowRadius` 1) of cells whose bed lies under the water of the centre cell; the volume really added (f32 depth x cell area) is booked (`hydro_sources.axle:1-16,133`). `fillBasin(level, x, z)`: breadth-first four-connected flood from the seed through cells whose bed is below `level`, raising each to `level` (`hydro_world.axle:336-386`); `pour(depth)` adds at once (negative lifts).
- **Instructions:** `fillGhosts` refills the 2-cell ring every substep (O(perimeter)); `fillBasin` allocates `seen` and `queue` of the grid size.
- **Cost:** O(perimeter) per substep for ghosts; O(K) for `fillBasin`; inflow O(block) per port per substep.
- **Why this and not another:** not documented.
- **Where:** `src/sim/fluid/hydro_grid.axle:291-362`, `src/sim/fluid/hydro_sources.axle:133`, `src/sim/fluid/hydro_world.axle:336,427,445,465`.
- **Docs:** `doc/FLUID.md` ("HydroWorld: design" call list); formulas MISSING.

### S-33. I want water that is accounted for: where every cubic metre is
- **Means:** an f64 ledger over an f32 grid: grid + airborne (particles and lip carries) + outflow + sunk + soaked = poured + inflow; deposits use error feedback.
- **Mathematics:** `addDepth` adds amount + credit, stores the part the f32 sum could not hold back in `credit` and adds it to the next deposit: "a depth of a metre has a resolution of 1e-7, a landing parcel adds a few 1e-5" so repeated tiny deposits lose water without it (`hydro_grid.axle:109-111,444-454`). Measured: waterfall (1152 m3 in): residual 1.7e-4 m3 (1.5e-7 relative); closed world with a curtain and a jet (62 000 particles, 120 s): 2.4e-8 relative drift; before error feedback a still pool lost 0.2 % (`doc/FLUID.md:93-96,174-175,204`).
- **Instructions:** `ledger()` returns a `HydroLedger` with `residual()`; sums are f64; parcels keep the remainder of an f32 rounding in an f64 carry (`hydro_lips.axle:23-26`).
- **Cost:** O(K) to sum the grid (`volume()`); the other terms are running sums.
- **Why this and not another:** not documented.
- **Where:** `src/sim/fluid/hydro_world.axle:1006-1030`, `src/sim/fluid/hydro_grid.axle:434-470`.
- **Docs:** `doc/FLUID.md` ("Books", "Deposits").

### S-34. I want a waterfall: water that leaves a cliff as a falling curtain and lands in a pool
- **Means:** lip detection on the bed; the grid flux across a lip is the free-overfall discharge, hidden from the receiving cell and accumulated in an f64 carry per lip; the carry is launched as layers of particles.
- **Mathematics:** a lip is a face whose bed drops by more than `dropThreshold` 1.5 m (or a cliff spread over up to 3 cells of slope >= 1) (`hydro_lips.axle:41`, `hydro_params.axle:26-32`). Mean discharge per metre q = carry / (cell x wait); exit speed v_e = max((g q)^(1/3), 0.5) m/s; landing speed v_L = sqrt(v_e^2 + 2 g H) with H the fall height found when the bed was loaded; layer period = curtainSpacing / v_L; layers = ceil(wait/period) (at most 8); particles across the crest = ceil(cellSize/curtainSpacing) (`hydro_lips.axle:310-345`). A lip passing less than `minDischarge` 0.002 m2/s, or a full pool, pours its carry into the cell below. Hidden flux: `storeX/storeZ` give the donor's view the flux and the receiver 0 (`hydro_passes.axle:155-172`).
- **Instructions:** `detect` scans every face once (O(K), allocates the lip arrays) on bed change; `launch` runs every substep over the lips; each layer is flown for the time it has been due, so the curtain has no hole whatever the step (`hydro_lips.axle:21-23`).
- **Cost:** particles alive per metre of crest ~ fallTime x landingSpeed / spacing^2: about 580 for a 10 m fall at 0.5 m (9.2 k for a 16 m crest) (`doc/FLUID.md:85-91`); 93 761 particles falling cost 0.47 ms per substep on 8 workers (grid included), 5.2 ms per million particle-steps; 38 bytes a particle (`doc/FLUID.md:124-128,114-115`). `setBedAt` re-detects every lip: fine for edits, not per frame (`doc/FLUID.md:266`).
- **Why this and not another:** "A heightfield cannot make a falling sheet of water" (`hydro_lips.axle:3`).
- **Where:** `src/sim/fluid/hydro_lips.axle:91` (`detect`), `:261` (`launch`), `:310` (`release`), `:348` (`launchLayers`).
- **Docs:** `doc/FLUID.md` ("Overfall").

### S-35. I want falling drops that slow in the air, break into spray and never lose water
- **Means:** ballistic particles under gravity with implicit quadratic drag; gas Weber number decides instability; a parcel unstable for a time of order the aerodynamic time splits in two exact halves.
- **Mathematics:** drag a = (3/8) C_d (rho_air/rho_water) |v| v / r applied implicitly, v <- v / (1 + k |v| dt) with k = (3/8) C_d rho_air / (rho_water r) written as `grip` (`hydro_particles.axle:16-18,283-287`); gravity first (semi-implicit), then drag, then position with the new velocity. Weber We = rho_air v^2 d / sigma; unstable when We > 12 and r > 4 mm; the wait is breakupTime (5) x sqrt(rho_water/rho_air) x d / max(v, 0.5) (`:329-343`, `hydro_params.axle:63-72`). Splitting halves the volume: "exact in binary floating point" (`hydro_particles.axle:20-21`).
- **Instructions:** `fly` writes only the slots of its own index range and records a fate (fly, land, split, leave); landing, splitting and compaction are serial in index order; the pool is compacted by moving the last particle into each hole: O(dead), no allocation (`hydro_particles.axle:23-27`).
- **Cost:** O(P) per substep, f32; the pool is allocated once at `capacity` (100 000 default).
- **Why this and not another:** not documented; the legacy engine uses the same drag law in f64 (S-49).
- **Where:** `src/sim/fluid/hydro_particles.axle:259` (`fly`), `src/sim/fluid/hydro_air.axle:346` (`split`).
- **Docs:** `doc/FLUID.md` ("Overfall").

### S-36. I want a falling parcel to land as a splash, a current and foam, with volume conserved
- **Means:** landing deposits depth and a share of horizontal momentum; fast parcels throw a crown of smaller drops (volume taken exactly); foam and turbulence are written into the cell.
- **Mathematics:** ratio = speed / splashSpeed (3 m/s); above 1 a crown is thrown (at most `splashShare` 0.35 of the volume), the rest lands as depth = keep / cell area with momentum landingKick (0.5) x depth x (vx, vz); foam += foamGain (0.35) x (speed x depth), turbulence += turbulenceGain (0.5) x the same, both capped at 1 (`hydro_air.axle:163-208`, `hydro_params.axle:74-87`).
- **Instructions:** serial, in index order; dye fractions are returned where the parcel lands (`:198-201`).
- **Cost:** O(landings) per substep; a crown makes O(children) new parcels (bounded by the pool).
- **Why this and not another:** not documented.
- **Where:** `src/sim/fluid/hydro_air.axle:163` (`land`), `:293` (`crown`).
- **Docs:** `doc/FLUID.md` ("Overfall").

### S-37. I want white froth at the foot of a fall, without losing water
- **Means:** a conservative aeration emitter: a hard landing hands a share of its water to short-lived light parcels that pour back to the grid.
- **Mathematics:** speed above `aerationSpeed` 6 m/s: `aerationShare` 4 % of the parcel's volume goes to up to 32 aerated parcels of 5e-5 m3, launched at up to 0.6 of the impact speed, life 0.5 to 1.5 x 2 s, braked as if of density 100 kg/m3, never breaking up (`hydro_air.axle:232-291`, `doc/FLUID.md:237-250`). A parcel at the end of its life or touching water pours volume, dye and a share of momentum back into the cell under it (`hydro_air.axle:210`).
- **Instructions:** scatter from a stateless hash of the landing number and the parcel (so 1 and N workers agree); `aerationPerStep` 60 000 launches per substep and `aerationCapacity` 150 000 parcels bound the cost; at the cap the landing simply keeps its water.
- **Cost:** 38 + 4 (life) + 4 per tracer bytes per parcel, pooled once (150 000 parcels about 6 MB, 8 MB with 4 tracers); measured on the 12 m fall (12 m3/s, 8 workers): up to 10 517 aerated parcels, 0.459 ms per substep against 0.359 without the emitter; ledger residual 3.9e-6 m3 of 528 (`doc/FLUID.md:250-255`).
- **Why this and not another:** the 4 % is "the order of the air a plunging jet entrains" (`hydro_params.axle:92-96`, citing Chanson's measurements of plunge pools).
- **Where:** `src/sim/fluid/hydro_air.axle:210`, `:232` (`aerate`).
- **Docs:** `doc/FLUID.md` ("Aerated parcels").

### S-38. I want a jet, geyser or fountain that throws water in a cone and the water comes back
- **Means:** a vent turns a discharge into liquid parcels launched from a disc along a tilted axis inside a cone; draws from the grid by default so the ledger needs no new term.
- **Mathematics:** owed volume per substep = discharge x power x pulse x dt; parcel volume = max(minParcel 2e-5 m3, discharge / maxRate 20 000 per s); launches = floor(owed/parcel); axis = (sin(tilt) cos(az), cos(tilt), sin(tilt) sin(az)); apex = speed^2/(2g) less air drag (`hydro_vents.axle:3-20,231-271,334-336`). Measured: apex 10.2 m for 15 m/s (v^2/2g = 11.5, drag takes 11 %), 2.72 m at 4g (2.87), ratio 3.74; discharge 0.50 m3/s drawn; books close to 6e-5 m3 of 1600; a pulsed vent 1.004 m3 for 1.0 expected (`doc/FLUID.md:160-163`).
- **Instructions:** `draw` takes water from the cells around the vent limited by what they hold; `launch` flies each parcel for the time since it left (`hydro_vents.axle:290,322`).
- **Cost:** at most `maxRate` x flightTime parcels alive per vent (flightTime = 2 speed/g for a vertical jet): about 60 k alive at 0.5 m3/s by default.
- **Why this and not another:** a vent in the legacy engine builds a dense lattice with a dome (S-52); the doc plans to migrate the old geyser to `addVent` (`doc/FLUID.md:8-10,160-163`).
- **Where:** `src/sim/fluid/hydro_vents.axle:221` (`run`), `:322` (`launch`), `src/sim/fluid/hydro_world.axle:485`.
- **Docs:** `doc/FLUID.md` ("Jets, edges and the readout").

### S-39. I want to colour water by origin (dye, pollution, a tributary) and track where it goes
- **Means:** passive tracers: depth of dyed water per cell advected with the same fluxes, first-order upwind; particles carry fractions and give them back.
- **Mathematics:** concentration c = dye/h in 0..1 (stored in `conc` by the positivity pass); dye flux = water flux x donor's concentration with the donor's scale factor; update dye' = max(dye + (dt/dx) sum of face dye fluxes, 0) (`hydro_passes.axle:221-228,302-325`). Bounded and positive "by construction"; "fronts smear by about a cell" (first order) (`doc/FLUID.md:185-198`). Measured: dam break 5e-8 relative dye residual; steady-channel front 1.40 m/s vs 1.45 m/s of water.
- **Instructions:** tracers 0 to 8 (`HYDRO_TRACERS_MAX`); infiltration removes water without its dye so dye books are then not exact.
- **Cost:** 12 bytes a cell and 4 a particle per tracer; "about 20 % more per cell-step with 4 tracers" (`doc/FLUID.md:114-115,198`).
- **Why this and not another:** no limited second-order dye (a stated trade-off).
- **Where:** `src/sim/fluid/hydro_passes.axle:221,302-325`, `src/sim/fluid/hydro_world.axle:283,943-999`.
- **Docs:** `doc/FLUID.md` ("Dye tracers and compartments").

### S-40. I want floating objects (leaves, boats, markers) that ride the flow, fall over weirs and show trails
- **Means:** Lagrangian drifters moved by the engine's velocity readout with the explicit midpoint rule plus a stateless random-walk eddy diffusion.
- **Mathematics:** x_{n+1} = x_n + dt u(x_n + dt/2 u(x_n)) x factor, surface factor 1.2 (the surface of a turbulent stream runs 1.15 to 1.3 of the mean); diffusion displacement sqrt(2 D dt) N(0,1) per axis with D = alpha h (u* + turb sqrt(g h)), u* = sqrt(g) n |u| / h^(1/6) (`hydro_drifters.axle:329-346,367-378`; the normal is four stateless hash uniforms summed, keyed by marker id, substep and axis). Crossing a lip a marker becomes a ballistic parcel with the local speed (at least 0.5 m/s) and the same drag, in micro-steps of at most 20 ms (`:78,56-80`). Measured: 1.4437 m/s on a channel vs 1.4437 mean surface velocity; 200 markers 1.7312 m/s against 1.2 x 1.4444 = 1.7333 (0.1 %); falls 11.91 m in 1.570 s over the 12 m lip (sqrt(2H/g) = 1.558 s) (`doc/FLUID.md:218-221,232`).
- **Instructions:** serial in index order on the calling thread; a ring of 128 positions per marker sampled every 0.25 s (`HYDRO_TRAIL_POINTS`).
- **Cost:** O(drifters) per substep; about 1.6 kB per marker (trail 1536 B + 49 B), 3.3 MB for the default 2048 (`hydro_drifters.axle:25-29`).
- **Why this and not another:** serial stepping is chosen because drifters are few: the result is trivially the same for any worker count (`:29-31`).
- **Where:** `src/sim/fluid/hydro_drifters.axle:249` (`step`), `:329` (`normal`), `:337` (`diffusivity`), `src/sim/fluid/hydro_world.axle:863-932`.
- **Docs:** `doc/FLUID.md` ("Drifters").

### S-41. I want turbulence and foam fields to colour rapids and wakes
- **Means:** shear of the velocity field -> turbulence; foam made where turbulence is above an onset, advected semi-Lagrangian and decaying.
- **Mathematics:** shear = |u_{i+1} - u_{i-1}| + |u_{j+1} - u_{j-1}| + |w_{i+1} - w_{i-1}| + |w_{j+1} - w_{j-1}|; fresh turbulence = min(shear x h x (1/(2 dx)) / 6, 1); turb' = max(turb (1 - 0.5 dt), fresh); foam' = min(carried (1 - 0.17 dt) + 1.2 dt max(turb - 0.35, 0), 1) (`hydro_passes.axle:414-427`, constants `:33-49`: saturation 6 m/s, rate 1.2, onset 0.35, decays 0.17 /s (half-life ~4 s) and 0.5 /s). `carry`: bilinear interpolation of the foam at the point the water came from (semi-Lagrangian), Courant limit keeping it inside (`:436-457`).
- **Instructions:** two stages because foam advects into a second buffer (`foamNext`, then `settleFoam`).
- **Cost:** O(active cells) per substep, 12 bytes a cell (foam x2 + turbulence).
- **Why this and not another:** not documented (constants have no derivation).
- **Where:** `src/sim/fluid/hydro_passes.axle:387` (`surface`), `:436` (`carry`), `:460`.
- **Docs:** MISSING (the constants and the shear formula are in no doc; `doc/FLUID.md` lists foam only as a feature).

### S-42. I want to read depth, surface, velocity, foam anywhere between cell centres
- **Means:** bilinear blend of the four cell centres around the point; the surface elevation is blended only over wet cells so it does not sag across a rim.
- **Mathematics:** depth = plain bilinear; surface = sum over wet cells of bilinear weight x (bed + h) / sum of those weights, bed when no wet cell; velocity at a point from face discharges (staggered mean of the two faces over the depth, `surfaceVelocityAt`) (`hydro_sample.axle:1-12,106-195`; `doc/FLUID.md:170`). Cells whose water is more than a cell above or below the nearest one are ignored (the far side of a cliff).
- **Instructions:** no allocation; points outside read the nearest edge cell.
- **Cost:** O(1) per query.
- **Why this and not another:** not documented.
- **Where:** `src/sim/fluid/hydro_sample.axle:36,106,158`, `src/sim/fluid/hydro_world.axle:721-780`.
- **Docs:** `doc/FLUID.md` ("Velocity readout").

## Water in columns with particles: the legacy `FluidWorld` (`src/sim/fluid/fluid_*`)

Cell units, f64. `doc/FLUID.md:1-12` marks it frozen: "`HydroWorld` is the engine for new work"; `fluid_*` is to be deleted once the geyser, river and intermittent examples migrate.

### S-43. I want a cheap water surface from columns that slosh (virtual pipes)
- **Means:** linearised shallow water on a staggered grid, written as "virtual pipes": a velocity per frontier between two columns, driven by the head difference.
- **Mathematics:** head h = ground + water (+ external `load`, + a pressure term over `maxLevel` in `Pressure` overflow) (`fluid_field.axle:1-9`). Per frontier: u' = (u + pull (head_a - head_b) dt) / (1 + drag dt), pull = min(conductivity g, 0.25 / (depth dt^2)) where depth is the water above the sill (higher of the two grounds) on the donor side (`fluid_pipes.axle:107-138`; `FLUID_STABILITY` 0.25 `:37`); viscosity: u += min(visc dt, 0.2) sum(u_neighbours - u) (`:140-168`, `FLUID_VISCOUS_SHARE` `:45`); transfer volume = min(|u| dt, 0.5) x depth, then limited by what the donor holds and in `Keep` mode by half the receiver's room (`:170-205`, `FLUID_COURANT` 0.5, `FLUID_ROOM_SHARE` 0.5). Wave speed is the physical sqrt(g h) while the stability cap is not reached.
- **Instructions:** two passes over a snapshot ("every velocity is computed from the same levels before any water moves, so the scan order cannot bias the flow"); every transfer subtracts from one column exactly what it adds to the other, so volume is conserved to rounding (`fluid_pipes.axle:1-34`). Levels are f64 "on purpose: conservation here is exact cancellation" (`fluid_field.axle:11-14`).
- **Cost:** O(awake frontiers) per tick; one tick = `rules.dt` = 0.05 s by default (`fluid_rules.axle:41`). Phase order per tick: particles, vents, sources, pipes accelerate, diffuse, limit, apply, sinks, spills, infiltration, surface analysis (`fluid_world.axle:465-495`). No measured figure in the files read.
- **Why this and not another:** the audit in `doc/FLUID.md:145-150` lists its weaknesses: "linearised ... no hydrostatic reconstruction", "waves in deep water are slowed by the stability cap instead of substepping" (S-28 replaces it).
- **Where:** `src/sim/fluid/fluid_pipes.axle:56,107,140,170,271`, `src/sim/fluid/fluid_world.axle:483` (`flowColumns`).
- **Docs:** `doc/FLUID.md` ("Audit of the legacy FluidWorld").

### S-44. I want a settled column world to cost almost nothing
- **Means:** an `ActiveSet` strategy: only columns woken by the previous tick (plus sources, drains, pours, ground edits and kicks) and the frontiers around them are visited; `FullSweep` visits everything.
- **Mathematics:** none: plain arithmetic. A frontier whose per-tick transfer falls under `sleepThreshold` stops waking its columns, "which freezes a surface gap of a few `sleepThreshold` across it" (`fluid_tick.axle:1-24`).
- **Instructions:** frontier ids are array indices (all east frontiers row by row, then all south ones), so a frontier's two columns are arithmetic; awake lists are `Vec<i32>` rebuilt each tick (`doc/FLUID.md:147-149`); stamps use `i64` where `i32` would do (same audit).
- **Cost:** a settled world is "one list walk per tick".
- **Why this and not another:** the stated trade: "sub-threshold water is left unpriced rather than simulated".
- **Where:** `src/sim/fluid/fluid_tick.axle`, `src/sim/fluid/fluid_pipes.axle:56-105`.
- **Docs:** `doc/FLUID.md` (audit only).

### S-45. I want springs, drains, overflows, pistons and soaking ground in a column world
- **Means:** sources and drains on blocks of columns with an exact ledger; a spill pass that hands surplus above `maxLevel` to the lowest neighbour at once; loads as extra head; infiltration.
- **Mathematics:** invariant `totalVolume + drained - injected` (a test holds the engine to it, `fluid_emitters.axle:1-10`); spill repeats until nothing above the brim can move, never past the donor's own capped surface (`:12-17`, `applySpill` `:210`); a `load` raises the head so "a piston on one arm of a U-tube raises the other arm until the heads match" (`fluid_field.axle:1-9`); infiltration removes min(held, rate x dt) per wet column per tick (`fluid_world.axle:497-517`).
- **Instructions:** sources spread over a block "not a point" so the surface is a plateau; spill is a loop until stable.
- **Cost:** O(block) per source per tick; spill O(columns above the brim) per pass; soak O(width x depth) when on, free when off.
- **Why this and not another:** "a strong point source builds a hydraulic cone that no pool has" (`fluid_emitters.axle:7-9`).
- **Where:** `src/sim/fluid/fluid_emitters.axle:28,99,158,210`, `src/sim/fluid/fluid_world.axle:153-163`.
- **Docs:** MISSING.

### S-46. I want an object that hits water to displace it, shove it and throw spray
- **Means:** an impact turns an object (position, size, speed) into displacement of the footprint, an outward momentum shove, and liquid particles above a speed threshold.
- **Mathematics:** the footprint rises by exactly the object's volume; shove strength grows with volume/(volume + footprint x depth) ("a pebble in a lake barely shoves, a boulder in a puddle sends it flying") and with speed; spray share grows with the energy past the threshold, never more than half of what the footprint held, taken out of the columns (`fluid_impact.axle:1-14`); conserved: `totalVolume + airborne` after = before + object volume.
- **Instructions:** `displace`, `push`, `thin`, `wake` over the block; randomness from a `Pcg32` seeded by the world.
- **Cost:** O(footprint) per impact.
- **Why this and not another:** not documented.
- **Where:** `src/sim/fluid/fluid_impact.axle:94`, `src/sim/fluid/fluid_world.axle:344`.
- **Docs:** MISSING.

### S-47. I want splashing, throwing, pouring water as a real fluid of particles that does not compress
- **Means:** position-based fluids (Macklin and Mueller 2013, named in the file): incompressibility as a position constraint solved by Jacobi iterations on a spatial hash; XSPH viscosity and a cohesion pull for surface tension.
- **Mathematics:** density rho_i = sum_j V W_poly6(|q_i - q_j|, h) plus a tabulated wall term; constraint C = max(rho/rho_0 - 1, 0) (compression only, "a free surface does not pull", so no tensile-instability correction); lambda_i = -C / (sum_j |grad W_spiky|^2 + |sum_j grad|^2 + epsilon) with epsilon = 0.1 x (rest-lattice gradient sum) (`FLUID_RELAX`); delta q_i = (V/rho_0) sum_j (lambda_i + lambda_j) grad W_spiky, capped at 0.25 h per iteration (`fluid_liquid.axle:333-435`, constants `:36-54`). Kernel sizes: smoothing h = 4 x radius by default (`fluid_particle_params.axle:222`); the rest density and wall table are calibrated on a cubic lattice of spacing 2 r (`:132-203`). Velocity = position change / dt, blended with neighbours, speed cap 150 cells/s.
- **Instructions:** per tick: predict (gravity), spatial sort, neighbour lists (at most 48 per particle), `iterations` (default 3) x [multipliers, deltas, displace], velocities, viscosity and cohesion, fates; all Jacobi (read old positions, write all deltas, then apply) so a particle's update is independent of order and thread (`fluid_liquid.axle:1-30`, `fluid_runner.axle:28-57`).
- **Cost:** O(iterations x P x 48) neighbour work per tick; pool default capacity 30 000 liquid, 200 000 spray (`fluid_particle_params.axle:28,80`); pool arrays are f64, 68 bytes a particle (six position/velocity, radius, age, fate) before solver scratch (`fluid_pool.axle:41-50`). No measured figure in the files read.
- **Why this and not another:** SPH needs a time step bounded by the speed of sound ("a geyser throws water at 30 cells per second on a world that ticks at 20 Hz: SPH would need a dozen substeps or a soft, spongy fluid"); FLIP "needs a background grid of the whole volume ... which fights a world of columns"; PBF is "unconditionally stable at any speed, one parameter (the iteration count) trades stiffness for cost" (`fluid_liquid.axle:1-14`).
- **Where:** `src/sim/fluid/fluid_liquid.axle:253` (`predict`), `:333` (`multipliers`), `:387` (`deltas`), `:437` (`displace`), `:463` (`settle`), `:510` (`soften`), `:584` (`decide`).
- **Docs:** `doc/FLUID.md` (audit mentions it only); formulas MISSING.

### S-48. I want to find the neighbours of a particle in constant time without a hash map's order dependence
- **Means:** a spatial hash with cubes of the kernel support, addresses wrapped into a fixed 64 x 64 x 32 block of buckets, built by counting sort.
- **Mathematics:** bucket = (ix & 63) | ((iz & 63) << 6) | ((iy & 31) << 12) (`fluid_grid.axle:66-69`); wrap dimensions are at least 3, so the 27 cubes around any cube land in 27 different buckets and a query never visits a particle twice (header `:1-14`). Distant cubes can share a bucket: "only costs a few extra distance tests".
- **Instructions:** count, prefix-sum, scatter in index order, shift starts back (`:77-106`); one thread; the order depends on positions alone.
- **Cost:** O(P + buckets) per build with 131 072 buckets (starts array of that size + 1, i32); a query visits 27 buckets.
- **Why this and not another:** "A hash map would iterate in an order that depends on its history; this cannot."
- **Where:** `src/sim/fluid/fluid_grid.axle:66,77`.
- **Docs:** MISSING.

### S-49. I want fine spray that hangs in the air and big drops that fly far
- **Means:** independent ballistic drops with implicit quadratic drag; the smaller the drop, the harder it is braked.
- **Mathematics:** a = -(3/8) C_d (rho_air/rho_water) |v| v / r, applied as v / (1 + k |v| dt) so it never reverses a velocity (`fluid_aloft.axle:1-14`, `FLUID_DRAG_SHAPE` 0.375 `:22`, C_d default 0.47 `fluid_particle_params.axle:89`); drops older than 60 s end (`FLUID_SPRAY_MAX_AGE`).
- **Instructions:** no neighbour lookups, so any thread can fly any slice.
- **Cost:** O(P_spray) per tick; spray capacity 200 000 by default.
- **Why this and not another:** not documented. The metric engine uses the same law (S-35).
- **Where:** `src/sim/fluid/fluid_aloft.axle:40` (`flySpray`).
- **Docs:** MISSING.

### S-50. I want water and particles to exchange volume (landing, splash, breakup, breaking crests) with the books closed
- **Means:** the only two places that touch both a pool and the columns: `fluid_coupling` (particles to columns: land, splash, break) and `fluid_emit` (columns to particles: breaking-crest spray, throw).
- **Mathematics:** a landing pours the particle's volume into the column and kicks the frontiers by its momentum share; above the splash speed part rebounds as a crown; a loose liquid particle whose Weber number passes the threshold shatters into spray (`fluid_coupling.axle:1-20`). Emission: a column that `fluid_surface` says is breaking sheds a share of its water per second as spray; a column whose surface rises faster than `throwSpeed` 3 cells/s throws the excess as liquid particles (`fluid_emit.axle:1-20`; `fluid_particle_params.axle:119`). Every emission removes from the column exactly the volume of the particles made.
- **Instructions:** serial in index order; fates written by the parallel kernels are acted on in `settle`, then pools are compacted preserving order; a spawn into a full pool keeps the water ("costs fidelity and never water") (`fluid_spawn.axle:1-7`).
- **Cost:** O(P) per tick for `settle`, O(columns) for the surface analysis when on.
- **Why this and not another:** "A heightfield cannot overturn, jet or foam, so the standard way to fake what it cannot hold is to take the water out of the columns exactly where the real surface would have left them" (`fluid_emit.axle:3-6`).
- **Where:** `src/sim/fluid/fluid_coupling.axle:106,163,193`, `src/sim/fluid/fluid_emit.axle:50,85,128`.
- **Docs:** MISSING.

### S-51. I want to know where a surface is breaking, and draw foam and turbulence on it
- **Means:** per-column surface analysis (velocity, slope, curvature, convergence, a breaking number 0..1) and a foam/turbulence pair advected semi-Lagrangian.
- **Mathematics:** a column breaks as a steep crest (slope past `steepness` 0.55, standing above its neighbours) or when the Froude number passes `froude` 1.1 (flow faster than sqrt(g h)); slopes only between wet columns (`fluid_surface.axle:1-16`, `fluid_particle_params.axle:108,112`). Foam: coverage 0..1 advected with the surface velocity, diffused a little, half-life 4 s (`:131`); turbulence rises at once and decays more slowly (`fluid_foam.axle:1-20`); dry columns lose foam faster (4x, `FLUID_FOAM_DRY_FADE`).
- **Instructions:** serial sweeps in column order; skipped while nothing moves and nothing is foamy (`fluid_world.axle:519-540`).
- **Cost:** O(columns) per tick when busy; f32 fields.
- **Why this and not another:** "stand-ins for physics a heightfield cannot hold".
- **Where:** `src/sim/fluid/fluid_surface.axle:145,177`, `src/sim/fluid/fluid_foam.axle:90`.
- **Docs:** MISSING.

### S-52. I want a geyser: a dome of water that bulges, then a dense column that erupts and breaks into a fan
- **Means:** a vent that lays liquid particles on a slab lattice as wide as the conduit, one slab every two radii of travel, plus a dome of volume poured into the columns around it.
- **Mathematics:** height = speed^2/(2 g) at any gravity; flow = eruptionPower x pi x radius^2 x speed cell-volumes per second; particles per second = flow / particle volume; `eruptionPower` is the filled share of the lattice (thinned at random) (`fluid_vent.axle:1-30`). Spray is not emitted: it breaks off the core by the Weber rule of the liquid solver. Ledger: `totalVolume + airborne = poured + injected - drained`.
- **Instructions:** lattice laid with the population's serial `Pcg32`, in vent order.
- **Cost:** O(particles born per tick); bounded by the liquid pool.
- **Why this and not another:** "A geyser is not a faster fountain." The doc plans to replace it by `HydroWorld::addVent` (S-38).
- **Where:** `src/sim/fluid/fluid_vent.axle:215` (`apply`), `:244` (`dome`).
- **Docs:** `doc/FLUID.md` ("Jets, edges and the readout" names the planned migration).

### S-53. I want random numbers in a parallel kernel that do not depend on which thread draws
- **Means:** a stateless hash of (seed, tick, particle, purpose); serial phases use a `Pcg32` drawn in a fixed particle order.
- **Mathematics:** `FluidNoise.unit` maps the hash to [0,1) in steps of 2^-53 (`fluid_noise.axle:15,26-48`); `cbrt` and `decay` (half-life) by fixed-iteration routines without libm: decay by `FLUID_DECAY_SQUARINGS` = 6 squarings (`:18,50-80`).
- **Instructions:** pure functions, no state.
- **Cost:** O(1) per draw.
- **Why this and not another:** "A parallel kernel cannot share a `Pcg32`: which thread draws first would decide who gets which number."
- **Where:** `src/sim/fluid/fluid_noise.axle:26,37,50,73`.
- **Docs:** MISSING.

### S-54. I want to feed a terrain to the water, and read columns between centres
- **Means:** the game supplies ground heights (`setGround`, or baked once from a `FluidGround` trait with `sampleGround`); readings are bilinear between column centres, clamped at the edge.
- **Mathematics:** column (i, j) spans [i, i+1) x [j, j+1) and its number belongs to (i + 0.5, j + 0.5); bilinear blend of the four centres; the gradient is constant inside each square of centres (`fluid_sample.axle:1-12`).
- **Instructions:** `FluidStencil` + `blend` / `blendF32`; no allocation.
- **Cost:** O(1) per read; O(width x depth) to bake a ground.
- **Why this and not another:** "Bilinear is the cheapest reading that is continuous".
- **Where:** `src/sim/fluid/fluid_world.axle:110,123`, `src/sim/fluid/fluid_sample.axle:63,105`, `src/sim/fluid/fluid_ground.axle`.
- **Docs:** MISSING.

---

## Animation (`src/sim/animation`)

### S-55. I want a bone's value at any time from a few keys, in constant time per query
- **Means:** keyframe tracks (`Vec3Track` for translation/scale, `QuatTrack` for rotation): binary search for the segment, then step / linear / cubic Hermite (glTF CUBICSPLINE layout).
- **Mathematics:** segment = last key with t_k <= t by bisection (`track_math.axle:75-87`); s = (t - t_k)/(t_{k+1} - t_k) (guarded); Hermite value = h00 p_k + h10 dt m_out + h01 p_{k+1} + h11 dt m_in with h00 = 2s^3 - 3s^2 + 1, h10 = s^3 - 2s^2 + s, h01 = -2s^3 + 3s^2, h11 = s^3 - s^2 (`:99-111`, `vec3_track.axle:140-149`). Times outside the keys clamp to the first and last value.
- **Instructions:** floats in `malloc` arrays: `times` and `values` (3 per key; cubic keys use in-tangent, value, out-tangent = 9 floats; the track allocates 9 per key whatever the interpolation, `vec3_track.axle:17-21,37`).
- **Cost:** O(log keys) per query; memory per key 4 + 36 bytes allocated for vectors (the cubic size) and 4 + 48 for rotations (12 floats) (`quat_track.axle:13-18,33`).
- **Why this and not another:** "a track of thousands of keys costs the same as one of two" (`vec3_track.axle:1-9`).
- **Where:** `src/sim/animation/vec3_track.axle:114` (`sample`), `src/sim/animation/track_math.axle:75,99`.
- **Docs:** MISSING.

### S-56. I want rotations between keys to take the short way round and stay unit length
- **Means:** slerp of the shortest arc for `Linear`; component-wise Hermite then renormalise for `Cubic`.
- **Mathematics:** a key and its negative are the same rotation, so the blend flips one of them when the dot product is negative (header `quat_track.axle:1-6`, the flip is inside `Quat::slerp` of core, not read here). Cubic: q = h00 q_k + h10 dt m_out + h01 q_{k+1} + h11 dt m_in, normalised (`quat_track.axle:142-156`); that function does no shortest-arc flip between the two keys (see Doubts).
- **Instructions:** keys are normalised in `setKey`.
- **Cost:** O(log keys) + one slerp (UNVERIFIED cost of `Quat::slerp`, outside the zone).
- **Why this and not another:** not documented.
- **Where:** `src/sim/animation/quat_track.axle:116,142`.
- **Docs:** MISSING.

### S-57. I want a clip clock that loops, clamps, and stays exact after hours of play
- **Means:** wrap time modulo duration in f32, or in f64 for the running clock with the result narrowed to f32.
- **Mathematics:** looping: r = t - floor-by-truncation(t/d) d, corrected into [0, d) (`track_math.axle:53-69`, `animation_clip.axle:140-163`); `floorDiv` for negative clocks (`track_math.axle:90-96`). A clip of no length answers 0. The animator's clock is f64 (`animator.axle:92-93`).
- **Instructions:** none beyond the arithmetic.
- **Cost:** O(1).
- **Why this and not another:** "wrapClock ... stays exact after hours of play" (`animation_clip.axle:139`).
- **Where:** `src/sim/animation/animation_clip.axle:140` (`wrapClock`), `src/sim/animation/track_math.axle:53`.
- **Docs:** MISSING.

### S-58. I want a clip to write its animation into a pose, leaving the bones it does not animate alone
- **Means:** channels (bone index -> up to three tracks); empty tracks leave that part of the bone as it was.
- **Mathematics:** none: plain arithmetic. `sampleAt(t)` loops over channels: translation, rotation, scale each replaced only if its track has keys (`animation_clip.axle:194-212`).
- **Instructions:** `channelOf(bone)` is a linear search (`:125-132`); `addChannel` refuses a second channel for a bone; the clip's length grows to the last key.
- **Cost:** O(channels x log keys) per sample; `translationAt` and `rotationAt` pay an extra O(channels) search.
- **Why this and not another:** "start from the bind pose (or from another animation) and the bones the clip does not animate keep their values".
- **Where:** `src/sim/animation/animation_clip.axle:64,194`.
- **Docs:** MISSING.

### S-59. I want model-space and skinning matrices from local bone transforms
- **Means:** parent-before-child order lets one pass compose the hierarchy; skinning matrix = model x inverse-bind.
- **Mathematics:** M_i = M_parent(i) x T_i (as `Mat4` from translation, rotation, scale), S_i = M_i x B_i^-1 (`pose.axle:101-115`); exact for any scale because matrices are composed. A `Transform` route (`modelTransform`) composes TRS triples up the chain and is exact for uniform scale only (`pose.axle:1-7,89-99`).
- **Instructions:** bones are stored parent before child ("a bone's parent has a smaller index", `skeleton.axle:1-6`); `Pose` keeps `local`, `model`, `skin` arrays of count + 1.
- **Cost:** O(bones) per `update`, one `Mat4` multiply x2 per bone; memory per bone: a `Transform` plus two `Mat4` (sizes UNVERIFIED). `modelTransform(bone)` is O(depth).
- **Why this and not another:** not documented.
- **Where:** `src/sim/animation/pose.axle:89,101`, `src/sim/animation/skeleton.axle`.
- **Docs:** MISSING.

### S-60. I want to skin a mesh on the CPU (tools, picking, tests)
- **Means:** linear blend skinning: weighted sum of the vertex run through up to four bones' skinning matrices.
- **Mathematics:** p' = (sum_k w_k S_{j_k} p) / (sum_k w_k) over the four influences with w > 0 (weights normalised by their sum; a vertex with all zero weights stays) (`skinning.axle:26-56`). Normals use the upper 3x3 of the matrices and are renormalised: right for rotations and uniform scale, wrong for non-uniform scale (no inverse transpose) (`:1-12,58-85`).
- **Instructions:** flat arrays: 3 floats per vertex, 4 joints and 4 weights per vertex; one pass.
- **Cost:** O(V x 4) matrix-point products.
- **Why this and not another:** "For skinning on the GPU the same matrices go to the vertex shader; this helper serves tools, tests, picking and CPU-only builds."
- **Where:** `src/sim/animation/skinning.axle:26,58`.
- **Docs:** MISSING.

### S-61. I want a character that crossfades between idle, walk and run driven by parameters
- **Means:** a state machine over clips with parameter-driven transitions and timed crossfades.
- **Mathematics:** pose = lerp(outgoing, incoming, w) with w = min(fadeTime/fadeLength, 1) rising 0 to 1; at w = 0 and w = 1 the arithmetic is skipped, so the endpoints are the clips' own values (`animator.axle:254-262,368-380`, `pose_blend.axle:70-78`). Transition: the first transition of the current state, in insertion order, whose condition (Always, Greater, Less, IsTrue, IsFalse, Finished) holds starts the fade; no new transition during a fade so the weights stay a pair summing to 1 (`:325-337`). Time moves only by dt x timeScale x state speed (`:288-304`).
- **Instructions:** at most 32 states and 32 parameters (`ANIMATOR_MAX_*`); the animator copies the bind pose; each update samples both clips during a fade (2 clip samples + one pose lerp) and none during no fade except the one current clip.
- **Cost:** O(bones) per update for the lerp plus O(channels x log keys) per sampled clip. Parameter lookups by name use a `StringInterner`.
- **Why this and not another:** "no wall clock, no hidden step, so feeding it a fixed step gives the same poses on every run" (`animator.axle:8-10`).
- **Where:** `src/sim/animation/animator.axle:220` (`update`), `:355` (`begin`), `:368` (`evaluate`).
- **Docs:** MISSING.

### S-62. I want to blend poses in layers: an aim over a walk, an additive lean, a per-bone mask
- **Means:** per-bone weights (`BoneMask`, subtree masks) multiplying the blend weight; additive layers as a difference from a reference pose.
- **Mathematics:** lerp: translation and scale straight, rotation along the shortest arc (`Transform::lerp`, core); additive: translation and scale by subtraction t = t_base + w (t_layer - t_ref), rotation turn = ref^-1 x layer, part = slerp(identity, turn, w), q = q_base x part (`pose_blend.axle:80-93`). Masks multiply the weight bone by bone (`:34-40,52-67`).
- **Instructions:** all functions write into `out`, which may be one of the inputs; `BoneMask::subtree` uses `isInSubtree` per bone, O(bones x depth).
- **Cost:** O(bones) per blend.
- **Why this and not another:** not documented.
- **Where:** `src/sim/animation/pose_blend.axle:26,34,43,52`, `src/sim/animation/bone_mask.axle:26`.
- **Docs:** MISSING.

### S-63. I want a footstep or hit event to fire exactly once per pass, also across the loop point
- **Means:** half-open intervals [from, to) on an unwrapped clock, counted in every repetition of a loop.
- **Mathematics:** passes from floorDiv(from, d) to floorDiv(to, d); a marker at base + t_event fires when from <= at < to (`clip_events.axle:20-42`); a non-looping clip clamps at its length and a marker exactly at the length fires when the step reaches it (`:45-64`); steps backwards report nothing.
- **Instructions:** markers are kept sorted (insertion with shift, O(n) per add, `animation_clip.axle:218-235`); results go to an `EventBuffer` (ids i32, times f64, start room 16 doubling).
- **Cost:** O(passes x markers) per update (several whole loops in one step make several passes).
- **Why this and not another:** "Half-open means a marker ... is reported by the next step, never twice and never lost" (`clip_events.axle:6-8`).
- **Where:** `src/sim/animation/clip_events.axle:20`, `src/sim/animation/event_buffer.axle`.
- **Docs:** MISSING.

### S-64. I want a walk cycle to move the character, not slide its feet (root motion)
- **Means:** measure the root bone's translation and rotation between two clock readings and hand the delta to the character; remove it from the pose.
- **Mathematics:** delta translation = T(b) - T(a), delta rotation = R(b) R(a)^-1 on one pass; across the loop point: (a to end) + whole cycles x (end - start) + (start to b) (`root_motion.axle:54-82,100-104`); combining deltas: translation adds, rotations multiply (`:35-40`); weighting for crossfade: translation x w, rotation slerp(identity, r, w) (`:43-48`); the animator blends the incoming and outgoing deltas with the fade weights (`animator.axle:307-323`). `lockRoot` returns the root to its bind x and z (and y unless `keepHeight`) (`root_motion.axle:88-97`).
- **Instructions:** a loop `while (whole > 0)` adds one cycle per remaining loop (O(loops) in one step).
- **Cost:** O(log keys) per `span`, two spans per step.
- **Why this and not another:** "the game moves the character body by that amount, and `lockRoot` removes the same movement from the pose so it is not applied twice".
- **Where:** `src/sim/animation/root_motion.axle:54,88`.
- **Docs:** MISSING.

### S-65. I want an arm or leg to reach a target with a pole vector (two-bone IK)
- **Means:** analytic two-bone solver: law of cosines for the mid joint, one swing to aim the chain, an optional twist to face a pole.
- **Mathematics:** with lengths l1, l2 and distance d clamped to [max(|l1 - l2|, eps), l1 + l2]: cos(bend) = (l1^2 + l2^2 - d^2)/(2 l1 l2), bend = acos(clamp(.)) (`ik.axle:40-46`); fold = rotation about u x v by (bendWant - bendNow); swing = fromTo(reach after fold, target - root); twist about the root-to-target line by atan2(have x want . line, have . want) so the mid joint lies on the pole's side (`:55-66,167-186`); a target beyond reach stretches the limb straight and returns false (`:129-193`).
- **Instructions:** three `modelTransform` calls (O(depth) each); results converted back to local rotations by undoing the parent's model rotation (`:28-36,188-191`); bone lengths and offsets stay as authored.
- **Cost:** O(depth) per solve, no iteration.
- **Why this and not another:** FABRIK for chains of any length (S-66).
- **Where:** `src/sim/animation/ik.axle:129` (`TwoBoneIk::solve`).
- **Docs:** MISSING.

### S-66. I want a tail, spine or tentacle to follow a target (chain IK)
- **Means:** FABRIK (named in the file), iterating backward from the target and forward from the root, preserving bone lengths.
- **Mathematics:** end point set to the target; each earlier joint placed at distance l_i from the next along the old direction (`ikPlaceFrom`, `ik.axle:68-71`); root reset and a forward pass; stop when |end - target| <= tolerance or `maxIterations`; target beyond total length: chain laid straight (`:205-258`); the point positions are turned back into local rotations root first with `Quat::fromTo` (`:261-285`).
- **Instructions:** allocates two arrays of `count` per solve; `IkResult` gives reached, iterations, error.
- **Cost:** O(iterations x count) + O(count x depth) for `modelTransform`.
- **Why this and not another:** not documented.
- **Where:** `src/sim/animation/ik.axle:205` (`FabrikChain::solve`), `:261`.
- **Docs:** MISSING.

### S-67. I want a head or turret to look at a point with a weight and a turn limit
- **Means:** one rotation taking the bone's chosen local axis to the target direction, scaled by a weight and clamped to a maximum angle.
- **Mathematics:** full = fromTo(facing, wanted); turn = slerp(identity, full, clamp(weight)); if angle > maxAngle turn = slerp(identity, turn, maxAngle/angle); result = turn x model rotation (`ik.axle:295-322`); "`fromTo` takes the short way, so the turn is at most half a revolution".
- **Instructions:** one `modelTransform` + `ikParentRotation`.
- **Cost:** O(depth).
- **Why this and not another:** not documented.
- **Where:** `src/sim/animation/ik.axle:295` (`LookAt::apply`).
- **Docs:** MISSING.

---

## Audio (`src/sim/audio`)

The engine has no device: it renders blocks of stereo f32 into a buffer; a test, an offline bounce or a device callback drive it identically (`audio_engine.axle:1-8`; ROADMAP: "offline only, nothing drives an audio device", `doc/ROADMAP.md:34`).

### S-68. I want to mix many voices into stereo without clipping
- **Means:** add the voices, multiply by the master gain, run a soft limiter that cannot exceed 1.
- **Mathematics:** y = x for |x| <= K = 0.8; above the knee y = sign(x) (K + (1 - K) t/(1 + t)) with t = (|x| - K)/(1 - K), then min(., 1): odd, continuous, with continuous slope at the knee (derivative of the curve is 1/(1 + t)^2 = 1 at t = 0) (`audio_engine.axle:410-429`, knee `:65`). Input first clamped to +-1e6 so the arithmetic stays finite.
- **Instructions:** `render(out, frames)` zeroes the buffer, mixes blocks of at most 128 frames voice by voice, then one pass applies master and limiter per sample (`:469-484`); voices add with `+=` into interleaved L/R.
- **Cost:** O(frames x live voices) mixing + O(frames) limiting; one division per limited sample. No measured figure.
- **Why this and not another:** not documented beyond the properties above; a hard clip or a compressor is not discussed.
- **Where:** `src/sim/audio/audio_engine.axle:414` (`softLimit`), `:469` (`render`), `:432` (`mixBlock`).
- **Docs:** MISSING.

### S-69. I want a fixed number of voices, and the least important sound to give way when they run out
- **Means:** a fixed voice pool (1 to 255); stealing by (lowest priority, then oldest start order); a new sound is refused if every live voice outranks it.
- **Mathematics:** none: plain arithmetic. `claimSlot` returns a free slot, else the victim = minimum of (priority, start order); refused when `victim.priority > request.priority`; counts `stolen` and `refused` (`audio_engine.axle:255-286`). Music is played at priority 1000 so it outranks every effect (`:55`).
- **Instructions:** linear scan over the pool for each `play`.
- **Cost:** O(V) per play, V <= 255; memory fixed at construction (V `AudioVoice` objects).
- **Why this and not another:** not documented.
- **Where:** `src/sim/audio/audio_engine.axle:255` (`claimSlot`), `:292` (`play`).
- **Docs:** MISSING.

### S-70. I want a sound handle that becomes invalid when the sound ends, even if the slot is reused
- **Means:** handle = serial << 8 | slot; the voice keeps its serial; a mismatch means a different sound.
- **Mathematics:** serial wraps at 23 bits (mask 8 388 607), never 0, so the handle stays a positive i32 (`audio_engine.axle:37-43,301-308`); `slotOf` compares `voice.serial == handle >> 8` (`:239-252`).
- **Instructions:** `stop`, `pause`, `setGain`, `setPitch`, `setEmitter` all go through `slotOf` and ignore stale handles.
- **Cost:** O(1).
- **Why this and not another:** not documented.
- **Where:** `src/sim/audio/audio_engine.axle:239`.
- **Docs:** MISSING.

### S-71. I want to play a sample at another pitch or a different sample rate without zipper noise
- **Means:** a fractional read position stepped by (pitch x Doppler x clip rate / engine rate) frames per output frame, read by linear or Catmull-Rom interpolation.
- **Mathematics:** step = pitch x ratio x (clip.rate / engine.rate) (`audio_engine.axle:461`). Linear: p1 + (p2 - p1) t. Catmull-Rom through p1 (t=0) and p2 (t=1): p1 + (t/2)(a + t(b + t d)), a = p2 - p0, b = 2 p0 - 5 p1 + 4 p2 - p3, d = 3 (p1 - p2) + p3 - p0 (`audio_voice.axle:331-337`); beyond the clip the outer neighbours repeat the inner ones so the curve flattens at the ends (`:314-319`). The position is an f64.
- **Instructions:** per output frame and channel: 2 (linear) or 4 (cubic) reads, each through `fold` (loop wrap by modulo, `:287-301`); multi-channel clips are averaged to mono on the spatial path.
- **Cost:** O(frames x channels x taps) per voice.
- **Why this and not another:** "Linear: cheap, slightly dull at high pitch. Cubic: smoother when pitch-shifting" (`audio_voice.axle:25-30`).
- **Where:** `src/sim/audio/audio_voice.axle:384` (`mix`), `:304` (`read`), `:331`.
- **Docs:** MISSING.

### S-72. I want looping music with an intro, and crossfades that keep the loudness level
- **Means:** loop points inside a clip; an equal-power fade curve on both the outgoing and the incoming voice.
- **Mathematics:** fade-in level sin(age/fadeLen x pi/2) and fade-out level sin(left/len x pi/2) when `equalPower`, else linear (`audio_voice.axle:340-357`, quarter turn 1.5707964); `sin^2 + cos^2 = 1` keeps the summed power level through a crossfade (the file says "so the summed loudness stays level", `music_track.axle:1-6`). A loop shorter than 1 frame plays once (`:21-22,234-236`). Position wraps by subtracting one loop length (`:360-364`).
- **Instructions:** `playMusic(track, crossfade)` fades the old music out and the new in over `crossfade` seconds on the music bus; the clip is held decoded in memory ("this is not disk streaming").
- **Cost:** O(1) per frame for the envelope (one `sin` per frame during a fade).
- **Why this and not another:** a linear crossfade dips in loudness at the middle (the stated reason for equal power).
- **Where:** `src/sim/audio/audio_engine.axle:383` (`playMusic`), `src/sim/audio/audio_voice.axle:340`, `src/sim/audio/music_track.axle`.
- **Docs:** MISSING.

### S-73. I want sounds to fall quiet with distance (four models)
- **Means:** OpenAL-style distance models: none, inverse, linear, exponential, clamped between `minDistance` and `maxDistance`.
- **Mathematics:** with d clamped to [lo, hi], lo >= 1e-4: Inverse: lo / (lo + rolloff (d - lo)); Linear: clamp(1 - rolloff (d - lo)/(hi - lo), 0, 1); Exponential: (d/lo)^(-rolloff) via `AudioMath::pow` (`audio_spatial.axle:36-46,108-117`). Beyond max the gain stays at its max-distance value.
- **Instructions:** the exponential model uses the deterministic `pow` of S-79; others are plain arithmetic.
- **Cost:** O(1) per voice per block.
- **Why this and not another:** "OpenAL's conventions" (`audio_spatial.axle:3-4`).
- **Where:** `src/sim/audio/audio_spatial.axle:36` (`AudioAttenuation::gain`).
- **Docs:** MISSING.

### S-74. I want a sound to come from the left or right without changing loudness
- **Means:** equal-power panning by azimuth.
- **Mathematics:** angle = (p + 1) pi/4, left = cos(angle), right = sin(angle), so L^2 + R^2 = 1 for p in [-1, 1] (`audio_spatial.axle:125-129`). For a 3D source the pan is the sine of the angle from straight ahead: p = clamp(dir . right / |dir|, -1, 1) with right = forward x up (`:144-151`). A flat stereo clip is lifted by sqrt(2) = 1.4142135 so it matches a centred mono sound (which the law attenuates by 3 dB) (`audio_engine.axle:57-59`).
- **Instructions:** trig from `core::math::trig` (deterministic).
- **Cost:** two trig calls per voice per block.
- **Why this and not another:** a linear pan would dip by 3 dB at the centre (the equal-power rationale; not stated in the file).
- **Where:** `src/sim/audio/audio_spatial.axle:125,144`.
- **Docs:** MISSING.

### S-75. I want the pitch shift of a passing siren (Doppler)
- **Means:** frequency ratio from the radial speeds of listener and source.
- **Mathematics:** ratio = (c + v_L)/(c + v_S) with c = 343 m/s and both speeds measured along the listener-to-source line (positive = away from the listener), each clamped to +-0.9 c so the ratio stays finite (`audio_spatial.axle:14-22,136-141`); the emitter's `doppler` factor scales both speeds (`:166-171`).
- **Instructions:** ratio multiplies the voice's read step per block (the ratio is held constant within a block of 128 frames).
- **Cost:** O(1) per voice per block.
- **Why this and not another:** not documented (the sign convention in the file's comment is the only description).
- **Where:** `src/sim/audio/audio_spatial.axle:136` (`dopplerRatio`), `:154` (`solve`).
- **Docs:** MISSING.

### S-76. I want distant sounds to lose their high frequencies
- **Means:** a one-pole low-pass whose coefficient is set from the distance.
- **Mathematics:** damping = clamp((d - min)/(max - min), 0, 1); coefficient c = 1 - damping (1 - 0.125), so c runs from 1 (open) to 0.125 ("about a 1 kHz cutoff at 44.1 kHz") (`audio_engine.axle:67-68,455`); filter y += c (x - y) on the mono-mixed sample (`audio_voice.axle:422-425`).
- **Instructions:** one state float per voice.
- **Cost:** O(1) per frame per spatial voice.
- **Why this and not another:** "air absorbs high frequencies first" (`audio_spatial.axle:3-5`).
- **Where:** `src/sim/audio/audio_engine.axle:445` (`blockFor`), `src/sim/audio/audio_voice.axle:384`.
- **Docs:** MISSING.

### S-77. I want a moving sound source with no clicks when its gain jumps between updates
- **Means:** parameters (bus, distance, pan, Doppler) are re-solved once per block of 128 frames and the gains ramp linearly across the block.
- **Mathematics:** gain_k = last + k (block - last)/n (`audio_voice.axle:395-399`), so the last frame equals the new gain; the very first block starts from its own value (primed flag).
- **Instructions:** `blockFor` returns an `AudioBlock` (left, right, step, damp); `mix` consumes it.
- **Cost:** one spatial solve (a square root and a handful of dot products) per spatial voice per 128 frames.
- **Why this and not another:** "Gains are ramped across each block so a moving emitter does not click" (`audio_voice.axle:5-6`). The step (Doppler) is not ramped: UNVERIFIED whether this is audible.
- **Where:** `src/sim/audio/audio_engine.axle:32-33`, `src/sim/audio/audio_voice.axle:384`.
- **Docs:** MISSING.

### S-78. I want a mixing hierarchy: groups with their own volume and mute (music, effects, UI)
- **Means:** a tree of buses (up to 32, five built in) below the master; a voice's bus gain is the product of the gains from its bus up to the master, zero if any is muted.
- **Mathematics:** g = prod gain(b) over b in chain; master applied at the end (`audio_engine.axle:205-222,479-482`).
- **Instructions:** `busChain` walks parents with a guard of 32 steps.
- **Cost:** O(depth) per voice per block.
- **Why this and not another:** not documented.
- **Where:** `src/sim/audio/audio_engine.axle:163` (`addBus`), `:206` (`busChain`).
- **Docs:** MISSING.

### S-79. I want exp, ln and pow that give the same bits on every machine
- **Means:** range reduction + Taylor/atanh series using only +, -, x, / ("the C library's versions may differ in the last bit between platforms").
- **Mathematics:** exp: k = round(x/ln 2), r = x - k ln 2 (|r| <= ln2/2), sum of 16 Taylor terms, times 2^k computed by repeated squaring (`audio_math.axle:27-63`, accuracy "about 1e-12 relative"); ln: scale x by 2 into [0.75, 1.5], s = (m - 1)/(m + 1), ln m = 2 sum_{i<14} s^(2i+1)/(2i+1), plus e ln 2 (`:66-89`); pow(a, b) = exp(b ln a), 0 for a <= 0 (`:92-97`); ln(x <= 0) answers -700.
- **Instructions:** loops with fixed iteration counts (the ln scaling loop is as long as the exponent of x).
- **Cost:** about 16 multiply-add per exp, 14 per ln: much slower than libm, used for bells, bursts and the exponential attenuation only.
- **Why this and not another:** "would break 'render twice, get the same bytes' across machines".
- **Where:** `src/sim/audio/audio_math.axle:46,66,92`.
- **Docs:** MISSING.

### S-80. I want to build sounds from code: oscillators, an envelope, a filter
- **Means:** waveshapes by phase in turns (sine, square, saw, triangle, noise); piecewise-linear ADSR; first-order filter.
- **Mathematics:** saw = 2 p - 1; triangle 4p (p < 1/4), 2 - 4p (< 3/4), 4p - 4; ADSR: attack t/A, decay 1 - (1 - S)(t - A)/D, sustain S, then linear release from the level at gate (`synth.axle:48-60,83-98,124-146`). One-pole: w = 2 pi fc / fs, coefficient w/(1 + w), y += coef (x - y), high-pass = x - y (`:160-174`). Noise from an explicit `Pcg32`.
- **Instructions:** pure functions or small state machines stepped per sample; phase kept in f64 by `Synth::tone` (`synth_clips.axle:58-65`).
- **Cost:** O(1) per sample.
- **Why this and not another:** "Games that make their clips from these need no audio assets at all".
- **Where:** `src/sim/audio/synth.axle:48,105,155`.
- **Docs:** MISSING.

### S-81. I want an echo or a room reverb
- **Means:** a feedback delay line; a Schroeder/Freeverb reverb: four parallel damped combs into two series all-passes.
- **Mathematics:** delay: out = x + echo wet, line <- x + echo feedback, feedback <= 0.99 (`synth.axle:183-204`). Comb: y = line; store = y (1 - d) + store d; line <- x + store fb (`:208-226`); all-pass: out = held - x, line <- x + 0.5 held (`:229-245`). Lengths (frames at 44 100 Hz) 1116, 1188, 1277, 1356 and 556, 441, scaled by rate/44100 ("chosen so the echoes do not line up"); input x 0.15, comb feedback 0.7 + 0.28 room, damping <= 0.95 (`:14-32,260-282`).
- **Instructions:** circular buffers with modulo index, f32.
- **Cost:** O(1) per sample: 4 combs + 2 all-passes; memory (sum of the six lengths) x 4 bytes = 5936 frames about 23 KB at 44.1 kHz.
- **Why this and not another:** not documented beyond the Freeverb attribution in the comments.
- **Where:** `src/sim/audio/synth.axle:183,248`, `src/sim/audio/synth_clips.axle:175` (`withReverb`).
- **Docs:** MISSING.

### S-82. I want a bell, a noise burst, a looping pad or a jingle with no audio files
- **Means:** additive synthesis: five inharmonic decaying partials; low-passed noise; three notes snapped to whole cycles per clip.
- **Mathematics:** bell: sum_k a_k e^(-5 t / life_k) sin(2 pi f r_k t), ratios 1, 2, 2.76, 5.4, 8.93 ("after a measured church bell"), amplitudes 1, 0.6, 0.45, 0.25, 0.12, life_k = seconds/(1 + 0.8 k), 3 ms onset ramp, normalised to peak 0.8 (`synth_clips.axle:19-27,70-91,93-113`). Noise burst: noise x e^(-8 t/seconds) through a one-pole low-pass (`:116-128`). Pad: root, x5/4, x3/2, each a triangle (0.6) plus sine (0.4) with 2 tremolo cycles of depth 0.25 per clip; each partial snapped to a whole number of cycles over the clip length so it loops with no click (`:131-162`).
- **Instructions:** `mixInto(dest, src, atFrame, gain)` lays one mono clip over another.
- **Cost:** O(frames x partials) at build time (the bell evaluates 5 `exp` and 5 `sin` per sample with the slow deterministic `exp`).
- **Why this and not another:** "The sounds are simple on purpose".
- **Where:** `src/sim/audio/synth_clips.axle:47,70,116,131,165`.
- **Docs:** MISSING.

### S-83. I want to bounce the engine's output to a WAV file
- **Means:** `renderClip(frames)` then `AudioOffline::save` through `WavCodec` (16-bit PCM or 32-bit float).
- **Mathematics:** none: plain arithmetic here; the codec itself is in `src/data/audio/wav.axle`, outside this zone and not read.
- **Instructions:** one render into a temporary buffer of `2 x frames + 2` floats, copied into a clip (`audio_engine.axle:487-495`); file write through `FileOutputStream` (`audio_offline.axle:14-27`); errors answer a string.
- **Cost:** O(frames) time and 2 buffers of 8 bytes per frame (f32 stereo, twice).
- **Why this and not another:** "There is no device in this engine; the way to hear it is to render a stretch of time into a clip".
- **Where:** `src/sim/audio/audio_offline.axle:14`, `src/sim/audio/audio_engine.axle:487`.
- **Docs:** MISSING.

---

## Navigation (`src/sim/navigation`)

### S-84. I want a walkability and cost map with moving obstacles that a cache can detect as stale
- **Means:** `GridMap`: static cost per cell (0 = blocked, 1 = ground, larger = mud) plus a counted dynamic block layer; a `revision` counter.
- **Mathematics:** step cost = (1000 orthogonal | 1414 diagonal) x cost of the cell entered; integers, "so path costs add without rounding and equal costs compare exactly" (`grid_map.axle:14-23,184-191`); `blockRect` increments per cell so two overlapping obstacles keep the cell blocked until both go (`:229-243`).
- **Instructions:** every change bumps `revision` (`changes`); cells are row-major `i32` (two arrays: cost, blocks, 8 bytes a cell).
- **Cost:** O(rect area) per block/unblock; O(1) queries.
- **Why this and not another:** not documented.
- **Where:** `src/sim/navigation/grid_map.axle:39,118,158,229`.
- **Docs:** MISSING.

### S-85. I want a path across a grid without visiting every cell (A*)
- **Means:** A* with an octile (or Manhattan) heuristic on a binary `Heap`, working arrays reused between queries and stamped with a run number.
- **Mathematics:** h = 1000 hi + 414 lo with hi = max(|dx|, |dy|), lo = min (octile; Manhattan 1000 (|dx| + |dy|) without diagonals); admissible because the cheapest cell costs 1 (`grid_pathfinder.axle:1-6,393-407`). Key = (g + h) x 65536 + min(h, 65535) so equal f tie-breaks towards the smaller remaining estimate ("it dives towards the goal instead of flooding"), the heap breaks the remaining ties by insertion order (`:263-265,386-390`). Lazy deletion: a popped cell already closed is skipped (`:324-326`).
- **Instructions:** neighbours in fixed order; `g`, `parent`, `seen`, `closed` are `i32[K]` each (16 bytes a cell), stamped with `run` instead of cleared, "so a query costs what it explores, not the size of the map" (`:253-254,313-352`); `find` allocates a `GridPath` and a reversed index array on the trace.
- **Cost:** O(E log E) with E the cells expanded (`expanded()` counts them); worst case O(K log K); memory 16 bytes a cell + heap.
- **Why this and not another:** the flow field (S-88) for many agents with one goal; the navmesh (S-89) for open space.
- **Where:** `src/sim/navigation/grid_pathfinder.axle:304` (`find`), `:393` (`estimate`).
- **Docs:** MISSING.

### S-86. I want diagonal moves that never slip between two walls
- **Means:** a corner rule in `canStep`: with `setCutCorners(false)` (the default) both cells beside a diagonal step must be open.
- **Mathematics:** none: plain arithmetic: allowed = target walkable and (orthogonal, or diagonals on and (sideA and sideB; or sideA or sideB when cutting is on)) (`grid_map.axle:166-182`).
- **Instructions:** two extra `isWalkable` tests per diagonal.
- **Cost:** O(1).
- **Why this and not another:** "an agent cannot slip between two diagonal walls or graze a wall's corner" (`grid_map.axle:9-12`).
- **Where:** `src/sim/navigation/grid_map.axle:166`.
- **Docs:** MISSING.

### S-87. I want a grid path that is straight, not staircase-shaped
- **Means:** line-of-sight smoothing: keep a cell only if it is the farthest later cell in clear sight, under a cost cap.
- **Mathematics:** the line between cell centres is walked with exact integer arithmetic: at step (ix, iy) of (nx, ny) the sign of (1 + 2 ix) ny - (1 + 2 iy) nx says whether the line crosses a vertical or a horizontal edge next; zero means exactly through a corner, then the corner rule decides (`grid_line.axle:564-608`). The cap `maxCost` is the dearest cell the original path used between the two ends, so a detour round mud is not straightened through it (`grid_path.axle:497-542`).
- **Instructions:** for each anchor scan all later cells and test each: O(n) tests, each O(line length).
- **Cost:** O(n^2 L) worst case for n path cells and line length L; cheap for short paths.
- **Why this and not another:** "giving the corners of an any-angle route over the same cells" (`grid_path.axle:1-5`); theta* and jump point search are not used.
- **Where:** `src/sim/navigation/grid_path.axle:502,520`, `src/sim/navigation/grid_line.axle:564`.
- **Docs:** MISSING.

### S-88. I want fifty agents to head for the same goal with one computation
- **Means:** a flow field: Dijkstra from the goal cells over the same moves and costs, storing for each cell the cost to go and the next cell.
- **Mathematics:** the heap key is the distance, relaxed backwards from a cell onto a neighbour using the forward move (neighbour -> here) so one-way corner rules agree with A* ("`costAt(start)` is the cost of the A* path"); stale heap entries skipped by comparing the key to `dist` (`flow_field.axle:62-91`).
- **Instructions:** `rebuild(map, goalXs, goalYs, count)` clears two arrays and sweeps; an agent then does a table lookup (`stepX`, `stepY`); `isStale(map)` compares the `revision`.
- **Cost:** O(K log K) per rebuild; O(1) per agent per step; memory 8 bytes a cell (`dist`, `next`).
- **Why this and not another:** "A* answers one agent's question; when fifty agents head for the same place, one sweep from the goal answers all of them".
- **Where:** `src/sim/navigation/flow_field.axle:42` (`rebuild`), `:62` (`sweep`).
- **Docs:** MISSING.

### S-89. I want a navigation mesh of convex polygons joined by doorways
- **Means:** vertices + convex polygons (counter-clockwise, reversed if clockwise); edges shared by exactly two polygons become portals; or hand-made portals.
- **Mathematics:** area by the shoelace sum (`navmesh.axle:173-181`); convex iff no corner turns clockwise beyond 1e-5 (cross product test, `:184-196`); a portal's two ends are sorted into left and right by the sign of (centre-to-centre) x edge, and its midpoint stored (`:469-490`); shared edges found with a `Map<i64, i32>` keyed (min << 32 | max) (`:229-250`).
- **Instructions:** polygon data in `Vec`s of f32 and i32 (struct-of-arrays); `build()` links edges, lays out out-lists by counting, then freezes the mesh.
- **Cost:** O(total edges) to build with a hash map; memory per directed portal: from, to, left xy, right xy, mid xy = 4 + 4 + 24 bytes.
- **Why this and not another:** "big open rooms are one polygon, and agents move in straight lines inside it".
- **Where:** `src/sim/navigation/navmesh.axle:131` (`addPolygon`), `:218` (`build`), `:469` (`makePortal`).
- **Docs:** MISSING.

### S-90. I want a shortest route inside a mesh from point to point
- **Means:** A* where the nodes are portals entered at their midpoints, then the funnel algorithm (S-91).
- **Mathematics:** g = length of the polyline through portal midpoints; heuristic = Euclidean distance from the portal midpoint to the goal (a lower bound of the remaining polyline); heap key = trunc(cost x 1024) so costs equal to 1/1024 tie (`navmesh.axle:37-38,390-430,509-511`); the goal is one extra node past the last portal. Result path length <= corridor length.
- **Instructions:** `locate` scans all polygons for start and goal (first containing, slack 1e-5 x edge length); `NavSearch` allocates three arrays of portals + 1 per query plus a heap (`:43-76,334-377`).
- **Cost:** O(P log P) with P portals explored, plus O(polygons x vertices) to locate and O(portals) to allocate per query: not "a query costs what it explores" (see Doubts).
- **Why this and not another:** not documented.
- **Where:** `src/sim/navigation/navmesh.axle:347` (`findPath`), `:391` (`runSearch`).
- **Docs:** MISSING.

### S-91. I want to straighten a corridor of portals into the true shortest path
- **Means:** the funnel algorithm ("simple stupid funnel").
- **Mathematics:** twice the signed area of (a, b, c) = (b - a) x (c - a), positive when c is left of ray a->b (`funnel.axle:228-230`); the cone (apex, left, right) is narrowed portal by portal; when one side crosses the other the other side's end becomes a corner and the scan restarts after it (`:183-225`). Result is the shortest path inside the corridor, never longer than the line through the portal midpoints.
- **Instructions:** portals as `f32[4 x n]`; the goal is a zero-width last portal; points closer than 1e-6 are merged (`nav_path.axle`).
- **Cost:** O(portals) amortised per pull (restarts re-scan from the corner).
- **Why this and not another:** not documented.
- **Where:** `src/sim/navigation/funnel.axle:183` (`Funnel::pull`).
- **Docs:** MISSING.

### S-92. I want a mesh made automatically from a walkability grid
- **Means:** greedy rectangle cover of the open cells, one convex polygon each, joined along touching sides.
- **Mathematics:** the first free open cell in row order stretches right while the row stays open and free, then down while the whole span stays open and free; a doorway as wide as the overlap, found as runs of equal neighbour owner along the right and lower side of each rectangle (`navmesh_grid.axle:75-99,146-199`).
- **Instructions:** `owner` (i32 per cell) and `open` (bool per cell) arrays; a snapshot of the map: dynamic obstacles count as blocked, traversal costs are ignored.
- **Cost:** O(K) scan plus O(rect side) per run; produces a handful of polygons for a large room instead of hundreds of cells (the file's claim); the cover is greedy, not minimal.
- **Why this and not another:** not documented (no optimal rectangle partition).
- **Where:** `src/sim/navigation/navmesh_grid.axle:38` (`build`), `:75` (`scan`).
- **Docs:** MISSING.

### S-93. I want the agents near a point without comparing every pair
- **Means:** a uniform bucket grid built by counting sort; `gather` visits the buckets a circle overlaps.
- **Mathematics:** bucket = clamp(floor((v - min)/cell)) per axis; a circle's buckets are r0..r1 x c0..c1 (`neighbor_grid.axle:492-530`); the answer is a superset (caller checks the distance).
- **Instructions:** count, prefix sum, scatter (`rebuild`, `:455-481`, allocating a `fill` array of buckets + 1); buckets in row order, agents in index order, so results are reproducible.
- **Cost:** O(N + buckets) per rebuild; O(buckets overlapped + agents found) per gather.
- **Why this and not another:** "a game that already keeps its agents in the world's spatial index can hand `Steering::separation` the positions that index returns instead".
- **Where:** `src/sim/navigation/neighbor_grid.axle:455,492`.
- **Docs:** MISSING.

### S-94. I want an agent to head for a point, or to stop on it without overshooting
- **Means:** steering by acceleration towards a desired velocity; `arrive` scales the desired speed inside a slow radius.
- **Mathematics:** a = clamp(gain (v_want - v), maxAccel) with gain = maxAccel/maxSpeed, so a difference of a full maxSpeed asks for the full maxAccel (the velocity settles in about maxSpeed/maxAccel seconds) (`steering.axle:279-285`); arrive: speed = maxSpeed d/slowRadius inside the radius (`:291-303`); `step`: v' = limit(v + a dt, maxSpeed), x' = x + v' dt (`:437-446`, semi-implicit Euler).
- **Instructions:** pure functions over a `SteerAgent` value.
- **Cost:** O(1) per agent.
- **Why this and not another:** "No behaviour keeps state of its own, so a game can mix them (`seek + separation`), clamp the sum, and replay the same steps".
- **Where:** `src/sim/navigation/steering.axle:269,279,291,437`.
- **Docs:** MISSING.

### S-95. I want agents to keep their distance from each other
- **Means:** separation: push away from each neighbour inside `range`, harder the closer.
- **Mathematics:** strength = (range - d)/range; push += (offset/d) x strength; a = limit(push x maxAccel, maxAccel); two agents on the same spot are pushed opposite ways, decided by their indices (`steering.axle:310-343`).
- **Instructions:** one loop over the supplied neighbour arrays, skipping `selfIndex`.
- **Cost:** O(n_neighbours) per agent; with `NeighborGrid` O(local density) instead of O(N).
- **Why this and not another:** not documented.
- **Where:** `src/sim/navigation/steering.axle:310`.
- **Docs:** MISSING.

### S-96. I want an agent to follow a corner path smoothly without hunting each corner
- **Means:** path following with a look-ahead point: project the agent onto its segment, then walk `lookAhead` along the path.
- **Mathematics:** progress = (p - p0).(p1 - p0)/|p1 - p0|^2; segment advances while progress >= 1; target = the point `lookAhead` along the path from the projection, clamped to the last corner (`steering.axle:351-384,392-424,449-456`).
- **Instructions:** state is only the segment index, passed back by the caller.
- **Cost:** O(corners passed) per call.
- **Why this and not another:** "rounds corners smoothly and keeps the agent from hunting for each corner point" (`steering.axle:12-14`).
- **Where:** `src/sim/navigation/steering.axle:351` (`followPath`).
- **Docs:** MISSING.

---

## Particles (`src/sim/particles`)

### S-97. I want sparks, embers, leaves or portal motes moved by composable forces
- **Means:** a pool of plain f32 arrays moved by a stack of closed ops; each op is one flat loop over the pool in stack order, so forces compose by addition.
- **Mathematics:** Gravity v += g dt; Drag v *= max(1 - k dt, 0) (the header writes exp(-k dt) approx 1 - k dt, the code uses the linear form); Wind v += (w - v) min(k dt, 1); Attract v += (c - p) k dt + (up x (c - p)) s dt, i.e. dv_x = (dx k + dz s) dt, dv_z = (dz k - dx s) dt; Rise v_y += k dt; Colour and Size lerp over age/life; positions then p += v dt (semi-implicit Euler) (`particles.axle:300-391`, header `:1-16`).
- **Instructions:** one loop per op over `count` particles; the op code and 8 parameters per op stored in two `Vec`s; no allocation per tick.
- **Cost:** O(n x ops) per step; memory 13 arrays x capacity x 4 bytes (12 f32 + 1 i32) = 52 bytes a particle; 600 motes 31 KB (`doc/handbook/render/15-view-layers.md:119`). No measured time in the file ("microseconds" in the handbook).
- **Why this and not another:** "a new op is one value, one loop, one builder" (`particles.axle:25`); design in `doc/design/particles-wind.md` (not read for this file).
- **Where:** `src/sim/particles/particles.axle:158` (`PtcEffect`), `:300` (`step`).
- **Docs:** `doc/handbook/render/15-view-layers.md` section 3.6 (and `doc/design/particles-wind.md`).

### S-98. I want particle births that are the same in every replay, reference picture and thread count
- **Means:** births per tick as a function of the tick alone, draws from a `Pcg32` seeded by (effect seed, emitter key, tick).
- **Mathematics:** n = floor((t + 1) r dt) - floor(t r dt) (no carried remainder); `Pcg32(seed x 1000003 + key, 2 t + 1)` (`particles.axle:265-297`). Per-particle hashed ops (`Wobble`, `Flicker`) use `luxNoiseCorner(id, slot, seed)` with slot = floor(tick x often x dt) (`:351-360,375-383`).
- **Instructions:** positions uniform in the spawn box, velocity +-spread per component, life in [life, life + lifeSpread].
- **Cost:** O(births) per tick; emission stops silently when the pool is full.
- **Why this and not another:** "a replay, a reference picture and any thread count give the same particles".
- **Where:** `src/sim/particles/particles.axle:265`.
- **Docs:** `doc/handbook/render/15-view-layers.md` ("Births per tick are floor((t+1) r dt) - floor(t r dt)").

### S-99. I want effects stepped at a fixed rate from a frame clock, warmed up on the first frame
- **Means:** `PtcClock`: a tick clock (60 per second) that returns the tick range to run, catches up at most 6 ticks once particles are alive, lives the first 180 ticks at once, and clears the pool when the clock goes backwards.
- **Mathematics:** target = floor(seconds x rate); first call sets tick = target - warm; if target < tick: clear; if target - tick > catchUp and alive > 0: tick = target - catchUp (`particles.axle:131-148`). An empty effect runs every missed tick, which is how its first call warms it up.
- **Instructions:** returns `PtcTicks { from, to, clear }`.
- **Cost:** O(1) plus up to `warm` = 180 steps on the first frame.
- **Why this and not another:** "a picture never shows an empty fountain".
- **Where:** `src/sim/particles/particles.axle:109-148`.
- **Docs:** `doc/handbook/render/15-view-layers.md` (3.6, only the births).

### S-100. I want dead particles removed deterministically, in constant time per death
- **Means:** swap-remove in index order: the last particle takes the dead one's slot.
- **Mathematics:** none: plain arithmetic. The pool is walked from the start and the particle moved from the end is aged once more by staying on the same index (`particles.axle:398-425`).
- **Instructions:** copies 13 array entries per death.
- **Cost:** O(dead) per tick plus O(n) for the aging walk.
- **Why this and not another:** "which particle lands where depends on nothing but the pool".
- **Where:** `src/sim/particles/particles.axle:400` (`cull`).
- **Docs:** `doc/handbook/render/15-view-layers.md` (3.6, "the dead are swap-removed in index order").

---

## Missing documentation

| mechanism | file | what is not written down anywhere in `doc/` |
|---|---|---|
| Rigid-body step order, 10 + 6 iterations, 120 Hz, 64-step cap | `src/sim/kinetic/physics_world.axle:37-473`, `physics_settings.axle` | the whole kinetic pipeline: only one line in `doc/ROADMAP.md:28` |
| Sweep and prune on X, pair keys, merge sorts | `broad_phase.axle`, `kinetic_sort.axle` | complexity and why X only |
| Box-box SAT, clipping, bias constants 0.98 / 0.95 / 0.0005 | `narrow_box.axle:19-54` | derivation of the biases; feature id layout (64 / 4 / 100 / 4096 spans) |
| Sequential impulses, effective masses, friction cone, pushFactor 0.4, slop 5 mm, maxPush 4 m/s | `contact_solver.axle`, `physics_settings.axle` | the formulas and why friction is solved before the normal row |
| Split impulse (pseudo velocities) and `jointBeta` bias | `contact_solver.axle:74-154`, `joint_solver.axle:36-204` | that the joint "Baumgarte" bias acts on the pseudo-velocity pass only |
| Hinge angle, limits, reference directions | `joint_solver.axle:108-267` | convention of the zero angle (creation pose) and the limit sign rules |
| Capsule inertia (parallel axis, 3r/8) | `shape.axle:134-149` | only a code comment |
| Golden-section capsule/box search (40 steps) | `narrow_box.axle:232-256` | accuracy and cost |
| Sleeping islands (union-find, thresholds 0.05 / 0.08 / 0.5 s) | `sleeper.axle` | whole mechanism, including the per-step allocations |
| State hash quantisation | `state_hash.axle` | how a replay test should use it |
| Hydro foam/turbulence constants (6, 1.2, 0.35, 0.17, 0.5) and shear formula | `hydro_passes.axle:33-49,414-427` | the model and its derivation |
| Hydro aeration/crown/split constants | `hydro_air.axle:35-49` (`HYDRO_SPLASH_*`, `HYDRO_CROWN_*`, `HYDRO_BREAK_SPREAD`) | what the numbers mean, the crown geometry |
| Hydro lips: cliff detection over 3 cells, 32-cell trace for fall height | `hydro_lips.axle:41-50,91-198` | the algorithm for the fall height H |
| Hydro inflow block rule ("bed under the water of the centre cell") | `hydro_sources.axle:133` | only the header and a doc line |
| Substep floor 1 m/s (`HYDRO_QUIET_SPEED`) | `hydro_world.axle:42,533` | the doc gives the unfloored formula |
| Legacy PBF kernels (poly6, spiky), wall density table, relaxation, caps | `fluid_liquid.axle` | everything but the choice of PBF over SPH/FLIP |
| Legacy column pipes constants (0.25, 0.5, 0.2, 0.5) | `fluid_pipes.axle:37-49` | meaning of each limit beyond the code comments |
| Legacy surface analysis (Froude 1.1, steepness 0.55), foam, emit, impact | `fluid_surface.axle`, `fluid_foam.axle`, `fluid_emit.axle`, `fluid_impact.axle` | formulas and defaults |
| Legacy spatial hash 64 x 64 x 32 wrap | `fluid_grid.axle` | none beyond the header |
| Keyframe tracks, Hermite weights, clip clocks | `track_math.axle`, `vec3_track.axle`, `quat_track.axle`, `animation_clip.axle` | any chapter |
| Animator crossfade and transition rules, root-motion loop arithmetic | `animator.axle`, `root_motion.axle` | any chapter |
| Additive layers and masks | `pose_blend.axle:80-93` | the additive-rotation formula |
| Two-bone IK, FABRIK, look-at | `ik.axle` | formulas and the pole-twist construction |
| Skinning normals with non-uniform scale | `skinning.axle:1-12` | the limitation is only a code comment |
| Audio soft limiter, knee 0.8 | `audio_engine.axle:410-429` | the curve |
| Voice stealing and handle format | `audio_engine.axle:37-43,255-286` | the policy |
| Doppler, attenuation, pan, distance low-pass (coefficient 0.125) | `audio_spatial.axle`, `audio_engine.axle:67-68` | formulas and units |
| Deterministic exp/ln/pow | `audio_math.axle` | accuracy proof (the "1e-12" is only asserted) |
| Reverb tunings | `synth.axle:14-32` | provenance of the numbers beyond "Freeverb" |
| Bell partial ratios and amplitudes | `synth_clips.axle:19-27,93-113` | the source of the "measured church bell" values |
| Grid costs 1000 / 1414, A* tie key, octile heuristic | `grid_map.axle`, `grid_pathfinder.axle` | the formulas |
| Line-of-sight test with exact integers | `grid_line.axle` | the decision variable |
| Navmesh A* over portals, key scale 1024 | `navmesh.axle` | the node model |
| Funnel | `funnel.axle` | only a comment |
| Greedy rectangle cover | `navmesh_grid.axle` | that it is not minimal |
| Steering gains, separation law, follow-path look-ahead | `steering.axle` | formulas |
| Particles: `PtcClock` warm/catch-up and `Drag` form | `particles.axle:109-148,319-326` | only the births are in `doc/handbook/render/15-view-layers.md` |

## Doubts

- `src/sim/fluid/hydro_grid.axle:18-19` says "90 bytes" per cell; the items listed in the same comment sum to 94 (bed 4, depth 4, credit 4, discharge 8, velocity 8, 12 face-flux arrays 48, lip flags 2, scale 4, foam 8, turbulence 4), which is what `doc/FLUID.md:98-112` says.
- `doc/FLUID.md:50` gives the substep as `cfl * cellSize / max(|u| + sqrt(g h))`; the code bounds the maximum from below by 1 m/s (`hydro_world.axle:42,533`), so the doc formula is incomplete.
- `src/sim/kinetic/joint_solver.axle:1-6` says the joint position error is "fed back as a velocity (Baumgarte)"; in the code the bias enters only `iteratePosition` on the pseudo velocities (`:181-204`), never `iterate` (`:153-178`): a split-impulse form, not classical Baumgarte on real velocities.
- `src/sim/kinetic/physics_query.axle:1-6` says a ray cast tests the ray against every body's shape "after a cheap box test"; `raycast` (`:51-82`) calls `rayShape` for every live body with no box test (only `overlapInto` has one, `:244-260`).
- `src/sim/kinetic/physics_world.axle:485-503` applies the torque but no gyroscopic term (w x I w); for bodies with unequal principal inertias spin about a non-principal axis is then not angular-momentum conserving (verified by reading only; no test run).
- `src/sim/kinetic/sleeper.axle:71-72,124,148` and `physics_world.axle:513` allocate several O(N) arrays on every step, and `wakeIsland` scans all slots (`:25`): costs the CLAUDE.md hot-loop rules would flag; not wrong, but not "free" as the sleeping comment suggests ("costs nothing until an awake body touches it", `sleeper.axle:1-8`; the per-step bookkeeping still runs).
- `src/sim/animation/quat_track.axle:142-156` (cubic) blends the four-component Hermite without a shortest-arc sign flip between the two keys, unlike the `Linear` path; UNVERIFIED whether importers pre-flip the keys.
- `src/sim/animation/vec3_track.axle:17-18,37` says every track allocates the cubic size "whatever its interpolation, so switching never needs a reallocation", but `interp` is a constructor argument with no setter, so no switch can happen and a `Step`/`Linear` track wastes 6 of 9 floats per key (layout uses stride 3, `:156-161`); `quat_track.axle:13-15` does the same with 12 floats per key.
- `src/sim/audio/audio_voice.axle:360-364` wraps a looping position by subtracting one loop length once; if the step per frame is longer than the loop (very short loop, high pitch) the position stays beyond the loop end: UNVERIFIED consequence (reads are folded by modulo in `fold`, `:287-301`, but `position` itself keeps growing).
- `src/sim/navigation/navmesh.axle:229-250` links an edge when exactly two polygons share it; a third polygon sharing the same edge becomes a new "owner" of it (the key was removed after the second) and is never linked to the other two; the file says "exactly two" but does not reject three.
- `src/sim/navigation/navmesh.axle:1-17` and `grid_pathfinder.axle:253-254` differ: the grid finder reuses stamped arrays so "a query costs what it explores", but `NavMesh::findPath` allocates `NavSearch` arrays of size portals + 1 and `locate` scans every polygon on each query (`:334-341,366`).
- `doc/ARCHITECTURE.md:10` and `doc/NAMES.md:30` list "gameplay" under `src/sim`; there is no such directory (`animation audio fluid kinetic navigation particles`).
- `src/sim/particles/particles.axle:5` header writes `Drag v *= exp(-k dt) ≈ 1 - k dt`; the code (`:320`) and the handbook (`15-view-layers.md:90`) use the linear form clamped at zero, which differs from the exponential for k dt not small (it zeroes the velocity at k dt >= 1).
- `src/sim/fluid/hydro_params.axle:139-141` documents the CFL limit as "positive below one half", while `checked()` replaces any value above 0.45 by 0.25 (`:228-230`).
- `src/sim/kinetic/body_store.axle:289-298`: `remove` does not call `wakeIsland` on the removed body's island or clear its contacts; whether stale manifolds are harmless relies on the next `collide` rebuilding them: UNVERIFIED (not traced through `Sleeper.update` of a sleeping island that contained the removed body).

## Summary of coverage

All 100 entries come from the source files of `src/sim` that exist today: kinetic (S-01 to S-24: stepping, shapes, broad and narrow phase, contacts, joints, sleeping, queries, hash), `HydroWorld` (S-25 to S-42), the legacy `FluidWorld` (S-43 to S-54), animation (S-55 to S-67), audio (S-68 to S-83), navigation (S-84 to S-96) and particles (S-97 to S-100). Every file in the zone was opened; kinetic (except `debug_draw` and `joint_set`, read as headers and field lists), animation (all but the bodies of `pose`, `skeleton`, `bone_mask`, `event_buffer`, read in part), audio, navigation, particles, `hydro_flux`, `hydro_passes`, `hydro_runner` and `hydro_params` were read line by line, `hydro_grid` in part; for the large `hydro_world`, `hydro_lips`, `hydro_air`, `hydro_vents`, `hydro_drifters`, `hydro_sources`, `hydro_sample` and all `fluid_*` files I read the headers in full and the main kernels (`fluid_pipes`, `fluid_liquid`, `fluid_grid`, the substep and step of `hydro_world`, `fly`/`release`/`land`) but not every function: their constants and formulas are quoted from the places read, and the rest is attributed to the file headers and `doc/FLUID.md` (whose measured figures are quoted with their line numbers and were not re-measured; nothing was built or run). Not verified: sizes of `Shape`, `Vec<bool>`, `Transform` and `Mat4`; the internals of `Quat::slerp`, `Transform::lerp` and `hashCombine` (outside the zone); the WAV codec (`src/data/audio/wav.axle`); the "gameplay" area named in `doc/ARCHITECTURE.md`, which has no files; and any claim marked `UNVERIFIED` above. No test files were read, so "tested" statements come from `doc/FLUID.md`.
