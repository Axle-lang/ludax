# `src/world`

Layer 3. Sparse-set ECS, scenes, transform hierarchy, spatial indices.

9 files in 2 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: core, world, runtime](../handbook/problems/core-world-runtime.md).

## `src/world`

Entities and components (sparse-set stores), scenes with a transform hierarchy and a JSON form, a spatial index, queries and an inspector.

| File | What it does |
|---|---|
| `hierarchy.axle` | who is whose child. |
| `inspect.axle` | a scene as readable text: the tree, names, and where everything is. |
| `query.axle` | the entities that have several kinds of component at once. |
| `scene.axle` | entities with names, a parent/child tree and transforms. |
| `scene_json.axle` | a scene saved to JSON and loaded back. |
| `spatial.axle` | a uniform grid that answers "what is near this box". |
| `store.axle` | the components of one kind, packed. |
| `world.axle` | which entities exist. |

## `src/world/shape`

Shapes of a few boxes inside a cell, with exact rays.

Read more: [small things](../handbook/render/18-shapes.md).

| File | What it does |
|---|---|
| `shape_bank.axle` | the small solid parts a cell may hold instead of filling it: a flower's stem and bloom, a torch's stick and flame, a button, a lever's base and handle, a fence post, a lantern on its chain. |
