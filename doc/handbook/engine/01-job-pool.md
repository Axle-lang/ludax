# 4.1 The job pool

[Handbook](../README.md) · previous: [3.8 Display](../render/08-display.md) · next: [5.1 Optimisation log](../history/2026-11-optimisation.md)

## 1. Contract

`JobPool` (`src/core/jobs/pool.axle`) runs one `RangeKernel` over a range of items on a fixed set of threads.

- `run(count, grain)`: cuts `[0, count)` into chunks of `grain` items, has the workers call
  `kernel.runRange(begin, end)` once for each, and returns when all are done.
- **Guarantee**: what a chunk covers depends on `count` and `grain` alone. A kernel that writes only at the indices
  it was handed gives the same bytes on 1 worker or 24 (`src/core/jobs/kernel.axle`).
- **Not guaranteed**: which worker runs which chunk, or in what order.

## 2. Algorithm

```
run(count, grain):
    cursor <- 0;  total <- count;  this.grain <- grain
    send GO to min(workers, chunks) workers            one channel message each
    wait for as many reports

worker:
    wait for a message
    loop:  c <- cursor.incrementAndGet() - 1           an atomic add: 6 ns
           if c >= chunks: break
           kernel.runRange(c * grain, min(count, (c + 1) * grain))
    report
```

One message a worker a loop (about 5 microseconds), one atomic add a chunk. A chunk that is slow does not hold up the
others: workers take the next free chunk, so the load balances itself.

## 3. Measurements

### 3.1 The pool by itself

2000 empty loops of 180 chunks on 23 workers: 35 microseconds a loop. Idle for 4 s: **0.00 s** of processor time.
The workers sleep on their channel; an old comment that said they "burn half a core a thread" was wrong.

### 3.2 Scaling (Ryzen 9 9900X: 12 cores, 24 hardware threads)

| Workers | Pure arithmetic (`sqrt` chain, 720 rows, grain 2) | Speedup | Frame trace + fill, ground view | Speedup |
|---|---|---|---|---|
| 1 | 87.9 ms | 1 | 132 ms | 1 |
| 4 | 26.4 ms | 3.3 | 46.8 ms | 2.8 |
| 8 | 13.8 ms | 6.4 | 26.3 ms | 5.0 |
| 12 | 9.5 ms | 9.2 | 23.2 ms | 5.7 |
| 23 | 5.7 ms | 15.3 | 20.5 ms | 6.4 |

(Measured 2026-11-10, before the later tracer work; the shape is what matters.)

- Arithmetic scales to 15 x: the pool is not the limit.
- The frame scales to 5.7 x on 12 workers and gains **12 % from the next 11**. The second hardware thread of each
  core shares its caches and its execution units; for a ray walk, which is loads and branches, it adds little.

### 3.3 The decision

`McOptions.workerCount()` gives **one worker a core**, taken as half the hardware threads. On this machine 12
instead of 23.

| | 23 workers | 12 workers |
|---|---|---|
| Frame, ground view | 40 ms (with another process running) / 33 ms | 34 ms |
| Processor time a frame | about twice | 1 |
| Light-flood scratch | 41 MB | 22 MB |

`--threads N` overrides it. On a machine without simultaneous multithreading the rule halves the workers for no
reason; that case should read the core count from the system when the standard library offers it.

## 4. What was ruled out as the limit

| Suspect | Test | Verdict |
|---|---|---|
| The workers spin while idle | processor time of an idle pool | no: 0.00 s |
| Reference counts shared by all threads | the IR of the hot functions | no atomic in them (but see §5) |
| False sharing between worker objects | 128 bytes of padding in `McPixelWorker` and `McTracer` | no change |
| Allocation in the hot path | calls to `malloc` in the IR of the frame's functions | none |
| Dispatch cost | 35 microseconds a loop against 20 ms of work | no |

What is left is the machine: 12 cores, a shared last-level cache, and a workload of dependent loads. The trace reads
about 20 MB of section caches and baked light scattered over memory.

## 5. A hazard: reference counts and trait-typed kernels

A kernel is handed to the pool as the trait `RangeKernel`. Axle 0.20 decides whether a `Shared<T>` needs an atomic
count from the types that cross a thread launch, and it does not look inside the classes that implement a trait. So
every `Shared` reached only through a kernel was counted **without atomics** while the pool's threads used it:
counts were lost and objects freed while in use (`shared refcount: strong count underflow`, or a segfault).

- Finding F10 in `AXLE_COMPILER_FINDINGS.md`; entry §533 of the Axle ledger; repro in
  `tools/axle_repro/shared_trait_race`.
- Workaround for the game: `games/blockland/src/app/mc_env.axle`, last function.
- Check: `axle build -O 3 --emit llvm -o out.ll && grep -c "rc.dec.* = add i32" out.ll` must print 0.
- Every other user of `JobPool` whose kernel holds a `Shared` is exposed until the compiler is fixed.

## 6. Rules for a kernel

1. Write only to the items of your range (or to the chunk's own slot, `begin / grain`).
2. Read only what no chunk of the same loop writes.
3. Keep per-chunk scratch in an object indexed by the chunk, never by the thread.
4. Choose the grain so a chunk is a few hundred microseconds: 2 rows of a 1280-wide picture. Smaller wastes atomics,
   larger leaves workers idle at the end of the loop.
5. Do not throw.

## 7. Source

`src/core/jobs/pool.axle`, `src/core/jobs/kernel.axle`; `games/blockland/src/app/mc_options.axle` (`workerCount`),
`mc_frame.axle` (`runRange`, `MCF_TRACE_GRAIN`).
