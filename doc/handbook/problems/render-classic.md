# Problems of the classic renderer (`src/render/{cmd,cpu,graph,light,scene,texture}`)

A glossary of needs: "I want X" -> the mathematical or algorithmic means the code uses, and what it costs. Every formula,
constant and complexity below was read in the file named in **Where**; a claim that could not be checked in the files read is
marked `UNVERIFIED`. Complexities that are derived by counting loops in the code (not measured) say "derived". Line numbers are
those of the working tree when this file was written. Paths are relative to `src/render/` unless they start with `doc/`.

## Zone and existing prose

Files read (lines): `cmd/` cmd_codec 193, cmd_costs 123, cmd_stream 289; `cpu/` cpu_bvh 387, cpu_explain 136, cpu_kernel 379,
cpu_renderer 450, cpu_shadow 132, cpu_surface 431, cpu_tris 720; `graph/` graph_graph 345, graph_plan 543, graph_record 121,
graph_report 153, graph_types 196; `light/` light_brdf 170, light_color 102, light_dfg 207, light_explain 98, light_irradiance 293,
light_material 120, light_math 165, light_quadrature 87, light_sh 223, light_shade 237, light_sky 449, light_source 196,
light_units 119, light_vndf 71; `scene/` scene_assets 114, scene_camera 192, scene_extract 240, scene_frame 184, scene_light 153,
scene_material 92, scene_mesh 170, scene_shapes 267; `texture/` texture 276. Not read (called from the zone): `core/math`
(Mat3/Mat4, Frustum, Aabb, DQuat, trig `sin`/`cos`/`sqrt`), `data/bytes` (`Crc32`, `ByteBuf`), `core/jobs`, `core/profile`,
`data/image`.

Existing prose: `doc/spec/rendering.md` (94 lines: data flow, command stream table, graph rules, backend contract, one paragraph on the
CPU backend), `doc/spec/lighting-math.md` (105 lines: formulas of sections 1-9), `doc/spec/lighting.md` (contract; section 9 is the
explainer), `doc/handbook/render/05-shading.md` (the split-sum table, BRDF and SH9 as used by the path-lit picture),
`06-sky.md` (the baked sky; quotes the cost of `light_sky.axle`), `08-display.md` (tone curve and sRGB as tables in the path-lit
display), `12-lux-layers.md:105` (one line on `GraphCompiler`). There is no handbook chapter for the CPU rasteriser, the BVH, the
render graph, the command codec, texturing or scene extraction: those entries say `MISSING` or point at the one RENDERING.md
paragraph.

Symbols: T triangles, I instances, n triangles in a BVH, W x H the picture, P = W*H pixels, S shaded pixels, L lights, np passes,
nr resources, E read/write declarations, B total (triangle, tile) overlaps.

---

## Command stream and its wire form

### R-01. I want a frame to be plain data that a CPU oracle and a GPU backend execute identically
- **Means:** a `CmdStream` of fixed-shape commands (opcode, 3 integer slots, 4 float slots) stored as three parallel flat arrays; ids only, no pointers; eight opcodes (BeginPass, EndPass, SetTarget, Clear, BindMaterial, DrawMesh, BuildAccel, Resolve). Equality and one-line text per command exist for diffs.
- **Mathematics:** none: plain arithmetic. Command `k` lives at `ops[k]`, `args[3k..3k+2]`, `vals[4k..4k+3]`.
- **Instructions:** push writes 8 scalars at computed offsets; growth doubles the three arrays and copies `used`, `3*used`, `4*used` elements; `equals` compares slot by slot (`sameAs`), floats with `!=`.
- **Cost:** push amortised O(1); growth copies at most 2n elements in total over n pushes (derived). Memory 4 + 12 + 16 = 32 B per command; initial room 64 commands. `equals`/`describe` O(n). No measured figure in the files read.
- **Why this and not another:** header: "rendering is data ... so a GPU backend and the CPU oracle execute the same commands" (design rule 6). Alternative (a command object per draw) is not discussed.
- **Where:** `cmd/cmd_stream.axle:1-19,62-65,84-88,101-135,247-288`.
- **Docs:** `doc/spec/rendering.md:33-50` (table of opcodes, same slot meanings).

### R-02. I want to save, send or replay a recorded frame as bytes and refuse a damaged file instead of half-building a stream
- **Means:** `CmdCodec::encode/decode`: magic "LXCS", version, count n, n records of 8 little-endian words, CRC-32 of everything before it. Decode checks, in order: length >= 16, magic, version, `n in [0, 1e8]` and `len == 12 + 32n + 4`, checksum, then every opcode; on any failure the target stream is left empty and a reason string is returned.
- **Mathematics:** CRC-32 over the first `len - 4` bytes (polynomial and table are in `data/bytes`, not read: `UNVERIFIED`). Size = 12 + 32 n + 4 bytes.
- **Instructions:** `pushLe32` per word; `encode` is a pure function of the stream, so equal streams give equal bytes; the exact-length test happens before the CRC so a bad count cannot size a buffer.
- **Cost:** O(n) time and 32 n + 16 bytes (the encoder reserves 4 spare bytes: `12 + 32n + 4 + 4`). No measured figure.
- **Why this and not another:** header: a frame "can be saved, diffed, sent to another process or replayed against a different backend". Alternatives (text, no checksum) not discussed.
- **Where:** `cmd/cmd_codec.axle:1-12,66-129`.
- **Docs:** `doc/spec/rendering.md:48-50` (layout, one sentence); the checks and the 1e8 cap are not written down outside the code.

### R-03. I want f32 values written to bytes and read back bit for bit without a float-to-bits cast
- **Means:** `floatBits` takes the number apart by repeated halving or doubling until the mantissa is in [1, 2); `bitsFloat` rebuilds it by repeated multiplication by 2 or 0.5. Exact for finite normal numbers and zero; -0 reads back as 0, denormals flush to 0, NaN becomes 0, infinity becomes the largest finite number.
- **Mathematics:** x = (-1)^s * 2^e * m, m in [1, 2); bits = s<<31 | (e + 127)<<23 | floor((m - 1) * 2^23). Inverse: v = (1 + mantissa * 2^-23) * 2^(exponent - 127). Scaling by 2 is exact in binary floating point, so the loops lose nothing.
- **Instructions:** two `while` loops of exact multiplications (no division); the exponent is bounded below by -126 so the loops end after at most about 127 steps.
- **Cost:** O(|e|) per float, up to about 127 multiplications; 4 floats per command (derived).
- **Why this and not another:** header: "Axle has no float-to-bits cast". Lost cases (-0, denormals) are justified as "no command has any reason to hold one".
- **Where:** `cmd/cmd_codec.axle:9-12,44-61,132-192`.
- **Docs:** `doc/spec/rendering.md:49-50` (the -0 caveat only).

### R-04. I want per-pass counts that reproduce exactly, with the (non-reproducible) time kept apart
- **Means:** `PassCosts`: slot arrays indexed by pass id (draw calls, triangles submitted, triangles rasterised, pixels shaded; nanoseconds and call count copied from the `Profiler` by `absorbProfile`). Counts are part of the render's identity; time is reported separately.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** guarded increments (`has(pass)`); `absorbProfile` copies profiler entry k into slot k.
- **Cost:** per pass 8 + 4 + 4 + 8 + 8 + 8 = 40 B (derived from the field types); O(passes) to reset or absorb.
- **Why this and not another:** header: "Design rule 8: per-pass cost is observable ... Those counts are deterministic ... Time is not".
- **Where:** `cmd/cmd_costs.axle:1-8,14-123`.
- **Docs:** `doc/spec/rendering.md:62-63,77`; `doc/spec/lighting.md` section 9 for the rule.

---

## Triangle setup: transform, clip, snap, bin (`cpu/cpu_tris.axle`)

### R-05. I want mesh triangles turned into screen triangles, every instance with its own matrix
- **Means:** for each instance in the draw range and each mesh triangle: positions by the model matrix, normals by the 3x3 normal matrix `upper3x3().normalMatrix()` (formula in `core/math/mat3`, not read: `UNVERIFIED` that it is the inverse transpose), clip = viewProjection * (p, 1). A triangle with zero face normal is skipped. Face normal = (b - a) x (c - a), stored normalised and not flipped for back faces.
- **Mathematics:** none: plain arithmetic (matrix-vector products).
- **Instructions:** per source triangle 3 vertex loads into a 12-float work record (clip xyzw, position, normal, uv); `normalizedOr` fallback (0,1,0) for a zero normal; the per-instance normal matrix is computed once per instance, not per triangle.
- **Cost:** O(I * T_mesh) transforms; every submitted triangle is counted in `submitted`. Memory per stored triangle: snap 6 x i32 + zinv 6 x f32 + attr 24 x f32 + geo 3 x f32 + meta 5 x i32 = 24 + 24 + 96 + 12 + 20 = 176 B (derived from `CTRI_*`); arrays start at 256 triangles and double, copying the stored part.
- **Why this and not another:** not documented (header gives the pipeline, not alternatives).
- **Where:** `cpu/cpu_tris.axle:80-105,351-430`.
- **Docs:** `doc/spec/rendering.md:83-88` (one paragraph); MISSING for the record layout.

### R-06. I want triangles that cross the near plane, or reach far outside the screen, drawn correctly
- **Means:** Sutherland-Hodgman clipping of the clip-space polygon against five planes: near (z >= 0) and the four sides of a guard band 4 screen sizes wide. A triangle wholly inside all five planes takes a fast path with no copying. Survivors (a polygon of up to ten slots) are emitted as a triangle fan.
- **Mathematics:** inside distance for plane p: near `z`, left `4w + x`, right `4w - x`, bottom `4w + y`, top `4w - y`; a vertex is inside when >= 0. For an edge from i to j that crosses, t = d_i / (d_i - d_j) and every one of the 12 floats of the vertex (clip, position, normal, uv) is lerped: v = v_i + (v_j - v_i) t. Linear interpolation of the attributes in clip space is exact because they are later interpolated perspective-correctly (header).
- **Instructions:** `workInside` tests 3 vertices x 5 planes with 15 comparisons and no stores; the slow path ping-pongs between two preallocated buffers (10 vertices x 12 floats); fewer than 3 vertices after any plane aborts.
- **Cost:** fast path 15 comparisons; slow path O(5 * n_vertices * 12) floats per triangle (derived). No far-plane clip: depth outside 0..1 is rejected per pixel (R-13). The reason for a 4x guard band (rather than clipping to the screen) is not stated; the snapped coordinates are stored as `i32`, so some bound is needed (`UNVERIFIED` inference).
- **Why this and not another:** not documented beyond the header ("exact for attributes that are later interpolated perspective-correctly").
- **Where:** `cpu/cpu_tris.axle:62-75,433-534`.
- **Docs:** `doc/spec/rendering.md:83` (one sentence).

### R-07. I want coverage decided in exact integer arithmetic, so two triangles sharing an edge agree about every pixel
- **Means:** after the divide by w, vertices are snapped to a grid of 1/256 pixel; from there all coverage maths is integer (R-12).
- **Mathematics:** s = floor( ((x_clip / w) * 0.5 + 0.5) * W * 256 + 0.5 ), same with y and H, i.e. rounding to the nearest 1/256 pixel. The reciprocal 1/w is kept for perspective-correct interpolation (R-18); depth z/w is kept per vertex.
- **Instructions:** one reciprocal per vertex reused for x, y, z and the stored 1/w; `floorI` is a truncating cast with a correction (no libm floor); a vertex with w <= 1e-6 aborts the triangle.
- **Cost:** O(1) per emitted triangle; a pixel centre is at 128 on the snapped grid.
- **Why this and not another:** header: "coverage is exact, two triangles sharing an edge agree on which side of it every pixel centre is, and the top-left rule leaves no pixel covered twice or not at all".
- **Where:** `cpu/cpu_tris.axle:35-42,74-78,560-585,650-656`.
- **Docs:** `doc/spec/rendering.md:83-86`.

### R-08. I want back faces dropped (or shaded as the back) using the same arithmetic that decides coverage
- **Means:** the sign of the snapped signed area is the facing test; stored triangles are put in canonical orientation (positive area) and a flag says which side they showed.
- **Mathematics:** 2A = (bx - ax)(cy - ay) - (by - ay)(cx - ax) in i64. With y down, a counter-clockwise (front) triangle has 2A < 0; 2A = 0 is dropped as degenerate; `back = 2A > 0`. A front triangle swaps its last two vertices on store so that 2A > 0 for every stored triangle.
- **Instructions:** one i64 cross product per emitted triangle; the cull is skipped when the material is double-sided or `cullBack` is off.
- **Cost:** O(1) per triangle.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_tris.axle:12-15,127-130,538-557,588-594,610-648`.
- **Docs:** `doc/spec/rendering.md:70` states the front-face convention only.

### R-09. I want triangles wholly off the picture rejected before they cost any memory
- **Means:** test the snapped bounding box against the target after rounding.
- **Mathematics:** reject when maxX < 0, maxY < 0, (minX >> 8) >= W or (minY >> 8) >= H (arithmetic shift = division by 256 for the pixel).
- **Instructions:** six `minI/maxI`, four comparisons.
- **Cost:** O(1) per triangle.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_tris.axle:597-606`.
- **Docs:** MISSING.

### R-10. I want every tile to see its triangles in submission order, without a comparison sort
- **Means:** a two-pass counting sort of (triangle, tile) pairs: count per tile, prefix-sum into `binStart`, then fill `binList` in triangle order. A triangle that touches several tiles appears in each tile's list.
- **Mathematics:** counting sort (stable by construction): `binStart[k+1]` = sum of counts up to k; the tile range of a triangle comes from its snapped bounding box shifted right by 8 and divided by 32, clamped to the target.
- **Instructions:** two passes over the triangles, each recomputing `tileRange`; a `fill[]` cursor array; `binList` is reallocated on every `bin()` (a fresh `new i32[total + 1]`).
- **Cost:** O(T + B) time with B the total number of overlaps; memory 4 (B + 1) bytes for the list + 4 (tiles + 1) for the starts + the temporary cursors. A long thin triangle overlaps many tiles (B grows with the bounding box, not the area): derived.
- **Why this and not another:** header: it "keeps that order inside every tile, which is what makes the picture independent of thread count".
- **Where:** `cpu/cpu_tris.axle:12-15,659-719`.
- **Docs:** `doc/spec/rendering.md:83-84`.

---

## Rasterisation and visibility (`cpu/cpu_kernel.axle`)

### R-11. I want the picture to be bit-identical whatever the number of worker threads
- **Means:** one tile (32 x 32 pixels) is one unit of parallel work; a tile reads and writes only its own pixels and its own slot of the shaded-pixel count, and sees its triangles in submission order. Counts are summed in tile index order afterwards.
- **Mathematics:** none: plain arithmetic. Determinism follows from the absence of shared writes and of any order that depends on a thread.
- **Instructions:** `renderTile` = clearTile, opaque raster, `shadeVisible`, blended raster; `runRange` loops tiles; the pool gets 1 tile per job (`CPUR_TILES_PER_JOB`); with `workers = 0` the tiles run on the calling thread in order (`runSerial`).
- **Cost:** parallel over ceil(W/32) * ceil(H/32) tiles. Serial parts per flush: `copyIn` and `copyOut` copy 3 + 1 floats per pixel each (16 B/pixel each way, derived), plus `bin`. Memory in the kernel per pixel: vis 4 B + cover 4 B + colour 12 B + depth 4 B = 24 B; each target resource adds colour 12 B, depth 4 B and an `Image` (storage format `UNVERIFIED`). No measured scaling in the files read.
- **Why this and not another:** header and `CpuSettings.workers` doc: "The picture does not depend on it".
- **Where:** `cpu/cpu_kernel.axle:1-13,37-38,63-107,154-158,214-224`; `cpu/cpu_renderer.axle:42-46,52-55,70-87,110-131,289-311`.
- **Docs:** `doc/spec/rendering.md:86-87`.

### R-12. I want exact coverage, with no pixel drawn twice or missed along a shared edge
- **Means:** integer edge functions evaluated at pixel centres and the top-left fill rule. Edge i is opposite vertex i; the inside is positive; a pixel centre exactly on an edge belongs to the triangle only when that edge is a top edge (horizontal, pointing right) or a left edge (pointing up).
- **Mathematics:** e0 = dx0 (py - by) - dy0 (px - bx) with (dx0, dy0) = c - b; likewise e1 on c to a and e2 on a to b; px = 256 x + 128, py = 256 y + 128. Inside iff for all i: e_i > 0 or (e_i = 0 and topLeft_i), with topLeft(dx, dy) = (dy = 0 and dx > 0) or dy < 0. The sum e0 + e1 + e2 = 2A (twice the area) is the invariant that makes the three values barycentric weights.
- **Instructions:** values initialised once per row, then stepped incrementally: e_i(x + 1) = e_i(x) - dy_i * 256, three i64 subtractions per pixel; iteration limited to the triangle's bounding box intersected with the tile; `i64` throughout because products of snapped coordinates exceed i32.
- **Cost:** O(bounding-box pixels inside the tile) per (triangle, tile), 3 edge tests per pixel; there is no skipping of empty spans inside the box (derived). The suite proves "every pixel of a mesh is covered exactly once" with `debugCover` (header); no timing is quoted.
- **Why this and not another:** header: "exact, no pixel twice, none missed along a shared edge". Float edge functions are not discussed.
- **Where:** `cpu/cpu_kernel.axle:1-17,259-336`.
- **Docs:** `doc/spec/rendering.md:84-85`.

### R-13. I want the depth of a covered pixel, a far-plane test, and a deterministic winner on ties
- **Means:** interpolate the per-vertex depth z/w (linear in screen space after the divide) with the edge values; keep a fragment when 0 <= depth <= 1 and depth < stored depth.
- **Mathematics:** depth = (e0 z0 + e1 z1 + e2 z2) / (e0 + e1 + e2), evaluated in f64 and narrowed to f32. Because z/w is affine on the screen plane, this barycentric combination is exact for it.
- **Instructions:** 3 f64 multiply-adds and one f64 division per covered pixel (the division is by the same `area` for the whole triangle and is not hoisted into a reciprocal); the rejection `depth >= stored` means the earlier triangle wins a tie.
- **Cost:** O(1) per covered pixel; there is no hierarchical depth rejection of a whole triangle against the tile (derived).
- **Why this and not another:** header: "Depth ties go to the earlier triangle". Far-plane clipping is replaced by the per-pixel range test.
- **Where:** `cpu/cpu_kernel.axle:290-362`.
- **Docs:** MISSING.

### R-14. I want each pixel shaded once, however many triangles overlapped it
- **Means:** visibility first, shading afterwards: pass 1 stores (depth, triangle id) per pixel for the opaque and masked triangles of the tile; pass 2 shades each pixel that has an id; pass 3 mixes the blended triangles.
- **Mathematics:** none: plain arithmetic. Shading cost is S <= P instead of overdraw * P.
- **Instructions:** `vis[]` reset to -1 per tile; the shading loop skips ids < 0; a `tileShaded` counter per tile.
- **Cost:** O(S * (L lights + shadow queries + texture reads)) for the shading (R-27, R-19, R-61); the visibility pass costs coverage only. Reported to `PassCosts.pixels`.
- **Why this and not another:** header: "so a covered pixel costs one shading however many triangles overlapped". Forward shading per fragment is the implicit alternative.
- **Where:** `cpu/cpu_kernel.axle:3-13,181-224`.
- **Docs:** `doc/spec/rendering.md:84-85`.

### R-15. I want cut-out materials (fences, leaves) whose holes are decided before the depth is written
- **Means:** in the visibility pass, a `Mask` material samples its alpha at the fragment and drops the pixel below the cutoff, before storing depth and id.
- **Mathematics:** none: plain arithmetic (alpha < cutoff => discard).
- **Instructions:** calls the full `CpuSurface::sample` for each fragment that passes the depth test, which evaluates all textures of the material, not only the alpha one (derived from `sample`/`applyTextures`).
- **Cost:** one surface sample per candidate fragment of a masked triangle; overdraw of masked geometry is therefore not free (derived).
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_kernel.axle:346-357`; `cpu/cpu_surface.axle:302-347`.
- **Docs:** `doc/spec/rendering.md:85`.

### R-16. I want translucent surfaces mixed over the opaque picture in a stable order
- **Means:** blended triangles are rasterised after the shading pass, in submission order (the extractor sorted the instances far to near); a fragment is depth-tested without writing depth, shaded and mixed; fully clear texels (alpha <= 0) cost nothing further.
- **Mathematics:** out = c * a + dst * (1 - a) per channel (straight alpha, "over"). Correct only if the order is far to near; the file makes no claim for intersecting triangles.
- **Instructions:** one `sampleOf` + one `radiance` per covered blended pixel; no early exit for `a` near 1.
- **Cost:** O(blended covered pixels * shading), counted as shaded pixels (derived).
- **Why this and not another:** not documented (order-independent transparency is not discussed).
- **Where:** `cpu/cpu_kernel.axle:9-11,365-378`; sort in `scene/scene_extract.axle:190-202`.
- **Docs:** `doc/spec/rendering.md:30-31,67-69`.

### R-17. I want to check the fill rule on a real mesh
- **Means:** `debugCover` counts, before the depth test, how many triangles cover each pixel.
- **Mathematics:** none: plain arithmetic (the property tested is cover == 1 for every pixel of a closed mesh).
- **Instructions:** one increment in `coverPixel`, off by default.
- **Cost:** one extra i32 read-modify-write per covered pixel when on.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_kernel.axle:15-17,342-344`; `cpu/cpu_renderer.axle:66-67,413-416`.
- **Docs:** MISSING (the suite is the only record).

---

## Surface evaluation and texturing (`cpu/cpu_surface.axle`, `texture/texture.axle`, `scene/scene_mesh.axle`)

### R-18. I want position, normal and uv interpolated perspective-correctly
- **Means:** barycentric weights from the same integer edge values, divided through by the stored 1/w and renormalised.
- **Mathematics:** with lambda_i = e_i / 2A and q_i = 1/w_i: weight_i = lambda_i q_i / sum_j (lambda_j q_j), attribute = sum_i weight_i a_i. If the sum is not positive each vertex counts a third.
- **Instructions:** evaluated in f64; the edge values are recomputed from the pixel centre (`edgesAt`), and the weights are also computed at the centres one pixel to the right and one below (edges stepped by -dy * 256 and + dx * 256) to obtain the uv footprint (R-19); no screen-space derivative hardware needed.
- **Cost:** 3 weight sets per surface sample (3 divisions each plus one for the sum); 8 floats per vertex interpolated (position 3, normal 3, uv 2): derived.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_surface.axle:160-217,302-347`.
- **Docs:** `doc/spec/rendering.md:83-86` (the fact, not the formula); MISSING.

### R-19. I want textures that neither shimmer when minified nor blur along a floor seen at a grazing angle
- **Means:** the pixel's footprint in uv comes from the weights at the pixel centre, one pixel right and one pixel down. The two footprint vectors measured in texels give a major and a minor axis; up to 8 trilinear taps are spread along the major axis, each with the major length divided by the tap count as its own footprint.
- **Mathematics:** l_x = sqrt( (du_x W_tex)^2 + (dv_x H_tex)^2 ), same for l_y; major = max, minor = min; taps = clamp( floor(major / minor + 0.999), 1, 8 ) (a ratio a hair over a whole number must not cost a tap); a minor axis below 1e-4 texels with a major axis above 1 texel gives the full 8 taps; tap offsets o_i = (i + 1/2)/taps - 1/2 times the major uv vector; per-tap footprint = major / taps. The mean of the taps is returned.
- **Instructions:** 2 square roots per fetch; the taps loop is the only variable-length loop of the surface code.
- **Cost:** up to 8 taps x 2 mip levels x 4 texels = 64 texel reads per texture per pixel, up to four textures per material (base colour, metal-roughness, emissive, normal): derived worst case 256. No measured figure.
- **Why this and not another:** comment: "so a floor at a grazing angle is sharp across and filtered along instead of blurred both ways". Plain trilinear is the `taps == 1` case.
- **Where:** `cpu/cpu_surface.axle:28-47,108-129,219-277`.
- **Docs:** MISSING (`doc/handbook/render/14-water-surface.md` section 3.6.2 treats a different mechanism).

### R-20. I want a bump look from a tangent-space normal map on meshes that carry no tangents
- **Means:** the tangent is derived per triangle from the vertex positions and uvs, orthogonalised against the interpolated normal; the map texel is unpacked and applied in that frame; the geometric normal stays the triangle's so a bumpy surface is still not lit from behind its face.
- **Mathematics:** det = du1 dv2 - du2 dv1 (skip when |det| < 1e-7); T = (e1 dv2 - e2 dv1) / det; T' = normalize(T - n (T.n)); B = n x T'; shading normal = normalize( t_x T' + t_y B + max(t_z, 0.05) n ), t = unpack * scale for x and y. Unpack: the texture was decoded as sRGB colour, so channel c is first re-encoded: t = srgbEncode(c) * 2 - 1.
- **Instructions:** one reciprocal, two cross products, two normalisations; `anyPerpendicular` fallback when T' degenerates.
- **Cost:** O(1) per pixel on top of the tap loop of R-19.
- **Why this and not another:** the 0.05 floor: "so the shading normal never turns to the back of its own surface". The re-encode is a workaround for `Texture` always decoding sRGB (see Doubts).
- **Where:** `cpu/cpu_surface.axle:43-47,375-421`.
- **Docs:** `doc/spec/rendering.md:73-75` (convention "tangent space with green up" only).

### R-21. I want a double-sided surface lit correctly from behind, and a view vector right for both camera kinds
- **Means:** a stored triangle carries a back flag; both normals are negated for it; the view vector is the normalised negated position for a perspective camera and the constant -forward for an orthographic one.
- **Mathematics:** v = normalize(-p) (position camera-relative, eye at the origin) or v = -forward.
- **Instructions:** `normalizedOr(geo)` fallback; no division by zero.
- **Cost:** O(1).
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_surface.axle:70-77,279-296`.
- **Docs:** MISSING.

### R-22. I want colour textures filtered in linear light, with a complete mip chain
- **Means:** `Texture` converts the sRGB bytes once through a 256-entry table to linear f32 RGBA and builds each level from the previous one by averaging up to 2 x 2 texels; the chain ends at the first 1 x 1 level (at most 32 levels).
- **Mathematics:** level l+1 has size max(1, n/2) per axis (integer division); a texel is the mean of the four texels at (2x..2x+1, 2y..2y+1), the edge texel repeated past the end. Averaging encoded values would make each level darker than the picture (header).
- **Instructions:** `lut[256]` of `lightSrgbDecode8`; one pass per level.
- **Cost:** build O(texels); memory 16 B per texel (4 x f32) times the sum of the levels, about 16 * 4/3 = 21.3 B per base texel for a power-of-two square (derived). An empty image gives a 1 x 1 transparent texture.
- **Why this and not another:** header: "averaging encoded values makes every mip level darker than the picture it stands for".
- **Where:** `texture/texture.axle:1-8,17-31,51-131`.
- **Docs:** MISSING.

### R-23. I want a cut-out leaf not to bleed the colour of its transparent texels into the coarser levels
- **Means:** colour is averaged weighted by alpha; alpha is the plain mean; a block with total alpha under 1e-4 takes the plain colour mean.
- **Mathematics:** rgb = sum_i rgb_i a_i / sum_i a_i, a = sum_i a_i / n (n = 4); plain mean when sum a_i <= 1e-4.
- **Instructions:** two accumulators per channel (weighted and plain), one guarded divide.
- **Cost:** O(1) per output texel (4 reads).
- **Why this and not another:** header: "so a cut-out leaf does not bleed the colour of its transparent texels".
- **Where:** `texture/texture.axle:5-8,135-166`.
- **Docs:** MISSING.

### R-24. I want to read a texture at a level that matches the pixel's footprint, wrapped or clamped
- **Means:** trilinear: pick level = log2(footprint) when the footprint (texels covered by one screen pixel) exceeds 1, bilinear-read the two surrounding levels and blend; wrap mode `Repeat` or `Clamp`.
- **Mathematics:** level = min(log2 f, levels - 1); lo = floor(level); frac = level - lo; bilinear at level l: x = u W_l - 1/2, x0 = floor x, weights (1 - fx, fx) and (1 - fy, fy) over the four texels; a blend fraction <= 1e-4 returns the finer level alone. Repeat index ((i mod n) + n) mod n.
- **Instructions:** `lightLog2` (an f64 series, R-49) per read; 8 texel reads for two levels.
- **Cost:** 8 texel reads and one `lightLog2` per tap (R-19 multiplies this by the tap count).
- **Why this and not another:** not documented.
- **Where:** `texture/texture.axle:188-258`.
- **Docs:** MISSING.

### R-25. I want procedural meshes (box, plane, sphere, cylinder) with exact normals and the same bytes on every machine
- **Means:** builders that emit indexed triangles counter-clockwise from outside, hard-edged shapes with unshared vertices, round shapes sharing along the seam; angles from the deterministic `sin`/`cos`.
- **Mathematics:** sphere vertex (sin t cos p, cos t, sin t sin p) * radius with t = pi i / rings, p = 2 pi j / segments; uv = (j/s, i/r). Counts: box 24 vertices, 12 triangles; plane (cx+1)(cz+1) vertices, 2 cx cz triangles; sphere (s+1)(r+1) vertices, 2 s (r-1) triangles (pole triangles omitted); cylinder 2(s+1) + 2(s+2) vertices, 4 s triangles.
- **Instructions:** `MeshData` holds flat arrays (3 + 3 + 2 f32 per vertex, 3 i32 per triangle) so the bytes can be uploaded unchanged; `finish()` computes the AABB.
- **Cost:** O(vertices + triangles); 32 B per vertex + 12 B per triangle (derived).
- **Why this and not another:** header: arrays "so the same bytes can be uploaded unchanged later".
- **Where:** `scene/scene_mesh.axle:1-47,80-86`; `scene/scene_shapes.axle:1-7,46-203`.
- **Docs:** MISSING.

### R-26. I want a glTF metallic-roughness material with per-pixel texture modulation and an alpha mode
- **Means:** `RenderMaterial` = constants + texture ids (-1 for none) + doubleSided; `toLight` hands the constant part to the lighting library; textures are applied per pixel by the backend: base colour (x), roughness from green (x), metallic from blue (x), emissive (x), alpha from the base texture's alpha.
- **Mathematics:** none: plain arithmetic (products of constants and texels, roughness and metallic saturated).
- **Instructions:** one `toLight` copy per sample; occlusion and diffuse model are not copied (they keep the `LightMaterial` defaults).
- **Cost:** O(1) plus the fetches of R-19.
- **Why this and not another:** header: "Colours are linear. `toLight` hands the constant part to the lighting library".
- **Where:** `scene/scene_material.axle:1-6,76-91`; `cpu/cpu_surface.axle:349-381`.
- **Docs:** `doc/spec/lighting.md` section 3.

---

## Shadow rays and the BVH (`cpu/cpu_shadow.axle`, `cpu/cpu_bvh.axle`)

### R-27. I want a hard shadow from any light, found by a ray, with no self-shadowing acne and no cost for lights that cannot reach the point
- **Means:** per light with `shadowMode == Ray`, one ray from the surface point (lifted along the geometric normal) to the light's centre (point, spot) or to infinity against the light's travel direction (directional); visibility 1 or 0. Lights outside their range or wholly behind the surface are skipped without a ray.
- **Mathematics:** bias = 0.002 + 0.00002 |p| (camera-relative units; f32 positions lose precision with distance); origin = p + bias n_geo; ray length = dist - bias (point) or 1e9 (directional); skipped when ray.dir . n_geo < -0.05 (a margin that keeps grazing points lit); a hit is any triangle intersection at 1e-5 < t < length.
- **Instructions:** one `occluded` query per Ray light per shaded pixel; blocker distance via `nearest` only for the explainer.
- **Cost:** per shaded pixel and Ray light: one BVH query, O(log n) expected for a balanced tree and O(n) worst (derived, no measurement in the files read).
- **Why this and not another:** header: "One ray means a hard shadow edge whatever the light's radius: the soft penumbra of a sized light is future work".
- **Where:** `cpu/cpu_shadow.axle:1-34,62-131`.
- **Docs:** `doc/spec/rendering.md:75-76,92`; `doc/spec/lighting-math.md:74-81` (planned penumbra maths, not implemented here).

### R-28. I want a triangle BVH built identically on every run, every frame
- **Means:** median split: at each node the triangles are ordered by the centroid coordinate along the axis of widest centroid spread (stable merge sort on a fixed-point key), cut in half, the children take two adjacent node slots; leaves hold at most 4; depth capped at 48.
- **Mathematics:** key = (centroid_axis * 1024) as i64 (centroids closer than 1/1024 unit tie and keep input order); a node with zero centroid extent stays a leaf. Nodes < 2n (arrays sized 2n + 2).
- **Instructions:** a leaf stores a corner and two edges (9 floats) ready for the intersection test; the right child is always left + 1, so a node stores one child index.
- **Cost:** time O(n log^2 n): a full sort of the node's range at every level, about log2(n/4) levels (derived). Memory: 36 B per triangle + up to (2n + 2) * (24 B box + 4 + 4) = 32 B per node slot; build scratch: order 4 B and centroids 12 B per triangle, plus keys 8 B and two index arrays during each sort. No measured build time in the files read.
- **Why this and not another:** header: "No random number, hash or thread takes part, so the same triangles always give the same tree". A surface-area-heuristic build is not discussed (not documented).
- **Where:** `cpu/cpu_bvh.axle:1-16,24-56,102-127,171-253`.
- **Docs:** `doc/spec/rendering.md:87` (one sentence "median-split BVH"); MISSING for the rest.

### R-29. I want a fast yes/no ray-box test
- **Means:** the slab test on a precomputed reciprocal direction.
- **Mathematics:** a_k = (lo_k - o_k) / d_k, b_k = (hi_k - o_k) / d_k for each axis; the ray interval [max_k min(a_k, b_k), min_k max(a_k, b_k)] intersected with [0, tmax]; hit iff t0 <= t1. A direction component below 1e-10 inverts to +-1e20 (a division by zero would trap in Axle).
- **Instructions:** reciprocal computed once per ray (`prepare`), 6 subtract-multiplies per box, min/max chains; the `BvhRay` struct (9 floats) is passed by value because "a struct of nine floats costs the same as nine scalars here" (header).
- **Cost:** 6 multiplications and a few min/max per node visited.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_bvh.axle:15-16,41-45,256-295`.
- **Docs:** MISSING.

### R-30. I want a robust ray-triangle test that accepts either side of a triangle
- **Means:** Moller-Trumbore on the stored corner and two edges.
- **Mathematics:** p = d x e2; det = e1 . p; reject |det| < 1e-12; s = o - a; u = (s . p)/det in [0, 1]; q = s x e1; v = (d . q)/det with v >= 0 and u + v <= 1; t = (e2 . q)/det; accept 1e-5 < t < tmax. No sign test on det, so triangles are double-sided.
- **Instructions:** 2 cross products, 4 dot products, 1 reciprocal division (reused three times); early outs after u and after v; `BVH_T_MIN` rejects the surface's own hit.
- **Cost:** a few dozen flops per leaf triangle, at most 4 triangles per leaf. The determinant threshold is absolute, not relative to the triangle size (derived from the constant).
- **Why this and not another:** header: "Triangles are double-sided".
- **Where:** `cpu/cpu_bvh.axle:35-39,298-324`.
- **Docs:** MISSING.

### R-31. I want "is anything in the way" for shadows and "what is hit first" for explanations
- **Means:** `occluded` recurses and returns on the first triangle hit; `nearest` walks with an explicit stack of 64 slots and shrinks `tmax` to the best hit so far.
- **Mathematics:** none: plain arithmetic. A path of at most 48 splits leaves at most one sibling per level on the stack, so 64 slots suffice; a push that does not fit is skipped.
- **Instructions:** `nearest` pushes both children and pops the last one pushed (the right child first); children are not ordered by ray direction. Both queries are read-only, so any number of threads may ask at once.
- **Cost:** O(visited nodes + leaf triangles tested); worst case O(n). `nearest` allocates its 64-slot stack on every call (`new i32[64]`): derived.
- **Why this and not another:** not documented.
- **Where:** `cpu/cpu_bvh.axle:11-13,50-56,327-386`.
- **Docs:** MISSING.

### R-32. I want only opaque shadow casters in the shadow structure, rebuilt from the scene each frame
- **Means:** `BuildAccel` collects, for every instance that casts shadows, has a mesh and a material and is not blended, the world-space corners of its triangles, then builds the BVH and the shadow query over them and the scene's lights.
- **Mathematics:** none: plain arithmetic (corner = model * position).
- **Instructions:** two passes over the instances (count, then fill one `f32[]` of 9 floats per triangle); blended instances are left out because "the rays never test alpha".
- **Cost:** O(total caster triangles) plus the build of R-28, at every BuildAccel; memory 36 B per triangle for the corner array (the BVH constructor keeps its own copy).
- **Why this and not another:** comment: "a blended surface lets light through, and the rays never test alpha". Masked (cut-out) casters are included as solid triangles, so a shadow ray ignores the mask (derived).
- **Where:** `cpu/cpu_renderer.axle:12-13,313-356`.
- **Docs:** `doc/spec/rendering.md:87`.

---

## Render graph and frame recording (`graph/`)

### R-33. I want to describe a frame by named resources and named passes, with ids that never depend on a hash
- **Means:** `RenderGraph`: `addImage`/`addBuffer` declare resources, `addPass`, `reads`, `writes`, `markOutput`; names are interned in declaration order so ids are the declaration order; an unknown name is kept as a negative id so validation can name it.
- **Mathematics:** none: plain arithmetic. Image bytes = max(W * H * bytesPerPixel, 0) with bytesPerPixel Hdr 16, Depth32 4, Srgb8 4, Opaque 0.
- **Instructions:** parallel `Vec`s per attribute; every tie in the compiler is broken by the id.
- **Cost:** O(1) per declaration (the cost of `StringInterner::find` is in `core/id`, not read: `UNVERIFIED`); memory per resource about 4 + 4 + 4 + 4 + 8 + 1 + 1 B, per edge 4 + 4 + 1 B (derived).
- **Why this and not another:** header: ids are "the same on every run, and every tie in the compiler is broken by those ids".
- **Where:** `graph/graph_graph.axle:1-12,73-139,152-164`; `graph/graph_types.axle:20-30,65-67,158-165`.
- **Docs:** `doc/spec/rendering.md:52-57`.

### R-34. I want mistakes in a frame description reported by name before anything runs
- **Means:** `GraphCompiler::compile` validates: duplicate names, unknown resources, a read nobody writes (unless imported), read-before-write for a pass that reads and writes one resource, a cycle (naming the passes), no output, and a pass given resources of the wrong kind (build-accel without an accel write, forward without a colour write, resolve without a colour read and a colour or texture write). Problems go to a fixed 128-entry log; later ones are only counted, and `isValid` is false if any were dropped.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** 0/1 integer tables `reads` and `writes` (np x nr) and `dep` (np x np).
- **Cost:** table memory 4 (2 np nr + np^2) bytes (derived); validation O(E + np nr).
- **Why this and not another:** `graph_types` header: the log "never grows, because a generic container of strings is not safe in the compiler we pin".
- **Where:** `graph/graph_plan.axle:1-15,69-71,158-215,220-295`; `graph/graph_types.axle:1-6,44-93`.
- **Docs:** `doc/spec/rendering.md:57-59`.

### R-35. I want to know which pass must run before which
- **Means:** writers of one resource chain in pass-id order; a pure reader depends on the last writer; a pass that reads and writes depends on the last earlier writer; a missing earlier writer is an error unless the resource is imported.
- **Mathematics:** dependency relation dep(q, p) = 1 when q must precede p; the graph is a DAG iff Kahn's algorithm (R-37) places every pass.
- **Instructions:** `lastWriterBefore` scans passes 0..p.
- **Cost:** O(nr * np + (read-and-write pairs) * np), worst O(nr np^2) (derived).
- **Why this and not another:** the header states the semantics "in one place" (`graph_graph.axle:9-12`); alternatives are not discussed.
- **Where:** `graph/graph_plan.axle:1-15,298-338`; `graph/graph_graph.axle:9-12`.
- **Docs:** `doc/spec/rendering.md:54-57`.

### R-36. I want passes nothing visible depends on to cost nothing
- **Means:** roots are passes that write an output or an imported resource; liveness spreads to every pass a live pass depends on, to a fixed point; the rest are culled (not run, not recorded, no memory for their private resources).
- **Mathematics:** live = least set containing the roots and closed under "q precedes live p", iterated until no change.
- **Instructions:** a `while (changed)` loop over np x np.
- **Cost:** O(np nr + np^2 * rounds), rounds <= np, so O(np^3) worst case (derived); frames have a handful of passes.
- **Why this and not another:** not documented.
- **Where:** `graph/graph_plan.axle:9-10,398-426`.
- **Docs:** `doc/spec/rendering.md:59-60`.

### R-37. I want a deterministic order of execution that respects the dependencies
- **Means:** Kahn's algorithm with the lowest pass id first among the ready passes, so independent passes keep the order they were added in; passes on a cycle stay unplaced and are named in a `Cycle` issue; the run order is that order restricted to live passes.
- **Mathematics:** Kahn: repeatedly remove a node with no remaining predecessors; fewer nodes placed than np proves a cycle.
- **Instructions:** `waiting[p]` = number of predecessors; after a placement the scan restarts from pass 0 (`break`), which yields "lowest id first".
- **Cost:** O(np^2) time (the textbook Kahn is O(V + E) with a queue; this version scans), memory 2 np ints (derived).
- **Why this and not another:** header: "Kahn's algorithm with the lowest pass id first among the ready ones, so independent passes keep the order they were added in". A priority queue is not discussed.
- **Where:** `graph/graph_plan.axle:11-12,341-381,429-443`.
- **Docs:** `doc/spec/rendering.md:60-61`; `doc/handbook/render/12-lux-layers.md:105`.

### R-38. I want to know, for every resource, when it is first and last needed
- **Means:** first and last run position over the live passes that touch it; outputs and imports are kept alive to the last pass.
- **Mathematics:** first(r) = min and last(r) = max of the run positions of the passes touching r; for an output or imported r, last = (number of run passes) - 1.
- **Instructions:** one sweep over the declarations.
- **Cost:** O(E + nr).
- **Why this and not another:** not documented.
- **Where:** `graph/graph_plan.axle:13-14,446-472`.
- **Docs:** `doc/spec/rendering.md:61-62`.

### R-39. I want transient targets to share memory when they are never alive together
- **Means:** greedy interval colouring: transient resources (used, not imported, not output) are taken in order of first use; each takes the first existing block of the same size and the same class (image or acceleration structure) that is free by then, else a new block. The report gives bytes with and without sharing and the persistent bytes (non-imported outputs, never shared).
- **Mathematics:** a block is free for r when its last user ends strictly before first(r) (`groupEnd < from`), so two resources whose lifetimes touch at one pass position do not share. Saving = transientBytes - aliasedBytes, where aliased = sum of block sizes. No optimality claim is made in the file.
- **Instructions:** `taken[]` flags; `nextTransient` is a linear scan for the earliest unassigned first use.
- **Cost:** O(nr^2 + nr * blocks) time (derived); the compiler only plans bytes and allocates nothing. Example size: a 1920 x 1080 `Hdr` target is 16 B x 2,073,600 pixels = 33,177,600 B (derived from `GFMT_BYTES_HDR`). The CPU backend allocates one buffer set per target id on demand and does not consume the aliasing plan (derived from `CpuRenderer::target`).
- **Why this and not another:** header: "a greedy interval assignment by first use". Alternatives are not discussed.
- **Where:** `graph/graph_plan.axle:13-15,474-542`; `graph/graph_types.axle:65-67,158-165`; `cpu/cpu_renderer.axle:140-149`.
- **Docs:** `doc/spec/rendering.md:61-62`.

### R-40. I want a frame turned into commands with as few state changes as possible
- **Means:** `FrameRecorder::record` walks the live passes in order and emits BeginPass, the commands of the pass kind, EndPass. A Forward pass sets the colour and depth target, clears both, then draws the instance list as runs of equal (mesh, material): `BindMaterial` only when the material changes, one `DrawMesh` per run. An invalid plan records nothing.
- **Mathematics:** none: plain arithmetic.
- **Instructions:** one linear scan with `runEnd`; relies on the extractor's sort to make equal state adjacent (R-45).
- **Cost:** O(I) per Forward pass; draw calls = number of runs, which is the number of distinct (material, mesh) groups plus the splits caused by blended instances (derived).
- **Why this and not another:** not documented (batching is the stated purpose of the sort in `scene_extract`).
- **Where:** `graph/graph_record.axle:1-12,38-120`.
- **Docs:** `doc/spec/rendering.md:17-22`.

### R-41. I want to read a frame plan and its cost as text that compares byte for byte across runs
- **Means:** `GraphReport::text`: problems, passes in order with reads and writes, culled passes, every resource with kind, size, flags, lifetime and block, and the memory summary; per-pass counters when the backend filled `PassCosts`; times only on request.
- **Mathematics:** none: plain arithmetic (time printed as hundredths of a millisecond, nanoseconds / 10000).
- **Instructions:** string building; `list` scans all declarations for each pass.
- **Cost:** O(np * E) for the listing (derived); not on a hot path.
- **Why this and not another:** header: a report "without [times] can be compared byte for byte".
- **Where:** `graph/graph_report.axle:1-8,27-140`.
- **Docs:** `doc/spec/rendering.md:62-63`.

---

## Explaining a pixel (`light/light_explain.axle`, `cpu/cpu_explain.axle`)

### R-42. I want to know why one pixel has its colour, with the explanation provably equal to the picture
- **Means:** `lightExplain` shades a point like `lightShade` but keeps one `LightContribution` per light (reason, N.L, attenuation, shadow, RGB) plus the ambient and emissive terms; `CpuExplain::pixel` rebuilds the surface with the renderer's own `CpuSurface::sample`; `difference()` is the largest channel gap between the sum of the parts and the shaded result, and is exactly 0.
- **Mathematics:** the sum is formed in the order emissive + ambient + (diffuse sum + specular sum) over the lights in list order, the order `total()` uses; equality is exact because both paths call `lightContribution`.
- **Instructions:** one extra full shading per explained pixel; blocker distance by `nearest` for lights in shadow.
- **Cost:** O(L) per explained pixel, plus the full `lightShade` again for the independent result.
- **Why this and not another:** `light_explain` header: "so the gap is exactly 0 and a test fails the moment either path is changed alone".
- **Where:** `light/light_explain.axle:1-98`; `cpu/cpu_explain.axle:1-35,92-135`.
- **Docs:** `doc/spec/lighting.md` section 9; `doc/spec/rendering.md:87-88`.

---

## Scene extraction and camera (`scene/`)

### R-43. I want a world 5000 km from the origin to render the same picture, with f32 on the hot path
- **Means:** positions are f64; extraction subtracts the camera's f64 position from each entity's translation, builds the model matrix in f64 and only then narrows to f32; lights are placed the same way; the view matrix is the camera's rotation alone (the camera is the origin).
- **Mathematics:** model = narrow( T(t - c) R S ), c the camera position; view = conjugate(q) as a matrix. Subtraction in f64 is exact enough that the f32 narrowing happens at small magnitudes.
- **Instructions:** one `DTransform::make` and one `narrowMat4` per instance; `relativePoint` for lights.
- **Cost:** O(M) matrix builds for M mesh entities; no measured figure.
- **Why this and not another:** `scene_camera` header (design rule 5): "keeps its precision ten kilometres from the world's centre"; RENDERING.md quotes a check at 5000 km (`prism`).
- **Where:** `scene/scene_camera.axle:1-8,159-161,189-191`; `scene/scene_extract.axle:1-10,165-187`; `scene/scene_frame.axle:1-8`.
- **Docs:** `doc/spec/rendering.md:25-28`.

### R-44. I want instances outside the camera's view dropped before they reach any backend
- **Means:** the mesh's local AABB is transformed by the camera-relative model matrix and tested against the frustum built from the view-projection product; "wholly outside" instances are dropped and counted (`considered`, `rejected`). A dead entity, or an unknown mesh or material id, is skipped.
- **Mathematics:** frustum planes from the view-projection matrix and the box-versus-planes test live in `core/math/frustum` and `core/math/geom` (not read: `UNVERIFIED`).
- **Instructions:** one `Aabb::transformed` and one `testAabb` per instance.
- **Cost:** O(M) per frame; the frustum is built once.
- **Why this and not another:** not documented. No spatial index is used (RENDERING.md "Not done" lists "culling of lights"; ROADMAP.md:18 notes no BVH or octree for the world).
- **Where:** `scene/scene_extract.axle:122-162`; `scene/scene_camera.axle:184-186`.
- **Docs:** `doc/spec/rendering.md:11-12,30-31`.

### R-45. I want the draw list in an order that depends on the data alone, with equal state adjacent
- **Means:** opaque and masked instances are sorted by (material, mesh, entity slot); the sort is a stable bottom-up merge sort over an `i64` key; no hash and no library order enters.
- **Mathematics:** key = material * 2^40 + mesh * 2^20 + slot, each field masked to 20 bits (1,048,575). A merge sort on equal keys keeps input order (`<=` takes the left run first).
- **Instructions:** two `i32[n+1]` index arrays, ping-pong merges, doubling run width; the sorted index list is then used to append the instances.
- **Cost:** O(n log n) comparisons, 8 n bytes of index arrays (derived). Ids above 2^20 - 1 wrap inside the key (only the order is affected).
- **Why this and not another:** header: "ordered by a key that depends on the data alone, so two runs hand the backend the same list". The same `sortedOrder` is reused by the BVH build (R-28).
- **Where:** `scene/scene_extract.axle:1-10,48-56,107-119,190-239`.
- **Docs:** `doc/spec/rendering.md:30-31`.

### R-46. I want blended instances drawn far to near
- **Means:** blended instances get a key above every opaque one, falling with view depth.
- **Mathematics:** depth = -(view * centre_of_bounds).z; steps = clamp( floor(depth * 16), 0, 2^20 - 1 ); key = 2^62 + (2^20 - 1 - steps) * 2^20 + slot. The depth resolution is 1/16 view unit and distances beyond 65,535 units are not told apart (derived from the constants).
- **Instructions:** one matrix-point transform per blended instance; integer key.
- **Cost:** O(1) per blended instance on top of R-45.
- **Why this and not another:** per-instance (bounds centre) sort rather than per triangle; not discussed.
- **Where:** `scene/scene_extract.axle:1-10,48-56,190-202`.
- **Docs:** `doc/spec/rendering.md:30-31`.

### R-47. I want a camera that is placed in f64, looks along -Z and projects to Vulkan clip space
- **Means:** `Camera`: position DVec3, rotation DQuat, perspective or orthographic; `lookAt` builds a basis and converts it to a quaternion; `viewProjection = projection * view`.
- **Mathematics:** forward = normalize(target - position); side = normalize(forward x up) (a perpendicular when the cross product vanishes); upward = side x forward; basis columns (side, upward, -forward) -> quaternion. Orthographic box: half height = orthoHeight / 2, half width = half height * aspect. The perspective and orthographic matrices are `Mat4::perspective/ortho` (not read: `UNVERIFIED`); the file states depth 0 near to 1 far and +Y down in NDC.
- **Instructions:** all in f64 until `narrowMat4`.
- **Cost:** O(1) per matrix; per frame once.
- **Why this and not another:** header: "the projection is Vulkan's (depth 0 near to 1 far, +Y down in NDC)".
- **Where:** `scene/scene_camera.axle:1-8,19,96-114,159-186`.
- **Docs:** `doc/spec/rendering.md:70` (conventions).

### R-48. I want lights and assets addressed by small stable ids, lights placed by their entity
- **Means:** `LightComp` (lux for a directional light, candela for point and spot, cd/m^2 for an emissive disc) is turned into a `LightSource` by `toSource` at the entity's camera-relative position and direction (local -Z rotated by the entity's rotation); `RenderAssets` hands out ids in insertion order for meshes, materials and textures.
- **Mathematics:** none: plain arithmetic (unit conversion is in R-65).
- **Instructions:** the asset arrays double from 8; the table takes ownership of meshes and textures and copies materials into a `Vec`.
- **Cost:** O(1) amortised per insertion; lookups O(1).
- **Why this and not another:** `scene_assets` header: ids are "the same on every run that inserts in the same order"; generic containers of ours "cannot hold classes".
- **Where:** `scene/scene_light.axle:1-8,113-152`; `scene/scene_extract.axle:165-177`; `scene/scene_assets.axle:1-65`.
- **Docs:** `doc/spec/rendering.md:14-16`; `doc/spec/lighting.md` section 2.

---

## Deterministic numerics and quadrature (`light/light_math.axle`, `light/light_quadrature.axle`)

### R-49. I want exp, log and pow that give the same bits on every machine and can be translated to a shader
- **Means:** `lightExp2`, `lightLog2`, `lightPow`, `lightExp` (and the f64 `lightExp2D`) computed in f64 from IEEE additions and multiplications only. The shading functions are written in a restricted subset of Axle (free functions on f32/i32/bool/Vec3, no allocation, constant loop bounds, guarded divisions) so a later tool can translate them to GLSL.
- **Mathematics:** 2^x = 2^k * e^(f ln 2) with k = round(x), f in [-1/2, 1/2], the exponential by a Taylor series of 14 further terms (truncation error below 1e-17, header), 2^k by repeated squaring over 11 bits. log2: fold the mantissa m into [1/sqrt 2, sqrt 2) counting halvings e, z = (m - 1)/(m + 1) with |z| <= 0.172, ln m = 2 atanh z = 2 (z + z^3/3 + ...) with 11 terms (below 1e-17), log2 = e + ln m / ln 2. pow(x, y) = 2^(y log2 x); 0 for x <= 0, 1 for y = 0; limits at the f32 exponent range (-126 .. 127).
- **Instructions:** fixed-count loops (14, 11, 11 iterations) so they unroll; `lightLog2` returns -126 for zero, negatives and NaN and 127 for infinity, so the answer is always finite; the argument folding of `lmathLog2D` is a `while` loop that runs once per binary order of magnitude of the input.
- **Cost:** about 14 multiply-adds + 11 loop steps of squaring for `exp2`; about 11 divisions-by-constant + the folding loop for `log2`; `pow` = both. All in f64. No measured figure in the files read.
- **Why this and not another:** subset rule 7: "their bodies here are the CPU definition and are computed in f64 from IEEE additions and multiplications, so the same bits come out on every machine. They are the one place a GPU result may differ (by a few ulp)". `CLAUDE.md` forbids libm `sin`/`cos` where determinism matters.
- **Where:** `light/light_math.axle:1-24,28-165`.
- **Docs:** `doc/spec/lighting-math.md:85-91` (one line, no term counts); the subset rules appear only in the file header.

### R-50. I want integrals over directions done exactly and reproducibly, without a pasted table of nodes
- **Means:** `LightGauss`: Gauss-Legendre nodes and weights computed by Newton's method on the Legendre polynomial.
- **Mathematics:** nodes are the roots of P_n; the start is x_i = cos(pi (i + 3/4)/(n + 1/2)); P_n by the three-term recurrence k P_k = (2k - 1) x P_{k-1} - (k - 1) P_{k-2}; derivative P_n' = n (x P_n - P_{n-1})/(x^2 - 1); iterate x <- x - P_n/P_n' until |step| < 1e-15 (at most 60 steps, "about four" in practice); weight w = 2 / ((1 - x^2) P_n'^2). A rule of n nodes is exact for polynomials of degree 2n - 1.
- **Instructions:** f64 throughout, deterministic `cosD` for the start; `at(i, a, b)` and `scaled(i, a, b)` map a node and weight to [a, b].
- **Cost:** O(n^2) per rule (n roots, a few steps, an O(n) recurrence each; derived). Measured by the suite (header): the weights sum to 2 within 4e-16; x^k integrates exactly up to degree 2n - 1 for n up to 64, error below 1e-14.
- **Why this and not another:** header: "A node table pasted from a book is a table that can have a typo".
- **Where:** `light/light_quadrature.axle:1-61`.
- **Docs:** `doc/spec/lighting-math.md:88-89` says the nodes are "tabulated" (see Doubts).

---

## The specular and diffuse surface response (`light/light_brdf.axle`, `light_dfg.axle`, `light_vndf.axle`)

### R-51. I want a rough-metal / plastic specular highlight that is physically shaped and symmetric in light and view
- **Means:** Cook-Torrance with GGX distribution, height-correlated Smith visibility and Schlick Fresnel: f_s = D V F, times the multiple-scattering compensation (R-52).
- **Mathematics:** alpha = max(roughness^2, 0.045), h = normalize(l + v); D = alpha^2 / (pi ((n.h)^2 (alpha^2 - 1) + 1)^2) with the invariant integral D (n.h) dw_h = 1; V = 0.5 / ( n.l sqrt(n.v^2 (1 - alpha^2) + alpha^2) + n.v sqrt(n.l^2 (1 - alpha^2) + alpha^2) ) = G2 / (4 n.l n.v); F = F0 + (1 - F0)(1 - v.h)^5, F0 = lerp(0.04, baseColor, metallic); f_s(l, v) = f_s(v, l).
- **Instructions:** (1 - x)^5 by three multiplications (x2 = x*x, x2*x2*x); one reciprocal in D, one in V with the denominator floored at 1e-9; the half vector uses `normalizedOr(n)`; n.v is floored at 1e-4; the whole function returns zero below the horizon (n.l <= 0). f64 twins exist for D, V and the Fresnel weight.
- **Cost:** per light per shaded pixel: 1 normalisation, 2 square roots, 2 divisions, about 40 flops (derived). Error budget asserted by the suite: D, V, F f32 versus f64 relative error <= 4e-6 (header). Documented deviation: alpha >= 0.045 (roughness 0.21) because "below it D is a spike that neither f32 nor a shadow map can represent and a real light is never a point".
- **Why this and not another:** the floors are documented deviations (header); the choice of GGX/Smith/Schlick follows glTF (`doc/spec/lighting-math.md` section 3 title).
- **Where:** `light/light_brdf.axle:1-25,28-40,54-106,148-170`.
- **Docs:** `doc/spec/lighting-math.md:35-44`; `doc/handbook/render/05-shading.md:50-64`.

### R-52. I want a rough surface not to lose energy, and diffuse plus specular never to exceed what arrives
- **Means:** the Kulla-Conty / Fdez-Aguera multiple-scattering factor, and a diffuse albedo that is only what the (compensated) specular lobe leaves over, derived once per pixel by `lightPrepare`.
- **Mathematics:** with (A, B) = dfg(n.v, roughness) and E = max(A + B, 0.001): compensation = 1 + F0 (1/E - 1); specular albedo = (F0 A + B) * compensation; diffuse albedo = baseColor (1 - metallic) max(1 - specular albedo, 0). Invariant (header of light_shade): a uniform environment L on a white material adds up to exactly L (the white furnace).
- **Instructions:** done once per pixel, not per light; a floor on E (a hole in the table cannot blow up the compensation); channel-wise `Vec3` arithmetic.
- **Cost:** one table lookup (R-53) plus about 30 flops per shaded pixel (derived).
- **Why this and not another:** `doc/spec/lighting-math.md:45-47`: the albedo is "tabulated by a tool through deterministic quadrature (not Monte Carlo noise)".
- **Where:** `light/light_brdf.axle:42,118-142`; `light/light_shade.axle:14-17`; `light/light_material.axle:90-111`.
- **Docs:** `doc/spec/lighting-math.md:45-47`; `doc/handbook/render/05-shading.md:36-48`.

### R-53. I want the directional albedo of the specular lobe as a table, computed exactly instead of sampled
- **Means:** `LightDfgTable`: a size x size table of (A, B) over (view cosine, roughness), each entry a Gauss-Legendre double integral in f64 over the half-vector domain; lookup is bilinear in sqrt(n.v) and roughness.
- **Mathematics:** E(mu, alpha) = integral over l of D V (n.l) dl; A = integral D V (1 - w) n.l dl, B = integral D V w n.l dl, w = (1 - v.h)^5, so albedo(F0) = F0 A + B. Change of domain to the half vector: dl = 4 (v.h) dh and D (n.h) dh = du dphi / (2 pi) with n.h^2 = (1 - u)/(1 + (alpha^2 - 1) u), giving A + B = (1/pi) integral_0^1 du integral_0^phi0 dphi 4 V (n.l)(v.h)/(n.h). The upper limit phi0 = pi where the circle of half-vectors is wholly above the horizon, otherwise phi0 = acos( n.v (1 - 2 n.h^2) / (2 n.h sin theta_v sin theta_h) ) (the lobe is symmetric in phi). The u range is cut at the two values where the horizon starts and stops clipping (theta_h between (pi/2 - theta_v)/2 and (pi/2 + theta_v)/2); inside that band a square-root singularity at the end of the phi range is tamed by u = lo + (hi - lo)(1 - cos(pi t))/2. Column i holds n.v = (i/(n-1))^2 (not below 1e-3), row j roughness j/(n-1).
- **Instructions:** all f64; per entry two u-segments x `order` u-nodes x `order` phi-nodes; a fresh `LightGauss(order)` is built for every entry; the table is stored as `f32`.
- **Cost:** default size 24, order 48 (`CpuSettings`): at most 2 * 48 * 48 = 4,608 integrand evaluations per entry, 576 entries, so at most 2,654,208 evaluations plus 576 rule builds at construction of every `CpuRenderer` (derived; no timing in the files read). Memory 24 * 24 * 2 * 4 = 4,608 B. Measured by the suite (header): order 32 versus 96 agree to 3e-7 for A and B at every node; the half-vector integral agrees with a brute-force midpoint integral over l to 1e-3 at alpha >= 0.09; bilinear lookup between nodes is within 2e-3 of direct quadrature.
- **Why this and not another:** header: the half-vector domain "where the GGX lobe is wide for every alpha" gives "no horizon kink, no noise" and geometric convergence; a Monte Carlo estimate is rejected in `doc/spec/lighting-math.md:45-47`.
- **Where:** `light/light_dfg.axle:1-24,26-207`; `cpu/cpu_renderer.axle:58-64,110-115`.
- **Docs:** `doc/spec/lighting-math.md:45-47`; `doc/handbook/render/05-shading.md:44`.

### R-54. I want a diffuse lobe choice between plain Lambert and a retro-reflective one that never gains energy
- **Means:** `LightDiffuseModel`: Lambert `albedo / pi`, or the normalised Disney/Burley lobe (Lagarde and de Rousiers 2014, as cited in the code).
- **Mathematics:** fd90 = 0.5 r + 2 (l.h)^2 r; scatter(x) = 1 + (fd90 - 1)(1 - x)^5 for x = n.l and x = n.v; factor = scatter(n.l) scatter(n.v) * (1 + r (1/1.51 - 1)) / pi, r the perceptual roughness. It replaces 1/pi; the diffuse albedo is the same `lightPrepare` leftover.
- **Instructions:** reuses `lightFresnelWeight`; l.h is taken as v.h (equal by symmetry of h).
- **Cost:** about 15 extra flops per light when selected. The header says there is no f64 twin of the Burley lobe; its energy is checked by quadrature instead.
- **Why this and not another:** selectable per material; the reason for the energy factor is "keeps the lobe from gaining energy" (comment).
- **Where:** `light/light_brdf.axle:49-51,108-116,157-163`; `light/light_material.axle:21-27`.
- **Docs:** `doc/spec/lighting-math.md:44`.

### R-55. I want to draw microfacet normals the viewer can actually see, for a reference path tracer
- **Means:** `lightVndfSample`: Heitz 2018 visible-normal sampling in tangent space, with its density `lightVndfPdf` and the Smith G1/G2.
- **Mathematics:** D_v(h) = G1(v) max(0, v.h) D(h) / n.v; G1 = 2 n.v / (n.v + sqrt(alpha^2 + (1 - alpha^2) n.v^2)); sample: stretch v by alpha, build an orthonormal frame, a disc point (r = sqrt u1, phi = 2 pi u2) warped by s = (1 + v.z)/2: p2 = (1 - s) sqrt(1 - p1^2) + s p2, lift to the hemisphere, unstretch. For the height-correlated Smith model the estimator weight is G2/G1 <= 1.
- **Instructions:** one `sin`/`cos` and several square roots per sample; deterministic `sin`/`cos` from the maths layer.
- **Cost:** about 60 flops per sample (derived). Checks (header): the density integrates to 1 over the hemisphere (quadrature error below 1e-4); the mean n.h over 200,000 seeded samples agrees with its quadrature value within four standard errors; the mean G2/G1 agrees with the table's E(mu, alpha).
- **Why this and not another:** header: "wastes no samples on back-facing microfacets" compared with sampling D(h) n.h. The caller (a path tracer) is not in the files read: `UNVERIFIED` who uses it.
- **Where:** `light/light_vndf.axle:1-71`.
- **Docs:** `doc/spec/lighting-math.md:48-49` (one line).

---

## Light sources, exactly (`light/light_irradiance.axle`, `light_source.axle`, `light_shade.axle`)

### R-56. I want a lamp with a size to light a surface without a 1/d^2 hot spot and with the right horizon cut-off
- **Means:** a point light is the uniform sphere of radiance L = I/(pi R^2); its illuminance on a surface is the closed form of Snyder 1996 (as cited in the code, after Lagarde and de Rousiers 2014); radius 0 is the classical point light I cos(theta)/d^2.
- **Mathematics:** with sin^2 sigma = R^2/d^2 and c = cos theta: S = pi sin^2 sigma * saturate(c) when the sphere is wholly above (c^2 > sin^2 sigma) or wholly below the horizon; otherwise S = (c acos(y) - x sin(theta) sqrt(1 - y^2)) sin^2 sigma + atan( sin(theta) sqrt(1 - y^2) / x ), x = sqrt(1/sin^2 sigma - 1), y = clamp(-x c / sin theta, -1, 1); E = L S. A radius below 1e-4 is a point; distances are kept above sqrt(1e-8); sin^2 sigma is capped at 0.99999 so x is real.
- **Instructions:** one branch on the three regimes; `acos`, `atan` and two square roots only in the clipped regime; an f64 twin is the reference.
- **Cost:** about 1 division and 3 transcendentals per light per pixel in the clipped band, otherwise a handful of flops (derived). Error budget (header): f32 versus f64 relative 2e-5 away from the horizon cusp (suite, Pcg32 sweep); the f64 twin versus a quadrature of the spherical cap 1e-9 relative.
- **Why this and not another:** header: "no hot spot at the light, no shadow-terminator error at the horizon and no tuning". The earlier engine had a sizeless sun and `0.8^(15-level)` falloff.
- **Where:** `light/light_irradiance.axle:1-53,96-140,201-220`.
- **Docs:** `doc/spec/lighting-math.md:16-23`; `doc/spec/lighting.md` section 2.

### R-57. I want the sun to have a disc, so the terminator and shadow penumbra have a physical width
- **Means:** a directional light with angular diameter delta is the same sphere at infinity.
- **Mathematics:** with angular radius r = delta/2 and normal-incidence illuminance E_n = L pi sin^2 r: E = E_n S(cos theta, sin^2 r) / (pi sin^2 r); below sin^2 r < 1e-10 the sun is a point: E = E_n saturate(cos theta). The sun's delta is about 0.0093 rad (0.533 degrees).
- **Instructions:** reuses `lightSphereIlluminance`.
- **Cost:** as R-56; one `sin` per light.
- **Why this and not another:** not documented beyond the header.
- **Where:** `light/light_irradiance.axle:15-17,146-153`; `light/light_source.axle:69-70,94-107`.
- **Docs:** `doc/spec/lighting-math.md:24-26`.

### R-58. I want a small emitting disc (a lit window, a screen) as a light
- **Means:** the cone formula with the disc seen face on, scaled by the cosine at the emitter.
- **Mathematics:** sin^2 sigma = r^2 / (r^2 + d^2); E = L S(cos theta, sin^2 sigma) * saturate(cos at emitter); exact on the axis, "the usual disc approximation off it" (header).
- **Instructions:** one `lightSphereIlluminance` call.
- **Cost:** as R-56.
- **Why this and not another:** not documented (linearly transformed cosines for true area lights are planned in `doc/spec/lighting-math.md:31-32`, not implemented in the files read).
- **Where:** `light/light_irradiance.axle:19-20,159-164`.
- **Docs:** `doc/spec/lighting-math.md:31-33`.

### R-59. I want a lamp's reach to end smoothly and a spot's cone to have a soft edge
- **Means:** a finite-range window and the glTF spot cone, both applied on top of the physical falloff.
- **Mathematics:** window w = saturate(1 - (d/range)^4)^2 (1 at the light, exactly 0 with zero slope at the range; range 0 = unlimited). Cone: scale = 1/max(1e-3, cos_inner - cos_outer); a = saturate(cos_angle * scale - cos_outer * scale); factor a^2: 1 inside the inner cone, 0 at and beyond the outer, C1 at the outer edge but only C0 at the inner edge (the slope jumps from 2 scale to 0: the code comment says `doc/spec/lighting-math.md` is wrong to call it C1 there).
- **Instructions:** two squarings for the window (no pow); the cone is one multiply-add and a square.
- **Cost:** a few flops per light.
- **Why this and not another:** "a deliberate artistic deviation, off when range is 0" (header).
- **Where:** `light/light_irradiance.axle:22-24,167-187,250-293`.
- **Docs:** `doc/spec/lighting-math.md:27-30` (see Doubts for the C1 claim).

### R-60. I want to know whether a light reaches a point and, if not, why, with layers and per-object exclusion
- **Means:** `lightIncidence` returns a reason and the irradiance; tests in the order excluded layer or object, include mask, range (not for directional), spot cone, wholly behind the geometric surface; the shadow is decided by the caller afterwards.
- **Mathematics:** the backface test: reject when irradiance <= 0 or the cosine of the light centre with the geometric normal is <= -sqrt(min(sin^2 sigma, 1)), i.e. the centre is below the horizon by more than the light's angular radius. The shading normal supplies the cosine for the irradiance, the geometric normal supplies this test, so a normal-mapped face is still not lit from behind its triangle.
- **Instructions:** bit tests `(mask & layer)`; `normalizedOr` for the direction; the same function serves the renderer and the explainer.
- **Cost:** O(1) per light.
- **Why this and not another:** header of `lightIncidence`: "a normal-mapped surface must still not be lit from behind its triangle".
- **Where:** `light/light_irradiance.axle:56-71,73-89,224-243,250-293`; `light/light_source.axle:43-60,181-184`.
- **Docs:** `doc/spec/lighting.md` section 12; `cpu/cpu_explain.axle:36-50` words the reasons.

### R-61. I want to shade one surface point with many lights and keep every term separable
- **Means:** `lightShade` = emissive + ambient (diffuse, specular) + the sum over lights of `lightContribution`, each with its own shadow factor from a `LightShadowQuery`; terms are kept apart (direct diffuse, direct specular, ambient diffuse, ambient specular, emissive) so a shadow or a cloud can recombine them.
- **Mathematics:** L_o = L_e + sum_i f(l_i, v) E_i V_i + ambient (rendering equation); the cosine n.l is inside E_i, not in f. Ambient: diffuse = prepared diffuse x SH9 irradiance/pi x occlusion; specular = specular albedo x supplied radiance x occlusion.
- **Instructions:** `lightPrepare` once, then per light `visibility` (a trait call), `lightIncidence`, `lightBrdf`; a fully shadowed light reports `Shadow` and costs no BRDF; the sum order is emissive, ambient, direct.
- **Cost:** O(L) per shaded pixel, each light costing R-56..R-60 + R-51 + a shadow query (R-27). `LightNoShadows` answers 1.
- **Why this and not another:** header: "ONE CODE PATH ... The explainer therefore cannot disagree with the renderer, and the suite checks the sums bit for bit".
- **Where:** `light/light_shade.axle:1-20,35-237`.
- **Docs:** `doc/spec/lighting-math.md:7-11`; `doc/spec/lighting.md` sections 1 and 9.

---

## Environment lighting and units (`light/light_sh.axle`, `light_units.axle`, `cpu/cpu_kernel.axle`)

### R-62. I want the diffuse light of a whole sky dome in 27 numbers
- **Means:** `LightSh9::project`: nine real spherical-harmonic coefficients per colour channel by a deterministic product rule.
- **Mathematics:** c_i = integral L(w) Y_i(w) dw by Gauss-Legendre in cos(theta) (`bands` nodes, so no clustering at the poles) times a uniform trapezoid of 2 * bands azimuths, each sample weighted w_i * 2pi/(2 bands). Exact for a degree-2 basis times a polynomial environment in cos(theta) and for the trigonometric degree of the basis in phi. The suite measured (header) a constant to 1e-6 with 32 bands, against 3e-4 for the equal-area midpoint rule that `doc/spec/lighting-math.md` names.
- **Instructions:** one environment query per sample through a trait object (`LightEnvironment`); each sample adds 9 basis values x 3 channels.
- **Cost:** 2 bands^2 samples: 2,048 for 32 bands, each a full environment evaluation (for the analytic sky about 15,700 `exp2` series, R-71; derived). Memory 9 x Vec3 = 108 B.
- **Why this and not another:** header: "(LIGHTING_MATH.md names an equal-area grid; its midpoint rule measured 3e-4 off on a constant, this rule 1e-6, so this is what ships.)"
- **Where:** `light/light_sh.axle:1-17,86-113,150-188`.
- **Docs:** `doc/spec/lighting-math.md:63-65` (names the rejected grid); `doc/handbook/render/05-shading.md:71`.

### R-63. I want the diffuse light on a surface from the dome without integrating anything per pixel
- **Means:** `LightSh9::irradiance(n)`: the cosine-lobe convolution of the nine coefficients, divided by pi.
- **Mathematics:** E(n)/pi = c0 Y00 + (2/3) (c1 Y1-1 + c2 Y10 + c3 Y11) + (1/4) (c4 Y2-2 + c5 Y2-1 + c6 Y20 + c7 Y21 + c8 Y22) (Ramamoorthi and Hanrahan 2001: A_0 = pi, A_1 = 2 pi/3, A_2 = pi/4); clamped at 0 per channel (nine terms ring below zero next to a bright lobe). Invariants (suite): a constant L gives exactly L (the white-furnace law); a linear gradient a + b w.y gives a + (2/3) b n.y to 1e-6.
- **Instructions:** basis from 5 constants and about a dozen products; 9 scaled adds of `Vec3`.
- **Cost:** about 60 flops per shaded pixel; 108 B of coefficients.
- **Why this and not another:** header: replaces voxel-axle's single scalar `skyView(n.y)` and keeps colour and direction of the dome.
- **Where:** `light/light_sh.axle:19-33,190-223`.
- **Docs:** `doc/spec/lighting-math.md:63-65`; `doc/handbook/render/05-shading.md:68-75`.

### R-64. I want specular reflections of a sky above a ground without a probe
- **Means:** the kernel blends the radiance of the sky and the ground along the reflection vector over a band that widens with roughness (a rough lobe averages a wide part of the sky); with one radiance for both it is constant, the furnace.
- **Mathematics:** r = reflect(-v, n); band = 0.12 + 0.8 * roughness; t = smoothstep(-band, band, r.y); specular = lerp(below, sky, t). A uniform environment of radiance L sets SH coefficient c0 = L / Y00 so that E/pi = L.
- **Instructions:** one reflection, one smoothstep, one lerp per shaded pixel; assumes world up is +Y.
- **Cost:** about 20 flops per pixel.
- **Why this and not another:** not documented (a prefiltered probe is not in the CPU backend).
- **Where:** `cpu/cpu_kernel.axle:40-44,226-236`; `scene/scene_frame.axle:22-23,113-136`.
- **Docs:** MISSING.

### R-65. I want one definition of scale, so a 800-lumen lamp and the sun can live in the same scene
- **Means:** `LightUnits`: scene radiance 1.0 is a diffuse white surface (albedo 1) lit by the reference sun (100,000 lux) at normal incidence; the sun's scene irradiance is pi; every other unit converts through that.
- **Mathematics:** scene = lux * pi / 100,000 (so one scene unit = 100,000/pi = 31,831 cd/m^2); candela at one metre equals the lux there; point lamp candela = lumens/(4 pi); spot candela = lumens / (2 pi (1 - cos outer)) (0 for a closed cone); cd/m^2 follows the same factor.
- **Instructions:** pure scalar arithmetic with guarded divisions.
- **Cost:** O(1).
- **Why this and not another:** header: "Every conversion below follows from this single choice; nothing else in the lighting code may mention lux or candela".
- **Where:** `light/light_units.axle:1-40,63-81`.
- **Docs:** `doc/spec/lighting-math.md:7-14` (see Doubts: the 683 lm/W constant is not in the code).

### R-66. I want an exposure chosen the way a camera or a light meter would, in stops
- **Means:** EV100 from aperture, shutter and ISO, a saturation-based exposure multiplier, and a reflected-light-meter exposure for a measured average.
- **Mathematics:** EV100 = log2(N^2/t) - log2(ISO/100); exposure = (100,000/pi) / (1.2 * 2^EV100), so a scene value of luminance 1.2 * 2^EV100 cd/m^2 maps to exactly 1 and +1 EV halves the output; the EV100 at which the sunlit white maps to 1 is log2(100,000/pi/1.2) = about 14.7; for an average radiance a: EV = log2(cd(a) * 100 / 12.5) so the average lands at 12.5/(100 * 1.2), about a tenth of the display range. A black average answers EV 0.
- **Instructions:** `lightLog2` and `lightExp2` (R-49).
- **Cost:** O(1) per frame.
- **Why this and not another:** header cites the saturation-based exposure of Lagarde and de Rousiers 2014 (Frostbite).
- **Where:** `light/light_units.axle:21-28,85-118`; `scene/scene_frame.axle:70`.
- **Docs:** `doc/spec/lighting-math.md:100-105` (differs from the code: see Doubts).

### R-67. I want bright light to roll off to white without changing the colour of mid-tones
- **Means:** a tone curve applied to the largest channel, the other channels following with the same scale, so hue and saturation are kept and no channel exceeds 1.
- **Mathematics:** with knee k in [0.01, 0.99] (default 0.6) and m the largest channel: T(m) = m for m <= k, else k + (1 - k)(1 - exp(-(m - k)/(1 - k))); the colour is scaled by T(m)/m. T(0) = 0, T increasing, T < 1, C1 at the knee (T'(k) = 1 on both sides; the second derivative jumps from 0 to -1/(1 - k)).
- **Instructions:** one `lightExp` (an f64 series) per pixel and one division by m (guarded: m > 0).
- **Cost:** about 14 + 11 loop steps per pixel (R-49). The path-lit display replaces this by a 4097-entry table over m in 0..40 read linearly (`08-display.md:76-86`), because this version is the exact reference.
- **Why this and not another:** header: "below the knee the picture is untouched, which keeps mid-tones linear".
- **Where:** `light/light_color.axle:1-40,43-62`.
- **Docs:** `doc/spec/lighting-math.md:93-98`; `doc/handbook/render/08-display.md:76-86`.

### R-68. I want the exact sRGB transfer, round-trip safe at 8 bits
- **Means:** IEC 61966-2-1 piecewise encode/decode with `lightPow` for the 2.4 power; 8-bit pair rounds to nearest.
- **Mathematics:** encode(x) = 12.92 x for x <= 0.0031308, else 1.055 x^(1/2.4) - 0.055; decode(y) = y/12.92 for y <= 0.04045, else ((y + 0.055)/1.055)^2.4. encode8(decode8(i)) = i for every i in 0..255 (header: exact bijection); relative accuracy of `lightPow` about 1e-7.
- **Instructions:** one `lightPow` (log2 series + exp2 series) per channel.
- **Cost:** 3 `lightPow` per output pixel in `Resolve` plus 3 `lightPow` per decoded texel at texture load (a LUT of 256 hides the latter at runtime). The pathlight display uses a table indexed by sqrt(x) instead (`08-display.md:88-100`).
- **Why this and not another:** header: "Differences from voxel-axle: its `gamma` used a table and a global power; here the maths is closed form."
- **Where:** `light/light_color.axle:1-18,70-102`; `cpu/cpu_renderer.axle:359-384`.
- **Docs:** `doc/spec/lighting-math.md:93-98`; `doc/handbook/render/08-display.md:88-100`.

---

## The analytic sky (`light/light_sky.axle`)

### R-69. I want the optical depth of an atmosphere along any ray, exactly, with no ray march
- **Means:** the Chapman function by Gauss-Legendre quadrature on panels that follow the decay of its integrand.
- **Mathematics:** for a species with scale height H and density rho0: tau = beta rho0 H exp(-h/H) Ch(X, chi), X = (R + h)/H, and Ch(X, chi) = integral_0^inf exp(X - sqrt(X^2 + 2 X s cos chi + s^2)) ds (s in scale heights): the optical depth towards space in units of the vertical optical depth at the point; Ch(X, 0) = 1; about 1/cos chi for a small angle; about sqrt(pi X/2) at the horizon (all in the file). The integral is cut where the exponent has fallen by 45 (e^-45 = 3e-20): reach = -X c + sqrt(X^2 c^2 + 90 X + 45^2), c = max(cos chi, 0); five panels with edges 0, reach/64, reach/16, reach/4, reach/2, reach, each 16 Gauss-Legendre nodes. Rayleigh: scale height 8 km, beta = (5.802, 13.558, 33.1) per megametre (about lambda^-4); Mie: 1.2 km, scatter 3.996 and extinction 4.44 per megametre, grey; planet radius 6,371 km, atmosphere top 80 km (coefficients after Hillaire 2020 per the code).
- **Instructions:** f64 throughout; `lightExp2D` for the exponential; nodes computed once per sky (`LightGauss(16)`).
- **Cost:** 5 x 16 = 80 integrand evaluations (an `exp2` series and a square root) per call. Measured elsewhere: the radiance integral over this model costs 0.16 ms a direction, 1.3 s for a 128 x 64 grid on one thread (`doc/handbook/render/06-sky.md:25-27`). Checks (suite, header): Chapman against a million-step trapezoid, secant law at small angles, the right-angle asymptotic series, continuity across the identity of R-70.
- **Why this and not another:** header: "evaluated by Gauss-Legendre quadrature of that integral on panels that follow its decay, with no march and no noise".
- **Where:** `light/light_sky.axle:1-26,38-62,152-179`.
- **Docs:** `doc/spec/lighting-math.md:66-68`; `doc/handbook/render/06-sky.md:25-27` (the consumer, not the maths).

### R-70. I want the optical depth along a ray that first descends (past the horizon) and a test for rays the ground blocks
- **Means:** an exact identity reduces a downward ray to two upward integrals; a ray whose lowest point is below the ground is blocked.
- **Mathematics:** Ch(X, chi) = 2 exp(X - X sin chi) Ch(X sin chi, pi/2) - Ch(X, pi - chi) for chi beyond a right angle; blocked (answer -1, transmittance 0) when X sin chi < X_ground = R/H.
- **Instructions:** two `lskyChapmanUp` calls and one exponential.
- **Cost:** 160 integrand evaluations for a descending ray (derived).
- **Why this and not another:** not documented beyond the header.
- **Where:** `light/light_sky.axle:8-12,181-200,248-259`.
- **Docs:** `doc/spec/lighting-math.md:66-68` (names the Chapman function only).

### R-71. I want the colour of the sky along a view ray, with the right blue, red and extinction
- **Means:** single scattering integrated along the view ray with a fixed Gauss-Legendre rule and cubic spacing; each sample takes the body's light attenuated on the way in, the scattering at that altitude and the loss on the way to the eye.
- **Mathematics:** L = integral over s of E_top T(bodyTau + eyeTau - viewTau) (beta_R rho_R P_R + beta_M rho_M P_M) ds, tau per channel = beta_R * (R-depth) + beta_Mext * (M-depth), T = exp(-tau). Rayleigh phase P_R = 3/(16 pi) (1 + cos^2); Cornette-Shanks phase for Mie with g = 0.76: P_M = 3/(8 pi) (1 - g^2)(1 + cos^2) / ((2 + g^2)(1 + g^2 - 2 g cos)^1.5). Sample spacing s = reach t^3, ds = reach 3 t^2 w, t the Gauss node on [0, 1]; the points where the sun is hidden by the ground contribute nothing.
- **Instructions:** per sample 4 Chapman calls (body and view direction, Rayleigh and Mie), 2 density exponentials; the view-ray rule `LightGauss(samples)` is built on every call.
- **Cost:** default 24 samples (`LSKY_VIEW_SAMPLES`), so about 24 x 4 x 80 = 7,680 + 160 integrand evaluations per body, and `skyRadianceWith` integrates the sun and the moon: about 15,700 (derived). Measured: 0.16 ms a direction (`06-sky.md:25-27`). Hence the sky is baked, not evaluated per pixel.
- **Why this and not another:** the cubic spacing "packs the samples where the air is thick, near the eye" (comment).
- **Where:** `light/light_sky.axle:1-26,110-150,292-364,371-380`.
- **Docs:** `doc/spec/lighting-math.md:66-68`; `doc/handbook/render/06-sky.md:25-30` (see Doubts for the sample count).

### R-72. I want the sun and the moon as lights whose strength and tint follow from the same atmosphere
- **Means:** the sun's top-of-atmosphere irradiance is normalised so that the overhead sun delivers exactly the reference sun; its tint at the eye is the transmittance (sunsets redden by construction); the moon is the same model at a fixed ratio with a cool tint, always opposite the sun; a floor of starlight.
- **Mathematics:** E_top = pi / max(T_overhead(green), 1e-6) with the overhead transmittance from the eye's altitude (default 2 m); sun light = directional light with colour irradiance/peak, lux = sceneToLux(peak), diameter 2 * 0.004650 rad; moon ratio 2.5e-6, radius 0.004540 rad, tint (0.8, 0.9, 1.15); starlight 6e-8 * (0.8, 0.9, 1.2); `atDayTime(t)` puts the sun at angle (t - 0.25) * 2 pi (sunrise at 0.25).
- **Instructions:** one transmittance (2 Chapman calls) per light per frame, so negligible.
- **Cost:** O(1) per frame.
- **Why this and not another:** header: "the sky, the sun disc and the `LightSource` for the sun are one consistent model".
- **Where:** `light/light_sky.axle:14-19,52-58,70-78,211-289`.
- **Docs:** `doc/spec/lighting-math.md:66-68`; `doc/handbook/render/06-sky.md` (consumer).

### R-73. I want a ground seen below the horizon and visible sun and moon discs that integrate to the right irradiance
- **Means:** a Lambertian ground lit by the sun and by the sky at a flattened mirrored direction; discs added to the radiance with a scale that returns the irradiance when integrated.
- **Mathematics:** L_ground = (E_sun max(sun.y, 0) + pi L_sky(mirror)) * albedo/pi with albedo 0.25 by default and the mirrored direction (x, -0.05 y, z) normalised (a flat ground sees most of the sky near the horizon); a disc of angular radius r has radiance E/(pi sin^2 r), so integrating it over the disc gives E; a direction is in the disc when dir . axis >= cos r.
- **Instructions:** one extra sky evaluation for ground directions; a dot product and a comparison per body for the discs.
- **Cost:** a ground ray costs one sky ray (about 15,700 `exp2` series: derived).
- **Why this and not another:** not documented (the 0.05 flatten is an unexplained constant beyond its comment).
- **Where:** `light/light_sky.axle:70-82,382-426`.
- **Docs:** `doc/handbook/render/06-sky.md` (consumer); MISSING for the ground model.

### R-74. I want the sky dome as an ambient term, without the sun and moon counted twice
- **Means:** `LightSky::ambient(bands)`: project the dome with its discs switched off (they are lights) through R-62; `faceLight` returns direct and ambient for a white Lambertian normal.
- **Mathematics:** direct = (E_sun max(n.sun, 0) + E_moon max(n.moon, 0)) / pi; ambient = dome.irradiance(n).
- **Instructions:** builds a second `LightSky` of the same sun with `discs = false` because a trait object cannot be a view of `self` (comment).
- **Cost:** 2 bands^2 sky evaluations: 2,048 x 0.16 ms, about 0.33 s for 32 bands (derived from the measured figure of R-69; not measured as a whole).
- **Why this and not another:** header of the method.
- **Where:** `light/light_sky.axle:428-448`.
- **Docs:** `doc/spec/lighting-math.md:61-68`.

---

## Missing documentation

| mechanism | file | what is not written down |
|---|---|---|
| CPU rasteriser setup: clip planes, guard band, 1/256 snap, record layout (176 B per triangle), counting-sort binning | `cpu/cpu_tris.axle` | only one paragraph (`doc/spec/rendering.md:83-88`); no formulas, memory, or reason for the 4x guard band |
| Tile kernel: edge-function stepping, top-left rule, depth interpolation, deferred shading, mask and blend paths | `cpu/cpu_kernel.axle` | one sentence each in `doc/spec/rendering.md:84-86`; no costs, no per-pixel memory |
| Perspective-correct weights, footprint finite differences, up-to-8-tap anisotropic filter, normal-map tangent frame | `cpu/cpu_surface.axle` | nothing outside the header |
| BVH: median split on a fixed-point key, build complexity, slab and Moller-Trumbore tests, stack bounds | `cpu/cpu_bvh.axle` | one clause "median-split BVH" (`doc/spec/rendering.md:87`) |
| Shadow bias formula, 1e9 directional length, -0.05 horizon margin | `cpu/cpu_shadow.axle` | header only |
| Command codec: field checks, 1e8 cap, float round-trip rules | `cmd/cmd_codec.axle` | `doc/spec/rendering.md:48-50` gives layout and -0 only |
| Graph compiler: complexities, strict `<` aliasing rule, equal-size class sharing, 128-issue cap | `graph/graph_plan.axle` | `doc/spec/rendering.md:52-63` states rules, no costs, no memory table |
| Mip chain: alpha-weighted mean, odd sizes, 21.3 B per texel, trilinear level selection | `texture/texture.axle` | nothing |
| Extraction sort key layout (20-bit fields, 2^62 blend flag, 1/16-unit depth steps) | `scene/scene_extract.axle` | `doc/spec/rendering.md:30-31` states the order, not the key |
| Deterministic exp2/log2/pow: series lengths, error bounds, the "shading subset" rules | `light/light_math.axle` | `doc/spec/lighting-math.md:90-91` one line; the 8 subset rules only in the header |
| DFG derivation (half-vector domain, horizon band, cosine substitution), build cost, accuracy figures | `light/light_dfg.axle` | `doc/spec/lighting-math.md:45-47` gives the idea; figures only in the header |
| Gauss-Legendre rule computed by Newton | `light/light_quadrature.axle` | `doc/spec/lighting-math.md:88` says tabulated |
| Chapman panels and cut, view-ray rule, sun normalisation, ground model | `light/light_sky.axle` | `doc/spec/lighting-math.md:66-68` names the method; `06-sky.md` only quotes cost |
| VNDF sampling and its checks | `light/light_vndf.axle` | `doc/spec/lighting-math.md:48-49` one line |
| Specular ambient blend of sky and ground by roughness | `cpu/cpu_kernel.axle` | nothing |
| Procedural mesh counts and layouts | `scene/scene_shapes.axle` | nothing |

## Doubts

- `light/light_sky.axle:15` says the view ray uses "a fixed Gauss-Legendre rule (32 nodes, cubic spacing)", but `LSKY_VIEW_SAMPLES` is 24 (`:68`) and the method doc says "order 24" (`:391`) and "16..48" (`:369`); 32 is not the default.
- `light/light_irradiance.axle:55-71` documents `LightReason` as "Tested in this order" with the enum order None, Range, Mask, Excluded, Backface, Cone, Shadow; the code tests excluded, mask, range (`:224-236`), then cone, then backface (`:278-293`), and the doc of `lightIncidence` (`:245-249`) says "excluded, mask, range, cone, backface". The enum comment is stale (range, mask and excluded are in the wrong order and cone and backface are swapped).
- `light/light_irradiance.axle:178-182` records that `doc/spec/lighting-math.md:28` ("C1 at the inner edge") is contradicted by the maths; the doc was not corrected.
- `doc/spec/lighting-math.md:63-65` says SH projection is by "an equal-area grid"; `light/light_sh.axle:5-7` states the shipped rule is Gauss-Legendre x trapezoid because the midpoint rule on that grid measured 3e-4 off.
- `doc/spec/lighting-math.md:88-89` says Gauss-Legendre "nodes tabulated"; `light/light_quadrature.axle:1-11` computes them by Newton's method and says tabulated nodes are the thing to avoid.
- `doc/spec/lighting-math.md:45-47` says the albedo table is "stored as an asset"; `cpu/cpu_renderer.axle:114` builds it by quadrature at construction (24 x 24, order 48 by default) and `light/light_dfg.axle:13` says shaders "receive it as a texture".
- `doc/spec/lighting-math.md:12-13` promises a 683 lm/W constant "kept in one constant"; `light/light_units.axle` has none (the scale is pi / 100,000, `:17,38-40`).
- `doc/spec/lighting-math.md:100-105` gives `exposure = 1/(1.2 * 2^EV100)` and a q = 0.65 derivation; `light/light_units.axle:97-100` computes `(100000/pi) / (1.2 * 2^EV)`, so the documented value differs by the scale factor 31,831; the auto-exposure histogram of the same section is not in this zone.
- `scene/scene_material.axle:40` says the normal map is "stored linearly in 0..1", but `Texture` decodes every texture as sRGB (`texture/texture.axle:1-8,95-110`) and `cpu/cpu_surface.axle:383-390` re-encodes; the chain of mips is therefore averaged after an sRGB decode, which is not the average of the encoded vectors, and no comment says this is accepted.
- `texture/texture.axle:112-131`: a level has size `n/2` (integer division) and averages the blocks at 2x..2x+1, so the last row or column of an odd-sized level never contributes to the next level (for 5 texels the fifth is dropped); the header says only "averaging 2 x 2 texels".
- `scene/scene_extract.axle:48-56,190-193`: material, mesh and entity slot are masked to 20 bits in the sort key, so ids at or above 1,048,576 alias silently (only the order is affected); not mentioned in the header.
- `scene/scene_camera.axle:19,96-103`: `lookAt` tests `side.lengthSquared() < 0.5` after `normalizedOr`, which presumably returns a unit vector or the unit fallback, so the branch looks unreachable (`normalizedOr` semantics are in `core/math`, not read: `UNVERIFIED`).
- `scene/scene_frame.axle:19-23` repeats the tone knee 0.6 and the SH constant Y00 that `light/light_color.axle:25` and `light/light_sh.axle:25` define: three copies of a named number.
- `light/light_source.axle:181-184` (`mayLight`) duplicates the layer and exclusion test of `lirrFilter` (`light/light_irradiance.axle:224-236`); the two can drift apart (whether `mayLight` is called anywhere: `UNVERIFIED`).
- `cpu/cpu_tris.axle:71-72` says five planes give "at most ten" vertices; a triangle gains at most one vertex per plane, so at most 8; the constant 10 is safe but the comment is looser than the arithmetic.
- `light/light_math.axle:49` says repeated squaring takes "at most 10 steps for |n| <= 1023" while the loop runs 11 iterations (`:41,58`); harmless.
- `cmd/cmd_codec.axle:67` reserves `CMDC_CRC + CMDC_CRC` bytes for one checksum; harmless slack, probably a typo.

## Summary

74 entries cover the command stream and codec (R-01..R-04), CPU triangle setup, clipping, snapping and binning (R-05..R-10), the tile rasteriser (R-11..R-17), surface evaluation and texturing including mip chain and anisotropic taps (R-18..R-26), shadow rays and the BVH (R-27..R-32), the render graph from validation to memory aliasing and recording (R-33..R-41), the explainer (R-42), scene extraction and camera (R-43..R-48), and the lighting library (R-49..R-74: deterministic exp/log/pow, Gauss-Legendre, GGX/Smith/Schlick, multiple scattering, the DFG table, Burley, VNDF, sphere/disc/directional irradiance, range and cone, SH9, units and exposure, tone curve, sRGB, the Chapman-function sky). Every formula and constant was read in the cited file. Not verified because the callee lies outside the zone: the matrix constructors (`Mat4::perspective/ortho`, `normalMatrix`), `Frustum`/`Aabb` tests, `Crc32`, `StringInterner` complexity, `Image` storage, the f32 `sin/cos/acos/atan` implementations, and who calls `lightVndfSample`. Costs marked "derived" were obtained by counting loops and array sizes in the code, not by measurement; the only measured figures quoted are the sky integral (0.16 ms a direction, 1.3 s for 128 x 64, from `doc/handbook/render/06-sky.md`) and the accuracy figures printed in file headers (suite results), which were not re-run.
