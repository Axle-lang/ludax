# 3.11 The face cache: light kept in the world

[Handbook](../README.md) · previous: [3.10 Water](10-water.md) · next: [4.1 The job pool](../engine/01-job-pool.md)

## 1. Contract

`LumenFaceCache` and `LumenFaceBatch` (`src/render/pathlight/pathlight_facecache.axle`) keep the diffuse light of
the faces of the world from one picture to the next.

- **In**: for a face (a flat patch the caller names with an `i64` key) and an epoch, nine lights (a 3 by 3 lattice
  over the face) or one (a *flat* face).
- **Out**: `read(key, epoch, full, u, v)`: the light at the place `(u, v)` of the face, or "not kept".
- **Guarantees**
  1. The light read is a function of the face, the place on it and the epoch: not of the camera, the pixel, the
     frame or the thread.
  2. While the epoch stands, a picture computes no light, however the camera moves.
  3. A reader never sees a slot half written: the cache is read-only while a picture is drawn.
  4. A crowded cache forgets; it never answers with another face's light.

The caller decides what a face is (the key), when the light of the world has changed (the epoch) and how the nine
points are lit (its own shading). The engine stores, blends and publishes.

## 2. Why

The diffuse light of a point depends on the point, on how its surface faces and on the state of the light. It does
not depend on the eye. Shading it again for every picture, at places of the screen that slide over the world as the
camera turns, was both the largest cost of a frame after the ray walk and the cause of what was reported as
"shadow edges that turn to pixels when I move": the same shadow, sampled at other points every frame.

## 3. Mathematics

### 3.1 Nine points

The baked light ([3.9](09-baked-shadows.md)) is blended trilinearly between the centres of cells. Along a face of a
block, of side 1, its slope therefore changes at the middle of the face and nowhere else inside it. A lattice with
points at 0, 1/2 and 1 each way holds exactly the places where the slope changes:

```
point (i, j) at (i / 2, j / 2)          i, j in 0..2
read(u, v):  q = (2u, 2v);  cell (floor q) of the four quarters;  bilinear inside it
```

The read is continuous over the face and equal to the stored light at the nine points; a light linear over the
face, or with a kink at its middle, is given back exactly (both are checks). The outer points are lit 2 % inside
the face so that a point on an edge against a wall is not inside the wall.

### 3.2 Flat faces

A block that covers fewer than 8 pixels (`t * pixel * 8 >= 1`) cannot show the shape of the light on its face: it is
lit once, where it was first seen, and kept as one light. A flat entry does not answer a request for a lattice, so
a face the camera walks up to is lit again in full.

### 3.3 Epochs, and a light that drifts

An entry is good for one epoch. Two kinds of change:

| Change | What the caller does | Cost |
|---|---|---|
| A block, a chunk, the time of day set | raises the base epoch | every face asked for is lit again |
| The sun's travel, a batch of baked shadows, the clouds' shade | raises a *phase* | one face in 16 is lit again a step |

`faceStagger(key, base, phase, 16)` is the epoch of a face: `base * 2^32 + ((phase + turn(key)) / 16)`, 64 bits wide
so that a game left running never comes back to an epoch it has used (at 32 bits it would have, after a few minutes
of a picture at rest), where
`turn(key)` is 4 bits mixed from the key. Each face changes epoch once in 16 steps and each step changes one face in
16 (checked on 4000 keys: between 125 and 500 a step, 250 expected). A light that moves a little all the time is
followed a few faces at a time; lighting all of them in one frame was a slow frame every time it happened (p99 of a
walk under a running clock: 55 to 83 ms, against 35 to 46 staggered).

Two neighbouring faces may be a quarter of a second of sun apart: a hundredth of a degree.

## 4. Algorithm

```
pixel on a plain face, key k, place (u, v), epoch e = faceStagger(k, base, phase, 16):
    cache.read(k, e)            -> light                       shared, read-only
    else batch.read(k, e)       -> light                       this chunk's own
    else light the face (9 points, or 1), batch.begin / set    and read it back

between two stages, one thread:
    for each chunk: cache.publish(batch)
```

Both are direct-mapped tables: one face a slot, the newer face wins. A batch lists the slots it has written since it
was last published, so publishing copies only what is new.

## 5. In blockland

| Piece | Where |
|---|---|
| The key | `McPixelWorker.faceKey`: the cell and one of six faces |
| Which surfaces | `cacheable`: rough, not a metal, in the final view; mirrors, metals, lamps and water are shaded as before |
| The nine points | `pointLight`: the baked terms and the sky at the point, over a white albedo, seen along the normal |
| What is still the view's | the air: what it lets through and what it adds (`fogKeep`, `fogAdd`), stored in the sparse samples and shared between pixels of one plane within a block ([3.4](04-sparse-light.md)) |
| The epoch | `McSession.pass`: `lightEpoch` on a block, a chunk, the time of day; `lightPhase` while the clock, the bake or the clouds move |
| Publishing | after the samples and after the fill |

A pixel's radiance is `albedo * face light * keep + add`.

Two things changed in the look, on purpose: the light is seen along the normal, so the faint sheen of the ground at
a grazing angle is gone; and the specular part is multiplied by the texel's albedo.

### 5.1 A picture at rest

Nothing a pixel sees changes while the camera rests; only the light does. The stage `Relight` therefore traces
nothing: for every pixel whose history is a plain surface it finds the face again from the plane and the place the
last sample met (the plane gives the face's side and one coordinate of its cell, the place the other two), reads its
light and puts the air of the view before it:

```
hdr = albedo_accumulated * face light(u, v) * keep(z) + add(d, z)
```

Each relight moves the faces' turns on by 4 of the 16 steps; the whole picture is drawn again once in 24 relights,
for the sky, the mirrors and the edges (an edge keeps the blend it settled to). Cost: `P` reads, 1.7 ms a frame on
average, against a full frame 8 times a second before (80 % of the pool with the clock running).

## 6. Complexity

| | Time | Memory |
|---|---|---|
| Read | one slot, 12 floats, a bilinear blend | — |
| Miss | 9 shadings (or 1), once a face an epoch | — |
| Publish | the new entries of 360 batches, serial | — |
| Cache | — | 131 072 faces x 124 bytes = 16.3 MB |
| Batches | — | 360 chunks x 256 faces x 124 bytes = 11.4 MB |

Measured on 12 workers, 1280 x 720, head turning (machine also running the game):

| View | Before | After |
|---|---|---|
| Ground, clock stopped | 32 ms | 24 ms |
| Horizon | 30 ms | 29 ms |
| Sky under trees | 22 to 23 ms | 23 ms |
| Trees at 16:00, clock stopped | 38 ms | 24 ms |
| Walking under a running clock, median / p99 | 31 to 58 / 41 to 98 ms | 25 to 29 / 35 to 46 ms |

Two consecutive frames of a slow turn, bytes more than 8 levels apart: 9.6 % to 8.8 % near the ground, 7.8 % to
7.2 % from the sky.

## 7. Tests

`tests/src/render_facecache.axle`, 28 checks: the lattice (exactness, continuity, the border), epochs and keys, flat
against full, publishing (found in the batch at once, in the cache after; a face two chunks computed; a batch lists
a face once), a crowded cache, the turns of `faceStagger`.

## 8. Open

- lumen (`examples/rendering/lumen`) does not use the cache yet.
- The memory of the batches (11 MB) follows the number of chunks, not of threads.
- No test in the game compares a picture drawn with a warm cache and with a cold one.

## 9. Source

`src/render/pathlight/pathlight_facecache.axle`; `games/blockland/src/app/mc_worker.axle` (`faceShare`,
`pointLight`, `facePlace`, `cacheable`, `fogKeep`, `fogAdd`), `mc_frame.axle` (`trace`, `fill`, `publishFaces`),
`mc_session.axle` (`pass`).
