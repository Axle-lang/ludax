# `src/openworld`

Layer 7. Content modules; independent of each other.

14 files in 1 sub-area. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: core, world, runtime](../handbook/problems/core-world-runtime.md).

## `src/openworld`

Content for open worlds: cell partition and streaming, terrain, the sky clock and weather, an arcade vehicle model, and missions (text form, board, book, checks, saves).

| File | What it does |
|---|---|
| `mission_board.axle` | the play state of missions: a state machine per mission fed by a queue of events. |
| `mission_book.axle` | the definitions of missions: what they ask, in which order, and what they pay. |
| `mission_check.axle` | the list of problems a mission book's validation found. |
| `mission_raw.axle` | the plain numbers of play state that the save format reads and writes. |
| `mission_save.axle` | the play state of missions as bytes, and back. |
| `mission_text.axle` | missions written as text, read into a `MissionBook`. |
| `partition.axle` | the world cut into square cells, each with a list of things that live in it. |
| `sky_clock.axle` | the time of day, as a sun that moves and the numbers a sky needs. |
| `streamer.axle` | keeps the cells around the player alive as entities, and only those. |
| `terrain.axle` | the one question the open world asks of the ground: how high is it here? |
| `vehicle_model.axle` | an arcade car as a pure function: (parameters, state, input, ground) -> next state. |
| `vehicle_params.axle` | what a car is made of, as numbers. |
| `vehicle_state.axle` | a car at one instant, and what the driver asks of it. |
| `weather.axle` | a small weather machine: spells of one kind of weather, melting into the next. |
