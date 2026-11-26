# Modules

What each part of the engine is for. One page per area of `src/`, each with its sub-areas and, for every file, what it does. Pages are generated from the file headers (`tools/gen_module_docs.py`).

The rules for where code goes are in [the architecture](../guide/architecture.md); how a mechanism works is in [the handbook](../handbook/README.md); to find the means for a need, read [the problems glossary](../handbook/README.md#problems-glossary).

| Layer | Area | Responsibility | Files |
|---|---|---|---|
| 1 | [`src/core`](core.md) | maths, memory, containers (packed and paletted ones included), ids, random numbers, time, log, jobs, profiler, test harness | 54 |
| 2 | [`src/data`](data.md) | virtual file system, asset database, importers (glTF, `.bbmodel`, images, audio), serialisation (NBT, name tables), codecs (LZ4, inflate/deflate), sector region files, zip archives, random-access files | 40 |
| 3 | [`src/world`](world.md) | sparse-set ECS, scenes, transform hierarchy, spatial indices | 9 |
| 4 | [`src/sim`](sim.md) | `kinetic` physics, `fluid` water, animation, audio, navigation, particles | 93 |
| 5 | [`src/render`](render.md) | scene extraction, render graph, command stream, CPU backend, the lighting library, the path-lit picture (`pathlight`) and the layered light (`lux`) | 76 |
| 6 | [`src/runtime`](runtime.md) | main loop, game modules, settings | 10 |
| 7 | [`src/openworld`](openworld.md) | content modules; independent of each other | 14 |
| 7 | [`src/voxel`](voxel.md) | content modules; independent of each other | 29 |
