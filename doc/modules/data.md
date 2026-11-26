# `src/data`

Layer 2. Virtual file system, asset database, importers (glTF, `.bbmodel`, images, audio), serialisation (NBT, name tables), codecs (LZ4, inflate/deflate), sector region files, zip archives, random-access files.

40 files in 10 sub-areas. Generated from the file headers by `tools/gen_module_docs.py`: edit the header, not this page.

Read more: [problems: data and voxel](../handbook/problems/data-voxel.md).

## `src/data`

Byte buffers, files, data slots and text helpers shared by the importers and codecs.

| File | What it does |
|---|---|
| `bytes.axle` | a growable run of bytes, and the checksums file formats put on them. |
| `files.axle` | whole files in and out of a `ByteBuf`, and images by path. |
| `slots.axle` | numbered storage for class values: loaded assets, the parts of a model. |
| `text.axle` | strings and UTF-8 bytes: the conversions the file formats need. |

## `src/data/archive`

Container formats read and written byte by byte: random-access files, sector-based region files and zip archives.

| File | What it does |
|---|---|
| `random_file.axle` | positional reads and writes of a file on disk, without loading it. |
| `region_file.axle` | sector-addressed files of many small records: a grid of chunk slots in fixed-size sectors. |
| `zip_reader.axle` | reads entries out of a zip archive (a jar, an asset pack) without loading it. |

## `src/data/assets`

The asset database: stable ids, typed kinds, dependencies and image assets.

| File | What it does |
|---|---|
| `asset_db.axle` | the asset database: every file a game uses, by logical path, with an id, a kind and a version. |
| `asset_kind.axle` | what an asset is, and the number that names it. |
| `image_assets.axle` | pictures by name, loaded once. |

## `src/data/audio`

Audio clips and the WAV codec.

| File | What it does |
|---|---|
| `clip.axle` | decoded audio: interleaved f32 frames at a sample rate. |
| `wav.axle` | the RIFF/WAVE codec: bytes to an `AudioClip` and back. |

## `src/data/codec`

The LZ4 block codec.

| File | What it does |
|---|---|
| `lz4.axle` | the LZ4 block stream (the framing of the lz4-java `LZ4BlockOutputStream`) and its block format. |

## `src/data/image`

Images and the formats under them: PNG, inflate (a plain one and a table-driven fast one) and deflate with its code tables.

| File | What it does |
|---|---|
| `deflate.axle` | compresses bytes into a zlib stream. |
| `deflate_tables.axle` | the length and distance code tables that RFC 1951 shares between both directions. |
| `image.axle` | a picture as 8-bit RGBA pixels. |
| `inflate.axle` | decompresses a zlib stream (RFC 1950 around RFC 1951 deflate). |
| `inflate_fast.axle` | a table-driven deflate decoder for streams that are many megabytes in total. |
| `png.axle` | reads and writes PNG files. |

## `src/data/json`

A JSON parser, writer and document model.

| File | What it does |
|---|---|
| `json_doc.axle` | a JSON document as an arena of nodes. |
| `json_parse.axle` | JSON text to a `JsonDoc`, strictly as RFC 8259 defines it. |
| `json_write.axle` | a `JsonDoc` value back to JSON text. |

## `src/data/model`

Model importers and data: glTF 2.0 and bbmodel, meshes, generated shapes, animation clips, and the base64 and IEEE bit helpers they need.

| File | What it does |
|---|---|
| `base64.axle` | RFC 4648 base64, and the `data:` URIs that carry it. |
| `bbmodel_import.axle` | Blockbench (`.bbmodel`) models to a `ModelAsset`. |
| `gltf_file.axle` | the container of a glTF 2.0 model: its JSON, its binary buffers, and typed reads of accessors. |
| `gltf_import.axle` | glTF 2.0 (`.gltf` and `.glb`) to a `ModelAsset`. |
| `gltf_scene.axle` | the node tree, skins and animations of a glTF file. |
| `ieee.axle` | IEEE 754 single-precision numbers to and from their 32 bits. |
| `mesh.axle` | triangle geometry as flat arrays, the form importers produce and renderers consume. |
| `mesh_shapes.axle` | meshes made in code: box, sphere and plane. |
| `model_anim.axle` | skins and animation clips as plain data, for the animation system of the sim layer to consume. |
| `model_asset.axle` | an imported model: meshes, materials, a node tree, skins, clips and textures. |

## `src/data/serial`

Binary serialisation: the NBT reader and writer, and the name table.

| File | What it does |
|---|---|
| `name_table.axle` | names to small integers, in flat arrays that many threads may read at once. |
| `nbt_reader.axle` | a pull parser for NBT, the binary tree format of Minecraft saves and many tools. |
| `nbt_writer.axle` | builds an NBT document into a byte buffer. |

## `src/data/vfs`

The virtual file system: path normalisation, disk, memory and archive mounts, and listings.

| File | What it does |
|---|---|
| `vfs.axle` | the virtual file system: layered mounts under one tree of logical paths. |
| `vfs_archive.axle` | a set of files by path, and the container format that stores it in one `ByteBuf`. |
| `vfs_listing.axle` | the names found in one directory of the virtual file system. |
| `vfs_mount.axle` | one source of files in the virtual file system. |
| `vfs_path.axle` | logical paths of the virtual file system. |
