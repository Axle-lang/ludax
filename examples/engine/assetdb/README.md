# assetdb

The data layer end to end, with no window and no files on disk: a virtual file system built from a shipped archive
and a memory patch, an asset database that loads a level and everything it depends on, a glTF triangle, a
Blockbench crate, a JSON configuration and a PNG, and a hot reload that moves a version number only for what
changed.

```sh
cd examples/engine/assetdb
axle build -O 3
./target/assetdb.exe        # prints each check; the exit status is the number that failed
```

## What it does

1. **Layers.** `config/game.json`, a PNG and the crate are packed into an `LDXA` archive (`VfsArchive`) and mounted
   first. The scene, the triangle (`models/tri.gltf` and its separate `models/tri.bin`) and a second copy of the
   configuration go into a memory mount laid over it. The later mount wins: the configuration read is the patch's.
2. **Loading.** The level is registered with the assets it needs (`dependsOn`); `loadWithDependencies` loads the
   binary before the glTF that reads it, and the glTF, crate, picture and configuration before the level. Every
   value is then checked against what the content was built from (vertex and triangle counts, material, the
   16 x 16 texture decoded from the crate's embedded base64 PNG, pixels of the checker, JSON fields).
3. **Failures that must stay failures.** A model whose buffer file is missing, a path above the root, a file that
   is not there, and a dependency cycle are each refused with a message and leave the database usable.
4. **Reload.** Two files are edited in the memory mount and reloaded with `reload`: their versions go to 2, the
   picture nobody touched stays at 1, writing the same bytes again changes nothing, and a broken edit is refused
   while the last good value stays. Nothing watches the disk or reads a clock; the program decides when to look.

## What it does not do

- It never touches the real disk (a disk mount exists, `Vfs::addDisk`, and the tests exercise it, but a disk mount
  cannot list a directory because the standard library has no call for that).
- It shows no picture. Meshes, textures and animations are only counted and compared; drawing them is the render
  layer's job.
- Only the importers' supported parts are used: see the header of `src/data/model/gltf_import.axle` for what glTF
  features are and are not read (no sparse accessors, morph targets or JPEG pictures).

## Files

| File | Holds |
|---|---|
| `src/main.axle` | the run: mounting, loading, summary, checks, reload |
| `src/content/files.axle` | the content, made in code (glTF text, Blockbench text, JSON through `JsonDoc`, PNG bytes) |
| `src/report/report.axle` | the line-per-check printer and the failure count |
