# Ludax documentation

Ludax is a game engine written in Axle: entities and worlds, physics, animation, audio,
an asset pipeline, a voxel world and a renderer whose lighting is checked against independent mathematics. It runs on the
platform library [smalt](https://github.com/Axle-lang/smalt). Everything is deterministic: the same input gives the same bits,
whatever the number of threads. Source is `src/`; programs built on it are in `examples/` and `games/`.

The documentation is organised by the question you bring to it.

| You want to know | Read | What it is |
|---|---|---|
| What is built, and what is not | [roadmap](roadmap.md) | the state of each layer, with its limits |
| What each part of the engine does | [modules](modules/README.md) | one page per area of `src/`, every file with what it does |
| Where a new file goes, and how it is written | [architecture](guide/architecture.md), [style](guide/style.md), [names](guide/names.md) | the layers, the rules of the code, the vocabulary |
| How a mechanism works, and what it costs | [handbook](handbook/README.md) | one chapter per heavy mechanism: mathematics, algorithm, complexity, measurements |
| How to get something done at the least cost | [problems glossary](handbook/README.md#problems-glossary) | "I want X" followed by the algorithm, its formula, its cost in CPU and memory, and where it lives |
| What was tried, and why it stayed or went | [what was tried](handbook/history/techniques.md) | every procedure with its Axle version, measured cost and verdict |
| What the contract of a subsystem is | [specifications](spec/) | rendering, lighting, the lighting mathematics, fluids |

## The tree

```
doc/
  README.md          this page
  roadmap.md         what is done, partial, not started
  guide/             how to work in the code
    architecture.md    layers, imports, where code goes
    style.md           how a file is written
    names.md           one word per concept
  modules/           what each module does (generated from the file headers by tools/gen_module_docs.py)
  spec/              the contracts, each stating how it is proved
    rendering.md       data flow from world to picture, the command stream, the graph
    lighting.md        the lighting contract
    lighting-math.md   the formulas behind it, each with an independent check
    fluid.md           the two water engines
  handbook/          how the mechanisms work
    concepts/          smooth and sharp signals, determinism, the cost model, the complexity ledger
    standards/         rules for hot loops, shared buffers, types and memory
    engine/            the job pool
    render/            one chapter per rendering mechanism
    problems/          the glossary of needs and means, one file per zone of the code
    history/           what was tried, by technique; the core review and the extraction record
```

## Which page answers what

- **"Which file does X?"** Start in [modules](modules/README.md): the area, then the sub-area, then the one-line description of each file.
- **"How do I do X cheaply?"** The [problems glossary](handbook/README.md#problems-glossary) has an entry per need. Each names the
  means, the formula it relies on, the operations it runs, its cost in time and memory, the alternative that was rejected, and the
  `path:line` where it lives.
- **"Why is it done this way?"** The chapter of the mechanism in the [handbook](handbook/README.md), then
  [what was tried](handbook/history/techniques.md) for the procedures that were dropped.
- **"Is this allowed here?"** [architecture](guide/architecture.md) for imports and layers, [style](guide/style.md) for how code
  is written, and [the hot-loop rules](handbook/standards/01-hot-loop-rules.md) before writing a loop that runs for every pixel.

## Checks

Tests are Axle programs, one suite per area; the commands are at the end of
[architecture](guide/architecture.md). `python tools/gen_module_docs.py --check` fails when the module pages no longer match the
file headers.
