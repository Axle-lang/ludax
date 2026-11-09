# chimes

A six-second 3D sound scene made entirely in code with Ludax's audio engine, rendered offline and checked.

```sh
cd examples/engine/chimes
axle build -O 3
./target/chimes        # writes chimes.wav and chimes.png next to where you run it
```

## What it is, and is not

This is the **software audio engine** (`src/sim/audio`) and the **WAV codec** (`src/data/audio`), exercised without
any sound hardware. The engine fills buffers; it does not open an audio device, and nothing here plays out of your
speakers. Getting samples to a device is a separate concern: the smalt mixer (see the `bastion` example) does that,
and a future bridge would call `AudioEngine::render` from the device callback. Until then you listen by opening
`chimes.wav` in any player.

## The scene

All sounds are made by the synth (`Synth`, `SynthWave`, `SynthAdsr`, `SynthReverb`), so there are no audio files.

| Time | Event |
|---|---|
| 0 s | music pad A (a C major chord, 4 s clip) loops in with a 0.5 s fade |
| 0 s - 6 s | a 1 kHz siren flies along a line 5 m in front of the listener at 40 m/s, from 120 m left to 120 m right (Doppler, panning, distance attenuation, distance low-pass) |
| 0.5 s - 3.4 s | six single bells, in a room of reverb |
| 3 s | the music crossfades to pad B over 1 s (equal-power curves) |
| 4.5 s | eight bells at once into a pool of six voices: the least important are stolen |

The script (`src/scene/scene.axle`) advances the engine in 256-frame chunks and moves the siren between chunks.
Time is the frame count; no clock is read.

## What it checks

The program prints each check and exits with the number that failed:

- the peak of the render is below 1 (the master soft limiter);
- two full renders are bit-identical (hash of the float WAV bytes);
- voices were stolen and the pool never exceeded its size;
- the old music pad ended and the new one is still looping after the crossfade;
- **Doppler**, measured on a separate dry render of the siren alone: the zero crossings of the rendered signal in
  an approaching window (0.4 - 1.0 s) and a receding one (5.0 - 5.6 s) agree with what the physics predicts for the
  siren's actual path (summed frame by frame in `src/check/measure.axle`) within 2 %. A typical run measures
  1131.7 Hz approaching and 895.8 Hz receding for a 1000 Hz source (predicted 1131.8 and 895.7);
- `chimes.wav` (32-bit float stereo) is written, read back and decodes to exactly the rendered samples;
- `chimes.png` is written: left channel on top, right below, the crossfade tinted, the siren's closest pass (yellow)
  and the bell burst (red) marked. The picture is saved with the library's PNG encoder (`DataFiles::savePng`).

## Limits

- The engine mixes in 128-frame blocks; gains are ramped inside a block but spatial parameters are updated once per
  block, so a very fast emitter is stepped, not smooth.
- Doppler pitch is changed by resampling the voice, so it is exact in frequency but not corrected for the delay of
  sound travel (the signal is not time-shifted).
- "Streaming" music here means a long decoded clip with loop points held in memory, not decoding from disk.
- One listener, mono emitters (a stereo clip on a 3D emitter is mixed to mono), no occlusion or reverb zones.
