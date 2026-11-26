# `src/core`

Layer 1. Maths, memory, containers (packed and paletted ones included), ids, random numbers, time, log, jobs, profiler, test harness.

54 files in 11 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [the determinism chapter](../handbook/concepts/02-determinism.md); [hot-loop rules](../handbook/standards/01-hot-loop-rules.md); [problems: core, world, runtime](../handbook/problems/core-world-runtime.md).

## `src/core/collections`

Containers whose growth, cost and aborts are stated: dynamic vectors, hash maps, string maps, rings, slabs, sparse sets, heaps and bit sets, and the bit-packed and paletted cell stores the voxel world is made of.

| File | What it does |
|---|---|
| `bitset.axle` | a growable set of small non-negative integers, one bit each. |
| `heap.axle` | a binary min-heap: the element with the smallest key comes out first. |
| `map.axle` | a hash map whose iteration order is the order the keys were first inserted. |
| `packed_cells.axle` | fixed-width entries packed into 64-bit words, never spanning two words. |
| `paletted_pool.axle` | many paletted containers of equal size, stored side by side in two pools. |
| `ring.axle` | a fixed-capacity FIFO queue over a circular buffer. |
| `slab.axle` | a pool of values addressed by generational ids. |
| `sparse_set.axle` | a map from small whole-number keys to values, stored packed for fast iteration. |
| `string_map.axle` | `Map` for string keys: insertion-ordered, deterministic, values of any plain type. |
| `vec.axle` | a growable array of values, the engine's workhorse container. |

## `src/core/field`

Scalar fields with exact gradients, as tapes of operations: the noise and field graph that looks and effects read.

Read more: [view layers](../handbook/render/15-view-layers.md).

| File | What it does |
|---|---|
| `lux_field.axle` | fields: functions of a point and the time, built as a graph of a few ops, evaluated flat with their gradient. |
| `lux_noise.axle` | value noise with its exact gradient, in the core so that rendering and simulation share one noise. |

## `src/core/id`

Entity ids with generations, a dense id allocator, string ids and the hash functions they use.

| File | What it does |
|---|---|
| `entity_id.axle` | a generational reference to a slot: an index plus the slot's generation. |
| `hash.axle` | the engine's hash functions and the trait that lets a type key a `Map`. |
| `id_allocator.axle` | issues and retires `EntityId`s, recycling slots with a new generation. |
| `string_id.axle` | interned strings: each distinct text gets a small number, handed out in first-seen order. |

## `src/core/jobs`

The fixed worker pool and the range kernels it runs: loops cut into chunks over all cores, with a result that does not depend on the number of threads.

Read more: [the job pool](../handbook/engine/01-job-pool.md).

| File | What it does |
|---|---|
| `kernel.axle` | the unit of parallel work, and the rules that make its results deterministic. |
| `pool.axle` | worker threads that run a kernel over index ranges. |

## `src/core/log`

Levelled logging to sinks, with records and an in-memory sink for tests.

| File | What it does |
|---|---|
| `level.axle` | how serious a log record is. |
| `logger.axle` | leveled logging with a pluggable sink. |
| `memory.axle` | a sink that remembers the most recent records. |
| `record.axle` | one line of the log, and how it is printed. |
| `sink.axle` | where log records go: the trait, a console sink, and a combinator. |

## `src/core/math`

Vectors, matrices, quaternions, transforms, geometry and intersection tests, frustum culling and deterministic trigonometry, in f32 with generated f64 twins (the files starting with `d`).

| File | What it does |
|---|---|
| `convert.axle` | between the f64 world and the f32 renderer. |
| `dgeom.axle` | the shapes of space queries: box, sphere, ray and plane. |
| `dintersect.axle` | rays and shapes against each other. |
| `dmat3.axle` | a 3x3 f64 matrix: rotations, scales and normal transforms. |
| `dmat4.axle` | a 4x4 f64 matrix: model, view and projection transforms. |
| `dquat.axle` | a unit quaternion: a rotation in three dimensions. |
| `dtransform.axle` | translation, rotation and scale as separate parts. |
| `dvec2.axle` | a two-component f64 vector. |
| `dvec3.axle` | a three-component f64 vector. |
| `dvec4.axle` | a four-component f64 vector. |
| `frustum.axle` | the six planes of a camera, for culling. |
| `geom.axle` | the shapes of space queries: box, sphere, ray and plane. |
| `intersect.axle` | rays and shapes against each other. |
| `mat3.axle` | a 3x3 f32 matrix: rotations, scales and normal transforms. |
| `mat4.axle` | a 4x4 f32 matrix: model, view and projection transforms. |
| `quat.axle` | a unit quaternion: a rotation in three dimensions. |
| `scalar.axle` | constants and one-number helpers, in f32 and f64. |
| `transform.axle` | translation, rotation and scale as separate parts. |
| `trig.axle` | deterministic sin, cos, tan, atan2, acos and sqrt. |
| `vec2.axle` | a two-component f32 vector. |
| `vec3.axle` | a three-component f32 vector. |
| `vec4.axle` | a four-component f32 vector. |

## `src/core/mem`

A bump arena for scratch memory freed all at once.

| File | What it does |
|---|---|
| `arena.axle` | a bump allocator over one block of raw memory, freed all at once. |

## `src/core/profile`

Named scoped timers collected per frame.

| File | What it does |
|---|---|
| `entry.axle` | one line of the per-frame profile. |
| `names.axle` | interned profiler scope names. |
| `profiler.axle` | scoped CPU timing, recorded into a preallocated ring of frames. |

## `src/core/rng`

The Pcg32 generator: explicit, seedable, deterministic random numbers.

| File | What it does |
|---|---|
| `pcg32.axle` | a small, fast, explicitly seeded random number generator. |

## `src/core/test`

The check harness every test suite uses.

| File | What it does |
|---|---|
| `checks.axle` | the tiny harness every suite of the engine reports to. |

## `src/core/time`

The monotonic clock, the fixed-step accumulator and timers.

| File | What it does |
|---|---|
| `clock.axle` | the monotonic clock, unit conversions and the Stopwatch. |
| `fixedstep.axle` | the accumulator that turns uneven frames into even simulation ticks. |
| `timer.axle` | a countdown driven by simulation time, one-shot or repeating. |
