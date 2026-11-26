# `src/sim`

Layer 4. `kinetic` physics, `fluid` water, animation, audio, navigation, particles.

93 files in 6 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: simulation](../handbook/problems/simulation.md).

## `src/sim/animation`

Keyframe tracks, skeletons, clips, blending, IK, root motion, events and skinning.

| File | What it does |
|---|---|
| `animation_clip.axle` | an animation clip: tracks per bone, a length, a looping flag and event markers. |
| `animator.axle` | a state machine over clips with crossfades between states. |
| `bone_mask.axle` | a weight factor for every bone, to blend part of a skeleton. |
| `clip_events.axle` | which event markers of a clip a stretch of playback crosses. |
| `event_buffer.axle` | the growing list of events a stretch of playback fired. |
| `ik.axle` | inverse kinematics: reach a target by turning bones. |
| `pose.axle` | one local transform per bone, and the matrices derived from it. |
| `pose_blend.axle` | combining poses: crossfades, additive layers and per-bone masks. |
| `quat_track.axle` | keyframe tracks of rotations sampled by time. |
| `root_motion.axle` | the movement a clip's root bone makes, as a delta to hand to the character. |
| `skeleton.axle` | the bone hierarchy of a rig: what never changes while it plays. |
| `skinning.axle` | linear blend skinning on the CPU. |
| `track_math.axle` | the interpolation modes and the time arithmetic that vector tracks and rotation tracks share. |
| `vec3_track.axle` | keyframe tracks of vectors (translation, scale) sampled by time. |

## `src/sim/audio`

A deterministic software mixer: voices, spatialisation, music tracks, offline rendering and a synthesiser.

| File | What it does |
|---|---|
| `audio_engine.axle` | the software mixer: voices, buses, listener and a soft-limited stereo output, with no device attached. |
| `audio_math.axle` | the few scalar functions audio needs, computed the same way on every machine. |
| `audio_offline.axle` | bouncing the engine's output to a WAV file. |
| `audio_spatial.axle` | where a sound is relative to the listener, and what that does to it. |
| `audio_voice.axle` | one sound being played: a position in a clip and everything that shapes it. |
| `music_track.axle` | a long clip that loops, described as data. |
| `synth.axle` | oscillators, an ADSR envelope and one-pole filters: the parts a sound is built from in code. |
| `synth_clips.axle` | ready-made clips built from the synth parts, so a game needs no audio files. |

## `src/sim/fluid`

Two water engines: the legacy `FluidWorld` (`fluid_*`) and `HydroWorld` (`hydro_*`), with their particles, sources and couplings.

Read more: [the fluid specification](../spec/fluid.md).

| File | What it does |
|---|---|
| `fluid_aloft.axle` | spray in ballistic flight. |
| `fluid_coupling.axle` | where particles give their water back to the columns: landing, splash and breakup. |
| `fluid_emit.axle` | where the columns give water to the air: breaking crests and surfaces thrown up. |
| `fluid_emitters.axle` | where water enters and leaves the world outside the pipes: sources, drains and spills. |
| `fluid_field.axle` | the state of a column world: ground, water, external load, and the head they make. |
| `fluid_foam.axle` | whitewater coverage and turbulence, two fields over the columns that a renderer reads. |
| `fluid_grid.axle` | the spatial hash that finds a particle's neighbours, built by counting sort. |
| `fluid_ground.axle` | the one question the fluid simulation asks of the terrain: how high is the ground here? |
| `fluid_impact.axle` | an object hitting the water: displacement, an outward shock, and spray. |
| `fluid_liquid.axle` | the liquid particles as a true fluid: position-based fluids on a spatial hash. |
| `fluid_noise.axle` | deterministic randomness and small maths for code that runs on several threads. |
| `fluid_particle.axle` | the particle vocabulary of a `FluidWorld`: what a game or a renderer reads of the water that left the heightfield. |
| `fluid_particle_params.axle` | every number that shapes the particle layer, one struct per module. |
| `fluid_particles.axle` | the particle layer of a world: its populations, its solvers, and the order they run in. |
| `fluid_pipes.axle` | the transfer law: how water crosses the frontier between two columns. |
| `fluid_pool.axle` | the storage of one population of particles, and the population the layer is made of. |
| `fluid_rules.axle` | the vocabulary a game uses to configure and observe a `FluidWorld`. |
| `fluid_runner.axle` | the stages of the particle solver as parallel loops, bit-identical for any thread count. |
| `fluid_sample.axle` | reading the column fields between column centres. |
| `fluid_spawn.axle` | making particles, with the radius each population wants. |
| `fluid_surface.axle` | what the surface of the columns is doing: its velocity, its steepness, and where it breaks. |
| `fluid_tick.axle` | the bookkeeping one tick of the pipe model runs on: who is awake, what was touched, how the frontiers are numbered. |
| `fluid_vent.axle` | a vent: a conduit that throws a powerful column of water out of the pool, after a dome of water has been pushed up under it. |
| `fluid_world.axle` | FluidWorld, the column-water simulation a game drives. |
| `hydro_air.axle` | what becomes of airborne water: landing, splash, breakup and foam, in one serial phase. |
| `hydro_drifters.axle` | markers that ride the water for real: they float, they fall, they float on. |
| `hydro_flux.axle` | the numerical flux of one face: limited reconstruction, hydrostatic correction, HLL. |
| `hydro_grid.axle` | the state of the metric water engine: one padded, row-major structure-of-arrays grid. |
| `hydro_lips.axle` | overfalls: where the bed drops away and the water leaves it in a falling curtain. |
| `hydro_params.axle` | every number that shapes the shallow-water engine and its overfall particles. |
| `hydro_particles.axle` | the airborne water of the metric engine: storage and the ballistic flight kernel. |
| `hydro_passes.axle` | the tile loops of one substep: faces, positivity, update, and the surface fields. |
| `hydro_runner.axle` | the passes of a substep as parallel loops, bit-identical for any thread count. |
| `hydro_sample.axle` | reading the grid between cell centres, for a renderer, a boat or a sound. |
| `hydro_sources.axle` | inflows and sinks: the declared places where the world gains and loses water. |
| `hydro_vents.axle` | jets: a conduit that throws water into the air, a geyser, a fountain, a firehose. |
| `hydro_world.axle` | HydroWorld, the metric water simulation a game or a scene drives: rivers, lakes and waterfalls. |

## `src/sim/kinetic`

Rigid-body physics: shapes, broad and narrow phase, contacts and solver, joints, sleeping, queries and a state hash.

| File | What it does |
|---|---|
| `body_store.axle` | every rigid body of a physics world, one array per property. |
| `broad_phase.axle` | finds the pairs of bodies whose bounding boxes overlap. |
| `clip_poly.axle` | a small convex polygon that can be cut by planes, for clipping box faces against each other. |
| `contact_buffer.axle` | the scratch space a narrow-phase test writes its contact points into. |
| `contact_set.axle` | the contacts of one step, as the solver and the debug view see them. |
| `contact_solver.axle` | sequential impulses for contacts: non-penetration, Coulomb friction and restitution. |
| `debug_draw.axle` | the world as plain lines and points, for any renderer to draw. |
| `joint_set.axle` | the joints of a world: what they connect and the solver's working values for each. |
| `joint_solver.axle` | sequential impulses for ball-and-socket, distance and hinge joints. |
| `kinetic_geometry.axle` | closest-point queries on segments and boxes that the narrow phase and the ray casts share. |
| `kinetic_sort.axle` | the stable sorts kinetic uses to keep every iteration order deterministic. |
| `narrow.axle` | picks the contact test for a pair of shapes. |
| `narrow_basic.axle` | contact generation for spheres, capsules and planes. |
| `narrow_box.axle` | contact generation for oriented boxes: against spheres, capsules and each other. |
| `physics_measure.axle` | conserved quantities of a physics world: energy and momentum. |
| `physics_query.axle` | questions about the world that do not change it: ray casts and overlap tests. |
| `physics_settings.axle` | the tunable numbers of a physics world, gathered in one value. |
| `physics_world.axle` | PhysicsWorld, the rigid-body simulation a game talks to. |
| `shape.axle` | the collision shapes of kinetic and what they weigh. |
| `sleeper.axle` | puts resting groups of bodies to sleep and wakes them when something touches them. |
| `solver_state.axle` | the flat working copy of body motion that the constraint solvers iterate on. |
| `state_hash.axle` | a fingerprint of a whole physics state, for determinism checks and replays. |

## `src/sim/navigation`

Path finding on grids and navmeshes, flow fields, funnel smoothing and steering.

| File | What it does |
|---|---|
| `flow_field.axle` | a Dijkstra map towards one or more goals, for many agents at once. |
| `funnel.axle` | the funnel algorithm that straightens a corridor of portals into the shortest path. |
| `grid_line.axle` | whether a straight line over a grid map crosses only walkable cells. |
| `grid_map.axle` | a walkability and cost grid for path finding. |
| `grid_path.axle` | a route over grid cells, and line-of-sight smoothing of it. |
| `grid_pathfinder.axle` | A* on a `GridMap`. |
| `nav_path.axle` | the path a navigation mesh query returns. |
| `navmesh.axle` | a navigation mesh of convex polygons joined by portals, with A* over the portals. |
| `navmesh_grid.axle` | a navigation mesh made from a walkability grid. |
| `neighbor_grid.axle` | find the agents near a point without comparing every pair. |
| `steering.axle` | how an agent moves along a path without bumping into its neighbours. |

## `src/sim/particles`

The particle effect model: spawns, ticks and the clock that drives them.

Read more: [view layers](../handbook/render/15-view-layers.md).

| File | What it does |
|---|---|
| `particles.axle` | sparks, motes, embers and leaves: a pool of plain arrays moved by a stack of closed ops. |
