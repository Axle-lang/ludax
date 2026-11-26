# `src/runtime`

Layer 6. Main loop, game modules, settings.

10 files in 1 sub-area. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: core, world, runtime](../handbook/problems/core-world-runtime.md).

## `src/runtime`

The main loop and what drives it: the game loop and modules, the scheduler, typed settings with a text format, input snapshots, tapes and action maps.

| File | What it does |
|---|---|
| `action_map.axle` | what the player means, not which key they pressed. |
| `fan_out.axle` | a parallel-for over a component store, on the job pool. |
| `game_loop.axle` | the main loop, with the clock supplied from outside. |
| `game_module.axle` | the seam between the main loop and a game. |
| `input_state.axle` | one frame of input as plain data. |
| `input_tape.axle` | a recording of input snapshots, to play back later. |
| `scheduler.axle` | named systems, the order between them, and what each costs. |
| `settings.axle` | typed settings with defaults, ranges and a change counter. |
| `settings_text.axle` | the settings file format and the command line. |
| `text.axle` | the small text tools the runtime's file formats share: lines, words, numbers and error reports. |
